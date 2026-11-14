// TV Remote: shared types.
//
// A kind of TV is a `TVDriver`; a live link to one paired TV is a `TVConnection`.
// Built-in drivers are Swift classes (Philips.swift). External drivers are programs in any
// language that speak JSON lines on stdin/stdout (ScriptDriver.swift, DRIVERS.md).

import Foundation

// MARK: - Actions

/// Single source of truth for buttons, keyboard, tooltips and the shortcut sheet.
enum RemoteAction: String, CaseIterable {
    case up, down, left, right, ok, back, home
    case options, info, source
    case playPause, play, pause, rewind, forward
    case volumeDown, volumeUp, mute
    case keyboard
    case power, ambilight, refresh, locate, help

    /// Handled by the app itself, available for every TV.
    static let appLevel: Set<RemoteAction> = [.refresh, .locate, .help]

    /// What happens while a key is held down.
    enum Repeat {
        case none        // one press = one action
        case navigation  // repeat, but never build up a queue towards the TV
        case throttled   // repeat at a capped rate
    }

    var label: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .ok: "OK"
        case .back: "Back"
        case .home: "Home"
        case .options: "Options"
        case .info: "Info"
        case .source: "Source"
        case .playPause: "Play / Pause"
        case .play: "Play"
        case .pause: "Pause"
        case .rewind: "Rewind"
        case .forward: "Fast forward"
        case .volumeDown: "Volume down"
        case .volumeUp: "Volume up"
        case .mute: "Mute"
        case .keyboard: "Type text on the TV"
        case .power: "Power on / standby"
        case .ambilight: "Next Ambilight style"
        case .refresh: "Refresh status"
        case .locate: "Find TV on network"
        case .help: "Keyboard shortcuts"
        }
    }

    var symbol: String? {
        switch self {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        case .ok: nil
        case .back: "arrow.uturn.backward"
        case .home: "house"
        case .options: "ellipsis.circle"
        case .info: "info.circle"
        case .source: "tv.inset.filled"
        case .playPause: "playpause.fill"
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .rewind: "backward.fill"
        case .forward: "forward.fill"
        case .volumeDown: "speaker.minus"
        case .volumeUp: "speaker.plus"
        case .mute: "speaker.slash"
        case .keyboard: "keyboard"
        case .power: "power"
        case .ambilight: "lightbulb.led"
        case .refresh: "arrow.clockwise"
        case .locate: "antenna.radiowaves.left.and.right"
        case .help: "questionmark.circle"
        }
    }

    /// Shortcut as shown in tooltips and the shortcut sheet. The actual mapping lives in
    /// `KeyboardRouter.action(for:)` and in the "TV" menu (⌘ shortcuts).
    var shortcut: String {
        switch self {
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .ok: "↩"
        case .back: "Esc ⌫"
        case .home: "H"
        case .options: "O"
        case .info: "I"
        case .source: "S"
        case .playPause: "Space"
        case .play: ""
        case .pause: "P"
        case .rewind: ","
        case .forward: "."
        case .volumeDown: "−"
        case .volumeUp: "+"
        case .mute: "M"
        case .keyboard: "K"
        case .power: "⌘P"
        case .ambilight: "A"
        case .refresh: "⌘R"
        case .locate: "⌘L"
        case .help: "?"
        }
    }

    var repeatMode: Repeat {
        switch self {
        case .up, .down, .left, .right: .navigation
        case .volumeDown, .volumeUp: .throttled
        default: .none
        }
    }
}

// MARK: - TVs

/// A paired TV as remembered by the app. Driver-specific credentials live in `data`.
struct StoredTV: Codable, Identifiable, Equatable {
    var id: String              // "<driver>:<device id>", unique across drivers
    var driver: String          // `TVDriver.id`
    var name: String
    var host: String
    var data: [String: String] = [:]
    /// Another paired TV that plays this one's sound (a box on a TV's HDMI input): volume
    /// and mute go there.
    var volumeVia: String? = nil
    /// The driver's optional features switched on for this TV (driver.json "options").
    var options: [String: Bool]? = nil
}

/// A TV seen on the network (or at a typed-in address) that can be paired.
struct FoundTV: Identifiable, Hashable {
    var driver: String
    var deviceID: String        // stable per physical TV, e.g. a MAC-based identifier
    var name: String
    var host: String
    var model: String?
    var id: String { "\(driver):\(deviceID)" }
}

/// What the remote shows. Drivers fill in what they know.
struct TVState: Equatable {
    var power = "—"             // "On", "Standby" or another short status
    var volume: Int?            // absolute volume, when the TV reports one
    var volumeMax = 100
    var muted = false
    var picker: TVPicker?
    /// Whether something plays on the TV; nil = the TV does not say (then assume it does).
    var playing: Bool?
}

/// One extra control under the remote: the Ambilight style on Philips, apps on Apple TV.
struct TVPicker: Equatable {
    struct Option: Equatable, Hashable {
        var id: String
        var title: String
        var icon: String? = nil      // path to a local image (app logo)
    }

    var id: String
    var label: String
    var symbol: String
    var options: [Option]
    /// The selected option. nil = a launcher (a menu of one-off actions), not a selection.
    var current: String?
    /// Options shown as tiles (e.g. the last used apps); the rest stay in a menu.
    var recent: [String] = []
    /// Highlighted tile, e.g. the app in the foreground.
    var active: String? = nil
}

/// What the "Supported TVs" settings tab shows for a driver.
struct DriverInfo {
    var works: [String]
    var doesNotWork: [String] = []
    var notes: [String] = []
}

enum DriverStatus: Equatable {
    case ready
    case unavailable(String)
}

enum TVError: LocalizedError {
    case http(Int)
    case unauthorized
    case pairing(String)
    case driver(String)          // the driver itself cannot work (e.g. a missing dependency)
    case failed(String)          // one request failed; the TV may just be offline
    case anotherPin(String)      // pairing goes on: the TV shows one more PIN (the prompt)

    var errorDescription: String? {
        switch self {
        case .http(let code): "The TV answered with HTTP \(code)."
        case .unauthorized: "The TV rejected the saved credentials. Pair it again."
        case .pairing(let reason), .driver(let reason), .failed(let reason), .anotherPin(let reason): reason
        }
    }
}

/// A kind of TV the app can talk to. One instance per kind, created at launch.
@MainActor
protocol TVDriver: AnyObject {
    var id: String { get }
    var name: String { get }
    var info: DriverInfo { get }
    /// Can the driver work on this Mac at all? May start a helper process.
    func status() async -> DriverStatus
    func discover() async -> [FoundTV]
    func probe(host: String) async -> FoundTV?
    /// Starts pairing (the TV shows a PIN). Returns the text shown above the PIN field,
    /// or nil when the TV is already paired with this Mac and no PIN is needed.
    func beginPairing(_ tv: FoundTV) async throws -> String?
    func finishPairing(pin: String) async throws -> StoredTV
    func cancelPairing() async
    func connect(_ tv: StoredTV) -> any TVConnection
}

/// A live link to one paired TV.
@MainActor
protocol TVConnection: AnyObject {
    /// Remote buttons this TV understands (may grow once the connection is up).
    var actions: Set<RemoteAction> { get }
    /// true: volume is set to an absolute value; false: volume keys are sent as keys.
    var supportsAbsoluteVolume: Bool { get }
    func perform(_ action: RemoteAction, state: TVState) async throws
    func setVolume(_ value: Int) async throws
    func pick(_ picker: String, option: String) async throws
    /// Makes the focused text field on the TV read `text` (only with `.keyboard` in `actions`).
    /// `previous` is what was sent before; `submit` presses Enter afterwards.
    func sendText(_ text: String, previous: String, submit: Bool) async throws
    /// What the focused text field on the TV already holds, if the TV can tell.
    func readText() async -> String?
    func readState() async throws -> TVState
    /// The TV stopped answering: look for it again. Returns the updated record, or nil.
    func relocate() async -> StoredTV?
    func close()
}

// MARK: - Storage

/// Paired TVs in ~/Library/Application Support/TV Remote/tvs.json (chmod 600: credentials).
struct TVStore: Codable {
    var active: String?
    var tvs: [StoredTV] = []

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TV Remote")
    static var file: URL { folder.appendingPathComponent("tvs.json") }

    static func load() -> TVStore {
        var store = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(TVStore.self, from: $0) }
            ?? TVStore()
        // A TV paired with the philips.py CLI (or by an older version of this app) joins the list.
        if let tv = PhilipsDriver.cliTV() {
            if let i = store.tvs.firstIndex(where: { $0.id == tv.id }) {
                store.tvs[i].host = tv.host
                store.tvs[i].data = tv.data
            } else {
                store.tvs.append(tv)
            }
        }
        if !store.tvs.contains(where: { $0.id == store.active }) {
            store.active = store.tvs.first?.id
        }
        return store
    }

    func save() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        try? data.write(to: Self.file, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
        // philips.py reads config.json: keep it pointed at the Philips TV in use.
        if let tv = tvs.first(where: { $0.id == active }), tv.driver == PhilipsDriver.kind {
            PhilipsDriver.writeCLIConfig(tv)
        }
    }
}

// MARK: - Registry

@MainActor
enum Drivers {
    /// Built-in drivers first, then script drivers from the app bundle and the user's folder.
    static let all: [any TVDriver] = [PhilipsDriver()] + ScriptDriver.loadAll()

    static func named(_ id: String) -> (any TVDriver)? {
        all.first { $0.id == id }
    }

    /// Where users drop their own drivers.
    static var userFolder: URL { TVStore.folder.appendingPathComponent("Drivers") }
}
