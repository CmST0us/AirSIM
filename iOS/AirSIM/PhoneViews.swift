import SwiftUI
import UIKit

enum RecentCallTimeFormatter {
    static func string(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let currentDay = calendar.dateComponents([.year, .month, .day], from: now)
        if day == currentDay {
            let time = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           day == calendar.dateComponents([.year, .month, .day], from: yesterday) {
            return "昨天"
        }
        if day.year == currentDay.year {
            return String(format: "%02d/%02d", day.month ?? 0, day.day ?? 0)
        }
        return String(format: "%04d/%02d/%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}

enum RecentCallDialPolicy {
    static func numberToDial(_ number: String?) -> String? {
        guard let number, !number.isEmpty else { return nil }
        return number
    }
}

enum DialPadDeletePolicy {
    static func removingLast(from number: String) -> String {
        String(number.dropLast())
    }
}

struct DialPadTransportPresentation: Equatable {
    let title: String
    let detail: String
    let systemImage: String
    let transport: CallTransport

    static func make(
        vowlanOnline: Bool,
        moduleLocalReachable: Bool,
        cloudOnline: Bool
    ) -> DialPadTransportPresentation? {
        if vowlanOnline {
            return DialPadTransportPresentation(
                title: "VoWLAN",
                detail: "拨号及通话音频将通过同一 Wi-Fi 或三星热点",
                systemImage: "wifi",
                transport: .vowlan
            )
        }
        if moduleLocalReachable {
            return DialPadTransportPresentation(
                title: "模块本地",
                detail: "拨号及通话音频将通过模块本地链路",
                systemImage: "cable.connector",
                transport: .moduleLocal
            )
        }
        if cloudOnline {
            return DialPadTransportPresentation(
                title: "云端",
                detail: "拨号及通话音频将通过云端 Relay",
                systemImage: "cloud.fill",
                transport: .cloud
            )
        }
        return nil
    }
}

enum AvatarFallbackContent: Equatable {
    case person
    case initial(String)
}

enum RecentAvatarPolicy {
    static func content(contactName: String?) -> AvatarFallbackContent {
        let trimmed = contactName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let first = trimmed.first else { return .person }
        return .initial(String(first))
    }
}

struct InitialAvatar: View {
    let name: String
    var photoData: Data? = nil
    var fallbackContent: AvatarFallbackContent? = nil
    var size: CGFloat = 44

    private var resolvedFallback: AvatarFallbackContent {
        fallbackContent
            ?? .initial(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)))
    }

    var body: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                avatarFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var avatarFallback: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: fallbackColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                switch resolvedFallback {
                case .person:
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.52, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(y: size * 0.08)
                case let .initial(initial):
                    Text(initial)
                        .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: Color.indigo.opacity(0.55), radius: 1.4, x: 0, y: 1.2)
                        .overlay {
                            Text(initial)
                                .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.28))
                                .offset(y: -0.8)
                        }
                }
            }
            .overlay {
                Circle().stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.5), .white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: fallbackColors.last?.opacity(0.22) ?? .clear, radius: 3, y: 2)
    }

    private var fallbackColors: [Color] {
        switch resolvedFallback {
        case .person:
            return [
                Color(red: 0.64, green: 0.76, blue: 0.91),
                Color(red: 0.43, green: 0.48, blue: 0.78),
            ]
        case .initial:
            return [
                Color(red: 0.66, green: 0.78, blue: 0.92),
                Color(red: 0.43, green: 0.49, blue: 0.79),
            ]
        }
    }
}

/// 新系统使用原生 ContentUnavailableView，iOS 16 保留等价回退。
private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(emptyStateDescription)
            } actions: {
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private var emptyStateDescription: String {
        switch systemImage {
        case "message": return "收到的短信会显示在这里。"
        case "phone.arrow.up.right": return "完成通话后，记录会显示在这里。"
        case "person.2": return "联系人会从系统通讯录同步。"
        default: return "完成连接或授权后即可使用。"
        }
    }
}

// MARK: - 通话覆盖层

enum CallSurfacePhase: Equatable {
    case incoming
    case connected
}

enum CallSurfaceAction: Equatable {
    case decline
    case answer
    case mute
    case end
    case keypad
    case speaker
}

struct CallSurfaceContent: Equatable {
    let phase: CallSurfacePhase
    let primaryActions: [CallSurfaceAction]
    let secondaryActions: [CallSurfaceAction]
    let showsDuration: Bool

    init(state: String) {
        if ["incoming", "waiting"].contains(state) {
            phase = .incoming
            primaryActions = [.decline, .answer]
            secondaryActions = []
            showsDuration = false
        } else {
            phase = .connected
            primaryActions = [.end]
            secondaryActions = [.mute, .keypad, .speaker]
            showsDuration = true
        }
    }
}

enum CallProximityPolicy {
    static func shouldMonitor(state: String, speakerEnabled: Bool) -> Bool {
        guard !speakerEnabled else { return false }
        return ["dialing", "alerting", "connecting", "active", "held", "ending"].contains(state)
    }
}

struct ActiveCallView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let call: CallRecord
    @State private var showingKeypad = false

    private var incoming: Bool { CallSurfaceContent(state: call.state).phase == .incoming }
    private var dialing: Bool { ["dialing", "alerting", "connecting"].contains(call.state) }
    private var displayName: String { model.contacts.displayName(for: call.number) }
    private var contactPhotoData: Data? {
        call.number.flatMap { model.contacts.contact(for: $0)?.photoData }
    }
    private var moduleID: String? {
        model.cloudV2?.ownedCall?.binding.moduleID ?? model.moduleID(for: call)
    }
    private var callLabel: String {
        let route = model.cloudV2?.usingUSB == true ? "USB 本地" : "云端"
        return route + (incoming ? "来电" : "通话")
    }
    private var audioControlsEnabled: Bool {
        model.cloudV2.map { $0.media.state == .paired } ?? true
    }
    private var audioUnavailable: Bool {
        if let cloud = model.cloudV2 {
            if case .failed = cloud.media.state { return true }
            return false
        }
        return model.audio.errorMessage?.isEmpty == false
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if dynamicTypeSize.isAccessibilitySize || geometry.size.height < 500 {
                    ScrollView { portraitSurface(compact: false).padding(.vertical, 24) }
                } else if geometry.size.width > geometry.size.height {
                    HStack(spacing: 48) {
                        identity(compact: geometry.size.height < 500)
                            .frame(maxWidth: 420)
                        VStack(spacing: 32) {
                            if !incoming && !dialing { secondaryControls }
                            primaryControls
                        }
                        .frame(maxWidth: 340)
                    }
                    .padding(32)
                    .frame(maxWidth: 920, maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
                } else {
                    portraitSurface(compact: geometry.size.height < 720)
                        .padding(.top, geometry.size.height < 720 ? 16 : 38)
                        .padding(.bottom, geometry.size.height < 720 ? 24 : incoming ? 52 : 42)
                        .frame(maxWidth: 600, maxHeight: 790)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .foregroundStyle(A1Palette.onCard)
        .background(A1Palette.callBackground.ignoresSafeArea())
        .contentShape(Rectangle())
        .sheet(isPresented: $showingKeypad) { DTMFKeypadView() }
        .onAppear { updateProximityMonitoring() }
        .onChange(of: call.state) { _ in updateProximityMonitoring() }
        .onChange(of: model.speakerEnabled) { _ in updateProximityMonitoring() }
        .onDisappear { UIDevice.current.isProximityMonitoringEnabled = false }
    }

    private func portraitSurface(compact: Bool) -> some View {
        VStack(spacing: 0) {
            identity(compact: compact)
            if !incoming && !dialing {
                secondaryControls.padding(.top, compact ? 32 : 64)
            }
            Spacer(minLength: 28)
            primaryControls
        }
        .padding(.horizontal, 24)
    }

    private func identity(compact: Bool) -> some View {
        VStack(spacing: 0) {
            Label(callLabel, systemImage: "phone.connection.fill")
                .font(A1Typography.font(13, weight: .medium))
                .foregroundStyle(A1Palette.onCard.opacity(0.72))
                .frame(minHeight: 19)
            A1Avatar(name: displayName, photoData: contactPhotoData, size: compact ? 92 : 112, fontSize: compact ? 35 : 43)
                .padding(.top, compact ? 24 : 40)
            Text(displayName)
                .font(A1Typography.font(32, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.7)
                .frame(minHeight: 45)
                .padding(.top, compact ? 16 : 24)
            Text("\(incoming ? "打入" : "使用") \(model.lineTitle(moduleID: moduleID))")
                .font(A1Typography.font(15))
                .foregroundStyle(A1Palette.onCard.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .frame(minHeight: 21)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(A1Palette.onCard.opacity(0.10), in: Capsule())
                .padding(.top, 12)
            status.padding(.top, 20)
            if !incoming && !dialing && audioUnavailable {
                Text("通话音频暂不可用")
                    .font(A1Typography.font(13))
                    .foregroundStyle(A1Palette.negative)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var status: some View {
        if incoming {
            Text(A1PhonePresentation.display(call.number ?? "未知号码"))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(A1Palette.onCard.opacity(0.72))
                .frame(minHeight: 21)
        } else if dialing {
            Text("正在呼叫…")
                .font(A1Typography.font(15))
                .foregroundStyle(A1Palette.onCard.opacity(0.72))
                .frame(minHeight: 21)
        } else if call.state == "ending" {
            Text("正在结束…")
                .font(A1Typography.font(15))
                .foregroundStyle(A1Palette.onCard.opacity(0.72))
                .frame(minHeight: 35)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(durationText(at: context.date))
                    .font(.title.monospacedDigit())
                    .foregroundStyle(A1Palette.onCard.opacity(0.72))
                    .frame(minHeight: 35)
            }
        }
    }

    private var secondaryControls: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 24))
            : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            A1CallControl(title: "静音", symbol: "mic.slash.fill", diameter: 72,
                          fill: A1Palette.onCard.opacity(0.12),
                          selected: model.isMuted) {
                Task { await model.toggleMute() }
            }
            .accessibilityLabel(model.isMuted ? "取消静音" : "静音")
            .accessibilityIdentifier("a1-call-state-mute")
            .disabled(!audioControlsEnabled)
            A1CallControl(title: "键盘", symbol: "circle.grid.3x3.fill", diameter: 72,
                          fill: A1Palette.onCard.opacity(0.12)) { showingKeypad = true }
                .accessibilityIdentifier("a1-call-state-keypad")
            A1CallControl(title: "扬声器", symbol: "speaker.wave.2.fill", diameter: 72,
                          fill: A1Palette.onCard.opacity(0.12),
                          selected: model.speakerEnabled) { model.toggleSpeaker() }
                .accessibilityIdentifier("a1-call-state-speaker")
                .disabled(!audioControlsEnabled)
        }
    }

    @ViewBuilder
    private var primaryControls: some View {
        if incoming {
            HStack {
                A1CallControl(title: "拒绝", symbol: "phone.down.fill", diameter: 78,
                              fill: A1Palette.negative) { Task { await model.reject() } }
                    .accessibilityLabel("拒接")
                    .accessibilityIdentifier("a1-call-state-decline")
                Spacer(minLength: 40)
                A1CallControl(title: "接听", symbol: "phone.fill", diameter: 78,
                              fill: A1Palette.green) { Task { await model.answer() } }
                    .accessibilityIdentifier("a1-call-state-answer")
            }
            .frame(maxWidth: 270)
        } else {
            A1CallControl(title: dialing ? "取消呼叫" : "结束通话",
                          symbol: "phone.down.fill",
                          diameter: 78, fill: A1Palette.negative, labelSpacing: 16) { Task { await model.hangup() } }
                .accessibilityLabel(dialing ? "取消呼叫" : "挂断")
                .accessibilityIdentifier("a1-call-state-hangup")
                .disabled(call.state == "ending")
        }
    }

    private func durationText(at date: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(call.startedAt)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func updateProximityMonitoring() {
        UIDevice.current.isProximityMonitoringEnabled = CallProximityPolicy.shouldMonitor(
            state: call.state,
            speakerEnabled: model.speakerEnabled
        )
    }
}

private struct A1CallControl: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let symbol: String
    let diameter: CGFloat
    let fill: Color
    var selected = false
    var labelSpacing: CGFloat = 12
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: labelSpacing) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(selected ? Color.black : A1Palette.onCard)
                    .accessibilityHidden(true)
                    .frame(width: diameter, height: diameter)
                    .background(selected ? A1Palette.onCard : fill, in: Circle())
                Text(title)
                    .font(A1Typography.font(13))
                    .foregroundStyle(A1Palette.onCard.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 19)
            }
            .frame(minWidth: 78)
            .contentShape(Rectangle())
        }
        .buttonStyle(A1PressButtonStyle())
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DTMFKeypadView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @State private var enteredDigits = ""
    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    private var keySize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 90 : horizontalSizeClass == .compact ? 62 : 70
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text(enteredDigits.isEmpty ? " " : enteredDigits)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(enteredDigits.isEmpty ? .secondary : .primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(enteredDigits.isEmpty ? "尚未输入按键" : enteredDigits)
                    keypad
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 12 : 24)
            }
            .background(A1Palette.background)
            .navigationTitle("通话键盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(510), .large])
        .presentationDragIndicator(.visible)
    }

    private var keypad: some View {
        VStack(spacing: 16) {
            ForEach(rows, id: \.description) { row in
                HStack(spacing: dynamicTypeSize.isAccessibilitySize ? 10 : 24) {
                    ForEach(row, id: \.self) { digit in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            enteredDigits = String((enteredDigits + digit).suffix(18))
                            Task { await model.sendDTMF(digit) }
                        } label: {
                            Text(digit)
                                .font(.title)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                                .frame(width: keySize, height: keySize)
                                .background(A1Palette.keypadFill, in: Circle())
                                .overlay(Circle().strokeBorder(A1Palette.separator, lineWidth: 1))
                                .foregroundStyle(A1Palette.ink)
                                .contentShape(Circle())
                        }
                        .buttonStyle(A1PressButtonStyle())
                        .accessibilityLabel("发送 DTMF \(digit)")
                    }
                }
            }
        }
    }
}
