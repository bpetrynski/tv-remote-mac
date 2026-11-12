// TV Remote: preferences (window / menu bar / Dock) and the Settings window.

import AppKit
import SwiftUI

// MARK: - Preferences

enum ShowMode: String, CaseIterable, Identifiable {
    case window, menuBar, both

    var id: String { rawValue }
    var title: String {
        switch self {
        case .window: "In a window"
        case .menuBar: "In the menu bar only"
        case .both: "In a window and in the menu bar"
        }
    }
}

enum Prefs {
    static let modeKey = "showMode"
    static let dockKey = "showDockIcon"

    static var mode: ShowMode {
        ShowMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .window
    }

    static var dockIcon: Bool {
        UserDefaults.standard.object(forKey: dockKey) as? Bool ?? true
    }

    /// Without a menu bar icon the Dock icon is the only way back to the app, so it stays.
    @MainActor
    static func applyDockPolicy() {
        let show = mode == .window || dockIcon
        let policy: NSApplication.ActivationPolicy = show ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Changing the policy deactivates the app; bring the open window back to the front.
        DispatchQueue.main.async { NSApp.activate() }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            TVsSettings()
                .tabItem { Label("TVs", systemImage: "tv") }
            SupportedTVsSettings()
                .tabItem { Label("Supported TVs", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 500, height: 440)
        // From the menu bar the app may be in the background; Settings must come to the front.
        .onAppear { NSApp.activate() }
    }
}

struct GeneralSettings: View {
    @AppStorage(Prefs.modeKey) private var mode: ShowMode = .window
    @AppStorage(Prefs.dockKey) private var dock = true
    @AppStorage(MediaKeys.key) private var mediaKeys = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Form {
            Picker("Show the remote", selection: $mode) {
                ForEach(ShowMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)

            Toggle("Show icon in the Dock", isOn: $dock)
                .disabled(mode == .window)
            Text(mode == .window
                 ? "With the remote in a window only, the Dock icon stays: it is the way back to the app."
                 : "Without the Dock icon the app lives in the menu bar. Settings open from the TV menu in the remote.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Mac media keys control the TV", isOn: $mediaKeys)
            Text("F8 plays and pauses, F7 rewinds, F9 fast-forwards. An app that starts playing (Music, a video in the browser) takes the keys over; using the remote may win them back.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .onChange(of: mediaKeys) { MediaKeys.apply(RemoteModel.shared) }
        .onChange(of: mode) { _, new in
            Prefs.applyDockPolicy()
            if new == .menuBar {
                dismissWindow(id: "remote")
            } else {
                openWindow(id: "remote")
            }
        }
        .onChange(of: dock) { Prefs.applyDockPolicy() }
    }
}

struct TVsSettings: View {
    @EnvironmentObject private var model: RemoteModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Paired TVs") {
                if model.tvs.isEmpty {
                    Text("No TVs yet.").foregroundStyle(.secondary)
                }
                ForEach(model.tvs) { tv in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Name", text: Binding(get: { tv.name },
                                                            set: { model.rename(tv.id, to: $0) }))
                                .labelsHidden()
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium))
                            Text("\(model.driverName(tv)) · \(tv.host)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            let targets = model.volumeTargets(for: tv)
                            if !targets.isEmpty {
                                // A labelled Picker in a Form takes the whole row (label left,
                                // value right) and pushes the row past the window edge.
                                HStack(spacing: 4) {
                                    Text("Sound plays on")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Picker("", selection: Binding(
                                        get: { tv.volumeVia ?? "" },
                                        set: { model.setVolumeVia(tv.id, to: $0.isEmpty ? nil : $0) })) {
                                        Text("This TV").tag("")
                                        ForEach(targets) { Text(model.title($0)).tag($0.id) }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .controlSize(.small)
                                    .fixedSize()
                                }
                                .help("For a box on another TV's HDMI input: volume and mute go to that TV.")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer()
                        if tv.id == model.store.active {
                            Text("In use").font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            Button("Use") { model.select(tv.id) }
                        }
                        Button {
                            model.forget(tv.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Forget this TV")
                    }
                }
            }
            Section {
                Button("Add TV…") {
                    model.adding = true
                    openWindow(id: "remote")
                }
            } footer: {
                Text("Pairing happens in the remote window: the TV shows a PIN to type in.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SupportedTVsSettings: View {
    @EnvironmentObject private var model: RemoteModel
    @State private var status: [String: DriverStatus] = [:]
    @State private var installing: Set<String> = []

    var body: some View {
        Form {
            ForEach(Drivers.all.indices, id: \.self) { i in
                let driver = Drivers.all[i]
                Section {
                    ForEach(driver.info.works, id: \.self) { line(.works, $0) }
                    ForEach(driver.info.doesNotWork, id: \.self) { line(.doesNotWork, $0) }
                    ForEach(driver.info.notes, id: \.self) { line(.note, $0) }
                    if case .unavailable(let reason) = status[driver.id] {
                        line(.problem, reason)
                    }
                    if let script = driver as? ScriptDriver, script.manifest.requirements?.isEmpty == false,
                       status[driver.id] != .ready || script.needsInstall {
                        installRow(script)
                    }
                } header: {
                    HStack {
                        Text(driver.name)
                        Spacer()
                        badge(status[driver.id])
                    }
                }
            }

            Section("Add support for another TV") {
                Text("A driver is a folder with a driver.json file and a small program in any "
                     + "language that talks to the app through JSON lines on stdin and stdout. "
                     + "Put the folder into the Drivers folder and restart the app. The protocol "
                     + "is described in the README.md file in that folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Drivers Folder") { openDriversFolder() }
            }
        }
        .formStyle(.grouped)
        .task {
            for driver in Drivers.all {
                status[driver.id] = await driver.status()
            }
        }
    }

    private func installRow(_ driver: ScriptDriver) -> some View {
        HStack {
            Text("Packages: " + (driver.manifest.requirements ?? []).joined(separator: ", "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if installing.contains(driver.id) {
                ProgressView().controlSize(.small)
                Text("Installing…").font(.system(size: 11))
            } else {
                Button(driver.needsInstall ? "Install" : "Reinstall") {
                    Task { await install(driver) }
                }
            }
        }
    }

    private func install(_ driver: ScriptDriver) async {
        installing.insert(driver.id)
        status[driver.id] = nil
        do {
            try await driver.install()
            status[driver.id] = await driver.status()
        } catch {
            status[driver.id] = .unavailable(error.localizedDescription)
        }
        installing.remove(driver.id)
        // The TV in use may have been waiting for exactly this driver.
        if model.active?.driver == driver.id { model.reconnect() }
    }

    private enum Kind { case works, doesNotWork, note, problem }

    private func line(_ kind: Kind, _ text: String) -> some View {
        let (symbol, color): (String, Color) = switch kind {
        case .works: ("checkmark.circle.fill", .green)
        case .doesNotWork: ("xmark.circle.fill", .secondary)
        case .note: ("info.circle", .secondary)
        case .problem: ("exclamationmark.triangle.fill", .orange)
        }
        return Label {
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func badge(_ s: DriverStatus?) -> some View {
        switch s {
        case nil: ProgressView().controlSize(.mini)
        case .ready: Text("ready").foregroundStyle(.green)
        case .unavailable: Text("not available").foregroundStyle(.orange)
        }
    }

    /// Creates the folder on first use and puts the driver guide next to the drivers.
    private func openDriversFolder() {
        let folder = Drivers.userFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let guide = folder.appendingPathComponent("README.md")
        if let bundled = Bundle.main.url(forResource: "DRIVERS", withExtension: "md") {
            try? FileManager.default.removeItem(at: guide)
            try? FileManager.default.copyItem(at: bundled, to: guide)
        }
        NSWorkspace.shared.open(folder)
    }
}
