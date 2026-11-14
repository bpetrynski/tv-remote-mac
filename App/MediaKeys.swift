// The Mac's media keys (F7 ⏮, F8 ⏯, F9 ⏭) for the TV.
//
// The app registers as the system's "Now Playing" app, and macOS sends it the media keys.
// No Accessibility or Input Monitoring permission is needed (an event tap would need one,
// and with an ad-hoc signature it would have to be granted again after every build).
// The catch: an app that starts playing (Music, a video in a browser) becomes Now Playing
// and takes the keys. Using the remote announces the TV again, which may win them back.

import MediaPlayer

@MainActor
enum MediaKeys {
    static let key = "mediaKeys"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private static var targets: [(MPRemoteCommand, Any)] = []
    /// The TV's play state if its driver reports one; nil = unknown.
    private static var playing: Bool?

    /// "Paused" only when the TV says so. Unknown counts as playing: that keeps the app
    /// first in line for the keys.
    private static var shown: MPNowPlayingPlaybackState { playing == false ? .paused : .playing }

    /// Takes the keys (or gives them back) and shows the active TV as Now Playing.
    static func apply(_ model: RemoteModel) {
        let center = MPRemoteCommandCenter.shared()
        for (command, target) in targets { command.removeTarget(target) }
        targets = []

        let info = MPNowPlayingInfoCenter.default()
        playing = model.state.playing
        guard enabled, let tv = model.active else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }

        func route(_ command: MPRemoteCommand, to action: RemoteAction) {
            command.isEnabled = true
            let target = command.addTarget { _ in
                Task { @MainActor in model.run(action) }
                return .success
            }
            targets.append((command, target))
        }
        route(center.togglePlayPauseCommand, to: .playPause)   // F8
        route(center.playCommand, to: .play)
        route(center.pauseCommand, to: .pause)
        route(center.previousTrackCommand, to: .rewind)        // F7
        route(center.nextTrackCommand, to: .forward)           // F9

        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: tv.name,
            MPMediaItemPropertyArtist: "TV Remote",
        ]
        info.playbackState = shown
    }

    /// The TV's play state changed (or became unknown).
    static func update(playing: Bool?) {
        guard playing != self.playing else { return }
        self.playing = playing
        guard !targets.isEmpty else { return }
        MPNowPlayingInfoCenter.default().playbackState = shown
    }

    /// Announces the TV again after another app took over Now Playing.
    static func reclaim() {
        guard !targets.isEmpty else { return }
        MPNowPlayingInfoCenter.default().playbackState = shown
    }
}
