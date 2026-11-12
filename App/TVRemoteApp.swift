// TV Remote: app entry point. A remote for TVs on the local network, in a window, in the
// menu bar, or both. Kinds of TVs come from drivers (Core.swift).

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let keyboard = KeyboardRouter()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Writing to a driver that just quit must fail with an error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        Prefs.applyDockPolicy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyboard.install(RemoteModel.shared)
    }

    /// With a menu bar icon the app keeps running after its window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Prefs.mode == .window
    }
}

@main
struct TVRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = RemoteModel.shared
    @AppStorage(Prefs.modeKey) private var mode: ShowMode = .window

    var body: some Scene {
        Window("TV Remote", id: "remote") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
        .defaultLaunchBehavior(mode == .menuBar ? .suppressed : .presented)
        .commands { TVCommands(model: model) }

        MenuBarExtra("TV Remote", systemImage: "av.remote", isInserted: Binding(
            get: { mode != .window },
            // Removing the icon (⌘-drag out of the menu bar) falls back to the window.
            set: { if !$0 { mode = .window } }
        )) {
            ContentView().environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

struct TVCommands: Commands {
    @ObservedObject var model: RemoteModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .printItem) {}
        CommandGroup(replacing: .newItem) {
            Button("Add TV…") {
                model.adding = true
                openWindow(id: "remote")
            }
            .keyboardShortcut("n")
        }
        CommandMenu("TV") {
            ForEach(Array(model.tvs.prefix(9).enumerated()), id: \.element.id) { i, tv in
                Toggle(model.title(tv), isOn: Binding(get: { tv.id == model.store.active },
                                                      set: { _ in model.select(tv.id) }))
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))))
            }
            Divider()
            Button("Power On / Standby") { model.run(.power) }
                .keyboardShortcut("p")
                .disabled(!model.actions.contains(.power))
            Button("Refresh Status") { model.run(.refresh) }
                .keyboardShortcut("r")
                .disabled(!model.isPaired)
            Button("Find TV on Network") { model.run(.locate) }
                .keyboardShortcut("l")
                .disabled(!model.isPaired)
            Divider()
            Button("Keyboard Shortcuts") { model.run(.help) }
                .keyboardShortcut("/")
                .disabled(!model.isPaired)
            Divider()
            Button("Forget This TV…") { model.forget() }
                .disabled(!model.isPaired)
        }
    }
}
