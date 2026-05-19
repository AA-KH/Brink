import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var vm: MotionViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var showCalibration = false
    @State private var showClearConfirm = false
    @State private var quietHours: QuietHours = .default
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.brinkBackground.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: BrinkSpacing.lg) {
                        sensitivitySection
                        alertStyleSection
                        surfaceModeSection
                        quietHoursSection
                        calibrationSection
                        dangerSection
                        versionFooter
                    }
                    .padding(.horizontal, BrinkSpacing.lg)
                    .padding(.vertical, BrinkSpacing.lg)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.brinkBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(BrinkFont.label(15))
                        .foregroundColor(.brinkSafe)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear { quietHours = vm.quietHours }
        }
        .sheet(isPresented: $showCalibration) {
            CalibrationView(hasCompletedCalibration: .constant(true))
                .environmentObject(vm)
        }
    }
    
    // MARK: - Sensitivity Section
    
    private var sensitivitySection: some View {
        SettingsSection(title: "Detection", icon: "antenna.radiowaves.left.and.right") {
            VStack(spacing: BrinkSpacing.sm) {
                ForEach(SensitivityLevel.allCases) { level in
                    SensitivityRow(
                        level: level,
                        isSelected: vm.sensitivity == level,
                        onTap: { vm.sensitivity = level }
                    )
                }
            }
        }
    }
    
    // MARK: - Alert Style Section
    
    private var alertStyleSection: some View {
        SettingsSection(title: "Alert Style", icon: "bell") {
            VStack(spacing: 1) {
                ForEach(AlertStyle.allCases) { style in
                    AlertStyleRow(
                        style: style,
                        isSelected: vm.alertStyle == style,
                        onTap: { vm.alertStyle = style }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
    
    // MARK: - Surface Mode Section
    
    private var surfaceModeSection: some View {
        SettingsSection(title: "Surface Mode", icon: "square.3.layers.3d") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BrinkSpacing.sm) {
                    ForEach(SurfaceMode.allCases) { mode in
                        SurfaceModeChip(
                            mode: mode,
                            isSelected: vm.surfaceMode == mode,
                            onTap: { vm.surfaceMode = mode }
                        )
                    }
                }
            }
            
            if vm.surfaceMode != .auto {
                Text(vm.surfaceMode.description)
                    .font(BrinkFont.body(13))
                    .foregroundColor(.brinkTextSecondary)
                    .padding(.top, BrinkSpacing.xs)
            }
        }
    }
    
    // MARK: - Quiet Hours Section
    
    private var quietHoursSection: some View {
        SettingsSection(title: "Quiet Hours", icon: "moon") {
            VStack(spacing: BrinkSpacing.md) {
                Toggle(isOn: $quietHours.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suppress alerts")
                            .font(BrinkFont.body(15))
                            .foregroundColor(.brinkTextPrimary)
                        
                        Text("Alerts are silenced during set hours")
                            .font(BrinkFont.body(12))
                            .foregroundColor(.brinkTextSecondary)
                    }
                }
                .tint(.brinkSafe)
                .onChange(of: quietHours.isEnabled) { _ in
                    vm.quietHours = quietHours
                }
                
                if quietHours.isEnabled {
                    Divider().background(Color.brinkBorder)
                    
                    HStack {
                        quietTimePicker(label: "From", hour: $quietHours.startHour, minute: $quietHours.startMinute)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .light))
                            .foregroundColor(.brinkTextTertiary)
                        Spacer()
                        quietTimePicker(label: "To", hour: $quietHours.endHour, minute: $quietHours.endMinute)
                    }
                    .onChange(of: quietHours) { _ in
                        vm.quietHours = quietHours
                    }
                }
            }
        }
    }
    
    private func quietTimePicker(label: String, hour: Binding<Int>, minute: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(BrinkFont.label(11))
                .tracking(1.5)
                .foregroundColor(.brinkTextTertiary)
            
            DatePicker(
                "",
                selection: Binding(
                    get: {
                        Calendar.current.date(
                            bySettingHour: hour.wrappedValue,
                            minute: minute.wrappedValue,
                            second: 0,
                            of: Date()
                        ) ?? Date()
                    },
                    set: { date in
                        let cal = Calendar.current
                        hour.wrappedValue = cal.component(.hour, from: date)
                        minute.wrappedValue = cal.component(.minute, from: date)
                    }
                ),
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .colorScheme(.dark)
            .accentColor(.brinkSafe)
        }
    }
    
    // MARK: - Calibration Section
    
    private var calibrationSection: some View {
        SettingsSection(title: "Calibration", icon: "scope") {
            VStack(alignment: .leading, spacing: BrinkSpacing.sm) {
                Text("Re-run the calibration flow to update your personal motion baseline. Recommended after switching phone cases or environments.")
                    .font(BrinkFont.body(13))
                    .foregroundColor(.brinkTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Button {
                    showCalibration = true
                } label: {
                    Label("Recalibrate", systemImage: "arrow.clockwise")
                        .font(BrinkFont.label(14))
                        .foregroundColor(.brinkSafe)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, BrinkSpacing.md)
                        .padding(.horizontal, BrinkSpacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.brinkSafe.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.brinkSafe.opacity(0.2), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - Danger Section
    
    private var dangerSection: some View {
        SettingsSection(title: "Data", icon: "tray") {
            Button {
                showClearConfirm = true
            } label: {
                Label("Clear alert history", systemImage: "trash")
                    .font(BrinkFont.label(14))
                    .foregroundColor(.brinkHigh)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, BrinkSpacing.md)
                    .padding(.horizontal, BrinkSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.brinkHigh.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.brinkHigh.opacity(0.18), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .confirmationDialog(
                "Clear all alert history?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) { vm.clearHistory() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
    
    // MARK: - Version Footer
    
    private var versionFooter: some View {
        NavigationLink(destination: DataCollectionView().environmentObject(vm)) {
            VStack(spacing: BrinkSpacing.xs) {
                Text("BRINK")
                    .font(BrinkFont.label(11))
                    .tracking(4)
                    .foregroundColor(.brinkTextTertiary)
                
                Text("v1.0.0 — Before it falls.")
                    .font(BrinkFont.body(12))
                    .foregroundColor(.brinkTextTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BrinkSpacing.lg)
        }
        .buttonStyle(.plain)
    }
}
// MARK: - Settings Section Container

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: BrinkSpacing.md) {
            HStack(spacing: BrinkSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.brinkTextSecondary)

                Text(title.uppercased())
                    .font(BrinkFont.label(11))
                    .tracking(2)
                    .foregroundColor(.brinkTextSecondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(BrinkSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.brinkSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.brinkBorder, lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - Sensitivity Row

struct SensitivityRow: View {
    let level: SensitivityLevel
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: BrinkSpacing.md) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.brinkSafe : Color.brinkBorder,
                            lineWidth: 1.5
                        )
                        .frame(width: 20, height: 20)

                    if isSelected {
                        Circle()
                            .fill(Color.brinkSafe)
                            .frame(width: 10, height: 10)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(level.rawValue)
                        .font(BrinkFont.body(15))
                        .foregroundColor(isSelected ? .brinkTextPrimary : .brinkTextSecondary)

                    Text(level.description)
                        .font(BrinkFont.body(12))
                        .foregroundColor(.brinkTextTertiary)
                }

                Spacer()
            }
            .padding(.vertical, BrinkSpacing.sm)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Alert Style Row

struct AlertStyleRow: View {
    let style: AlertStyle
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: BrinkSpacing.md) {
                Image(systemName: style.icon)
                    .font(.system(size: 15, weight: .light))
                    .foregroundColor(isSelected ? .brinkSafe : .brinkTextSecondary)
                    .frame(width: 24)

                Text(style.rawValue)
                    .font(BrinkFont.body(15))
                    .foregroundColor(isSelected ? .brinkTextPrimary : .brinkTextSecondary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.brinkSafe)
                }
            }
            .padding(BrinkSpacing.md)
            .background(
                isSelected
                ? Color.brinkSafe.opacity(0.06)
                : Color.brinkSurface
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Surface Mode Chip

struct SurfaceModeChip: View {
    let mode: SurfaceMode
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: BrinkSpacing.sm) {
                Image(systemName: mode.icon)
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(isSelected ? .brinkSafe : .brinkTextSecondary)

                Text(mode.rawValue)
                    .font(BrinkFont.label(12))
                    .foregroundColor(isSelected ? .brinkTextPrimary : .brinkTextSecondary)
            }
            .frame(width: 72, height: 72)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        isSelected
                        ? Color.brinkSafe.opacity(0.10)
                        : Color.brinkSurfaceRaised
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.brinkSafe.opacity(0.4) : Color.brinkBorder,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(MotionViewModel())
}
