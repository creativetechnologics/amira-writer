import Foundation

enum AnimateAppSignals {
    static let toggleInspectorNotification = Notification.Name("Animate.ToggleInspector")
    static let spacebarPlayPauseNotification = Notification.Name("Animate.SpacebarPlayPause")
    static let openFileNotification = Notification.Name("Animate.OpenFile")
    static let switchPageNotification = Notification.Name("Animate.SwitchPage")

    /// Posted when the Animate timeline wants Mix to flatten its audio for a scene.
    /// userInfo key "sceneID" → UUID of the scene requesting the flatten.
    /// MixAudioFlattenService listens for this and responds by calling
    /// `AnimateStore.setDefaultAudioPath(_:for:)` once the WAV is ready.
    static let requestMixAudioFlattenNotification = Notification.Name("Animate.RequestMixAudioFlatten")
}
