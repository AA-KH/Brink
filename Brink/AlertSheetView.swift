import SwiftUI

// MARK: - Alert Sheet

struct AlertSheetView: View {
    let event: AlertEvent
    let onDismiss: () -> Void

    @State private var isVisible = false
    @State private var isPulsing = false

    private var level: RiskLevel { event.riskLevelEnum }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            sheetContent
                .offset(y: isVisible ? 0 : 120)
                .opacity(isVisible ? 1 : 0)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(BrinkAnimation.alertSlide) {
                isVisible = true
            }
            withAnimation(
                Animation.easeInOut(duration: 0.55).repeatForever(autoreverses: true)
            ) {
                isPulsing = true
            }
        }
    }

    // MARK: - Sheet Body

    private var sheetContent: some View {
        VStack(spacing: 0) {

            // Drag handle
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.brinkBorder)
                .frame(width: 36, height: 4)
                .padding(.top, BrinkSpacing.md)
                .padding(.bottom, BrinkSpacing.lg)

            // Icon + headline
            HStack(alignment: .top, spacing: BrinkSpacing.md) {
                alertIcon
                alertText
                Spacer()
            }
            .padding(.horizontal, BrinkSpacing.lg)

            // Separator
            Divider()
                .background(Color.brinkBorder)
                .padding(.vertical, BrinkSpacing.lg)
                .padding(.horizontal, BrinkSpacing.lg)

            // Risk score bar
            riskBar
                .padding(.horizontal, BrinkSpacing.lg)
                .padding(.bottom, BrinkSpacing.lg)

            // Dismiss button
            dismissButton
                .padding(.horizontal, BrinkSpacing.lg)
                .padding(.bottom, BrinkSpacing.xl)
        }
        .background(
            ZStack {
                Color.brinkSurface
                // Subtle color bleed at top
                VStack {
                    LinearGradient(
                        colors: [level.primaryColor.opacity(0.10), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 80)
                    Spacer()
                }
            }
        )
        .clipShape(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            level.primaryColor.opacity(isPulsing ? 0.45 : 0.20),
                            level.primaryColor.opacity(0.05)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: level.primaryColor.opacity(0.18), radius: 32, y: -8)
        .padding(.horizontal, BrinkSpacing.md)
    }

    // MARK: - Components

    private var alertIcon: some View {
        ZStack {
            Circle()
                .fill(level.primaryColor.opacity(0.14))
                .frame(width: 48, height: 48)

            Image(systemName: alertIconName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(level.primaryColor)
                .scaleEffect(isPulsing ? 1.08 : 1.0)
        }
    }

    private var alertIconName: String {
        switch level {
        case .safe:   return "checkmark"
        case .low:    return "exclamationmark"
        case .medium: return "exclamationmark.2"
        case .high:   return "exclamationmark.triangle.fill"
        }
    }

    private var alertText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(alertHeadline)
                .font(BrinkFont.heading(18))
                .foregroundColor(.brinkTextPrimary)

            Text(event.context)
                .font(BrinkFont.body(14))
                .foregroundColor(.brinkTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(event.timeAgo)
                .font(BrinkFont.mono(12))
                .foregroundColor(.brinkTextTertiary)
                .padding(.top, 2)
        }
    }

    private var alertHeadline: String {
        switch level {
        case .safe:   return "All clear"
        case .low:    return "Watch your phone"
        case .medium: return "Unstable position"
        case .high:   return "Fall risk detected"
        }
    }

    private var riskBar: some View {
        VStack(alignment: .leading, spacing: BrinkSpacing.sm) {
            HStack {
                Text("Risk level")
                    .font(BrinkFont.label(11))
                    .tracking(2)
                    .foregroundColor(.brinkTextTertiary)
                Spacer()
                Text(String(format: "%.0f%%", min(Double(level.rawValue) / 3.0, 1.0) * 100))
                    .font(BrinkFont.mono(11))
                    .foregroundColor(level.primaryColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.brinkBorder)
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [.brinkSafe, level.primaryColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: geo.size.width * CGFloat(level.rawValue) / 3.0,
                            height: 4
                        )
                }
            }
            .frame(height: 4)
        }
    }

    private var dismissButton: some View {
        Button(action: {
            withAnimation(BrinkAnimation.alertSlide) {
                isVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                onDismiss()
            }
        }) {
            Text("Got it")
                .font(BrinkFont.heading(16))
                .foregroundColor(level.primaryColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BrinkSpacing.md)
                .background(level.primaryColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(level.primaryColor.opacity(0.25), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.brinkBackground.ignoresSafeArea()
        AlertSheetView(
            event: AlertEvent(
                date: Date(),
                riskLevel: RiskLevel.high.rawValue,
                context: "Edge tilt — fall risk detected",
                dismissed: false
            ),
            onDismiss: {}
        )
    }
}
