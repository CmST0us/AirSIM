import Foundation
import CallKit
import AVFoundation

enum V2SystemCommandOutcome { case completed, pending, failed }
@MainActor
final class V2SystemCommandSubmission {
    let commandID: String?
    let binding: V2ControlBinding?
    var outcome: V2SystemCommandOutcome
    var ownedCall: V2CallContext?
    init(commandID: String?, binding: V2ControlBinding?, outcome: V2SystemCommandOutcome) {
        self.commandID = commandID; self.binding = binding; self.outcome = outcome
    }
}

@MainActor
protocol V2SystemCallReporting: AnyObject {
    var handler: (any CallKitActionHandling)? { get set }
    var currentSystemCallUUID: UUID? { get }
    func setEnabled(_ enabled: Bool)
    func synchronize(call: CallRecord?, previous: CallRecord?, callerName: String?)
    func reportCurrentCallEnded(reason: CXCallEndedReason)
    func reportCurrentOutgoingConnected()
}
extension CallKitController: V2SystemCallReporting {}

/// The selected v2 runtime owns one system call; discovery remains foreground-only.
@MainActor
final class V2SystemCallController: CallKitActionHandling {
    private unowned let model: CloudV2Model
    private let calls: any V2SystemCallReporting
    private(set) var verifiedBinding: V2ControlBinding?
    private var controlledCall: V2CallContext?
    private var incomingID: String?
    private var association: V2SystemCommandSubmission?
    private var endingUUID: UUID?
    private let associationTimeout: Duration
    private let endAssociationTimeout: Duration
    private var audioGeneration: UInt64 = 0
    private var resetHangups = Set<String>()
    var currentCallID: String? { controlledCall?.callID ?? model.ownedCall?.callID ?? incomingID }
    var authorizedBinding: V2ControlBinding? { verifiedBinding ?? controlledCall?.binding ?? model.ownedCall?.binding }
    var hasSystemCall: Bool { calls.handler === self && calls.currentSystemCallUUID != nil }

    init(model: CloudV2Model, calls: any V2SystemCallReporting = CallKitController.shared,
         associationTimeout: Duration = .seconds(25), endAssociationTimeout: Duration = .seconds(10)) {
        self.model = model; self.calls = calls
        self.associationTimeout = associationTimeout; self.endAssociationTimeout = endAssociationTimeout
    }
    func start() {
        guard !UITestScenario.active else { return }
        calls.handler = self; calls.setEnabled(true)
    }
    func stop() {
        if calls.handler === self { calls.handler = nil; calls.setEnabled(false) }
        clearContext()
    }
    func observeSnapshot() {
        if !hasSystemCall, model.foreground, let binding = model.freshBinding,
           let call = model.activeCall, call.direction == "incoming", ["incoming", "ringing", "waiting"].contains(call.state) {
            verifiedBinding = binding; incomingID = call.call_id
            calls.synchronize(call: CallRecord(id: call.call_id, index: 0, direction: "incoming", state: "incoming", number: call.number, startedAt: call.observedAt, updatedAt: call.observedAt, endedAt: nil, missed: false), previous: nil, callerName: nil)
        }
        guard hasSystemCall, let binding = authorizedBinding, let snapshot = model.snapshot else { return }
        guard snapshot.online, snapshot.connection_epoch == binding.connectionEpoch,
              snapshot.snapshot?.agent_boot_id == binding.bootID,
              snapshot.snapshot?.backend_epoch == binding.backendEpoch else { endSystemCall(); return }
        if let call = snapshot.snapshot?.calls.calls.first(where: { $0.call_id == currentCallID }) {
            if call.state == "disconnected" { endSystemCall() }
            else {
                calls.synchronize(call: CallRecord(id: call.call_id, index: 0, direction: call.direction, state: call.state, number: call.number, startedAt: call.observedAt, updatedAt: call.observedAt, endedAt: nil, missed: false), previous: nil, callerName: nil)
            }
        }
    }
    func endSystemCall() {
        guard hasSystemCall else { return }
        calls.reportCurrentCallEnded(reason: .remoteEnded)
        clearContext()
        model.systemAudioActive = false; model.media.requestStop()
        Task { await model.systemCallScopeChanged() }
    }
    private func clearContext() { audioGeneration &+= 1; verifiedBinding = nil; controlledCall = nil; incomingID = nil; association = nil; endingUUID = nil }
    func callKitPrepareAudioSession() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        try audio.setPreferredIOBufferDuration(0.02)
    }
    private func isCurrent(_ uuid: UUID, binding: V2ControlBinding) -> Bool {
        calls.handler === self && calls.currentSystemCallUUID == uuid && authorizedBinding == binding
    }
    private func waitForAssociation(_ ticket: V2SystemCommandSubmission, uuid: UUID,
                                    binding: V2ControlBinding, timeout: Duration) async throws -> V2CallContext? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while isCurrent(uuid, binding: binding) {
            if let owned = ticket.ownedCall, owned.binding == binding { return owned }
            if ticket.outcome == .failed { throw V2Error.stale }
            if ContinuousClock.now >= deadline { throw V2Error.stale }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
    func callKitStart(number: String) async throws {
        guard model.foreground, let binding = model.freshBinding, let uuid = calls.currentSystemCallUUID,
              calls.handler === self else { throw V2Error.stale }
        verifiedBinding = binding
        let ticket = await model.systemCommand("call.dial", args: ["number": number], binding: binding) { self.association = $0 }
        guard isCurrent(uuid, binding: binding) else { return }
        await model.systemCallScopeChanged()
        do {
            let owned = try await waitForAssociation(ticket, uuid: uuid, binding: binding, timeout: associationTimeout)
            guard isCurrent(uuid, binding: binding) else { return }
            controlledCall = owned
        } catch {
            guard isCurrent(uuid, binding: binding), endingUUID != uuid else { return }
            throw error
        }
    }
    func callKitAnswer(origin: CallAnswerOrigin) async throws {
        guard let binding = verifiedBinding, let id = currentCallID, let uuid = calls.currentSystemCallUUID else { throw V2Error.stale }
        let ticket = await model.systemCommand("call.answer", args: ["call_id": id], binding: binding) { self.association = $0 }
        do {
            let owned = try await waitForAssociation(ticket, uuid: uuid, binding: binding, timeout: associationTimeout)
            guard isCurrent(uuid, binding: binding) else { return }
            controlledCall = owned
        } catch {
            guard isCurrent(uuid, binding: binding), endingUUID != uuid else { return }
            throw error
        }
    }
    func callKitEnd() async throws {
        guard let uuid = calls.currentSystemCallUUID, let binding = authorizedBinding else { return }
        endingUUID = uuid
        let deadline = ContinuousClock.now.advanced(by: endAssociationTimeout)
        if let ticket = association, ticket.ownedCall == nil {
            guard let owned = try? await waitForAssociation(ticket, uuid: uuid, binding: binding, timeout: endAssociationTimeout),
                  isCurrent(uuid, binding: binding) else { return }
            controlledCall = owned
            // The receipt identifies the call; a fresh snapshot still authorizes control.
            while isCurrent(uuid, binding: binding), !model.ownedControlReady || model.busy {
                guard ContinuousClock.now < deadline else { return }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        guard isCurrent(uuid, binding: binding), let id = currentCallID else { return }
        let result = await model.systemCommand("call.hangup", args: ["call_id": id], binding: binding)
        if result.outcome == .failed { throw V2Error.stale }
    }
    func callKitSetMuted(_ muted: Bool) async { model.media.setMuted(muted) }
    func callKitPlayDTMF(_ digits: String) async throws {
        guard let owned = model.ownedCall else { throw V2Error.stale }
        let result = await model.systemCommand("call.dtmf", args: ["call_id": owned.callID, "tones": digits], binding: owned.binding)
        if result.outcome == .failed { throw V2Error.stale }
    }
    func callKitAudioSessionDidActivate() async {
        audioGeneration &+= 1; let stamp = audioGeneration
        await model.media.stop()
        guard hasSystemCall, audioGeneration == stamp else { return }
        model.systemAudioActive = true; model.connectAudio()
    }
    func callKitAudioSessionDidDeactivate() { audioGeneration &+= 1; model.systemAudioActive = false; model.media.requestStop() }
    func callKitProviderDidReset() async {
        model.systemAudioActive = false; await model.media.stop()
        if let owned = model.ownedCall, resetHangups.insert(owned.callID).inserted {
            _ = await model.systemCommand("call.hangup", args: ["call_id": owned.callID])
        }
        clearContext()
        await model.systemCallScopeChanged()
    }
    func callKitDidFail(_ message: String) { model.error = "系统通话未完成，请检查连接与权限。" }
    func callKitCallDidEnd() {
        clearContext(); model.systemAudioActive = false; model.media.requestStop()
        Task { await model.systemCallScopeChanged() }
    }
}
