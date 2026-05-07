import Foundation

/// Holds high-frequency playback state that is written at display refresh rate
/// (60 fps) by the transport CADisplayLink. Isolating these properties from the
/// main ``MixStore`` ``Observable`` class means views that only observe the store
/// (via ``Bindable``) are **not** re-evaluated 60 times per second — only views
/// that explicitly observe ``MixTransportState`` react to playhead movement.
@available(macOS 26.0, *)
@Observable
final class MixTransportState {
    /// Current playhead position in seconds. Written 60 fps during playback.
    var playheadSeconds: Double = 0
    var isPlaying = false
    var isRecording = false
}
