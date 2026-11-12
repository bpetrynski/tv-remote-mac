// TV Remote: app state (paired TVs, the active connection, command queue) and keyboard input.

import AppKit
import SwiftUI

// MARK: - Model

@MainActor
final class RemoteModel: ObservableObject {
    static let shared = RemoteModel()

    @Published private(set) var store = TVStore.load()
    @Published var state = TVState()
    @Published private(set) var driverActions: Set<RemoteAction> = []
    @Published var online = false
    @Published var busy = false
    @Published var searching = false
    /// Why the TV cannot be used right now (missing dependency, rejected credentials…).
    @Published var problem: String?
    /// Actions whose key is currently held down; used to highlight buttons.
    @Published var pressed: Set<RemoteAction> = []
    @Published var showHelp = false
    /// The pairing screen is shown on top of a working remote.
    @Published var adding = false
    /// The text field for typing on the TV is open.
    @Published private(set) var typing = false
    @Published private(set) var typedText = ""
    /// Name of the TV that plays this one's sound (`StoredTV.volumeVia`), if any.
    @Published private(set) var audioName: String?
    @Published private(set) var audioActions: Set<RemoteAction> = []

    private var connection: (any TVConnection)?
    /// The TV that takes volume and mute instead of the active one.
    private var audio: (any TVConnection)?
    private var audioSearching = false
    /// What the TV's text field holds as far as we know: the base for the next edit.
    private var sentText = ""
    static let volumeKeys: Set<RemoteAction> = [.volumeUp, .volumeDown, .mute]
    /// For TVs without a toggle key (Titan OS ignores PlayPause): what Space sends next.
    /// Assumes something is playing, so the first press pauses. A physical remote can make
    /// it drift; the next press then just does the other thing.
    private var assumePlaying = true

    private enum Command {
        case action(RemoteAction)
        case volume        // sends `state.volume` as it is at execution time, so changes coalesce
        case pick(String, String)
        case text(String, submit: Bool)
        case erase         // one character off the TV's field, beyond what the app knows
    }

    /// Commands go to the TV one at a time, in order. Parallel requests could arrive out of
    /// order, and for navigation (↓ ↓ →) the order matters.
    private var queue: [Command] = []
    private var worker: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// Last local state change; a status read that started earlier must not overwrite it.
    private var editedAt = Date.distantPast

    var tvs: [StoredTV] { store.tvs }
    var active: StoredTV? { store.tvs.first { $0.id == store.active } }
    var isPaired: Bool { active != nil }
    var host: String { active?.host ?? "" }
    /// Is anything waiting behind the command in flight?
    var hasBacklog: Bool { !queue.isEmpty }

    /// Buttons to show: what the TV supports plus the app's own actions.
    var actions: Set<RemoteAction> {
        var set = driverActions.union(RemoteAction.appLevel)
        if audioName != nil {
            set.subtract(Self.volumeKeys)
            set.formUnion(audioActions.intersection(Self.volumeKeys))
        }
        if set.isSuperset(of: [.play, .pause]) { set.insert(.playPause) }
        if state.picker?.current != nil { set.insert(.ambilight) }
        return set
    }

    private var absoluteVolume: Bool {
        (audio ?? connection)?.supportsAbsoluteVolume == true && state.volume != nil
    }

    private init() {
        open()
    }

    // MARK: TVs

    func title(_ tv: StoredTV) -> String {
        store.tvs.filter({ $0.name == tv.name }).count > 1 ? "\(tv.name) (\(tv.host))" : tv.name
    }

    func driverName(_ tv: StoredTV) -> String {
        Drivers.named(tv.driver)?.name ?? tv.driver
    }

    /// Connects to the active TV, dropping whatever was going on with the previous one.
    private func open() {
        defer { MediaKeys.apply(self) }
        connection?.close()
        connection = nil
        audio?.close()
        audio = nil
        audioName = nil
        audioActions = []
        typing = false
        typedText = ""
        sentText = ""
        queue.removeAll()
        refreshTask?.cancel()
        state = TVState()
        driverActions = []
        online = false
        problem = nil
        showHelp = false
        assumePlaying = true
        guard let tv = active else { return }
        guard let driver = Drivers.named(tv.driver) else {
            problem = "No driver for “\(tv.driver)” TVs is installed."
            return
        }
        let c = driver.connect(tv)
        connection = c
        driverActions = c.actions
        if let id = tv.volumeVia, let target = store.tvs.first(where: { $0.id == id }),
           let audioDriver = Drivers.named(target.driver) {
            let a = audioDriver.connect(target)
            audio = a
            audioActions = a.actions
            audioName = target.name
        }
        refresh()
    }

    /// Starts over with the active TV (e.g. after its driver was installed).
    func reconnect() {
        open()
    }

    func select(_ id: String) {
        guard id != store.active, store.tvs.contains(where: { $0.id == id }) else { return }
        store.active = id
        store.save()
        open()
    }

    func adopt(_ tv: StoredTV) {
        if let i = store.tvs.firstIndex(where: { $0.id == tv.id }) {
            store.tvs[i] = tv
        } else {
            store.tvs.append(tv)
        }
        store.active = tv.id
        store.save()
        adding = false
        open()
    }

    func rename(_ id: String, to name: String) {
        guard let i = store.tvs.firstIndex(where: { $0.id == id }) else { return }
        store.tvs[i].name = name
        store.save()
    }

    /// TVs that can play `tv`'s sound. A script driver runs one connection at a time, so the
    /// two TVs must use different drivers (Philips connections are independent).
    func volumeTargets(for tv: StoredTV) -> [StoredTV] {
        store.tvs.filter { $0.id != tv.id && ($0.driver != tv.driver || $0.driver == PhilipsDriver.kind) }
    }

    func setVolumeVia(_ id: String, to target: String?) {
        guard let i = store.tvs.firstIndex(where: { $0.id == id }), store.tvs[i].volumeVia != target else { return }
        store.tvs[i].volumeVia = target
        store.save()
        if id == store.active { open() }
    }

    /// Asks first, then removes the TV and its credentials.
    func forget(_ id: String? = nil) {
        guard let tv = store.tvs.first(where: { $0.id == (id ?? store.active) }) else { return }
        let alert = NSAlert()
        alert.messageText = "Forget \(tv.name)?"
        alert.informativeText = "The saved credentials will be deleted. To use the TV again, pair it with the PIN shown on screen."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        store.tvs.removeAll { $0.id == tv.id }
        var soundLost = false
        for i in store.tvs.indices where store.tvs[i].volumeVia == tv.id {
            store.tvs[i].volumeVia = nil
            soundLost = soundLost || store.tvs[i].id == store.active
        }
        if tv.driver == PhilipsDriver.kind { PhilipsDriver.forgetCLIConfig(tv) }
        let wasActive = store.active == tv.id
        if wasActive { store.active = store.tvs.first?.id }
        store.save()
        if wasActive || soundLost { open() }
    }

    /// Saves what a connection learned (a new address after the TV moved). Only the address
    /// and credentials: name and settings may have changed since the connection was made.
    private func update(_ tv: StoredTV) {
        guard let i = store.tvs.firstIndex(where: { $0.id == tv.id }),
              store.tvs[i].host != tv.host || store.tvs[i].data != tv.data else { return }
        store.tvs[i].host = tv.host
        store.tvs[i].data = tv.data
        store.save()
    }

    // MARK: Actions

    func run(_ action: RemoteAction) {
        MediaKeys.reclaim()
        switch action {
        case .refresh: refresh()
        case .locate: locate()
        case .help: showHelp.toggle()
        case .ambilight: cyclePicker()
        case .keyboard: typing ? stopTyping() : startTyping()
        case .playPause where !driverActions.contains(.playPause):
            guard actions.contains(.play) else { return }
            enqueue(.action(assumePlaying ? .pause : .play))
            assumePlaying.toggle()
        case .volumeUp where absoluteVolume: setVolume((state.volume ?? 0) + 1)
        case .volumeDown where absoluteVolume: setVolume((state.volume ?? 0) - 1)
        default:
            guard actions.contains(action) else { return }
            if action == .mute { state.muted.toggle() }
            if action == .play { assumePlaying = true }
            if action == .pause { assumePlaying = false }
            enqueue(.action(action))
        }
    }

    func setVolume(_ value: Int) {
        let clamped = max(0, min(state.volumeMax, value))
        guard clamped != state.volume || state.muted else { return }
        state.volume = clamped
        state.muted = false
        editedAt = Date()
        // Held key: one request carrying the latest value instead of a burst of requests.
        if !queue.contains(where: { if case .volume = $0 { true } else { false } }) {
            enqueue(.volume)
        }
    }

    func choose(_ picker: String, _ option: String) {
        if state.picker?.id == picker, state.picker?.current != nil {
            state.picker?.current = option
        }
        enqueue(.pick(picker, option))
    }

    // MARK: Typing

    func startTyping() {
        guard actions.contains(.keyboard), let c = connection else { return }
        typedText = ""
        sentText = ""
        typing = true
        // Text already on the TV (an earlier search) shows up in the field, to edit or delete.
        Task {
            guard let current = await c.readText(), !current.isEmpty,
                  typing, typedText.isEmpty, sentText.isEmpty, c === connection else { return }
            typedText = current
            sentText = current
        }
    }

    /// Backspace in an empty field: the TV had text the app could not read; delete it there.
    func eraseOnTV() {
        guard typing, typedText.isEmpty else { return }
        enqueue(.erase)
    }

    /// Every edit goes to the TV as it happens.
    func type(_ text: String) {
        guard typing, text != typedText else { return }
        typedText = text
        enqueueText(text, submit: false)
    }

    /// Return: send what is left, press Enter, close the field.
    func submitText() {
        enqueueText(typedText, submit: true)
        stopTyping()
    }

    func stopTyping() {
        typing = false
        typedText = ""
        // The field goes away; give the keys back to the remote.
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func enqueueText(_ text: String, submit: Bool) {
        // Fast typing: the edit still waiting at the end of the queue takes the newer text.
        if case .text(_, submit: false)? = queue.last {
            queue[queue.count - 1] = .text(text, submit: submit)
            return
        }
        enqueue(.text(text, submit: submit))
    }

    private func cyclePicker() {
        guard let p = state.picker, let current = p.current, !p.options.isEmpty else { return }
        let i = p.options.firstIndex { $0.id == current } ?? -1
        choose(p.id, p.options[(i + 1) % p.options.count].id)
    }

    // MARK: Command queue

    private func enqueue(_ cmd: Command) {
        guard connection != nil else { return }
        editedAt = Date()
        refreshTask?.cancel()
        queue.append(cmd)
        if worker == nil {
            worker = Task { await drain() }
        }
    }

    private func drain() async {
        busy = true
        while !queue.isEmpty, let c = connection {
            let cmd = queue.removeFirst()
            var target = c
            do {
                switch cmd {
                case .action(let a):
                    if Self.volumeKeys.contains(a), let audio { target = audio }
                    try await target.perform(a, state: state)
                case .volume:
                    if let audio { target = audio }
                    try await target.setVolume(state.volume ?? 0)
                case .pick(let picker, let option):
                    try await c.pick(picker, option: option)
                case .text(let text, let submit):
                    try await c.sendText(text, previous: sentText, submit: submit)
                    sentText = submit ? "" : text
                case .erase:
                    try await c.sendText("", previous: " ", submit: false)
                }
                if c === connection { online = true }
            } catch {
                // TV not answering: drop the rest instead of waiting seconds per queued key.
                if target !== c {
                    // The sound TV failed, not this one: just stop showing a volume.
                    state.volume = nil
                } else if c === connection {
                    online = false
                    problem = error.localizedDescription
                }
                queue.removeAll()
            }
        }
        busy = false
        worker = nil
        scheduleRefresh()
    }

    /// Read the state once after a burst of commands, not after each one.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            // Philips reports a new state only after ~300 ms; earlier reads lag one step behind.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    // MARK: State

    func refresh() {
        guard let c = connection else { return }
        Task {
            if await poll(c) { return }
            // The address may have changed (new router, new DHCP lease): look for the TV.
            // One scan at a time, or every key press with the TV off would start another sweep.
            guard !searching, c === connection else { return }
            await scan(c)
        }
    }

    /// Forced scan: the antenna button in the header.
    func locate() {
        guard let c = connection, !searching else { return }
        Task { await scan(c) }
    }

    private func scan(_ c: any TVConnection) async {
        searching = true
        let found = await c.relocate()
        searching = false
        guard c === connection else { return }
        if let tv = found {
            update(tv)
            _ = await poll(c)
        } else {
            online = false
            state.power = "not found"
        }
    }

    /// Volume and mute as the sound TV reports them. When it does not answer, it is looked
    /// for in the background; the remote stays usable meanwhile.
    private func withSound(_ s: TVState, from audio: any TVConnection) async -> TVState {
        var s = s
        if let a = try? await audio.readState() {
            s.volume = a.volume
            s.volumeMax = a.volumeMax
            s.muted = a.muted
        } else {
            s.volume = nil
            if !audioSearching {
                audioSearching = true
                Task {
                    if let tv = await audio.relocate() { update(tv) }
                    audioSearching = false
                }
            }
        }
        return s
    }

    /// One round of status reads. false = the TV does not answer at its current address.
    @discardableResult
    private func poll(_ c: any TVConnection) async -> Bool {
        let started = Date()
        do {
            var s = try await c.readState()
            if let audio { s = await withSound(s, from: audio) }
            guard c === connection else { return true }
            online = true
            problem = nil
            driverActions = c.actions
            // Something changed from the keyboard while this read was running: it is stale.
            guard worker == nil, editedAt < started else { return true }
            state = s
            return true
        } catch TVError.unauthorized {
            // The TV is there but no longer accepts our pairing; scanning will not help.
            guard c === connection else { return true }
            online = false
            state.power = "not authorized"
            problem = TVError.unauthorized.errorDescription
            return true
        } catch TVError.driver(let reason) {
            guard c === connection else { return true }
            online = false
            state.power = "unavailable"
            problem = reason
            return true
        } catch {
            guard c === connection else { return true }
            online = false
            state.power = "offline"
            return false
        }
    }
}

// MARK: - Keyboard

/// Keyboard handling through a local event monitor instead of `.keyboardShortcut` on buttons.
/// It gives control over key repeat, several keys per action (Esc and ⌫, `=` and `+`, the
/// numeric keypad) and highlights a button for as long as its key is held.
/// One instance for the whole app, so the window and the menu bar panel do not both react.
/// ⌘ shortcuts stay in the "TV" menu.
@MainActor
final class KeyboardRouter {
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private weak var model: RemoteModel?
    private var held: [UInt16: RemoteAction] = [:]
    private var lastFire: [RemoteAction: Date] = [:]

    /// Minimum gap between repeats of a held key (macOS key repeat runs at up to ~30/s).
    private static let navigationInterval = 0.08
    private static let volumeInterval = 0.09

    func install(_ model: RemoteModel) {
        guard monitor == nil else { return }
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
        // After switching windows the keyUp never arrives, so clear the highlights.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAll() }
        }
    }

    private func releaseAll() {
        held.removeAll()
        model?.pressed.removeAll()
    }

    /// Keys go to the TV only from the remote itself: not while typing (PIN, TV name),
    /// not from Settings and not from the pairing screen.
    private func remoteHasFocus(_ model: RemoteModel) -> Bool {
        guard model.isPaired, !model.adding, let window = NSApp.keyWindow else { return false }
        if window.firstResponder is NSText { return false }
        if window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true { return false }
        return true
    }

    private func handle(_ e: NSEvent) -> Bool {
        guard let model else { return false }

        if e.type == .keyUp {
            guard let action = held.removeValue(forKey: e.keyCode) else { return false }
            model.pressed.remove(action)
            return true
        }

        // Esc in the typing field closes it; Backspace in the empty field deletes on the TV.
        // Other keys belong to the field.
        if model.typing, NSApp.keyWindow?.firstResponder is NSText {
            if e.keyCode == 53 {
                if !e.isARepeat { model.stopTyping() }
                return true
            }
            if e.keyCode == 51, model.typedText.isEmpty, e.modifierFlags.intersection([.command, .option]).isEmpty {
                model.eraseOnTV()
                return true
            }
        }

        guard remoteHasFocus(model) else { return false }

        // ⌘1…⌘9 switch TVs. Handled here, not only in the TV menu, because the menu bar
        // panel (no Dock icon) has no main menu to carry the shortcuts.
        if e.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           let n = Int(e.charactersIgnoringModifiers ?? ""), (1...9).contains(n) {
            guard n <= model.tvs.count else { return false }
            if !e.isARepeat { model.select(model.tvs[n - 1].id) }
            return true
        }

        // Leave ⌘/⌃/⌥ combinations to the menus (⌘P, ⌘R, ⌘L, ⌘Q, ⌘W…).
        if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        guard let action = Self.action(for: e), model.actions.contains(action) else { return false }

        // While the shortcut sheet is open, Esc / ⌫ / ? only close it and send nothing to the TV.
        if model.showHelp, action == .back || action == .help {
            if !e.isARepeat { model.showHelp = false }
            return true
        }

        let now = Date()
        if e.isARepeat {
            guard allowRepeat(action, model: model, now: now) else { return true }
        } else {
            held[e.keyCode] = action
            model.pressed.insert(action)
        }
        lastFire[action] = now
        model.run(action)
        return true
    }

    private func allowRepeat(_ action: RemoteAction, model: RemoteModel, now: Date) -> Bool {
        let since = now.timeIntervalSince(lastFire[action] ?? .distantPast)
        switch action.repeatMode {
        case .none:
            return false
        case .navigation:
            // Never let moves pile up: when the arrow key is released, the cursor must stop
            // right away instead of drifting on for another second.
            return since >= Self.navigationInterval && !model.hasBacklog
        case .throttled:
            return since >= Self.volumeInterval
        }
    }

    /// Special keys by key code (layout independent), character keys by character.
    static func action(for e: NSEvent) -> RemoteAction? {
        switch e.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 36, 76: return .ok            // Return, keypad Enter
        case 53, 51: return .back          // Esc, Backspace
        case 49: return .playPause         // Space
        case 69: return .volumeUp          // keypad +
        case 78: return .volumeDown        // keypad −
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "h": return .home
        case "o": return .options
        case "i": return .info
        case "s": return .source
        case "p": return .pause
        case "m": return .mute
        case "a": return .ambilight
        case "k": return .keyboard
        case ",", "<": return .rewind
        case ".", ">": return .forward
        case "-", "_": return .volumeDown
        case "=", "+": return .volumeUp
        case "?", "/": return .help
        default: return nil
        }
    }
}
