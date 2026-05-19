import SwiftUI
import CoreMotion

// MARK: - Calibration View

struct CalibrationView: View {
    @Binding var hasCompletedCalibration: Bool
    @EnvironmentObject var vm: MotionViewModel

    @State private var step: CalibrationStep = .welcome
    @State private var progress: Double = 0.0
    @State private var progressTimer: Timer? = nil
    @State private var stepAppeared = false

    enum CalibrationStep: Int, CaseIterable {
        case welcome    = 0
        case hold       = 1
        case surface    = 2
        case pocket     = 3
        case complete   = 4

        var title: String {
            switch self {
            case .welcome:  return "Welcome to Brink"
            case .hold:     return "Hold naturally"
            case .surface:  return "Set it down"
            case .pocket:   return "Pocket it"
            case .complete: return "You're all set"
            }
        }

        var instruction: String {
            switch self {
            case .welcome:
                return "Brink learns how you normally hold and use your phone, then watches for anything unusual. Let's calibrate in 3 quick steps."
            case .hold:
                return "Hold your phone the way you normally would — scrolling, relaxed in hand. Keep it still for a moment."
            case .surface:
                return "Place your phone face-up on the surface you use most — a desk, nightstand, or table. Hold for a moment."
            case .pocket:
                return "Slide your phone into your pocket or bag as you usually would. Keep it there for a moment."
            case .complete:
                return "Baseline recorded. Brink knows your normal. It will stay quiet until something unusual happens."
            }
        }

        var icon: String {
            switch self {
            case .welcome:  return "eyes"
            case .hold:     return "hand.raised"
            case .surface:  return "rectangle.on.rectangle.angled"
            case .pocket:   return "bag"
            case .complete: return "checkmark.seal"
            }
        }

        var capturesDuration: Double {
            switch self {
            case .hold, .surface, .pocket: return 3.0
            default: return 0
            }
        }

        var isCapture: Bool { capturesDuration > 0 }

        var accentColor: Color {
            switch self {
            case .complete: return .brinkSafe
            default:        return .brinkSafe
            }
        }

        var nextButtonLabel: String {
            switch self {
            case .welcome:  return "Start calibration"
            case .hold:     return "Start capture"
            case .surface:  return "Start capture"
            case .pocket:   return "Start capture"
            case .complete: return "Open Brink"
            }
        }
    }

    var body: some View {
        ZStack {
            Color.brinkBackground.ignoresSafeArea()

            backgroundGlow

            VStack(spacing: 0) {
                progressBar
                    .padding(.top, BrinkSpacing.xl)

                Spacer()

                iconArea

                Spacer()
                    .frame(height: BrinkSpacing.xl)

                textContent

                Spacer()

                actionArea
                    .padding(.horizontal, BrinkSpacing.lg)
                    .padding(.bottom, BrinkSpacing.xxl)
            }
        }
        .onChange(of: step) { _ in
            stepAppeared = false
            withAnimation(.easeOut(duration: 0.4)) {
                stepAppeared = true
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                stepAppeared = true
            }
        }
    }

    // MARK: - Background Glow

    private var backgroundGlow: some View {
        RadialGradient(
            colors: [Color.brinkSafe.opacity(0.06), Color.clear],
            center: .center,
            startRadius: 0,
            endRadius: 360
        )
        .ignoresSafeArea()
        .opacity(stepAppeared ? 1 : 0)
        .animation(BrinkAnimation.standard, value: stepAppeared)
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(CalibrationStep.allCases.dropLast(), id: \.rawValue) { s in
                Capsule()
                    .fill(
                        s.rawValue <= step.rawValue
                        ? Color.brinkSafe
                        : Color.brinkBorder
                    )
                    .frame(height: 3)
                    .animation(BrinkAnimation.stateTransition, value: step)
            }
        }
        .padding(.horizontal, BrinkSpacing.lg)
    }

    // MARK: - Icon Area

    private var iconArea: some View {
        ZStack {
            // Outer ring
            Circle()
                .strokeBorder(Color.brinkSafe.opacity(0.18), lineWidth: 1)
                .frame(width: 140, height: 140)

            // Inner fill
            Circle()
                .fill(Color.brinkSafe.opacity(0.08))
                .frame(width: 110, height: 110)

            // Icon
            Image(systemName: step.icon)
                .font(.system(size: 42, weight: .ultraLight))
                .foregroundColor(.brinkSafe)
                .opacity(stepAppeared ? 1 : 0)
                .scaleEffect(stepAppeared ? 1 : 0.7)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1), value: stepAppeared)

            // Capture progress ring
            if step.isCapture {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color.brinkSafe.opacity(0.6),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .frame(width: 140, height: 140)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: progress)
            }
        }
    }

    // MARK: - Text Content

    private var textContent: some View {
        VStack(spacing: BrinkSpacing.md) {
            Text(step.title)
                .font(BrinkFont.heading(26))
                .foregroundColor(.brinkTextPrimary)
                .multilineTextAlignment(.center)
                .opacity(stepAppeared ? 1 : 0)
                .offset(y: stepAppeared ? 0 : 12)
                .animation(.easeOut(duration: 0.4).delay(0.15), value: stepAppeared)

            Text(step.instruction)
                .font(BrinkFont.body(16))
                .foregroundColor(.brinkTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(stepAppeared ? 1 : 0)
                .offset(y: stepAppeared ? 0 : 8)
                .animation(.easeOut(duration: 0.4).delay(0.22), value: stepAppeared)
        }
        .padding(.horizontal, BrinkSpacing.xxl)
    }

    // MARK: - Action Area

    private var actionArea: some View {
        VStack(spacing: BrinkSpacing.md) {
            // Primary CTA
            Button {
                handlePrimaryTap()
            } label: {
                Text(progress > 0 && progress < 1.0 ? "Capturing…" : step.nextButtonLabel)
                    .font(BrinkFont.heading(16))
                    .foregroundColor(progress > 0 && progress < 1.0 ? Color.brinkTextTertiary : Color.brinkBackground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BrinkSpacing.md + 2)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(progress > 0 && progress < 1.0 ? Color.brinkSurface : Color.brinkSafe)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.brinkSafe.opacity(0.4), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(progress > 0 && progress < 1.0)
            .animation(BrinkAnimation.standard, value: progress)

            // Skip (not on complete)
            if step != .complete && step != .welcome {
                Button {
                    advanceStep()
                } label: {
                    Text("Skip this step")
                        .font(BrinkFont.body(14))
                        .foregroundColor(.brinkTextTertiary)
                        .padding(.vertical, BrinkSpacing.sm)
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(stepAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.4).delay(0.3), value: stepAppeared)
    }

    // MARK: - Logic

    private func handlePrimaryTap() {
        if step == .complete {
            hasCompletedCalibration = true
            return
        }

        if step.isCapture {
            guard progress == 0 else { return }
            startCapture()
        } else {
            advanceStep()
        }
    }

    private func startCapture() {
        let duration = step.capturesDuration
        let tickInterval = 0.05
        let totalTicks = Int(duration / tickInterval)
        var ticks = 0

        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { timer in
            ticks += 1
            DispatchQueue.main.async {
                progress = Double(ticks) / Double(totalTicks)
                if ticks >= totalTicks {
                    timer.invalidate()
                    progressTimer = nil
                    advanceStep()
                }
            }
        }
    }

    private func advanceStep() {
        let next = step.rawValue + 1
        guard let nextStep = CalibrationStep(rawValue: next) else { return }
        progress = 0
        withAnimation(BrinkAnimation.stateTransition) {
            step = nextStep
        }
    }
}

// MARK: - Preview

#Preview {
    CalibrationView(hasCompletedCalibration: .constant(false))
        .environmentObject(MotionViewModel())
}
