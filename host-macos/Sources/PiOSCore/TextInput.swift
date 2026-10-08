import Foundation

public enum TextStroke: Equatable {
    case unicode([UInt16])
    case enter
}

public enum TextInput {
    /// Host-neutral fidelity: CRLF, CR and LF each mean one line break. Unicode
    /// scalars keep surrogate pairs together; no clipboard or layout substitution.
    public static func strokes(_ text: String) -> [TextStroke] {
        var result: [TextStroke] = []
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar.value == 10 {
                if !previousCR { result.append(.enter) }
            } else if scalar.value == 13 { result.append(.enter) }
            else { result.append(.unicode(Array(String(scalar).utf16))) }
            previousCR = scalar.value == 13
        }
        return result
    }
    public static func intervalMilliseconds(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Double {
        guard let raw = env["PI_OS_TYPE_INTERVAL_MS"], let value = Double(raw),
              value.isFinite, value >= 0, value <= 1000 else { return 20 }
        return value
    }
}
