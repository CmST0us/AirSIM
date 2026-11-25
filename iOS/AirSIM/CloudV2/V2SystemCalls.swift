import Foundation
import CallKit
import AVFoundation

enum V2SystemCommandOutcome { case completed, pending, failed }

#if DEBUG
/// Stage names and flags only; read from the device container after a failed call.
enum V2DebugTrace {
    private static let key = "airsim.v2.debug-trace"
    static func record(_ event: String) {
        var items = UserDefaults.standard.stringArray(forKey: key) ?? []
        items.append("\(ISO8601DateFormatter().string(from: Date())) \(event)")
        if items.count > 60 { items.removeFirst(items.count - 60) }
        UserDefaults.standard.set(items, forKey: key)
    }
}
#endif
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
    func adoptAnsweredCall(callID: String, number: String?) async throws
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
    private var incomingPush: V2PushEnvelope?
    private var verifyingPush = false
    private var incomingSystemUUID: UUID?
    private var incomingAssociationDeadline: ContinuousClock.Instant?
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
    private func logPushVerifyFailure(_ push: V2PushEnvelope) {
#if DEBUG
        let response = model.snapshot
        V2DebugTrace.record("pushVerifyFailed expiry=\(model.currentTime < push.expiresAt) deadline=\(incomingAssociationDeadline.map { ContinuousClock.now < $0 } == true) uuid=\(calls.currentSystemCallUUID == incomingSystemUUID) config=\(model.configuration != nil) module=\(model.selectedModuleID == push.domain.moduleID) server=\(response?.server_id == push.domain.serverID) responseModule=\(response?.module_id == push.domain.moduleID) connection=\(response.map { model.pushConnectionMatches(push, response: $0) } == true) boot=\(response?.snapshot?.agent_boot_id == push.domain.agentBootID) backend=\(response?.snapshot?.backend_epoch == push.domain.backendEpoch) call=\(response?.snapshot?.calls.calls.contains(where: { $0.call_id == push.callID && $0.state != "disconnected" }) == true) selected=\(model.selectedModule != nil)")
        NSLog("[AirSIM Push] verification failed expiry=%d uuid=%d server=%d module=%d connection=%d boot=%d backend=%d call=%d fresh=%d",
              model.currentTime < push.expiresAt,
              calls.currentSystemCallUUID == incomingSystemUUID,
              response?.server_id == push.domain.serverID,
              response?.module_id == push.domain.moduleID,
              response?.connection_epoch == push.domain.connectionEpoch,
              response?.snapshot?.agent_boot_id == push.domain.agentBootID,
              response?.snapshot?.backend_epoch == push.domain.backendEpoch,
              response?.snapshot?.calls.calls.contains(where: { $0.call_id == push.callID && $0.state != "disconnected" }) == true,
              model.freshBinding != nil)
#endif
    }
    func observeSnapshot() {
        if let push = incomingPush {
            if verifyingPush { return }
            // Definitive expiry, UUID loss, or configuration/module mismatch ends the system call.
            guard model.currentTime < push.expiresAt,
                  incomingAssociationDeadline.map({ ContinuousClock.now < $0 }) == true,
                  calls.currentSystemCallUUID == incomingSystemUUID,
                  let configuration = model.configuration,
                  configuration.identity.serverID == push.domain.serverID,
                  model.selectedModuleID == push.domain.moduleID else {
                logPushVerifyFailure(push)
                endSystemCall()
                return
            }
            guard let response = model.snapshot else { return }
            guard response.server_id == push.domain.serverID,
                  response.module_id == push.domain.moduleID else {
                logPushVerifyFailure(push)
                endSystemCall()
                return
            }
            // Wait for the next poll if the module is transiently offline or snapshot body is missing.
            guard response.online, let snapshot = response.snapshot else { return }
            // Different module boot or backend epoch definitively invalidates the pushed call.
            guard snapshot.agent_boot_id == push.domain.agentBootID,
                  snapshot.backend_epoch == push.domain.backendEpoch else {
                logPushVerifyFailure(push)
                endSystemCall()
                return
            }
            // Transiently stale snapshot age (e.g. brief cellular upload stall right after push)
            // waits for the next 1 s snapshot instead of terminating the ringing CallKit UI.
            let age = model.currentTime.timeIntervalSince(snapshot.observedAt)
            guard (-3...8).contains(age) else { return }
            guard let call = snapshot.calls.calls.first(where: {
                $0.call_id == push.callID && $0.direction == "incoming" && $0.state != "disconnected"
            }) else {
                logPushVerifyFailure(push)
                endSystemCall()
                return
            }
            // Wait for directory synchronization if selectedModule is still nil or behind the new epoch.
            guard let selected = model.selectedModule,
                  selected.online,
                  selected.connection_epoch == response.connection_epoch,
                  selected.agent_boot_id == snapshot.agent_boot_id,
                  selected.backend_epoch == snapshot.backend_epoch else { return }
            if model.usingUSB, !model.pushConnectionMatches(push, response: response) { return }
            guard let binding = try? response.controlBinding(configuration: configuration, module: selected, now: model.currentTime, usbLocal: model.usingUSB) else {
                return
            }
            verifiedBinding = binding
            incomingID = call.call_id
            incomingPush = nil
            incomingSystemUUID = nil
            incomingAssociationDeadline = nil
            calls.synchronize(
                call: CallRecord(id: call.call_id, index: 0, direction: "incoming", state: call.state,
                                 number: call.number, startedAt: call.observedAt, updatedAt: call.observedAt,
                                 endedAt: nil, missed: false),
                previous: nil, callerName: model.resolveCallerName?(call.number)
            )
        }
        // The cellular call outlives a module or App outage, so the system call
        // waits for the module and ends only on its observed end or a new module runtime.
        guard hasSystemCall, let binding = authorizedBinding, let response = model.snapshot,
              response.online, let snapshot = response.snapshot else { return }
        guard snapshot.agent_boot_id == binding.bootID, snapshot.backend_epoch == binding.backendEpoch else { endSystemCall(); return }
        let call = snapshot.calls.calls.first(where: { $0.call_id == currentCallID })
        if response.connection_epoch != binding.connectionEpoch {
            guard let call, call.state != "disconnected" else { endSystemCall(); return }
            guard let fresh = model.freshBinding, fresh.connectionEpoch == response.connection_epoch, fresh.moduleID == binding.moduleID,
                  fresh.bootID == binding.bootID, fresh.backendEpoch == binding.backendEpoch, fresh.usbLocal == binding.usbLocal else { return }
            rebind(from: binding, to: fresh)
        }
        if let call {
            if call.state == "disconnected" { endSystemCall() }
            else {
                calls.synchronize(call: CallRecord(id: call.call_id, index: 0, direction: call.direction, state: call.state, number: call.number, startedAt: call.observedAt, updatedAt: call.observedAt, endedAt: nil, missed: false), previous: nil, callerName: model.resolveCallerName?(call.number))
            }
        }
    }
    /// A call ringing in the App while it is in the foreground moves to the
    /// system ringing interface when the App leaves the foreground. Call before
    /// the model leaves the foreground, while its binding is still fresh.
    func handOverRingingCall() {
        guard !hasSystemCall, let binding = model.freshBinding, let call = model.activeCall, call.direction == "incoming",
              ["incoming", "ringing", "waiting"].contains(call.state) else { return }
        verifiedBinding = binding; incomingID = call.call_id
        calls.synchronize(call: CallRecord(id: call.call_id, index: 0, direction: "incoming", state: "incoming", number: call.number, startedAt: call.observedAt, updatedAt: call.observedAt, endedAt: nil, missed: false), previous: nil, callerName: model.resolveCallerName?(call.number))
    }
    /// A call answered in the App's own interface joins CallKit without any
    /// system interface, so the system can present it in the background.
    func adopt(_ owned: V2CallContext, number: String?) async {
        guard !hasSystemCall else { return }
        controlledCall = owned; verifiedBinding = owned.binding
        do { try await calls.adoptAnsweredCall(callID: owned.callID, number: number) } catch {
            if !hasSystemCall { controlledCall = nil; verifiedBinding = nil }
            model.error = "通话未能交给系统，App 退到后台时音频会中断。"
            return
        }
        await model.systemCallScopeChanged()
    }
    /// The module reconnected to the server; the same call continues under the new connection.
    func rebind(from old: V2ControlBinding, to fresh: V2ControlBinding) {
        if verifiedBinding == old { verifiedBinding = fresh }
        if let controlled = controlledCall, controlled.binding == old {
            controlledCall = V2CallContext(binding: fresh, callID: controlled.callID, generation: controlled.generation)
        }
    }
    func endSystemCall() {
        guard hasSystemCall else { return }
        calls.reportCurrentCallEnded(reason: .remoteEnded)
        clearContext()
        model.systemAudioActive = false; model.updateRingback(); model.media.requestStop()
        Task { await model.systemCallScopeChanged() }
    }
    private func clearContext() {
        audioGeneration &+= 1
        verifiedBinding = nil
        controlledCall = nil
        incomingID = nil
        incomingPush = nil
        incomingSystemUUID = nil
        incomingAssociationDeadline = nil
        association = nil
        endingUUID = nil
        model.media.resetCallPreferences()
    }
    func callKitPrepareAudioSession() throws {
#if DEBUG
        NSLog("[AirSIM V2] preparing CallKit RTCAudioSession")
#endif
        model.media.prepareCallKitVoiceSession()
    }
    private func sameCallDomain(_ lhs: V2ControlBinding, _ rhs: V2ControlBinding) -> Bool {
        lhs.identity == rhs.identity && lhs.moduleID == rhs.moduleID
            && lhs.bootID == rhs.bootID && lhs.backendEpoch == rhs.backendEpoch
            && lhs.usbLocal == rhs.usbLocal
    }
    private func isCurrent(_ uuid: UUID, binding: V2ControlBinding) -> Bool {
        guard calls.handler === self, calls.currentSystemCallUUID == uuid, let current = authorizedBinding else { return false }
        return sameCallDomain(current, binding)
    }
    private func waitForAssociation(_ ticket: V2SystemCommandSubmission, uuid: UUID,
                                    binding: V2ControlBinding, timeout: Duration) async throws -> V2CallContext? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while isCurrent(uuid, binding: binding) {
            if let owned = ticket.ownedCall, sameCallDomain(owned.binding, binding) { return owned }
            if ticket.outcome == .failed { throw V2Error.stale }
            if ContinuousClock.now >= deadline { throw V2Error.stale }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
    private func waitForIncomingVerification(
        uuid: UUID,
        deadline overrideDeadline: ContinuousClock.Instant? = nil,
        abortOnEnding: Bool = false
    ) async throws {
        guard incomingPush != nil, verifiedBinding == nil else { return }
        while verifiedBinding == nil {
            if abortOnEnding && endingUUID == uuid { throw V2Error.stale }
            let effectiveDeadline: ContinuousClock.Instant? = {
                switch (incomingAssociationDeadline, overrideDeadline) {
                case let (a?, b?): return a < b ? a : b
                case let (a?, nil): return a
                case let (nil, b?): return b
                case (nil, nil): return nil
                }
            }()
            guard incomingSystemUUID == uuid, calls.currentSystemCallUUID == uuid,
                  let deadline = effectiveDeadline, ContinuousClock.now < deadline else {
                throw V2Error.stale
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    func callKitStart(number: String) async throws {
        let normalized = AppModel.normalizedV2DialNumber(number)
        guard !normalized.isEmpty else { throw V2Error.invalidValue }
        guard model.foreground, let binding = model.freshBinding, let uuid = calls.currentSystemCallUUID,
              calls.handler === self, endingUUID != uuid else { throw V2Error.stale }
        verifiedBinding = binding
        let ticket = await model.systemCommand("call.dial", args: ["number": normalized], binding: binding) { self.association = $0 }
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
    func callKitDidReceiveIncoming(_ call: IncomingVoIPCall) {
        guard let push = call.v2Push, let systemUUID = calls.currentSystemCallUUID,
              systemUUID == push.callUUID || currentCallID == push.callID else {
#if DEBUG
            V2DebugTrace.record("incomingMismatch push=\(call.v2Push != nil) uuid=\(calls.currentSystemCallUUID != nil)")
#endif
            calls.reportCurrentCallEnded(reason: .failed)
            return
        }
        if currentCallID == push.callID, let binding = authorizedBinding,
           binding.bootID == push.domain.agentBootID, binding.backendEpoch == push.domain.backendEpoch,
           binding.moduleID == push.domain.moduleID, binding.identity.serverID == push.domain.serverID,
           (model.usingUSB || controlledCall != nil || association != nil || binding.connectionEpoch == push.domain.connectionEpoch) {
            if model.usingUSB {
                Task { [weak self] in await self?.model.verifyUSBPush(push) }
            }
            return
        }
        incomingPush = push
        verifyingPush = true
        incomingSystemUUID = systemUUID
        incomingAssociationDeadline = ContinuousClock.now.advanced(by: associationTimeout)
        incomingID = call.callID
        verifiedBinding = nil
        let expectedUUID = push.callUUID
        Task { [weak self] in
            guard let self else { return }
            await self.model.prepareForIncomingPush(push)
            self.verifyingPush = false
            if self.model.snapshot != nil { self.observeSnapshot() }
            guard self.incomingPush?.callUUID == expectedUUID else { return }
            await self.model.ensurePollingForSystemCall()
            try? await Task.sleep(for: self.associationTimeout)
            guard self.incomingPush?.callUUID == expectedUUID else { return }
            self.endSystemCall()
        }
    }
    private func waitForAnswerReadiness(uuid: UUID, deadline: ContinuousClock.Instant) async throws -> (V2ControlBinding, String) {
        while calls.handler === self && calls.currentSystemCallUUID == uuid {
            if endingUUID == uuid { throw V2Error.stale }
            if let verified = verifiedBinding, let id = currentCallID {
                if !model.busy && model.telephonyReady, let fresh = model.freshBinding,
                   sameCallDomain(fresh, verified) {
                    if fresh != verified { rebind(from: verified, to: fresh) }
                    return (fresh, id)
                }
            }
            guard ContinuousClock.now < deadline else { throw V2Error.stale }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw V2Error.stale
    }
    func callKitAnswer(origin: CallAnswerOrigin) async throws {
        guard let uuid = calls.currentSystemCallUUID else { throw V2Error.stale }
        let deadline = ContinuousClock.now.advanced(by: associationTimeout)
        do {
#if DEBUG
            V2DebugTrace.record("answerStart verified=\(verifiedBinding != nil) pendingPush=\(incomingPush != nil)")
            do { try await waitForIncomingVerification(uuid: uuid, abortOnEnding: true) }
            catch { V2DebugTrace.record("answerVerificationTimeout"); throw error }
#else
            try await waitForIncomingVerification(uuid: uuid, abortOnEnding: true)
#endif
            var binding: V2ControlBinding
            var ticket: V2SystemCommandSubmission
            while true {
                let ready = try await waitForAnswerReadiness(uuid: uuid, deadline: deadline)
                if endingUUID == uuid { return }
                binding = ready.0
                let id = ready.1
                ticket = await model.systemCommand("call.answer", args: ["call_id": id], binding: binding) { self.association = $0 }
#if DEBUG
                V2DebugTrace.record("answerSubmitted outcome=\(ticket.outcome) command=\(ticket.commandID != nil)")
#endif
                // Only retry waiting when no HTTP command was posted (e.g. momentary busy/freshness race).
                if ticket.commandID == nil, ticket.outcome == .failed,
                   calls.handler === self, calls.currentSystemCallUUID == uuid,
                   endingUUID != uuid, !model.hasUnresolvedCommand, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                break
            }
            let owned = try await waitForAssociation(ticket, uuid: uuid, binding: binding, timeout: associationTimeout)
            guard isCurrent(uuid, binding: binding) else { return }
            controlledCall = owned
        } catch {
            guard calls.handler === self, calls.currentSystemCallUUID == uuid, endingUUID != uuid else { return }
            throw error
        }
    }
    private enum EndReadiness {
        case ready(V2ControlBinding, String)
        case alreadyEnded
        case timedOut
    }
    private func waitForEndReadiness(uuid: UUID, deadline: ContinuousClock.Instant) async throws -> EndReadiness {
        var lastRefresh: ContinuousClock.Instant?
        while calls.handler === self && calls.currentSystemCallUUID == uuid {
            guard let expected = authorizedBinding, let id = currentCallID else { return .alreadyEnded }
            if model.pendingHangupCallID == id { return .alreadyEnded }
            if let response = model.snapshot, response.online, let snap = response.snapshot,
               response.server_id == expected.identity.serverID, response.module_id == expected.moduleID {
                if snap.agent_boot_id != expected.bootID || snap.backend_epoch != expected.backendEpoch {
                    return .alreadyEnded
                }
                if snap.calls.calls.contains(where: { $0.call_id == id && $0.state == "disconnected" }) {
                    return .alreadyEnded
                }
            }
            let needOwned = model.ownedCall?.callID == id
            if !model.busy && !model.hasUnresolvedCommand,
               let fresh = model.freshBinding, sameCallDomain(fresh, expected) {
                if fresh != expected { rebind(from: expected, to: fresh) }
                let ready = needOwned ? model.ownedControlReady : model.telephonyReady
                if ready { return .ready(fresh, id) }
            }
            guard ContinuousClock.now < deadline else { return .timedOut }
            let needsRefresh = !model.connected || model.freshBinding == nil || (needOwned && !model.ownedControlReady)
            if needsRefresh && !model.busy {
                let now = ContinuousClock.now
                if lastRefresh == nil || now - lastRefresh! >= .milliseconds(400) {
                    lastRefresh = now
                    await model.refreshForSystemCallControl()
                    continue
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return .alreadyEnded
    }
    func callKitEnd() async throws {
        guard let uuid = calls.currentSystemCallUUID else { return }
        endingUUID = uuid
        let deadline = ContinuousClock.now.advanced(by: endAssociationTimeout)
        if incomingPush != nil && verifiedBinding == nil {
            try await waitForIncomingVerification(uuid: uuid, deadline: deadline)
        }
        guard let initialBinding = authorizedBinding else { return }
        var waitedForAssociation = false
        if let ticket = association, ticket.ownedCall == nil {
            waitedForAssociation = true
            guard let owned = try? await waitForAssociation(ticket, uuid: uuid, binding: initialBinding, timeout: endAssociationTimeout),
                  isCurrent(uuid, binding: initialBinding) else { return }
            controlledCall = owned
        }
        while calls.handler === self && calls.currentSystemCallUUID == uuid {
            switch try await waitForEndReadiness(uuid: uuid, deadline: deadline) {
            case .alreadyEnded:
                return
            case .timedOut:
                if waitedForAssociation { return }
                throw V2Error.stale
            case let .ready(binding, id):
                let result = await model.systemCommand("call.hangup", args: ["call_id": id], binding: binding)
                // Only retry waiting when no HTTP POST was sent (e.g. momentary busy/freshness race).
                if result.commandID == nil, result.outcome == .failed,
                   calls.handler === self, calls.currentSystemCallUUID == uuid,
                   !model.hasUnresolvedCommand, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                if result.outcome == .failed { throw V2Error.stale }
                return
            }
        }
    }
    func callKitSetMutedSync(_ muted: Bool) { model.media.setMuted(muted) }
    func callKitSetMuted(_ muted: Bool) async { callKitSetMutedSync(muted) }
    func callKitPlayDTMF(_ digits: String) async throws {
        let sanitized = String(digits.uppercased().filter { "0123456789ABCD*#".contains($0) }.prefix(16))
        guard !sanitized.isEmpty else { return }
        guard let uuid = calls.currentSystemCallUUID else { throw V2Error.stale }
        let deadline = ContinuousClock.now.advanced(by: endAssociationTimeout)
        var lastRefresh: ContinuousClock.Instant?
        while calls.handler === self && calls.currentSystemCallUUID == uuid && endingUUID != uuid {
            if !model.busy && !model.hasUnresolvedCommand,
               model.ownedControlReady, let owned = model.ownedCall {
                let result = await model.systemCommand("call.dtmf", args: ["call_id": owned.callID, "tones": sanitized], binding: owned.binding)
                if result.commandID == nil, result.outcome == .failed,
                   calls.handler === self, calls.currentSystemCallUUID == uuid,
                   endingUUID != uuid, !model.hasUnresolvedCommand, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                if result.outcome == .failed { throw V2Error.stale }
                return
            }
            guard ContinuousClock.now < deadline else { throw V2Error.stale }
            let needsRefresh = !model.connected || model.freshBinding == nil || (model.ownedCall != nil && !model.ownedControlReady)
            if needsRefresh && !model.busy {
                let now = ContinuousClock.now
                if lastRefresh == nil || now - lastRefresh! >= .milliseconds(400) {
                    lastRefresh = now
                    await model.refreshForSystemCallControl()
                    continue
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw V2Error.stale
    }
    func callKitAudioSessionDidActivate() async {
#if DEBUG
        NSLog("[AirSIM Media] stage=callKitActivate")
#endif
        guard hasSystemCall, endingUUID == nil else { return }
        audioGeneration &+= 1; let stamp = audioGeneration
        await model.media.stop()
        guard hasSystemCall, endingUUID == nil, audioGeneration == stamp else { return }
        model.media.callKitAudioActivated(AVAudioSession.sharedInstance())
        guard hasSystemCall, endingUUID == nil, audioGeneration == stamp else {
#if DEBUG
            NSLog("[AirSIM Media] stage=callKitActivateSkipped hasSystemCall=%d currentGeneration=%d", hasSystemCall ? 1 : 0, audioGeneration == stamp ? 1 : 0)
#endif
            return
        }
#if DEBUG
        NSLog("[AirSIM Media] stage=callKitActivateAccepted")
#endif
        model.systemAudioActive = true; model.updateRingback(); model.connectAudio()
    }
    func callKitAudioSessionDidDeactivate() {
#if DEBUG
        NSLog("[AirSIM Media] stage=callKitDeactivate")
#endif
        audioGeneration &+= 1; model.systemAudioActive = false; model.updateRingback(); model.media.requestStop()
        model.media.callKitAudioDeactivated(AVAudioSession.sharedInstance())
    }
    func callKitProviderDidReset() async {
        model.systemAudioActive = false; model.updateRingback(); await model.media.stop()
        if let owned = model.ownedCall, resetHangups.insert(owned.callID).inserted {
            _ = await model.systemCommand("call.hangup", args: ["call_id": owned.callID])
        }
        clearContext()
        await model.systemCallScopeChanged()
    }
    func callKitDidFail(_ message: String) { model.error = "系统通话未完成，请检查连接与权限。" }
    func callKitCallDidEnd() {
        clearContext(); model.systemAudioActive = false; model.updateRingback(); model.media.requestStop()
        Task { await model.systemCallScopeChanged() }
    }
}
