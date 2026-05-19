import SwiftUI

// MARK: - Color Palette

extension Color {
    static let brinkBackground     = Color(hex: "#0D0D0F")
    static let brinkSurface        = Color(hex: "#141418")
    static let brinkSurfaceRaised  = Color(hex: "#1C1C22")
    static let brinkBorder         = Color(hex: "#2A2A32")

    // State colors
    static let brinkSafe           = Color(hex: "#2ECBAD")
    static let brinkSafeGlow       = Color(hex: "#2ECBAD").opacity(0.18)
    static let brinkLow            = Color(hex: "#F5C842")
    static let brinkLowGlow        = Color(hex: "#F5C842").opacity(0.18)
    static let brinkMedium         = Color(hex: "#F5A623")
    static let brinkMediumGlow     = Color(hex: "#F5A623").opacity(0.22)
    static let brinkHigh           = Color(hex: "#E8391A")
    static let brinkHighGlow       = Color(hex: "#E8391A").opacity(0.28)

    // Text
    static let brinkTextPrimary    = Color(hex: "#F0EEE9")
    static let brinkTextSecondary  = Color(hex: "#7A7A82")
    static let brinkTextTertiary   = Color(hex: "#44444C")

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red:   Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Typography

struct BrinkFont {
    /// Large display numbers / orb label
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .thin, design: .default)
    }
    /// Section headers
    static func heading(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }
    /// Body / labels
    static func body(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }
    /// Monospaced data readouts
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
    /// Small caps label style
    static func label(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }
}

// MARK: - Spacing

enum BrinkSpacing {
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 24
    static let xl:  CGFloat = 32
    static let xxl: CGFloat = 48
}

// MARK: - Animation

enum BrinkAnimation {
    static let orbBreath      = Animation.easeInOut(duration: 3.2).repeatForever(autoreverses: true)
    static let orbPulse       = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    static let orbUrgent      = Animation.easeInOut(duration: 0.38).repeatForever(autoreverses: true)
    static let ringExpand     = Animation.easeOut(duration: 1.1).repeatForever(autoreverses: false)
    static let stateTransition = Animation.easeInOut(duration: 0.55)
    static let alertSlide     = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let standard       = Animation.easeInOut(duration: 0.3)
}

// MARK: - Risk Level Colors Helper

extension RiskLevel {
    var primaryColor: Color {
        switch self {
        case .safe:   return .brinkSafe
        case .low:    return .brinkLow
        case .medium: return .brinkMedium
        case .high:   return .brinkHigh
        }
    }

    var glowColor: Color {
        switch self {
        case .safe:   return .brinkSafeGlow
        case .low:    return .brinkLowGlow
        case .medium: return .brinkMediumGlow
        case .high:   return .brinkHighGlow
        }
    }

    var label: String {
        switch self {
        case .safe:   return "Watching"
        case .low:    return "Slight Risk"
        case .medium: return "Unstable"
        case .high:   return "Danger"
        }
    }

    var sublabel: String {
        switch self {
        case .safe:   return "All clear"
        case .low:    return "Minor motion detected"
        case .medium: return "Unstable position"
        case .high:   return "Fall risk detected"
        }
    }

    var pulseSpeed: Animation {
        switch self {
        case .safe:   return BrinkAnimation.orbBreath
        case .low:    return BrinkAnimation.orbBreath
        case .medium: return BrinkAnimation.orbPulse
        case .high:   return BrinkAnimation.orbUrgent
        }
    }
}
