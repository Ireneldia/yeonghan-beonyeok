import AppKit

nonisolated struct AnnotationColor: Equatable, Sendable {
    static let defaultHex = "D69221"
    static let defaultColor = AnnotationColor(hex: defaultHex)!
    let hex: String

    init?(hex: String) {
        guard let normalized = Self.normalizedHex(hex) else { return nil }
        self.hex = normalized
    }

    static func normalizedHex(_ value: String) -> String? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.utf8.count == 6,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
        return hex
    }

    static func hex(from color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        return values.map { String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()
    }

    private var components: [CGFloat] {
        let value = UInt32(hex, radix: 16)!
        return [CGFloat((value >> 16) & 255), CGFloat((value >> 8) & 255), CGFloat(value & 255)].map { $0 / 255 }
    }

    var cgColor: CGColor {
        let rgb = components
        return CGColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
    }

    var nsColor: NSColor {
        let rgb = components
        return NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
    }

    var luminance: Double {
        let linear = components.map { component -> Double in
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}

nonisolated enum AnnotationColorError: LocalizedError {
    case invalidHex
    var errorDescription: String? { "주석 색상은 6자리 RGB 색상이어야 합니다." }
}
