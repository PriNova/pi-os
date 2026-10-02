import Foundation

/// Visual preferences only. Never part of a context, permission or agent argument.
public enum AppearancePreset: String, CaseIterable, Sendable {
    case system, clear, frost, graphite, warm, contrast
    public var title: String {
        switch self {
        case .system: return "System"
        case .clear: return "Clear"
        case .frost: return "Frost"
        case .graphite: return "Graphite"
        case .warm: return "Warm"
        case .contrast: return "Contrast"
        }
    }
}
public struct AppearancePreferences: Equatable, Sendable {
    public var preset: AppearancePreset
    public var largerText: Bool
    public var reduceTransparency: Bool
    public var lowerInset: Double
    public init(preset: AppearancePreset = .system, largerText: Bool = false,
                reduceTransparency: Bool = false, lowerInset: Double = 32) {
        self.preset = preset; self.largerText = largerText; self.reduceTransparency = reduceTransparency
        self.lowerInset = [20.0, 32.0, 48.0].contains(lowerInset) ? lowerInset : 32
    }
    public func opaque(systemReduceTransparency: Bool, systemIncreaseContrast: Bool) -> Bool {
        reduceTransparency || preset == .contrast || systemReduceTransparency || systemIncreaseContrast
    }
}
