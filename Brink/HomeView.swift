import SwiftUI

// MARK: - Home View

struct HomeView: View {
    @EnvironmentObject var vm: MotionViewModel
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showDebugMenu = false

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, BrinkSpacing.lg)
                    .padding(.top, BrinkSpacing.sm)

                Spacer()

                orbSection

                Spacer()

                sensorReadout
                    .padding(.horizontal, BrinkSpacing.lg)

                sensitivityControl
                    .padding(.horizontal, BrinkSpacing.lg)
                    .padding(.top, BrinkSpacing.lg)

                historyStrip
                    .padding(.top, BrinkSpacing.lg)
                    .padding(.bottom, BrinkSpacing.xl)
            }

            // Alert overlay
            if vm.showAlert, let event = vm.activeAlertEvent {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .transition(.opacity)

                AlertSheetView(event: event, onDismiss: vm.dismissAlert)
                    .transition(.move(edge: .bottom))
                    .zIndex(10)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(vm)
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
                .environmentObject(vm)
        }
        .animation(BrinkAnimation.stateTransition, value: vm.showAlert)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color.brinkBackground.ignoresSafeArea()

            // Ambient risk color bleed
            RadialGradient(
                colors: [
                    vm.riskLevel.primaryColor.opacity(0.07),
                    Color.clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: 320
            )
            .ignoresSafeArea()
            .animation(BrinkAnimation.stateTransition, value: vm.riskLevel)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // Wordmark
            Text("BRINK")
                .font(BrinkFont.label(15))
                .tracking(5)
                .foregroundColor(.brinkTextPrimary)

            Spacer()

            HStack(spacing: BrinkSpacing.md) {
                // Monitoring status dot
                monitoringBadge

                // Settings button
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .light))
                        .foregroundColor(.brinkTextSecondary)
                }

                // Debug / demo menu (long-press wordmark, handled here as button)
                Button {
                    showDebugMenu = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .light))
                        .foregroundColor(.brinkTextTertiary)
                }
                .confirmationDialog("Demo — Simulate Risk", isPresented: $showDebugMenu) {
                    Button("Safe")   { vm.simulateRiskEvent(.safe) }
                    Button("Low")    { vm.simulateRiskEvent(.low) }
                    Button("Medium") { vm.simulateRiskEvent(.medium) }
                    Button("High")   { vm.simulateRiskEvent(.high) }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
    }

    private var monitoringBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(vm.isMonitoring ? Color.brinkSafe : Color.brinkTextTertiary)
                .frame(width: 6, height: 6)

            Text(vm.isMonitoring ? "Active" : "Paused")
                .font(BrinkFont.label(11))
                .tracking(1.5)
                .foregroundColor(vm.isMonitoring ? .brinkSafe : .brinkTextTertiary)
        }
        .padding(.horizontal, BrinkSpacing.sm)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.brinkSurface)
                .overlay(Capsule().strokeBorder(Color.brinkBorder, lineWidth: 1))
        )
    }

    // MARK: - Orb Section

    private var orbSection: some View {
        VStack(spacing: BrinkSpacing.lg) {
            OrbView(riskLevel: vm.riskLevel, riskScore: vm.riskScore)
            OrbLabelView(riskLevel: vm.riskLevel, riskScore: vm.riskScore)
        }
    }

    // MARK: - Sensor Readout

    private var sensorReadout: some View {
        HStack(spacing: 0) {
            readoutCell(
                label: "ACCEL",
                value: String(format: "%.3f", vm.motionReading.accelerationMagnitude),
                unit: "g"
            )

            readoutDivider

            readoutCell(
                label: "GYRO",
                value: String(format: "%.2f", vm.motionReading.rotationMagnitude),
                unit: "r/s"
            )

            readoutDivider

            readoutCell(
                label: "STAB",
                value: String(format: "%.0f", vm.motionReading.stabilityScore * 100),
                unit: "%"
            )

            readoutDivider

            readoutCell(
                label: "RISK",
                value: String(format: "%.0f", vm.riskScore * 100),
                unit: "%",
                valueColor: vm.riskLevel.primaryColor
            )
        }
        .padding(.vertical, BrinkSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.brinkSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.brinkBorder, lineWidth: 1)
                )
        )
    }

    private func readoutCell(
        label: String,
        value: String,
        unit: String,
        valueColor: Color = .brinkTextPrimary
    ) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(BrinkFont.mono(9))
                .tracking(2)
                .foregroundColor(.brinkTextTertiary)

            HStack(alignment: .lastTextBaseline, spacing: 1) {
                Text(value)
                    .font(BrinkFont.mono(18))
                    .foregroundColor(valueColor)
                    .contentTransition(.numericText())

                Text(unit)
                    .font(BrinkFont.mono(9))
                    .foregroundColor(.brinkTextTertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var readoutDivider: some View {
        Rectangle()
            .fill(Color.brinkBorder)
            .frame(width: 1, height: 36)
    }

    // MARK: - Sensitivity Control

    private var sensitivityControl: some View {
        HStack(spacing: BrinkSpacing.xs) {
            ForEach(SensitivityLevel.allCases) { level in
                Button {
                    withAnimation(BrinkAnimation.standard) {
                        vm.sensitivity = level
                    }
                } label: {
                    Text(level.rawValue)
                        .font(BrinkFont.label(12))
                        .tracking(0.5)
                        .foregroundColor(vm.sensitivity == level ? .brinkTextPrimary : .brinkTextTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BrinkSpacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(
                                    vm.sensitivity == level
                                    ? Color.brinkSurfaceRaised
                                    : Color.clear
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(
                                            vm.sensitivity == level
                                            ? Color.brinkBorder
                                            : Color.clear,
                                            lineWidth: 1
                                        )
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(BrinkSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.brinkSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.brinkBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - History Strip

    private var historyStrip: some View {
        VStack(alignment: .leading, spacing: BrinkSpacing.sm) {
            HStack {
                Text("RECENT")
                    .font(BrinkFont.mono(10))
                    .tracking(2.5)
                    .foregroundColor(.brinkTextTertiary)

                Spacer()

                Button {
                    showHistory = true
                } label: {
                    Text("All")
                        .font(BrinkFont.label(12))
                        .foregroundColor(.brinkTextSecondary)
                }
            }
            .padding(.horizontal, BrinkSpacing.lg)

            if vm.alertHistory.isEmpty {
                emptyHistoryRow
                    .padding(.horizontal, BrinkSpacing.lg)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BrinkSpacing.sm) {
                        ForEach(vm.alertHistory.prefix(5)) { event in
                            HistoryChip(event: event)
                        }
                    }
                    .padding(.horizontal, BrinkSpacing.lg)
                }
            }
        }
    }

    private var emptyHistoryRow: some View {
        HStack(spacing: BrinkSpacing.sm) {
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .light))
                .foregroundColor(.brinkTextTertiary)

            Text("No alerts yet — all clear")
                .font(BrinkFont.body(13))
                .foregroundColor(.brinkTextTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BrinkSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.brinkSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.brinkBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - History Chip

struct HistoryChip: View {
    let event: AlertEvent
    private var level: RiskLevel { event.riskLevelEnum }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(level.primaryColor)
                    .frame(width: 6, height: 6)

                Text(level.label.uppercased())
                    .font(BrinkFont.mono(9))
                    .tracking(1.5)
                    .foregroundColor(level.primaryColor)
            }

            Text(event.context)
                .font(BrinkFont.body(12))
                .foregroundColor(.brinkTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 130, alignment: .leading)

            Text(event.timeAgo)
                .font(BrinkFont.mono(10))
                .foregroundColor(.brinkTextTertiary)
        }
        .padding(BrinkSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.brinkSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(level.primaryColor.opacity(0.22), lineWidth: 1)
                )
        )
    }
}

// MARK: - Preview

#Preview {
    HomeView()
        .environmentObject(MotionViewModel())
}
