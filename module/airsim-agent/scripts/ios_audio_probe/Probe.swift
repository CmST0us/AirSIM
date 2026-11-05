import Foundation
import WebRTC

@main struct Probe {
    @MainActor static func main() async {
        let audio = V2WebRTCAudio() // Initializes the production field trials first.
        RTCSetMinDebugLogLevel(.error)
        let device = SyntheticAudioDevice()
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: device)
        var stage = "offer"
        do {
            let peer = try V2WebRTCPeer(servers: [], peerFactory: factory)
            var connected = false
            peer.onState = { if $0 == .connected { connected = true } }
            let offer = try await peer.offer()
            guard offer.contains("red/48000") else { throw V2PeerError.offer }
            let endpoint = CommandLine.arguments[1]
            var request = URLRequest(url: URL(string: endpoint + "/offer")!)
            request.httpMethod = "POST"; request.httpBody = offer.data(using: .utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            stage = "answer"
            guard (response as? HTTPURLResponse)?.statusCode == 200, let answer = String(data: data, encoding: .utf8) else { throw V2PeerError.answer }
            try await peer.accept(answer: answer)
            stage = "connect"
            for _ in 0..<100 { if connected { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            guard connected else { throw V2PeerError.gathering }
            let pc = Mirror(reflecting: peer).children.first { $0.label == "connection" }!.value as! RTCPeerConnection
            let codecs = pc.transceivers.flatMap { $0.sender.parameters.codecs }
            stage = "codec"
            guard let opus = codecs.first(where: { $0.name.lowercased() == "opus" }),
                  (opus.parameters["maxaveragebitrate"] as? String) == "96000",
                  (opus.parameters["maxplaybackrate"] as? String) == "16000",
                  codecs.first?.name.lowercased() == "red" else { throw V2PeerError.answer }
            try await Task.sleep(nanoseconds: 3_000_000_000)
            stage = "media"
            let stats = await peer.statistics()
            let (body, _) = try await URLSession.shared.data(from: URL(string: endpoint + "/stats")!)
            let received = try JSONDecoder().decode([String: UInt64].self, from: body)
            guard stats.packetsReceived >= 50, received["primary", default: 0] >= 50,
                  received["depth_two", default: 0] >= 40, received["invalid", default: 0] == 0 else {
                print("PROBE COUNTERS: rx=\(stats.packetsReceived), primary=\(received["primary", default: 0]), depth_two=\(received["depth_two", default: 0]), invalid=\(received["invalid", default: 0])")
                throw V2PeerError.answer
            }
            print("PROBE PASS: iOS libwebrtc <-> module Pion; bidirectional SRTP; RED depth=2; Opus=96000/16000; no invalid packets")
            print("PROBE COUNTERS: rx=\(stats.packetsReceived), primary=\(received["primary", default: 0]), depth_two=\(received["depth_two", default: 0])")
            peer.close(); _ = audio; exit(0)
        } catch { print("PROBE FAIL: stage=\(stage), error=\(error)"); exit(1) }
    }
}
