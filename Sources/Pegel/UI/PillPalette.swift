import Foundation
import SwiftUI

/// Bar colour gradients. The rest of the capsule is the same in every palette.
enum PillPalette: String, CaseIterable, Codable, Sendable {
    case standard
    case citrus
    case lagoon
    case ember
    case neon
    case fern

    var label: String { L("palette.\(rawValue)") }

    /// Eleven steps taken from the design handoff, not computed, to match it exactly.
    var levelColors: [UInt32] {
        switch self {
        case .standard:
            return [
                0xB4_78EC, 0xAD_7BED, 0xA6_7FEF, 0x9F_82F0, 0x98_85F2, 0x92_89F3,
                0x8B_8CF4, 0x84_8FF6, 0x7D_92F7, 0x76_96F9, 0x6F_99FA,
            ]
        case .citrus:
            return [
                0xC8_F031, 0xD3_ED2D, 0xDE_EA28, 0xE9_E624, 0xF4_E31F, 0xFF_E01B,
                0xFF_CF16, 0xFF_BE10, 0xFF_AC0B, 0xFF_9B05, 0xFF_8A00,
            ]
        case .lagoon:
            return [
                0x2B_F0C4, 0x27_E4CB, 0x24_D8D2, 0x20_CCDA, 0x1D_C0E1, 0x19_B4E8,
                0x23_A6EB, 0x2D_97EE, 0x36_89F1, 0x40_7AF4, 0x4A_6CF7,
            ]
        case .ember:
            return [
                0xFF_2D8A, 0xFF_3780, 0xFF_4176, 0xFF_4A6B, 0xFF_5461, 0xFF_5E57,
                0xFF_6C51, 0xFF_794B, 0xFF_8746, 0xFF_9440, 0xFF_A23A,
            ]
        case .neon:
            return [
                0xFF_4FD8, 0xEE_50DE, 0xDC_51E4, 0xCB_53EB, 0xB9_54F1, 0xA8_55F7,
                0x9A_58F6, 0x8C_5CF5, 0x7F_5FF3, 0x71_63F2, 0x63_66F1,
            ]
        case .fern:
            return [
                0x7C_F06A, 0x69_EA6D, 0x57_E370, 0x44_DD74, 0x32_D677, 0x1F_D07A,
                0x1C_C783, 0x19_BF8B, 0x15_B694, 0x12_AE9C, 0x0F_A5A5,
            ]
        }
    }

    /// Corner colours for the trace. Standard's midpoint differs from the levels row,
    /// as it did before palettes existed.
    var traceStops: [UInt32] {
        switch self {
        case .standard: return [0xB4_78EC, 0x90_84F5, 0x6F_99FA]
        default:
            let colors = levelColors
            return [colors[0], colors[5], colors[10]]
        }
    }

    func levelColor(at index: Int) -> Color { Color(hex: levelColors[index]) }

    func traceColor(atSlot index: Int, of count: Int) -> Color {
        let stops = traceStops.map(Self.components)
        guard count > 1 else { return Self.color(stops[0]) }
        let scaled = Double(index) / Double(count - 1) * Double(stops.count - 1)
        let lower = min(Int(scaled), stops.count - 2)
        let fraction = scaled - Double(lower)
        let a = stops[lower]
        let b = stops[lower + 1]
        return Self.color(
            (
                a.r + (b.r - a.r) * fraction,
                a.g + (b.g - a.g) * fraction,
                a.b + (b.b - a.b) * fraction
            ))
    }

    private static func components(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }

    private static func color(_ value: (r: Double, g: Double, b: Double)) -> Color {
        Color(.sRGB, red: value.r, green: value.g, blue: value.b, opacity: 1)
    }

    private static let defaultsKey = "pillPalette"

    static func load() -> PillPalette {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
            let value = PillPalette(rawValue: raw)
        else { return .standard }
        return value
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
