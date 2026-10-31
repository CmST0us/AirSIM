package control

import "time"

type PCMConfig struct {
	SampleRate   uint32 `json:"sample_rate"`
	PeriodSize   uint32 `json:"period_size"`
	PeriodCount  uint32 `json:"period_count"`
	BufferFrames uint32 `json:"buffer_frames"`
}
type HelperEvent struct {
	Codec              string     `json:"codec,omitempty"`
	CodecFrameUS       int        `json:"codec_frame_us,omitempty"`
	CodecFrameBytes    int        `json:"codec_frame_bytes,omitempty"`
	Type               string     `json:"type"`
	Code               string     `json:"code,omitempty"`
	SampleRate         uint32     `json:"sample_rate,omitempty"`
	Channels           uint32     `json:"channels,omitempty"`
	SampleFormat       string     `json:"sample_format,omitempty"`
	FrameSamples       uint32     `json:"frame_samples,omitempty"`
	Capture            *PCMConfig `json:"capture,omitempty"`
	Playback           *PCMConfig `json:"playback,omitempty"`
	CaptureSamples     uint64     `json:"capture_samples,omitempty"`
	PlaybackSamples    uint64     `json:"playback_samples,omitempty"`
	CaptureXRuns       uint64     `json:"capture_xruns,omitempty"`
	PlaybackXRuns      uint64     `json:"playback_xruns,omitempty"`
	CaptureDrops       uint64     `json:"capture_drops,omitempty"`
	PlaybackDrops      uint64     `json:"playback_drops,omitempty"`
	InputDrops         uint64     `json:"input_drops,omitempty"`
	SequenceGaps       uint64     `json:"sequence_gaps,omitempty"`
	SilenceSamples     uint64     `json:"silence_samples,omitempty"`
	QueuePeak          uint64     `json:"queue_peak,omitempty"`
	ElapsedMS          uint64     `json:"elapsed_ms,omitempty"`
	CaptureProgressMS  uint64     `json:"capture_progress_ms,omitempty"`
	PlaybackProgressMS uint64     `json:"playback_progress_ms,omitempty"`
}

type SessionStatus struct {
	ID             string       `json:"session_id"`
	CallID         string       `json:"call_id"`
	Boot           string       `json:"agent_boot_id"`
	Epoch          string       `json:"backend_epoch"`
	State          string       `json:"state"`
	Reason         string       `json:"reason"`
	Created        time.Time    `json:"created_at"`
	Closed         *time.Time   `json:"closed_at,omitempty"`
	UplinkFrames   uint64       `json:"uplink_frames"`
	DownlinkFrames uint64       `json:"downlink_frames"`
	UplinkGaps     uint64       `json:"uplink_sequence_gaps"`
	DownlinkGaps   uint64       `json:"downlink_sequence_gaps"`
	LastUplink     *time.Time   `json:"last_uplink,omitempty"`
	LastDownlink   *time.Time   `json:"last_downlink,omitempty"`
	Actual         *HelperEvent `json:"actual,omitempty"`
	Stats          *HelperEvent `json:"helper_stats,omitempty"`
}
type AudioStatus struct {
	Available      bool           `json:"available"`
	Implementation string         `json:"implementation"`
	Verification   string         `json:"verification"`
	VoiceReady     bool           `json:"voice_ready"`
	Reason         string         `json:"reason"`
	Session        *SessionStatus `json:"session,omitempty"`
}
