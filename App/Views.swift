// TV Remote: the remote itself and the pairing screen. Used both in the window and in the
// menu bar panel.

import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: RemoteModel

    var body: some View {
        if model.isPaired && !model.adding {
            RemoteView()
        } else {
            PairingView()
        }
    }
}

// MARK: - Pairing

@MainActor
final class PairingFlow: ObservableObject {
    enum Step { case choose, pin, working }

    @Published var step: Step = .choose
    @Published var found: [FoundTV] = []
    /// Drivers still looking; results show up as each one finishes.
    @Published var scanning = 0
    @Published var manualHost = ""
    @Published var pin = ""
    @Published var prompt = ""
    @Published var message: String?

    private var driver: (any TVDriver)?
    private var target: FoundTV?

    func scan() async {
        guard scanning == 0 else { return }
        step = .choose
        message = nil
        found = []
        scanning = Drivers.all.count
        await withTaskGroup(of: Void.self) { group in
            for driver in Drivers.all {
                group.addTask { @MainActor in
                    let hits = await driver.discover()
                    self.found = (self.found + hits).sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    self.scanning -= 1
                }
            }
        }
    }

    func start(_ tv: FoundTV, model: RemoteModel) async {
        guard let d = Drivers.named(tv.driver) else { return }
        step = .working
        message = nil
        do {
            let text = try await d.beginPairing(tv)
            driver = d
            target = tv
            pin = ""
            guard let text else {
                // Already paired with this Mac (e.g. through the driver's own CLI).
                model.adopt(try await d.finishPairing(pin: ""))
                return
            }
            prompt = text
            step = .pin
        } catch {
            message = error.localizedDescription
            step = .choose
        }
    }

    /// Asks every driver whether its kind of TV answers at the typed address.
    func startManual(_ model: RemoteModel) async {
        let host = manualHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        step = .working
        message = nil
        var hit: FoundTV?
        await withTaskGroup(of: FoundTV?.self) { group in
            for driver in Drivers.all {
                group.addTask { @MainActor in await driver.probe(host: host) }
            }
            for await result in group where hit == nil {
                hit = result
            }
        }
        guard let hit else {
            message = "No supported TV answers at \(host)."
            step = .choose
            return
        }
        await start(hit, model: model)
    }

    /// Ask the TV for a fresh PIN (also used when the previous one expired).
    func requestAgain(_ model: RemoteModel) async {
        guard let target else { return }
        await start(target, model: model)
    }

    func confirm(_ model: RemoteModel) async {
        guard let driver, !pin.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        step = .working
        message = nil
        do {
            model.adopt(try await driver.finishPairing(pin: pin))
        } catch TVError.anotherPin(let text) {
            prompt = text
            pin = ""
            step = .pin
        } catch {
            message = error.localizedDescription
            step = .pin
        }
    }

    func cancel(_ model: RemoteModel) {
        if let driver { Task { await driver.cancelPairing() } }
        model.adding = false
    }
}

struct PairingView: View {
    @EnvironmentObject private var model: RemoteModel
    @StateObject private var flow = PairingFlow()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tv").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isPaired ? "Add a TV" : "Pair your TV").font(.headline)
                    Text("The TV must be on and on the same network.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isPaired {
                    Button("Cancel") { flow.cancel(model) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }

            switch flow.step {
            case .working:
                progress("Talking to the TV…")
            case .choose:
                chooser
            case .pin:
                pinEntry
            }

            if let message = flow.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsLink {
                Text("Which TVs are supported?")
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .padding(16)
        .frame(width: 290, alignment: .leading)
        .task { await flow.scan() }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 40)
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(flow.found) { tv in
                let paired = model.tvs.contains { $0.id == tv.id }
                Button {
                    Task { await flow.start(tv, model: model) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tv.name).font(.system(size: 12, weight: .medium))
                            Text(([Drivers.named(tv.driver)?.name, tv.model, tv.host] as [String?])
                                    .compactMap { $0 }.joined(separator: " · ")
                                 + (paired ? " · paired" : ""))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
            }

            if flow.scanning > 0 {
                progress("Looking for TVs…")
            } else {
                if flow.found.isEmpty {
                    Text("No TV found on the local network.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Button("Scan again") { Task { await flow.scan() } }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }

            Divider()

            Text("Or enter its IP address:").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("192.168.1.20", text: $flow.manualHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await flow.startManual(model) } }
                Button("Connect") { Task { await flow.startManual(model) } }
                    .disabled(flow.manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var pinEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(flow.prompt)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField("PIN", text: $flow.pin)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, design: .monospaced))
                    .onSubmit { Task { await flow.confirm(model) } }
                Button("Pair") { Task { await flow.confirm(model) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.pin.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button("Show a new PIN") { Task { await flow.requestAgain(model) } }
                Spacer()
                Button("Back") { flow.step = .choose }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
    }
}

// MARK: - Remote

struct RemoteButton: View {
    @EnvironmentObject private var model: RemoteModel
    let action: RemoteAction
    var symbol: String? = nil   // icon override, e.g. a crossed-out speaker
    var wide = false
    var tint: Color = .primary

    init(_ action: RemoteAction, symbol: String? = nil, wide: Bool = false, tint: Color = .primary) {
        self.action = action
        self.symbol = symbol
        self.wide = wide
        self.tint = tint
    }

    var body: some View {
        let pressed = model.pressed.contains(action)
        Button { model.run(action) } label: {
            Group {
                if let s = symbol ?? action.symbol {
                    Image(systemName: s).font(.system(size: 15, weight: .medium))
                } else {
                    Text(action.label).font(.system(size: 12, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, minHeight: wide ? 30 : 40)
            .foregroundStyle(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        // Keys are handled by KeyboardRouter; a focus ring would only be noise.
        .focusable(false)
        // Here, on the button itself: after .scaleEffect the tooltip never shows.
        .help(action.shortcut.isEmpty ? action.label : "\(action.label) (\(action.shortcut))")
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(pressed ? 0.3 : 0))
                .allowsHitTesting(false)
        )
        .scaleEffect(pressed ? 0.94 : 1)
        .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

struct RemoteView: View {
    @EnvironmentObject private var model: RemoteModel

    /// The shortcut sheet is built from `RemoteAction`, so it cannot drift from the tooltips.
    private static let helpRows: [([RemoteAction], String)] = [
        ([.up, .down, .left, .right], "Navigate (hold to repeat)"),
        ([.ok], "OK"),
        ([.back], "Back"),
        ([.home], "Home"),
        ([.options, .info, .source], "Options · Info · Source"),
        ([.playPause], "Play / Pause"),
        ([.pause], "Pause"),
        ([.rewind, .forward], "Rewind · Fast forward"),
        ([.volumeDown, .volumeUp], "Volume (hold to repeat)"),
        ([.mute], "Mute"),
        ([.ambilight], "Next Ambilight style"),
        ([.keyboard], "Type text on the TV"),
        ([.power], "Power on / standby"),
        ([.refresh], "Refresh status"),
        ([.locate], "Find TV on network"),
        ([.help], "This sheet"),
    ]

    var body: some View {
        VStack(spacing: 10) {
            header

            row([.power, .home, .back])
            if model.actions.contains(.up) { dpad }
            row([.options, .info, .source, .keyboard])
            if model.typing { TypingField() }
            row([.volumeDown, .mute, .volumeUp])
            row([.rewind, .play, .pause, .forward], wide: true)

            if let picker = model.state.picker {
                Divider()
                pickerView(picker)
            }
        }
        .padding(14)
        .frame(width: 290)
        .overlay { if model.showHelp { helpOverlay } }
        .onAppear { model.refresh() }
    }

    /// A row of buttons, minus the ones this TV does not have.
    @ViewBuilder
    private func row(_ list: [RemoteAction], wide: Bool = false) -> some View {
        let shown = list.filter { model.actions.contains($0) }
        if !shown.isEmpty {
            HStack(spacing: 6) {
                ForEach(shown, id: \.self) { action in
                    RemoteButton(action,
                                 symbol: action == .mute && model.state.muted ? "speaker.slash.fill" : nil,
                                 wide: wide,
                                 tint: action == .power ? .red : .primary)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                tvMenu
                Spacer()
                headerButton(.help)
                headerButton(.refresh)
                headerButton(.locate)
                    .disabled(model.searching)
            }
            HStack(spacing: 6) {
                if model.searching {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(model.online ? (model.state.power == "Standby" ? .orange : .green) : .red)
                        .frame(width: 8, height: 8)
                }
                Text(model.searching ? "looking for TV…" : model.state.power)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(model.host.isEmpty ? "address unknown" : model.host)
                Spacer()
                if let name = model.audioName {
                    Text("sound: \(name)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let volume = model.state.volume {
                    Image(systemName: model.state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("\(volume)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            if let problem = model.problem, !model.online {
                Text(problem)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// Switches between paired TVs; also the way in to adding and forgetting them.
    private var tvMenu: some View {
        Menu {
            ForEach(Array(model.tvs.enumerated()), id: \.element.id) { i, tv in
                let toggle = Toggle(isOn: Binding(get: { tv.id == model.store.active },
                                                  set: { _ in model.select(tv.id) })) {
                    Text("\(model.title(tv)) · \(model.driverName(tv))")
                }
                if i < 9 {
                    toggle.keyboardShortcut(KeyEquivalent(Character(String(i + 1))))
                } else {
                    toggle
                }
            }
            if let tv = model.active, !model.volumeTargets(for: tv).isEmpty {
                Divider()
                Picker("Sound Plays On", selection: Binding(
                    get: { tv.volumeVia ?? "" },
                    set: { model.setVolumeVia(tv.id, to: $0.isEmpty ? nil : $0) })) {
                    Text("This TV").tag("")
                    ForEach(model.volumeTargets(for: tv)) { Text(model.title($0)).tag($0.id) }
                }
            }
            Divider()
            Button("Add TV…") { model.adding = true }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Forget \(model.active?.name ?? "This TV")…") { model.forget() }
        } label: {
            Label(model.active.map(model.title) ?? "TV", systemImage: "tv")
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .focusable(false)
        .help("Switch TV (⌘1…⌘9)")
    }

    private func headerButton(_ action: RemoteAction) -> some View {
        Button { model.run(action) } label: {
            Image(systemName: action.symbol ?? "questionmark").font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundStyle(.secondary)
        .help(action == .locate && !model.host.isEmpty
              ? "\(action.label), now \(model.host) (\(action.shortcut))"
              : "\(action.label) (\(action.shortcut))")
    }

    private var dpad: some View {
        VStack(spacing: 6) {
            RemoteButton(.up)
            HStack(spacing: 6) {
                RemoteButton(.left)
                RemoteButton(.ok, tint: .accentColor)
                RemoteButton(.right)
            }
            RemoteButton(.down)
        }
    }

    /// A selection (Ambilight style) becomes a picker; a launcher (apps) becomes a menu,
    /// with its recent options as tiles when the driver provides them.
    @ViewBuilder
    private func pickerView(_ p: TVPicker) -> some View {
        if p.current == nil, !p.recent.isEmpty {
            AppTiles(picker: p)
        } else {
            plainPicker(p)
        }
    }

    private func plainPicker(_ p: TVPicker) -> some View {
        HStack(spacing: 8) {
            Image(systemName: p.symbol).foregroundStyle(.secondary)
            if let current = p.current {
                Picker("", selection: Binding(get: { current }, set: { model.choose(p.id, $0) })) {
                    ForEach(p.options, id: \.id) { o in
                        Text(o.title).tag(o.id)
                    }
                }
                .labelsHidden()
                .focusable(false)
                .help("\(p.label) (A cycles)")
            } else {
                Menu("Open \(p.label.lowercased())…") {
                    ForEach(p.options, id: \.id) { o in
                        Button(o.title) { model.choose(p.id, o.id) }
                    }
                }
                .focusable(false)
            }
        }
    }

    private var helpOverlay: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Keyboard shortcuts").font(.headline)
                Spacer()
                Button { model.showHelp = false } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            ForEach(Self.helpRows.filter { $0.0.contains(where: model.actions.contains) }, id: \.1) { actions, text in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(actions.filter(model.actions.contains).map(\.shortcut).joined(separator: " "))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 84, alignment: .leading)
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if model.tvs.count > 1 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("⌘1…⌘\(min(model.tvs.count, 9))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 84, alignment: .leading)
                    Text("Switch TV")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text("Esc or ? closes this sheet")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Typing

/// Text typed here appears in the focused text field on the TV as you type.
struct TypingField: View {
    @EnvironmentObject private var model: RemoteModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Type on the TV…", text: Binding(get: { model.typedText }, set: { model.type($0) }))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit { model.submitText() }
                .help("Select a text field on the TV first. Return sends Enter, Esc closes.")
            Button { model.stopTyping() } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .focusable(false)
            .help("Done (Esc)")
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

// MARK: - App tiles

/// The last used apps as logo tiles, plus a menu with every known app.
struct AppTiles: View {
    @EnvironmentObject private var model: RemoteModel
    let picker: TVPicker

    var body: some View {
        let byID = Dictionary(picker.options.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        HStack(spacing: 6) {
            ForEach(picker.recent.prefix(4), id: \.self) { id in
                let option = byID[id] ?? TVPicker.Option(id: id, title: id)
                Button { model.choose(picker.id, id) } label: {
                    VStack(spacing: 3) {
                        AppIcon(path: option.icon, title: option.title)
                            .frame(width: 40, height: 40)
                        Text(option.title)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: picker.active == id ? 2 : 0)
                )
                .help("Open \(option.title)")
            }
            Menu {
                ForEach(picker.options, id: \.id) { o in
                    Button {
                        model.choose(picker.id, o.id)
                    } label: {
                        if let image = AppIcon.image(o.icon) {
                            Label { Text(o.title) } icon: { Image(nsImage: image.menuSized) }
                        } else {
                            Text(o.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusable(false)
            .help("Open another app")
        }
    }
}

/// An app logo from a local file, or the app's initial on a tile while there is none.
struct AppIcon: View {
    let path: String?
    let title: String

    /// Logos are small and few; keep them decoded.
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(_ path: String?) -> NSImage? {
        guard let path else { return nil }
        if let hit = cache[path] { return hit }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = image
        return image
    }

    var body: some View {
        if let image = Self.image(path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(0.2))
                .overlay(Text(String(title.prefix(1))).font(.system(size: 18, weight: .semibold)))
        }
    }
}

private extension NSImage {
    /// Menus draw images at their own size; 16 pt matches the text.
    var menuSized: NSImage {
        let small = NSImage(size: NSSize(width: 16, height: 16))
        small.lockFocus()
        draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        small.unlockFocus()
        return small
    }
}
