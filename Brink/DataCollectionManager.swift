import Foundation
import UIKit
import Combine

// MARK: - RecordingLabel
//
// The seven event classes the ML model must distinguish.
// The class names here are canonical — they must match exactly the label
// strings in the Python training pipeline.

enum RecordingLabel: String, CaseIterable, Identifiable {
    case normalHold      = "normal_hold"
    case normalWalk      = "normal_walk"
    case intentionalRot  = "intentional_rotate"
    case surfaceStable   = "surface_stable"
    case preFallTilt     = "pre_fall_tilt"
    case preFallGrip     = "pre_fall_grip_slip"
    case preFallEdge     = "pre_fall_edge_slide"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normalHold:     return "Normal — Hold"
        case .normalWalk:     return "Normal — Walk"
        case .intentionalRot: return "Intentional Rotate"
        case .surfaceStable:  return "Surface — Stable"
        case .preFallTilt:    return "Pre-Fall — Tilt"
        case .preFallGrip:    return "Pre-Fall — Grip Slip"
        case .preFallEdge:    return "Pre-Fall — Edge Slide"
        }
    }

    /// Whether this label represents a dangerous class (positive training example).
    var isDangerClass: Bool {
        switch self {
        case .preFallTilt, .preFallGrip, .preFallEdge: return true
        default: return false
        }
    }
}

// MARK: - DataCollectionManager
//
// Records SensorSample streams from SensorPipeline into CSV files, one per
// session.  Each CSV row is one sample timestamped and labelled.  At the
// end of a session the file is saved to the app's Documents directory and
// can be exported via UIDocumentPickerViewController.
//
// Access: inject via SensorPipeline.  This class is intentionally not
// integrated into the production MotionViewModel — it is toggled on/off
// separately from the debug settings screen.
//
// Thread-safety: `startRecording` / `stopRecording` / `append` may be
// called from any queue.  All file I/O runs on `ioQueue`.

@MainActor
final class DataCollectionManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var currentLabel: RecordingLabel = .normalHold
    @Published private(set) var sampleCount: Int = 0
    @Published private(set) var sessionFiles: [URL] = []
    @Published private(set) var lastError: String? = nil

    // MARK: - Internal

    /// Serial queue for all file I/O — keeps disk writes off the main thread
    /// without needing async/await throughout.
    private let ioQueue = DispatchQueue(
        label: "com.brink.datacollection.io",
        qos: .utility
    )

    private var fileHandle: FileHandle? = nil
    private var currentFileURL: URL? = nil
    private var sessionStartDate: Date? = nil

    // MARK: - Public Interface

    /// Begin a new recording session with the given label.
    /// Creates a new CSV file and writes the header row.
    func startRecording(label: RecordingLabel) {
        guard !isRecording else { return }
        currentLabel = label
        sampleCount  = 0
        lastError    = nil

        let url = makeSessionURL(label: label)

        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.createCSVFile(at: url)
                Task { @MainActor in
                    self.currentFileURL   = url
                    self.sessionStartDate = Date()
                    self.isRecording      = true
                }
            } catch {
                Task { @MainActor in
                    self.lastError = "Failed to create file: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Stop the current recording session, flush and close the file.
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        let handle = fileHandle
        let url    = currentFileURL

        ioQueue.async { [weak self] in
            guard let self else { return }
            handle?.closeFile()
            Task { @MainActor in
                self.fileHandle      = nil
                self.currentFileURL  = nil
                self.sessionStartDate = nil
                if let url {
                    self.sessionFiles.insert(url, at: 0)
                }
            }
        }
        // ADD THIS:
        refreshFileList()
    }

    /// Append one sensor sample to the active recording.
    /// Safe to call from any queue; all work serialised on ioQueue.
    /// Silently no-ops when not recording.
    func append(sample: SensorSample, featureVector: FeatureVector?) {
        guard isRecording else { return }

        let label = currentLabel.rawValue
        let row   = makeCSVRow(sample: sample, featureVector: featureVector, label: label)

        ioQueue.async { [weak self] in
            guard let self, let handle = self.fileHandle else { return }
            if let data = (row + "\n").data(using: .utf8) {
                handle.write(data)
            }
            Task { @MainActor in
                self.sampleCount += 1
            }
        }
    }

    /// Change the label mid-session (useful for continuous recording with
    /// phase transitions, e.g. "walk then grip-slip").
    func changeLabel(_ newLabel: RecordingLabel) {
        guard isRecording else { return }
        currentLabel = newLabel
    }

    /// Delete a session file.
    func deleteFile(_ url: URL) {
        ioQueue.async { [weak self] in
            try? FileManager.default.removeItem(at: url)
            Task { @MainActor in
                self?.sessionFiles.removeAll { $0 == url }
            }
        }
    }

    /// Return all session CSV files in the Documents directory, sorted newest first.
    func refreshFileList() {
        ioQueue.async { [weak self] in
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: docs,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            ))?.filter { $0.pathExtension == "csv" }
             .sorted { url1, url2 in
                 let d1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                 let d2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                 return d1 > d2
             } ?? []

            Task { @MainActor in
                self?.sessionFiles = urls
            }
        }
    }

    // MARK: - Statistics

    var totalSamplesOnDisk: Int {
        // Rough estimate from file sizes (each row ≈ 350 bytes)
        sessionFiles.reduce(0) { acc, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return acc + Swift.max(0, (size - 512) / 350)  // subtract header
        }
    }

    // MARK: - Private: File Management

    private func makeSessionURL(label: RecordingLabel) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateStr = formatter.string(from: Date())
        let filename = "brink_\(label.rawValue)_\(dateStr).csv"
        return docs.appendingPathComponent(filename)
    }

    private func createCSVFile(at url: URL) throws {
        // Build header from FeatureVector canonical names plus raw sensor cols
        let rawCols = [
            "timestamp", "date",
            "acc_x", "acc_y", "acc_z",
            "rot_x", "rot_y", "rot_z",
            "pitch", "roll", "yaw",
            "grav_x", "grav_y", "grav_z",
            "pressure", "relative_altitude",
            "activity"
        ]
        let featureCols = FeatureVector.names.map { "f_\($0)" }
        let allCols = rawCols + featureCols + ["label"]
        let header  = allCols.joined(separator: ",")

        try (header + "\n").write(to: url, atomically: true, encoding: .utf8)
        fileHandle = try FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    private func makeCSVRow(
        sample: SensorSample,
        featureVector: FeatureVector?,
        label: String
    ) -> String {

        let dateStr = ISO8601DateFormatter().string(from: sample.date)

        var fields: [String] = [
            String(format: "%.6f", sample.timestamp),
            dateStr,
            fmt(sample.accX), fmt(sample.accY), fmt(sample.accZ),
            fmt(sample.rotX), fmt(sample.rotY), fmt(sample.rotZ),
            fmt(sample.pitch), fmt(sample.roll), fmt(sample.yaw),
            fmt(sample.gravX), fmt(sample.gravY), fmt(sample.gravZ),
            fmt(sample.pressure),
            fmt(sample.relativeAltitude),
            sample.activity.rawValue
        ]

        // Feature columns — empty string when window not yet full
        if let fv = featureVector {
            fields.append(contentsOf: fv.values.map { fmt($0) })
        } else {
            fields.append(contentsOf: Array(repeating: "", count: FeatureVector.count))
        }

        fields.append(label)

        return fields.joined(separator: ",")
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.8f", value)
    }
}

// MARK: - DataCollectionView
//
// A hidden debug UI presented via a gesture or Settings tap sequence.
// Not linked from any production navigation — it only appears when the
// developer explicitly triggers it.

import SwiftUI

struct DataCollectionView: View {
    @EnvironmentObject private var manager: DataCollectionManager
    @EnvironmentObject private var vm: MotionViewModel

    @State private var selectedLabel: RecordingLabel = .normalHold
    @State private var showExporter: Bool = false
    @State private var exportURL: URL? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.brinkBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: BrinkSpacing.lg) {
                        statusBanner
                        labelPicker
                        recordingControls
                        sampleStats
                        fileList
                    }
                    .padding(BrinkSpacing.lg)
                }
            }
            .navigationTitle("Data Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.brinkBackground, for: .navigationBar)
            .preferredColorScheme(.dark)
            .onAppear { manager.refreshFileList() }
            .sheet(isPresented: $showExporter) {
                if let url = exportURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    // MARK: - Subviews

    private var statusBanner: some View {
        HStack(spacing: BrinkSpacing.md) {
            Circle()
                .fill(manager.isRecording ? Color.brinkHigh : Color.brinkTextTertiary)
                .frame(width: 10, height: 10)
                .scaleEffect(manager.isRecording ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true),
                           value: manager.isRecording)

            Text(manager.isRecording
                 ? "RECORDING — \(manager.currentLabel.displayName)"
                 : "IDLE")
                .font(BrinkFont.mono(13))
                .foregroundColor(manager.isRecording ? .brinkHigh : .brinkTextTertiary)

            Spacer()

            Text("\(manager.sampleCount) samples")
                .font(BrinkFont.mono(11))
                .foregroundColor(.brinkTextSecondary)
        }
        .padding(BrinkSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.brinkSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            manager.isRecording ? Color.brinkHigh.opacity(0.4) : Color.brinkBorder,
                            lineWidth: 1
                        )
                )
        )
    }

    private var labelPicker: some View {
        VStack(alignment: .leading, spacing: BrinkSpacing.sm) {
            sectionHeader("CLASS LABEL")

            VStack(spacing: 1) {
                ForEach(RecordingLabel.allCases) { label in
                    Button {
                        if manager.isRecording {
                            manager.changeLabel(label)
                        } else {
                            selectedLabel = label
                        }
                    } label: {
                        HStack {
                            Circle()
                                .fill(label.isDangerClass ? Color.brinkHigh : Color.brinkSafe)
                                .frame(width: 8, height: 8)

                            Text(label.displayName)
                                .font(BrinkFont.body(14))
                                .foregroundColor(.brinkTextPrimary)

                            Spacer()

                            if selectedLabel == label || (manager.isRecording && manager.currentLabel == label) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.brinkSafe)
                            }
                        }
                        .padding(BrinkSpacing.md)
                        .background(
                            selectedLabel == label
                            ? Color.brinkSafe.opacity(0.07)
                            : Color.brinkSurface
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.brinkBorder, lineWidth: 1)
            )
        }
    }

    private var recordingControls: some View {
        HStack(spacing: BrinkSpacing.md) {
            if manager.isRecording {
                Button {
                    manager.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(BrinkFont.heading(15))
                        .foregroundColor(.brinkHigh)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BrinkSpacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.brinkHigh.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.brinkHigh.opacity(0.3), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    manager.startRecording(label: selectedLabel)
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .font(BrinkFont.heading(15))
                        .foregroundColor(.brinkBackground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BrinkSpacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.brinkHigh)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sampleStats: some View {
        HStack(spacing: 0) {
            statCell(label: "THIS SESSION", value: "\(manager.sampleCount)")
            Divider().background(Color.brinkBorder).frame(height: 36)
            statCell(label: "TOTAL FILES", value: "\(manager.sessionFiles.count)")
            Divider().background(Color.brinkBorder).frame(height: 36)
            statCell(label: "EST. SAMPLES", value: "\(manager.totalSamplesOnDisk)")
        }
        .padding(.vertical, BrinkSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.brinkSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.brinkBorder, lineWidth: 1)
                )
        )
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(BrinkFont.mono(8))
                .tracking(1.5)
                .foregroundColor(.brinkTextTertiary)

            Text(value)
                .font(BrinkFont.mono(18))
                .foregroundColor(.brinkTextPrimary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: BrinkSpacing.sm) {
            HStack {
                sectionHeader("SESSION FILES")
                Spacer()
                Button("Refresh") { manager.refreshFileList() }
                    .font(BrinkFont.label(12))
                    .foregroundColor(.brinkTextSecondary)
            }

            if manager.sessionFiles.isEmpty {
                Text("No session files yet.")
                    .font(BrinkFont.body(13))
                    .foregroundColor(.brinkTextTertiary)
                    .padding(.vertical, BrinkSpacing.md)
            } else {
                VStack(spacing: BrinkSpacing.sm) {
                    ForEach(manager.sessionFiles, id: \.absoluteString) { url in
                        SessionFileRow(
                            url: url,
                            onExport: {
                                exportURL = url
                                showExporter = true
                            },
                            onDelete: {
                                manager.deleteFile(url)
                            }
                        )
                    }
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(BrinkFont.mono(10))
            .tracking(2)
            .foregroundColor(.brinkTextTertiary)
    }
}

// MARK: - SessionFileRow

private struct SessionFileRow: View {
    let url: URL
    let onExport: () -> Void
    let onDelete: () -> Void

    var fileSize: String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        HStack(spacing: BrinkSpacing.md) {
            Image(systemName: "doc.text")
                .font(.system(size: 16, weight: .light))
                .foregroundColor(.brinkTextSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(BrinkFont.mono(11))
                    .foregroundColor(.brinkTextPrimary)
                    .lineLimit(1)

                Text(fileSize)
                    .font(BrinkFont.mono(10))
                    .foregroundColor(.brinkTextTertiary)
            }

            Spacer()

            Button(action: onExport) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .light))
                    .foregroundColor(.brinkSafe)
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .light))
                    .foregroundColor(.brinkHigh)
            }
        }
        .padding(BrinkSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.brinkSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.brinkBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - ShareSheet (UIActivityViewController wrapper)

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}
