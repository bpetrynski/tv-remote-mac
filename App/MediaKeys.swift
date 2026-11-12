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

    /// Takes the keys (or gives them back) and shows the active TV as Now Playing.
    static func apply(_ model: RemoteModel) {
        let center = MPRemoteCommandCenter.shared()
        for (command, target) in targets { command.removeTarget(target) }
        targets = []

        let info = MPNowPlayingInfoCenter.default()
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
        // "Playing" keeps the app first in line for the keys; the TV's real state is unknown.
        info.playbackState = .playing
    }

    /// Announces the TV again after another app took over Now Playing.
    static func reclaim() {
        guard !targets.isEmpty else { return }
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }
}
