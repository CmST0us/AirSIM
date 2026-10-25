import Foundation
import CallKit
import AVFoundation

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
    private var audioGeneration: UInt64 = 0
    private var resetHangups = Set<String>()
    var currentCallID: String? { controlledCall?.callID ?? model.ownedCall?.callID ?? incomingID }
    var authorizedBinding: V2ControlBinding? { verifiedBinding ?? controlledCall?.binding ?? model.ownedCall?.binding }
    var hasSystemCall: Bool { calls.handler === self && calls.currentSystemCallUUID != nil }

    init(model: CloudV2Model, calls: any V2SystemCallReporting = CallKitController.shared) { self.model = model; self.calls = calls }
    func start() {
        guard !R7UITestScenario.active else { return }
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
    private func clearContext() { audioGeneration &+= 1; verifiedBinding = nil; controlledCall = nil; incomingID = nil }
    func callKitPrepareAudioSession() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        try audio.setPreferredIOBufferDuration(0.02)
    }
    func callKitStart(number: String) async throws {
        guard model.foreground, await model.systemCommand("call.dial", args: ["number": number]) else { throw V2Error.stale }
        controlledCall = model.ownedCall
        await model.systemCallScopeChanged()
    }
    func callKitAnswer(origin: CallAnswerOrigin) async throws {
        guard verifiedBinding != nil, let id = currentCallID,
              await model.systemCommand("call.answer", args: ["call_id": id]) else { throw V2Error.stale }
        controlledCall = model.ownedCall
    }
    func callKitEnd() async throws {
        guard let id = currentCallID else { return }
        guard await model.systemCommand("call.hangup", args: ["call_id": id]) else { throw V2Error.stale }
    }
    func callKitSetMuted(_ muted: Bool) async { model.media.setMuted(muted) }
    func callKitPlayDTMF(_ digits: String) async throws {
        guard let owned = model.ownedCall, await model.systemCommand("call.dtmf", args: ["call_id": owned.callID, "tones": digits]) else { throw V2Error.stale }
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
