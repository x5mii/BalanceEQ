import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    var reopen: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopen?() }
        return true
    }
}

@main
enum EqualizerLauncher {
    static func main() {
        #if DEBUG
        if CommandLine.arguments.contains("--self-test") {
            AudioController.checkCleanupHandling()
            EqualizerView.checkControlGestures()
            DecimalField.check()
            AudioSpectrum.check()
            print("Core Audio teardown and control gesture checks passed.")
            return
        }
        #endif
        if CommandLine.arguments.contains("--diagnose") {
            print(AudioController.diagnostics())
            return
        }
        EqualizerMacApp.main()
    }
}

struct EqualizerMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("BalanceEQ", id: "equalizer") {
            EqualizerView(model: model, audio: model.audio, appDelegate: delegate)
                .background(MainWindowVisibility(audio: model.audio).frame(width: 0, height: 0))
                .onAppear {
                    delegate.onTerminate = { model.shutDown() }
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1160, height: 790)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .importExport) {
                Button("Import APO Preset…", action: model.importPreset).keyboardShortcut("o")
                Button("Export APO Preset…", action: model.exportPreset).keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("BalanceEQ") {
                Button(model.audio.isRunning ? "Stop EQ" : "Start EQ", action: model.toggleProcessing)
                    .disabled(model.audio.isStarting)
                Toggle("Bypass EQ", isOn: $model.bypassed).keyboardShortcut("b")
            }
        }

        MenuBarExtra("BalanceEQ", systemImage: "slider.vertical.3") {
            EqualizerMenu(model: model, audio: model.audio)
        }

        Window("About BalanceEQ", id: "about") {
            VStack(spacing: 16) {
                BalanceLogo().frame(width: 64, height: 64)
                Text("BalanceEQ").font(.title2.bold())
                Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") · Free and open source").foregroundStyle(.secondary)
                Text("System-wide sound, shaped by you.")
                Text("Copyright © 2026 BalanceEQ contributors.\nLicensed under GNU GPL version 3 or later.\nProvided without warranty. You may redistribute and modify this software under the license terms.")
                    .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                HStack {
                    Button("License") { openResource("LICENSE") }
                    Button("Third-party notices") { openResource("THIRD_PARTY_NOTICES", ext: "md") }
                }
            }.padding(32).frame(width: 410)
        }.windowResizability(.contentSize)
    }

    private func openResource(_ name: String, ext: String? = nil) {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { NSWorkspace.shared.open(url) }
    }
}

private struct EqualizerMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var audio: AudioController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(audio.isStarting ? "Starting system audio…" : (audio.isRunning ? "Processing system audio" : "Processing stopped"))
        Button("Open BalanceEQ") {
            openWindow(id: "equalizer")
            NSApp.activate(ignoringOtherApps: true)
        }
        Toggle("Bypass EQ", isOn: $model.bypassed)
        Button(audio.isRunning ? "Stop EQ" : "Start EQ", action: model.toggleProcessing)
            .disabled(audio.isStarting)
        Divider()
        Menu("Presets") {
            ForEach(model.presets) { preset in Button(preset.name) { model.choose(preset) } }
            if model.presets.isEmpty { Text("Save a preset in the main window") }
        }
        Divider()
        Button("About BalanceEQ") {
            openWindow(id: "about")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit BalanceEQ") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Observe the real window without replacing SwiftUI's window delegate.
private struct MainWindowVisibility: NSViewRepresentable {
    let audio: AudioController

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.audio = audio
        return view
    }
    func updateNSView(_ nsView: VisibilityView, context: Context) { }

    final class VisibilityView: NSView {
        weak var audio: AudioController?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            guard let window else { audio?.setMeteringEnabled(false); return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let visible = notification.name != NSWindow.willCloseNotification &&
                            self.window?.occlusionState.contains(.visible) == true && self.window?.isMiniaturized == false
                        self.audio?.setMeteringEnabled(visible)
                    }
                })
            }
            audio?.setMeteringEnabled(window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
