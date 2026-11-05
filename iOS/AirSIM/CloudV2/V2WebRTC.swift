import AVFoundation
import Foundation
import UIKit
import WebRTC

struct V2ICEServer: Decodable, Equatable {
    let urls: [String]
    let username: String
    let credential: String
    init(urls: [String], username: String, credential: String) { self.urls = urls; self.username = username; self.credential = credential }
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("urls username credential", optional: "")
        urls = try c.get("urls"); username = try c.get("username"); credential = try c.get("credential")
        guard (1...4).contains(urls.count), urls.allSatisfy({ $0.hasPrefix("turn:") && $0.utf8.count <= 256 }),
              !username.isEmpty, username.utf8.count <= 256, !credential.isEmpty, credential.utf8.count <= 256 else { throw V2Error.invalidValue }
    }
}

enum V2PeerState: Equatable { case connecting, connected, disconnected, failed, closed }
enum V2PeerError: Error { case offer, gathering, answer }

/// Counters read from WebRTC statistics. Never contains SDP, addresses or audio.
struct V2PeerStatistics: Equatable {
    var packetsReceived: UInt64 = 0, packetsSent: UInt64 = 0
    var packetsLost: Int64 = 0, concealedSamples: UInt64 = 0, receivedSamples: UInt64 = 0
    var jitterBufferMilliseconds = 0.0, roundTripMilliseconds = 0.0
    /// Local candidate type of the selected pair: host, srflx, prflx or relay.
    var candidate = ""
}

/// The WebRTC connection the media coordinator drives; tests substitute a fake.
@MainActor
protocol V2MediaPeer: AnyObject {
    var onState: ((V2PeerState) -> Void)? { get set }
    /// Gathers candidates and returns the complete offer.
    func offer() async throws -> String
    func accept(answer: String) async throws
    func setMuted(_ muted: Bool)
    func statistics() async -> V2PeerStatistics
    func close()
}

/// An output the call can play through. The receiver exists on iPhone only;
/// headsets, Bluetooth hands-free and car audio come and go.
struct V2AudioRoute: Identifiable, Equatable {
    enum Kind: Equatable { case receiver, speaker, external }
    let id: String
    let name: String
    let kind: Kind
    var symbol: String {
        switch kind {
        case .receiver: return "iphone"
        case .speaker: return "speaker.wave.2.fill"
        case .external: return name.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones"
        }
    }
    static let receiver = V2AudioRoute(id: "receiver", name: "iPhone", kind: .receiver)
    static let speaker = V2AudioRoute(id: "speaker", name: "扬声器", kind: .speaker)
}

/// WebRTC audio stays off until CallKit, or the App without CallKit, activates
/// the voice session; the audio unit never runs on an inactive session.
@MainActor
protocol V2MediaAudio: AnyObject {
    func activateVoice() throws
    func deactivateVoice()
    func callKitActivated(_ session: AVAudioSession)
    func callKitDeactivated(_ session: AVAudioSession)
    var routes: [V2AudioRoute] { get }
    var currentRoute: V2AudioRoute? { get }
    func select(_ route: V2AudioRoute) throws
}

// The bundled SDK exposes field trials through this process-wide API. Initialize
// once, before either RTCAudioSession or the peer factory touches WebRTC.
@MainActor
private enum V2WebRTCRuntime {
    private static let initialized: Void = {
        // Two exact prior Opus packets protect a two-packet burst. libwebrtc
        // drops older redundancy first when its packet size budget is reached.
        RTCInitFieldTrialDictionary(["WebRTC-Audio-Red-For-Opus": "Enabled-2"])
        RTCInitializeSSL()
    }()
    static func initialize() { _ = initialized }
}

@MainActor
final class V2WebRTCAudio: V2MediaAudio {
    private var session: RTCAudioSession { RTCAudioSession.sharedInstance() }
    init() {
        V2WebRTCRuntime.initialize()
        session.useManualAudio = true
        session.isAudioEnabled = false
    }
    var routes: [V2AudioRoute] {
        var routes = UIDevice.current.userInterfaceIdiom == .phone ? [V2AudioRoute.receiver, .speaker] : [.speaker]
        for port in AVAudioSession.sharedInstance().availableInputs ?? [] where port.portType != .builtInMic {
            routes.append(V2AudioRoute(id: port.uid, name: port.portName, kind: .external))
        }
        // Headphones without a microphone are an output only.
        if let output = AVAudioSession.sharedInstance().currentRoute.outputs.first,
           ![.builtInReceiver, .builtInSpeaker].contains(output.portType), !routes.contains(where: { $0.name == output.portName }) {
            routes.append(V2AudioRoute(id: output.uid, name: output.portName, kind: .external))
        }
        return routes
    }
    var currentRoute: V2AudioRoute? {
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let output = route.outputs.first else { return nil }
        switch output.portType {
        case .builtInReceiver: return .receiver
        case .builtInSpeaker: return .speaker
        default:
            let input = route.inputs.first?.uid
            return routes.first { $0.kind == .external && ($0.id == input || $0.id == output.uid || $0.name == output.portName) }
        }
    }
    func select(_ route: V2AudioRoute) throws {
        let audio = AVAudioSession.sharedInstance()
        session.lockForConfiguration(); defer { session.unlockForConfiguration() }
        switch route.kind {
        case .receiver, .speaker:
            if let microphone = audio.availableInputs?.first(where: { $0.portType == .builtInMic }) { try session.setPreferredInput(microphone) }
            try session.overrideOutputAudioPort(route.kind == .speaker ? .speaker : .none)
        case .external:
            try session.overrideOutputAudioPort(.none)
            if let port = audio.availableInputs?.first(where: { $0.uid == route.id }) { try session.setPreferredInput(port) }
        }
    }
    func activateVoice() throws {
        session.lockForConfiguration(); defer { session.unlockForConfiguration() }
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setActive(true)
        session.isAudioEnabled = true
    }
    func deactivateVoice() {
        session.isAudioEnabled = false
        session.lockForConfiguration(); defer { session.unlockForConfiguration() }
        try? session.setActive(false)
    }
    func callKitActivated(_ audio: AVAudioSession) {
        session.audioSessionDidActivate(audio)
        session.isAudioEnabled = true
    }
    func callKitDeactivated(_ audio: AVAudioSession) {
        session.isAudioEnabled = false
        session.audioSessionDidDeactivate(audio)
    }
}

@MainActor
final class V2WebRTCPeer: V2MediaPeer {
    private static let factory: RTCPeerConnectionFactory = {
        V2WebRTCRuntime.initialize()
        return RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
    }()
    var onState: ((V2PeerState) -> Void)?
    private let connection: RTCPeerConnection
    private let track: RTCAudioTrack
    private let observer = Observer()
    private let relayed: Bool

    /// Without ICE servers the connection is the USB link and host candidates suffice.
    init(servers: [V2ICEServer], peerFactory: RTCPeerConnectionFactory? = nil) throws {
        V2WebRTCRuntime.initialize()
        // Injection permits a synthetic audio device in offline interoperability
        // tests; normal calls use the shared system-audio factory.
        let factory = peerFactory ?? Self.factory
        let config = RTCConfiguration()
        config.iceServers = servers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherOnce
        config.tcpCandidatePolicy = .disabled
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: config, constraints: constraints, delegate: observer) else { throw V2PeerError.offer }
        self.connection = connection
        relayed = !servers.isEmpty
        track = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "audio")
        let initial = RTCRtpTransceiverInit(); initial.direction = .sendRecv; initial.streamIds = ["airsim"]
        guard connection.addTransceiver(with: track, init: initial) != nil else { connection.close(); throw V2PeerError.offer }
        observer.state = { [weak self] state in Task { @MainActor in self?.onState?(state) } }
    }
    func offer() async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let description: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { sdp, _ in
                if let sdp { continuation.resume(returning: sdp) } else { continuation.resume(throwing: V2PeerError.offer) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if error == nil { continuation.resume() } else { continuation.resume(throwing: V2PeerError.offer) }
            }
        }
        // Signaling is non-trickle. The offer leaves shortly after the first usable
        // candidate: allocations still pending, or an interface whose relay never
        // answers, only delay the first audio.
        let start = ContinuousClock.now
        var usableAt: ContinuousClock.Instant?
        while connection.iceGatheringState != .complete {
            let now = ContinuousClock.now
            if now - start >= .seconds(8) { break }
            if usableAt == nil, let sdp = connection.localDescription?.sdp, sdp.contains(relayed ? "typ relay" : "typ host") { usableAt = now }
            if let usableAt, now - usableAt >= .milliseconds(250) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let sdp = connection.localDescription?.sdp, sdp.contains("a=candidate:") else { throw V2PeerError.gathering }
        return sdp
    }
    func accept(answer: String) async throws {
        let description = RTCSessionDescription(type: .answer, sdp: answer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if error == nil { continuation.resume() } else { continuation.resume(throwing: V2PeerError.answer) }
            }
        }
    }
    func setMuted(_ muted: Bool) { track.isEnabled = !muted }
    func statistics() async -> V2PeerStatistics {
        await withCheckedContinuation { continuation in
            connection.statistics { report in continuation.resume(returning: Self.parse(report.statistics)) }
        }
    }
    func close() {
        observer.state = nil
        connection.close()
    }

    nonisolated static func parse(_ report: [String: RTCStatistics]) -> V2PeerStatistics {
        func number(_ stat: RTCStatistics, _ key: String) -> NSNumber? { stat.values[key] as? NSNumber }
        var s = V2PeerStatistics()
        var local: String?
        for stat in report.values {
            switch stat.type {
            case "inbound-rtp" where stat.values["kind"] as? String == "audio":
                s.packetsReceived = number(stat, "packetsReceived")?.uint64Value ?? 0
                s.packetsLost = number(stat, "packetsLost")?.int64Value ?? 0
                s.concealedSamples = number(stat, "concealedSamples")?.uint64Value ?? 0
                s.receivedSamples = number(stat, "totalSamplesReceived")?.uint64Value ?? 0
                if let delay = number(stat, "jitterBufferDelay")?.doubleValue, let emitted = number(stat, "jitterBufferEmittedCount")?.doubleValue, emitted > 0 {
                    s.jitterBufferMilliseconds = delay / emitted * 1000
                }
            case "outbound-rtp" where stat.values["kind"] as? String == "audio":
                s.packetsSent = number(stat, "packetsSent")?.uint64Value ?? 0
            case "candidate-pair" where number(stat, "nominated")?.boolValue == true && stat.values["state"] as? String == "succeeded":
                s.roundTripMilliseconds = (number(stat, "currentRoundTripTime")?.doubleValue ?? 0) * 1000
                local = stat.values["localCandidateId"] as? String
            default: break
            }
        }
        if let local, let candidate = report[local] { s.candidate = candidate.values["candidateType"] as? String ?? "" }
        return s
    }

    /// RTCPeerConnection calls its delegate on the signaling thread.
    private final class Observer: NSObject, RTCPeerConnectionDelegate {
        var state: ((V2PeerState) -> Void)?
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
            switch newState {
            case .new, .connecting: state?(.connecting)
            case .connected: state?(.connected)
            case .disconnected: state?(.disconnected)
            case .failed: state?(.failed)
            case .closed: state?(.closed)
            @unknown default: state?(.failed)
            }
        }
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
        func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    }
}
