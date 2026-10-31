import SwiftUI
import UIKit

struct A1DialPadView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var onSettings: () -> Void = {}
    @State private var selectedModuleID: String?
    @State private var showingLines = false
    @State private var showingContactEditor = false
    @State private var zeroWasLongPressed = false
    @State private var deleteRepeatTask: Task<Void, Never>?
    @GestureState private var deletePressed = false
    @State private var startingCall = false

    private let rows = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")]
    ]

    private var outgoingModuleID: String? {
        selectedModuleID ?? model.defaultOutgoingModuleID
    }

    private var selectedLine: AndroidAgentPresentation? {
        model.pairedAndroidAgents.first { $0.id == outgoingModuleID }
    }

    private var canCall: Bool {
        guard !model.numberInput.isEmpty, !model.isBusy, !startingCall,
              let line = selectedLine else { return false }
        if line.isCurrent { return model.canStartOutgoingCommand }
        guard let cloud = model.cloudV2 else { return false }
        return line.cloudOnline && cloud.canAct && cloud.activeCall == nil && !cloud.blocksSwitch
    }

    private var lineUnavailable: Bool {
        guard let cloud = model.cloudV2, cloud.configuration != nil else { return false }
        if cloud.usingUSB && selectedLine?.isCurrent == true { return false }
        if let selectedLine, !selectedLine.cloudOnline { return true }
        return !cloud.connected && cloud.error != nil
    }

    var body: some View {
        GeometryReader { geometry in
            let spacingScale = min(1, max(0, (geometry.size.height - 600) / 160))
            ScrollView {
                if lineUnavailable {
                    unavailableContent(height: geometry.size.height)
                } else {
                    VStack(spacing: 0) {
                        VStack(spacing: 8) {
                            lineSelector
                            numberDisplay
                        }
                        .padding(.vertical, 12)
                        .background(A1Palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .padding(.horizontal, 20)
                        .padding(.top, 12 + 12 * spacingScale)
                        keypad
                            .padding(.top, 24 + 8 * spacingScale)
                        actions
                            .padding(.top, 20)
                            .padding(.bottom, 24)
                    }
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                }
            }
            .scrollIndicators(.hidden)
            .background(A1Palette.background)
        }
        .background(A1Palette.background)
        .sheet(isPresented: $showingLines) { linePicker }
        .sheet(isPresented: $showingContactEditor) {
            A1ContactEditor(contact: nil, initialPhones: [model.numberInput])
        }
        .onDisappear {
            stopRepeatingDelete()
            showingLines = false
            selectedModuleID = nil
        }
        .onChange(of: model.activeCall?.id) { callID in
            if callID == nil { selectedModuleID = nil }
        }
        .onChange(of: model.messageScope) { _ in
            if !startingCall { selectedModuleID = nil }
            showingLines = false
        }
    }

    private func unavailableContent(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("拨号键盘").font(A1Typography.font(32, weight: .bold))
                Spacer()
                Button(action: onSettings) {
                    Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                        .background(A1Palette.soft, in: Circle())
                }.accessibilityLabel("号卡设置")
            }.padding(.top, 8)
            lineSelector.padding(.top, 33).zIndex(2)
            Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: 32, weight: .light))
                .frame(width: 88, height: 88).background(A1Palette.soft, in: Circle())
                .padding(.top, max(32, min(105, height * 0.15)))
            Text(model.cloudV2?.connected == true ? "号卡暂不可用" : "网络不可用")
                .font(A1Typography.font(24, weight: .medium)).padding(.top, 26)
            Text("连接恢复后，可继续使用这张号卡\n通话和收发短信。")
                .font(A1Typography.font(14)).foregroundStyle(A1Palette.secondary)
                .multilineTextAlignment(.center).padding(.top, 11)
            Text("连接将自动恢复")
                .font(A1Typography.font(15, weight: .medium)).foregroundStyle(A1Palette.linkBlue)
                .padding(.top, 50)
            if let outgoingModuleID {
                Text("当前选择仍为\(model.lineTitle(moduleID: outgoingModuleID))")
                    .font(A1Typography.font(12)).foregroundStyle(A1Palette.secondary).padding(.top, 25)
            }
        }.padding(.horizontal, 20).padding(.bottom, 32)
            .frame(maxWidth: 600).frame(maxWidth: .infinity)
            .accessibilityIdentifier("a1-dial-unavailable")
    }

    private var lineSelector: some View {
        Button { showingLines = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "simcard")
                    .accessibilityHidden(true)
                Text("呼出")
                    .foregroundStyle(A1Palette.secondary)
                Text(outgoingModuleID == nil ? "选择号卡" : model.lineTitle(moduleID: outgoingModuleID))
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .accessibilityHidden(true)
            }
            .font(A1Typography.font(14))
            .foregroundStyle(A1Palette.linkBlue)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(A1Palette.accentSoft, in: Capsule())
        }
        .buttonStyle(A1PressButtonStyle())
        .padding(.horizontal, 20)
        .accessibilityLabel("选择本次呼出号卡")
        .accessibilityValue(outgoingModuleID.map { model.lineTitle(moduleID: $0) } ?? "未选择")
        .accessibilityIdentifier("module-selector")
        .disabled(startingCall)
    }

    private var linePicker: some View {
        NavigationStack {
            List {
                Section {
                    if model.pairedAndroidAgents.isEmpty {
                        Text("请先在号卡页添加设备")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.pairedAndroidAgents) { line in
                        Button {
                            selectedModuleID = line.id
                            showingLines = false
                        } label: {
                            HStack(spacing: 12) {
                                Text(model.lineTitle(moduleID: line.id))
                                    .foregroundStyle(A1Palette.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                if line.id == outgoingModuleID {
                                    Image(systemName: "checkmark")
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("a1-dial-line-" + line.id)
                        .accessibilityAddTraits(line.id == outgoingModuleID ? .isSelected : [])
                    }
                } footer: {
                    Text("仅用于本次呼叫")
                }
            }
            .navigationTitle("选择本次呼出号卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingLines = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("a1-dial-lines")
    }

    private var numberDisplay: some View {
        VStack(spacing: 0) {
            Text(model.numberInput.isEmpty ? "准备通话" : A1PhonePresentation.display(model.numberInput))
                .font(.largeTitle.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(A1Palette.ink)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.45)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 46)
                .accessibilityIdentifier("a1-dial-number")
                .accessibilityLabel(model.numberInput.isEmpty ? "尚未输入号码" : model.numberInput)
                .textSelection(.enabled)
            if model.numberInput.isEmpty {
                Text("输入电话号码")
                    .font(A1Typography.font(14, weight: .medium))
                    .foregroundStyle(A1Palette.secondary)
                    .frame(minHeight: 44)
            } else {
                Button {
                    showingLines = false
                    showingContactEditor = true
                } label: {
                    Text("添加到联系人")
                        .font(A1Typography.font(14, weight: .medium))
                        .foregroundStyle(A1Palette.linkBlue)
                        .frame(minHeight: 44)
                }
                .buttonStyle(A1PressButtonStyle())
                .accessibilityIdentifier("a1-dial-add-contact")
            }
        }
        .padding(.horizontal, 20)
    }

    private var keyDiameter: CGFloat { dynamicTypeSize.isAccessibilitySize ? 88 : 76 }

    private var keypad: some View {
        VStack(spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: dynamicTypeSize.isAccessibilitySize ? 8 : 28) {
                    ForEach(row, id: \.0) { digit, letters in
                        key(digit, letters: letters)
                    }
                }
            }
        }
        .frame(width: 290)
    }

    private func key(_ digit: String, letters: String) -> some View {
        Button {
            guard !(digit == "0" && zeroWasLongPressed) else {
                zeroWasLongPressed = false
                return
            }
            showingLines = false
            model.numberInput.append(digit)
            playKeySound()
        } label: {
            VStack(spacing: 0) {
                Text(digit)
                    .font(dynamicTypeSize.isAccessibilitySize ? .largeTitle : .system(size: 38))
                    .foregroundStyle(A1Palette.ink)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(letters.isEmpty ? " " : letters)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(A1Palette.ink)
                }
            }
            .frame(width: keyDiameter, height: keyDiameter)
            .background(A1Palette.keypadFill, in: Circle())
            .overlay(Circle().strokeBorder(A1Palette.separator, lineWidth: 1))
            .contentShape(Circle())
        }
        .buttonStyle(A1PressButtonStyle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                if digit == "0" {
                    zeroWasLongPressed = true
                    showingLines = false
                    model.numberInput.append("+")
                    playKeySound()
                }
            }
        )
        .accessibilityLabel(letters.isEmpty ? digit : "\(digit) \(letters)")
        .accessibilityActions {
            if digit == "0" {
                Button("输入加号") {
                    showingLines = false
                    model.numberInput.append("+")
                    playKeySound()
                }
            }
        }
        .accessibilityIdentifier("a1-dial-key-" + (digit == "*" ? "star" : digit == "#" ? "hash" : digit))
    }

    private var actions: some View {
        HStack(spacing: 28) {
            Color.clear.frame(width: 78, height: 78)
            Button {
                guard let moduleID = outgoingModuleID, canCall else { return }
                showingLines = false
                startingCall = true
                let number = model.numberInput
                Task {
                    await model.call(number: number, moduleID: moduleID, persistSelection: false)
                    startingCall = false
                }
            } label: {
                Group {
                    if startingCall {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(canCall ? Color.white : A1Palette.secondary)
                    }
                }
                    .frame(width: 78, height: 78)
                    .background(canCall || startingCall ? A1Palette.green : A1Palette.soft, in: Circle())
            }
            .buttonStyle(A1PressButtonStyle())
            .disabled(!canCall)
            .accessibilityLabel("呼叫")
            .accessibilityIdentifier("a1-dial-call")

            Image(systemName: "delete.left")
                .font(.system(size: 24))
                .foregroundStyle(A1Palette.secondary)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
                .opacity(deletePressed ? 0.55 : 1)
                .gesture(deleteGesture)
                .frame(width: 78, height: 78)
                .opacity(model.numberInput.isEmpty ? 0 : 1)
                .allowsHitTesting(!model.numberInput.isEmpty)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("删除")
                .accessibilityHint("轻点删除一位，长按连续删除")
                .accessibilityAddTraits(.isButton)
                .accessibilityHidden(model.numberInput.isEmpty)
                .accessibilityAction { deleteLastDigit() }
                .accessibilityIdentifier("a1-dial-delete")
        }
        .frame(width: 290, height: 78)
    }

    private func playKeySound() {
        if !model.isMuted { UIDevice.current.playInputClick() }
    }

    private func deleteLastDigit() {
        guard !model.numberInput.isEmpty else { return }
        model.numberInput = DialPadDeletePolicy.removingLast(from: model.numberInput)
    }

    private func beginDeleting() {
        guard deleteRepeatTask == nil, !model.numberInput.isEmpty else { return }
        showingLines = false
        deleteLastDigit()
        deleteRepeatTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            while !Task.isCancelled, !model.numberInput.isEmpty {
                deleteLastDigit()
                try? await Task.sleep(for: .milliseconds(90))
            }
            deleteRepeatTask = nil
        }
    }

    private func stopRepeatingDelete() {
        deleteRepeatTask?.cancel()
        deleteRepeatTask = nil
    }

    private var deleteGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($deletePressed) { _, pressed, _ in pressed = true }
            .onChanged { _ in beginDeleting() }
            .onEnded { _ in stopRepeatingDelete() }
    }
}
