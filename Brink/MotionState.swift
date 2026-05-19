import Foundation

// MARK: - Risk Level

enum RiskLevel: Int, Comparable, CaseIterable {
    case safe   = 0
    case low    = 1
    case medium = 2
    case high   = 3

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Sensitivity

enum SensitivityLevel: String, CaseIterable, Identifiable {
    case low      = "Low"
    case balanced = "Balanced"
    case high     = "High"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .low:      return "Fewer alerts. Misses some minor risks."
        case .balanced: return "Recommended. Good accuracy, low noise."
        case .high:     return "More alerts. Catches edge cases earlier."
        }
    }

    var probabilityThreshold: Double {
        switch self {
        case .low:      return 0.92
        case .balanced: return 0.87
        case .high:     return 0.78
        }
    }
}

// MARK: - Surface Mode

enum SurfaceMode: String, CaseIterable, Identifiable {
    case auto   = "Auto"
    case bed    = "Bed"
    case table  = "Table"
    case pocket = "Pocket"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .auto:   return "sparkles"
        case .bed:    return "bed.double"
        case .table:  return "rectangle.on.rectangle"
        case .pocket: return "square.and.arrow.down"
        }
    }

    var description: String {
        switch self {
        case .auto:   return "Brink detects context automatically"
        case .bed:    return "Phone held above face or on pillow"
        case .table:  return "Phone resting on a flat surface"
        case .pocket: return "Phone in pocket or bag"
        }
    }
}

// MARK: - Alert Style

enum AlertStyle: String, CaseIterable, Identifiable {
    case soundAndVibration = "Sound & Vibration"
    case vibrationOnly     = "Vibration Only"
    case visualOnly        = "Visual Only"
    case silent            = "Silent"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .soundAndVibration: return "speaker.wave.2"
        case .vibrationOnly:     return "iphone.radiowaves.left.and.right"
        case .visualOnly:        return "eye"
        case .silent:            return "bell.slash"
        }
    }
}

// MARK: - Alert Event (History)

struct AlertEvent: Identifiable, Codable {
    var id: UUID = UUID()
    let date: Date
    let riskLevel: Int          // Stored as Int for Codable simplicity
    let context: String         // Human-readable context description
    var dismissed: Bool

    var riskLevelEnum: RiskLevel {
        RiskLevel(rawValue: riskLevel) ?? .medium
    }

    var timeAgo: String {
        let diff = Date().timeIntervalSince(date)
        if diff < 60       { return "Just now" }
        if diff < 3600     { return "\(Int(diff / 60))m ago" }
        if diff < 86400    { return "\(Int(diff / 3600))h ago" }
        return "\(Int(diff / 86400))d ago"
    }

    static var placeholder: AlertEvent {
        AlertEvent(date: Date(), riskLevel: RiskLevel.medium.rawValue, context: "Unstable position detected", dismissed: false)
    }
}

// MARK: - Motion Reading (live display)

struct MotionReading {
    var accelerationMagnitude: Double   // 0.0 – 3.0+
    var rotationMagnitude: Double       // rad/s
    var pitch: Double                   // radians
    var roll: Double                    // radians
    var stabilityScore: Double          // 0.0 (chaotic) – 1.0 (rock solid)

    static var idle: MotionReading {
        MotionReading(
            accelerationMagnitude: 0.01,
            rotationMagnitude: 0.0,
            pitch: 0.0,
            roll: 0.0,
            stabilityScore: 1.0
        )
    }
}

// MARK: - Quiet Hours

struct QuietHours: Codable, Equatable {
    var isEnabled: Bool
    var startHour: Int   // 0–23
    var startMinute: Int
    var endHour: Int
    var endMinute: Int

    static var `default`: QuietHours {
        QuietHours(isEnabled: false, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0)
    }

    var startDate: Date {
        Calendar.current.date(
            bySettingHour: startHour, minute: startMinute, second: 0, of: Date()
        ) ?? Date()
    }

    var endDate: Date {
        Calendar.current.date(
            bySettingHour: endHour, minute: endMinute, second: 0, of: Date()
        ) ?? Date()
    }

    var formattedStart: String { formatTime(hour: startHour, minute: startMinute) }
    var formattedEnd: String   { formatTime(hour: endHour,   minute: endMinute)   }

    private func formatTime(hour: Int, minute: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let m = String(format: "%02d", minute)
        let period = hour < 12 ? "AM" : "PM"
        return "\(h):\(m) \(period)"
    }
}
