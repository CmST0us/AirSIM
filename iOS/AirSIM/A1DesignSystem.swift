import SwiftUI
import UIKit

enum A1Layout {
    static func masterColumnWidth(totalWidth: CGFloat) -> CGFloat {
        min(402, max(320, totalWidth * 0.442))
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
    static let background = Color("A1Background")
    static let ink = Color("A1Ink")
    static let soft = Color("A1Soft")
    static let gray = Color("A1Gray")
    static let secondary = Color("A1Secondary")
    static let separator = Color("A1Separator")
    static let blue = Color("A1Blue")
    static let linkBlue = Color("A1LinkBlue")
    static let green = Color("A1Green")
    static let positive = Color("A1Positive")
    static let negative = Color("A1Negative")
}

enum A1Typography {
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let face: String
        switch weight {
        case .bold, .heavy, .black: face = "NotoSansSC-Bold"
        case .medium, .semibold: face = "NotoSansSC-Medium"
        case .light, .thin, .ultraLight: face = "NotoSansSC-Light"
        default: face = "NotoSansSC-Regular"
        }
        let style: Font.TextStyle = size >= 28 ? .largeTitle : size >= 17 ? .body : size >= 14 ? .subheadline : .caption
        return .custom(face, size: size, relativeTo: style)
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
        Image(name).renderingMode(.template)
            .foregroundStyle(tint ?? semanticTint)
            .accessibilityHidden(true)
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
                            .foregroundStyle(A1Palette.secondary)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
