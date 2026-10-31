import Foundation

// Field spellings intentionally follow the frozen R4 wire contract.

struct V2Call: Codable, Equatable {
    let call_id: String
    let state: String
    let ownership: String
    let direction: String
    let number: String
    let observed_at: String
    let observedAt: Date
    let disconnect_reason: String
    private enum CodingKeys: String, CodingKey { case call_id, state, ownership, direction, number, observed_at, disconnect_reason }
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("call_id state ownership direction number observed_at disconnect_reason", optional: "")
        call_id = try c.get("call_id")
        state = try c.get("state")
        ownership = try c.get("ownership")
        direction = try c.get("direction")
        number = try c.get("number")
        observed_at = try c.get("observed_at")
        disconnect_reason = try c.get("disconnect_reason")
        try V2Validation.uuid(call_id, empty: false)
        observedAt = try V2Validation.date(observed_at)
    }
}

struct V2ControlStatus: Decodable {
    let schema_version: Int
    let agent_boot_id: String
    let backend_epoch: String
    let ready: Bool
    let reason: String
    let scope: String
    let voice_ready: Bool
    let telephony_ready: Bool
    let messaging_ready: Bool
    let inbox_gap: Bool
    let inbox_dropped: UInt64
    let command_capacity_remaining: UInt64
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("schema_version agent_boot_id backend_epoch ready reason scope voice_ready telephony_ready messaging_ready inbox_gap inbox_dropped command_capacity_remaining", optional: "")
        schema_version = try c.get("schema_version")
        agent_boot_id = try c.get("agent_boot_id")
        backend_epoch = try c.get("backend_epoch")
        ready = try c.get("ready")
        reason = try c.get("reason")
        scope = try c.get("scope")
        voice_ready = try c.get("voice_ready")
        telephony_ready = try c.get("telephony_ready")
        messaging_ready = try c.get("messaging_ready")
        inbox_gap = try c.get("inbox_gap")
        inbox_dropped = try c.get("inbox_dropped")
        command_capacity_remaining = try c.get("command_capacity_remaining")
        try V2Validation.uuid(agent_boot_id, empty: true)
        try V2Validation.uuid(backend_epoch, empty: true)
        guard schema_version == 1 else { throw V2Error.invalidValue }
    }
}

struct V2Calls: Decodable {
    let agent_boot_id: String
    let backend_epoch: String
    let available: Bool
    let calls: [V2Call]
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("agent_boot_id backend_epoch available calls", optional: "")
        agent_boot_id = try c.get("agent_boot_id")
        backend_epoch = try c.get("backend_epoch")
        available = try c.get("available")
        calls = try c.get("calls")
        try V2Validation.uuid(agent_boot_id, empty: true)
        try V2Validation.uuid(backend_epoch, empty: true)
    }
}

struct V2Message: Codable, Equatable {
    let message_id: String
    let direction: String
    let sender: String
    let recipient: String
    let text: String
    let state: String
    let delivery: String
    let observed_at: String
    let observedAt: Date
    private enum CodingKeys: String, CodingKey { case message_id, direction, sender, recipient, text, state, delivery, observed_at }
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("message_id direction sender recipient text state delivery observed_at", optional: "")
        message_id = try c.get("message_id")
        direction = try c.get("direction")
        sender = try c.get("sender")
        recipient = try c.get("recipient")
        text = try c.get("text")
        state = try c.get("state")
        delivery = try c.get("delivery")
        observed_at = try c.get("observed_at")
        try V2Validation.uuid(message_id, empty: false)
        observedAt = try V2Validation.date(observed_at)
    }
}

struct V2PCMConfig: Decodable {
    let sample_rate: UInt32
    let period_size: UInt32
    let period_count: UInt32
    let buffer_frames: UInt32
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("sample_rate period_size period_count buffer_frames", optional: "")
        sample_rate = try c.get("sample_rate")
        period_size = try c.get("period_size")
        period_count = try c.get("period_count")
        buffer_frames = try c.get("buffer_frames")
    }
}

struct V2HelperEvent: Decodable {
    let type: String
    let code: String?
    let sample_rate: UInt32?
    let channels: UInt32?
    let sample_format: String?
    let frame_samples: UInt32?
    let capture: V2PCMConfig?
    let playback: V2PCMConfig?
    let capture_samples: UInt64?
    let playback_samples: UInt64?
    let capture_xruns: UInt64?
    let playback_xruns: UInt64?
    let capture_drops: UInt64?
    let playback_drops: UInt64?
    let input_drops: UInt64?
    let sequence_gaps: UInt64?
    let silence_samples: UInt64?
    let queue_peak: UInt64?
    let elapsed_ms: UInt64?
    let capture_progress_ms: UInt64?
    let playback_progress_ms: UInt64?
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("type", optional: "code sample_rate channels sample_format frame_samples capture playback capture_samples playback_samples capture_xruns playback_xruns capture_drops playback_drops input_drops sequence_gaps silence_samples queue_peak elapsed_ms capture_progress_ms playback_progress_ms")
        type = try c.get("type")
        code = try c.optional("code")
        sample_rate = try c.optional("sample_rate")
        channels = try c.optional("channels")
        sample_format = try c.optional("sample_format")
        frame_samples = try c.optional("frame_samples")
        capture = try c.optional("capture")
        playback = try c.optional("playback")
        capture_samples = try c.optional("capture_samples")
        playback_samples = try c.optional("playback_samples")
        capture_xruns = try c.optional("capture_xruns")
        playback_xruns = try c.optional("playback_xruns")
        capture_drops = try c.optional("capture_drops")
        playback_drops = try c.optional("playback_drops")
        input_drops = try c.optional("input_drops")
        sequence_gaps = try c.optional("sequence_gaps")
        silence_samples = try c.optional("silence_samples")
        queue_peak = try c.optional("queue_peak")
        elapsed_ms = try c.optional("elapsed_ms")
        capture_progress_ms = try c.optional("capture_progress_ms")
        playback_progress_ms = try c.optional("playback_progress_ms")
    }
}

struct V2AudioSessionStatus: Decodable {
    let session_id: String
    let call_id: String
    let agent_boot_id: String
    let backend_epoch: String
    let state: String
    let reason: String
    let created_at: String
    let closed_at: String?
    let uplink_frames: UInt64
    let downlink_frames: UInt64
    let uplink_sequence_gaps: UInt64
    let downlink_sequence_gaps: UInt64
    let last_uplink: String?
    let last_downlink: String?
    let actual: V2HelperEvent?
    let helper_stats: V2HelperEvent?
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("session_id call_id agent_boot_id backend_epoch state reason created_at uplink_frames downlink_frames uplink_sequence_gaps downlink_sequence_gaps", optional: "closed_at last_uplink last_downlink actual helper_stats")
        session_id = try c.get("session_id")
        call_id = try c.get("call_id")
        agent_boot_id = try c.get("agent_boot_id")
        backend_epoch = try c.get("backend_epoch")
        state = try c.get("state")
        reason = try c.get("reason")
        created_at = try c.get("created_at")
        closed_at = try c.optional("closed_at")
        uplink_frames = try c.get("uplink_frames")
        downlink_frames = try c.get("downlink_frames")
        uplink_sequence_gaps = try c.get("uplink_sequence_gaps")
        downlink_sequence_gaps = try c.get("downlink_sequence_gaps")
        last_uplink = try c.optional("last_uplink")
        last_downlink = try c.optional("last_downlink")
        actual = try c.optional("actual")
        helper_stats = try c.optional("helper_stats")
        try V2Validation.uuid(session_id, empty: false)
        try V2Validation.uuid(call_id, empty: false)
        try V2Validation.uuid(agent_boot_id, empty: true)
        try V2Validation.uuid(backend_epoch, empty: true)
        _ = try V2Validation.date(created_at)
        if let closed_at { _ = try V2Validation.date(closed_at) }
        if let last_uplink { _ = try V2Validation.date(last_uplink) }
        if let last_downlink { _ = try V2Validation.date(last_downlink) }
    }
}

struct V2AudioStatus: Decodable {
    let available: Bool
    let implementation: String
    let verification: String
    let voice_ready: Bool
    let reason: String
    let session: V2AudioSessionStatus?
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("available implementation verification voice_ready reason", optional: "session")
        available = try c.get("available")
        implementation = try c.get("implementation")
        verification = try c.get("verification")
        voice_ready = try c.get("voice_ready")
        reason = try c.get("reason")
        session = try c.optional("session")
    }
}

struct V2MediaFormat: Decodable {
    let sample_rate: Int
    let channels: Int
    let sample_format: String
    let frame_samples: Int
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("sample_rate channels sample_format frame_samples", optional: "")
        sample_rate = try c.get("sample_rate")
        channels = try c.get("channels")
        sample_format = try c.get("sample_format")
        frame_samples = try c.get("frame_samples")
        guard sample_rate == 8000, channels == 1, sample_format == "s16le", frame_samples == 160 else { throw V2Error.protocolViolation }
    }
}

struct V2Signal: Decodable {
    let available: Bool
    let observed_at: String?
    let observedAt: Date?
    let rssi: Int?
    let dbm: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("available observed_at rssi dbm")
        available = try c.get("available")
        observed_at = try c.nullable("observed_at")
        observedAt = try observed_at.map(V2Validation.date)
        rssi = try c.nullable("rssi")
        dbm = try c.nullable("dbm")
        if available {
            guard observedAt != nil, let rssi, (0...31).contains(rssi),
                  dbm == -113 + 2 * rssi else { throw V2Error.invalidValue }
        } else {
            guard rssi == nil, dbm == nil else { throw V2Error.invalidValue }
        }
    }

    func presentation(now: Date) -> ModuleSignalState {
        guard available, let observedAt, let rssi,
              (-3...30).contains(now.timeIntervalSince(observedAt)) else { return .unavailable }
        let bars: Int
        switch rssi {
        case 0...1: bars = 0
        case 2...9: bars = 1
        case 10...14: bars = 2
        case 15...19: bars = 3
        default: bars = 4
        }
        return .available(bars: bars)
    }
}

struct V2Snapshot: Decodable {
    let agent_boot_id: String
    let backend_epoch: String
    let observed_at: String
    let observedAt: Date
    let control: V2ControlStatus
    let calls: V2Calls
    let audio: V2AudioStatus
    let signal: V2Signal?
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("agent_boot_id backend_epoch observed_at control calls audio", optional: "signal")
        agent_boot_id = try c.get("agent_boot_id")
        backend_epoch = try c.get("backend_epoch")
        observed_at = try c.get("observed_at")
        control = try c.get("control")
        calls = try c.get("calls")
        audio = try c.get("audio")
        signal = try c.nullable("signal")
        try V2Validation.uuid(agent_boot_id, empty: true)
        try V2Validation.uuid(backend_epoch, empty: true)
        observedAt = try V2Validation.date(observed_at)
        guard agent_boot_id == control.agent_boot_id, agent_boot_id == calls.agent_boot_id, backend_epoch == control.backend_epoch, backend_epoch == calls.backend_epoch else { throw V2Error.invalidIdentity }
        if let session = audio.session { guard session.agent_boot_id == agent_boot_id, session.backend_epoch == backend_epoch else { throw V2Error.invalidIdentity } }
    }
}

struct V2Receipt: Decodable {
    let command_id: String
    let action: String
    let state: String
    let result_code: String
    let call_id: String?
    let message_id: String?
    let updated_at: String
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("command_id action state result_code updated_at", optional: "call_id message_id")
        command_id = try c.get("command_id"); action = try c.get("action"); state = try c.get("state")
        result_code = try c.get("result_code"); call_id = try c.optional("call_id"); message_id = try c.optional("message_id"); updated_at = try c.get("updated_at")
        try V2Validation.uuid(command_id)
        if let call_id { try V2Validation.uuid(call_id) }
        if let message_id { try V2Validation.uuid(message_id) }
        _ = try V2Validation.date(updated_at)
        guard ["prepared", "dispatched", "accepted", "observed", "failed", "expired", "outcome_unknown"].contains(state), result_code.count <= 64, V2Validation.matches(result_code, "^[a-z_]*$") else { throw V2Error.invalidValue }
    }
}

struct V2Capabilities: Decodable {
    let controlled_test_client: Bool
    let telephony: Bool
    let messaging: Bool
    let experimental_audio: Bool
    let apns: Bool
    let interactive_login: Bool
    let device_pairing: Bool
    let client_session_refresh: Bool
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields(
            "controlled_test_client telephony messaging experimental_audio apns interactive_login",
            optional: "device_pairing client_session_refresh"
        )
        controlled_test_client = try c.get("controlled_test_client")
        telephony = try c.get("telephony")
        messaging = try c.get("messaging")
        experimental_audio = try c.get("experimental_audio")
        apns = try c.get("apns")
        interactive_login = try c.get("interactive_login")
        device_pairing = try c.optional("device_pairing") ?? false
        client_session_refresh = try c.optional("client_session_refresh") ?? false
    }
}

struct V2Discovery: Decodable {
    let protocol_version: Int
    let profile: String
    let server_id: String
    let api_origin: String
    let device_origin: String
    let media_origin: String
    let capabilities: V2Capabilities
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("protocol_version profile server_id api_origin device_origin media_origin capabilities", optional: "")
        protocol_version = try c.get("protocol_version")
        profile = try c.get("profile")
        server_id = try c.get("server_id")
        api_origin = try c.get("api_origin")
        device_origin = try c.get("device_origin")
        media_origin = try c.get("media_origin")
        capabilities = try c.get("capabilities")
        try V2Validation.uuid(server_id, empty: false)
        guard protocol_version == 2, ["airsim-v2-r4.1", "airsim-v2-callkit"].contains(profile), capabilities.controlled_test_client, capabilities.telephony, capabilities.messaging, capabilities.experimental_audio, !capabilities.interactive_login else { throw V2Error.protocolViolation }
        _ = try V2Validation.origin(api_origin); _ = try V2Validation.origin(media_origin); _ = try V2Validation.origin(device_origin)
    }
}

struct V2Module: Decodable {
    let module_id: String
    let online: Bool
    let last_seen: String?
    let agent_boot_id: String
    let backend_epoch: String
    let connection_epoch: String
    let signal: V2Signal?
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("module_id online last_seen agent_boot_id backend_epoch connection_epoch", optional: "signal")
        module_id = try c.get("module_id")
        online = try c.get("online")
        last_seen = try c.nullable("last_seen")
        agent_boot_id = try c.get("agent_boot_id")
        backend_epoch = try c.get("backend_epoch")
        connection_epoch = try c.get("connection_epoch")
        signal = try c.nullable("signal")
        try V2Validation.uuid(module_id, empty: false)
        if let last_seen { _ = try V2Validation.date(last_seen) }
        try V2Validation.uuid(agent_boot_id, empty: true)
        try V2Validation.uuid(backend_epoch, empty: true)
        try V2Validation.uuid(connection_epoch, empty: true)
    }
}

struct V2Modules: Decodable {
    let server_id: String
    let modules: [V2Module]
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("server_id modules", optional: "")
        server_id = try c.get("server_id")
        modules = try c.get("modules")
        try V2Validation.uuid(server_id, empty: false)
        guard Set(modules.map(\.module_id)).count == modules.count else { throw V2Error.invalidIdentity }
    }
}

struct V2SnapshotResponse: Decodable {
    let server_id: String
    let module_id: String
    let online: Bool
    let last_seen: String?
    let connection_epoch: String
    let snapshot: V2Snapshot?
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("server_id module_id online last_seen connection_epoch snapshot", optional: "")
        server_id = try c.get("server_id")
        module_id = try c.get("module_id")
        online = try c.get("online")
        last_seen = try c.nullable("last_seen")
        connection_epoch = try c.get("connection_epoch")
        snapshot = try c.nullable("snapshot")
        try V2Validation.uuid(server_id, empty: false)
        try V2Validation.uuid(module_id, empty: false)
        if let last_seen { _ = try V2Validation.date(last_seen) }
        try V2Validation.uuid(connection_epoch, empty: true)
    }
}

struct V2MessagesResponse: Decodable {
    let server_id: String
    let module_id: String
    let agent_boot_id: String
    let backend_epoch: String
    let online: Bool
    let inbox_gap: Bool
    let inbox_dropped: UInt64
    let messages: [V2Message]
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("server_id module_id agent_boot_id backend_epoch online inbox_gap inbox_dropped messages", optional: "")
        server_id = try c.get("server_id")
        module_id = try c.get("module_id")
        agent_boot_id = try c.get("agent_boot_id")
        backend_epoch = try c.get("backend_epoch")
        online = try c.get("online")
        inbox_gap = try c.get("inbox_gap")
        inbox_dropped = try c.get("inbox_dropped")
        messages = try c.get("messages")
        try V2Validation.uuid(server_id, empty: false)
        try V2Validation.uuid(module_id, empty: false)
        try V2Validation.uuid(agent_boot_id, empty: true)
        try V2Validation.uuid(backend_epoch, empty: true)
        guard messages.count <= 128, Set(messages.map(\.message_id)).count == messages.count else { throw V2Error.invalidValue }
    }
}

struct V2CommandRecord: Decodable {
    let command_id: String
    let state: String
    let generation: String
    let receipt: V2Receipt?
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("command_id state generation receipt", optional: "")
        command_id = try c.get("command_id")
        state = try c.get("state")
        generation = try c.get("generation")
        receipt = try c.nullable("receipt")
        try V2Validation.uuid(command_id, empty: false)
        try V2Validation.uuid(generation)
        guard ["pending", "dispatched", "completed", "outcome_unknown"].contains(state) else { throw V2Error.invalidValue }
        if let receipt { guard receipt.command_id == command_id else { throw V2Error.invalidIdentity } }
    }
}

struct V2MediaCreated: Decodable {
    let session_id: String
    let ticket: String
    let expires_at: String
    let media_url: String
    let format: V2MediaFormat
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("session_id ticket expires_at media_url format", optional: "")
        session_id = try c.get("session_id")
        ticket = try c.get("ticket")
        expires_at = try c.get("expires_at")
        media_url = try c.get("media_url")
        format = try c.get("format")
        try V2Validation.uuid(session_id, empty: false)
        _ = try V2Validation.date(expires_at)
        guard V2Validation.matches(ticket, "^[0-9a-f]{64}$") else { throw V2Error.invalidValue }
    }
}

struct V2ServerError: Decodable {
    let error: String
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("error", optional: "")
        error = try c.get("error")
    }
}
