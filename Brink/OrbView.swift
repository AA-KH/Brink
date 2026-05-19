import SwiftUI

// MARK: - Orb View

struct OrbView: View {
    let riskLevel: RiskLevel
    let riskScore: Double

    @State private var isPulsing = false
    @State private var ringScale: CGFloat = 1.0
    @State private var ringOpacity: Double = 0.6
    @State private var innerGlowOpacity: Double = 0.4

    private let orbSize: CGFloat = 220

    var body: some View {
        ZStack {
            expandingRing
            outerGlow
            coreOrb
            innerSheen
        }
        .frame(width: orbSize * 2, height: orbSize * 2)
        .onAppear { startAnimations() }
        .onChange(of: riskLevel) { _ in restartAnimations() }
    }

    // MARK: - Layers

    private var expandingRing: some View {
        Circle()
            .strokeBorder(
                riskLevel.primaryColor.opacity(0.35),
                lineWidth: riskLevel >= .medium ? 1.5 : 0.8
            )
            .frame(width: orbSize + 60, height: orbSize + 60)
            .scaleEffect(ringScale)
            .opacity(ringOpacity)
    }

    private var outerGlow: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        riskLevel.primaryColor.opacity(isPulsing ? 0.22 : 0.08),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: orbSize * 0.85
                )
            )
            .frame(width: orbSize * 1.7, height: orbSize * 1.7)
            .scaleEffect(isPulsing ? 1.08 : 0.95)
    }

    private var coreOrb: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        riskLevel.primaryColor.opacity(isPulsing ? 0.28 : 0.18),
                        Color.brinkSurface.opacity(0.96),
                        Color.brinkBackground
                    ],
                    center: UnitPoint(x: 0.38, y: 0.34),
                    startRadius: 0,
                    endRadius: orbSize * 0.6
                )
            )
            .frame(width: orbSize, height: orbSize)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                riskLevel.primaryColor.opacity(isPulsing ? 0.55 : 0.28),
                                riskLevel.primaryColor.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            )
            .shadow(
                color: riskLevel.primaryColor.opacity(isPulsing ? 0.38 : 0.12),
                radius: isPulsing ? 36 : 18
            )
    }

    private var innerSheen: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity(innerGlowOpacity),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 40
                )
            )
            .frame(width: 80, height: 50)
            .offset(x: -28, y: -42)
            .blendMode(.screen)
    }

    // MARK: - Animation Control

    private func startAnimations() {
        withAnimation(riskLevel.pulseSpeed) {
            isPulsing = true
        }
        startRingAnimation()
        withAnimation(BrinkAnimation.orbBreath.delay(0.4)) {
            innerGlowOpacity = riskLevel == .safe ? 0.12 : 0.22
        }
    }

    private func restartAnimations() {
        isPulsing = false
        withAnimation(BrinkAnimation.stateTransition) {
            isPulsing = true
        }
        withAnimation(riskLevel.pulseSpeed) {
            isPulsing = true
        }
        startRingAnimation()
    }

    private func startRingAnimation() {
        guard riskLevel >= .low else {
            ringScale = 1.0
            ringOpacity = 0.3
            return
        }

        ringScale = 1.0
        ringOpacity = 0.6
        withAnimation(
            Animation.easeOut(duration: riskLevel == .high ? 0.7 : 1.2)
                .repeatForever(autoreverses: false)
        ) {
            ringScale = 1.35
            ringOpacity = 0.0
        }
    }
}

// MARK: - Orb Label

struct OrbLabelView: View {
    let riskLevel: RiskLevel
    let riskScore: Double

    var body: some View {
        VStack(spacing: BrinkSpacing.xs) {
            Text(riskLevel.label.uppercased())
                .font(BrinkFont.label(12))
                .tracking(3.5)
                .foregroundColor(riskLevel.primaryColor)

            Text(riskLevel.sublabel)
                .font(BrinkFont.body(14))
                .foregroundColor(.brinkTextSecondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Previews

#Preview {
    ZStack {
        Color.brinkBackground.ignoresSafeArea()
        VStack(spacing: 40) {
            OrbView(riskLevel: .safe, riskScore: 0.1)
            OrbLabelView(riskLevel: .safe, riskScore: 0.1)
        }
    }
}
