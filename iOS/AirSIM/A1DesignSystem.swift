import SwiftUI
import UIKit

enum A1Layout {
    static func masterColumnWidth(totalWidth: CGFloat) -> CGFloat {
        min(402, max(320, totalWidth * 0.442))
    }
}

struct A1PressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = isEnabled && configuration.isPressed
        return configuration.label
            .opacity(pressed ? 0.78 : 1)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

struct A1RowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(isEnabled && configuration.isPressed ? A1Palette.gray.opacity(0.5) : .clear)
    }
}

private struct A1WideLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var a1UsesWideLayout: Bool {
        get { self[A1WideLayoutKey.self] }
        set { self[A1WideLayoutKey.self] = newValue }
    }
}

enum A1Palette {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let ink = Color(uiColor: .label)
    static let soft = Color(uiColor: .tertiarySystemGroupedBackground)
    static let gray = Color(uiColor: .systemGray4)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let separator = Color(uiColor: .separator)
    static let blue = Color(uiColor: .systemBlue)
    static let linkBlue = Color(uiColor: .systemBlue)
    static let green = Color(uiColor: .systemGreen)
    static let positive = Color(uiColor: .systemGreen)
    static let negative = Color(uiColor: .systemRed)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let accent = Color(uiColor: .systemBlue)
    static let accentFill = Color(uiColor: .systemBlue)
    static let accentSoft = Color(uiColor: .tertiarySystemFill)
    static let callBackground = Color(uiColor: .systemGray6)
    static let keypadFill = Color(uiColor: .systemGray5)
    static let onCard = Color.white
}

enum A1Typography {
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let style: Font.TextStyle = size >= 32 ? .largeTitle : size >= 28 ? .title
            : size >= 22 ? .title2 : size >= 20 ? .title3 : size >= 17 ? .body
            : size >= 15 ? .subheadline : size >= 13 ? .footnote : size >= 12 ? .caption : .caption2
        return .system(style, design: .default).weight(weight)
    }
}

enum A1PhonePresentation {
    static func display(_ number: String) -> String {
        guard number.count == 11, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return number }
        return "\(number.prefix(3)) \(number.dropFirst(3).prefix(4)) \(number.suffix(4))"
    }
}

struct A1AssetIcon: View {
    let name: String
    var tint: Color? = nil
    init(_ name: String, tint: Color? = nil) { self.name = name; self.tint = tint }

    private var semanticTint: Color {
        switch name {
        case "a1-empty-plus", "a1-calls-phone", "a1-call-state-answer",
             "a1-call-state-active-hangup", "a1-call-state-outgoing-hangup",
             "a1-call-state-incoming-hangup", "a1-detail-phone", "a1-dial-call",
             "a1-empty-phone", "a1-wide-phone", "a1-wide-message", "a1-detail-message":
            return .white
        case "a1-dial-star", "a1-dial-check", "a1-call-state-mic",
             "a1-call-state-keypad", "a1-call-state-speaker":
            return A1Palette.ink
        case "a1-card-sim-green":
            return A1Palette.positive
        case "a1-dial-delete", "a1-duo-sms-chevron", "a1-contacts-search",
             "a1-sms-thread-send", "a1-sms-failure-send", "a1-duo-sms-send",
             "a1-wide-chevron", "a1-chevron", "a1-card-row-chevron", "a1-duo-sms-search",
             "a1-card-network", "a1-card-chevron", "a1-wide-search", "a1-detail-chevron",
             "a1-empty-clock", "a1-dial-call-disabled", "a1-empty-contacts":
            return A1Palette.secondary
        default:
            return A1Palette.linkBlue
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: symbolSize, weight: .medium))
            .frame(width: symbolSize + 4, height: symbolSize + 4)
            .foregroundStyle(tint ?? semanticTint)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        if name.contains("hangup") { return "phone.down.fill" }
        if name.contains("search") { return "magnifyingglass" }
        if name.contains("plus") { return "plus" }
        if name.contains("more") { return "ellipsis" }
        if name.contains("chevron") { return "chevron.right" }
        if name.contains("down") { return "chevron.down" }
        if name.contains("back") { return "chevron.left" }
        if name.contains("send") { return "arrow.up" }
        if name.contains("delete") { return "delete.left" }
        if name.contains("check") { return "checkmark" }
        if name.contains("star") { return "star.fill" }
        if name.contains("keypad") { return "circle.grid.3x3.fill" }
        if name.contains("speaker") { return "speaker.wave.2.fill" }
        if name.contains("mic") { return "mic.slash.fill" }
        if name.contains("info") { return "info.circle" }
        if name.contains("network") { return "antenna.radiowaves.left.and.right" }
        if name.contains("sim") { return "simcard" }
        if name.contains("contacts") { return "person.crop.circle" }
        if name.contains("clock") { return "clock" }
        if name.contains("message") { return "message.fill" }
        return "phone.fill"
    }

    private var symbolSize: CGFloat {
        name.contains("chevron") || name.contains("down") ? 14 : 20
    }
}

struct A1Avatar: View {
    let name: String
    var photoData: Data? = nil
    let size: CGFloat
    var fontSize: CGFloat? = nil

    private var initial: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "?" }
        if name.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) {
            return String(name.suffix(1))
        }
        return String(name.prefix(1)).uppercased()
    }

    var body: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(A1Palette.gray)
                    .overlay {
                        Text(initial)
                            .font(A1Typography.font(fontSize ?? size * 0.37, weight: .medium))
                            .foregroundStyle(A1Palette.ink)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(A1Palette.ink.opacity(0.06), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

struct A1LineBadge: View {
    let title: String
    var active = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "simcard")
            Text(title)
        }
            .font(.caption.weight(.medium))
            .foregroundStyle(active ? A1Palette.accent : A1Palette.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(active ? A1Palette.accentSoft : A1Palette.soft, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}
