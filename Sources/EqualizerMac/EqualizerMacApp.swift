import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    var reopen: (() -> Void)?
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
        Window("Equalizer for Mac", id: "equalizer") {
            EqualizerView(model: model, audio: model.audio, appDelegate: delegate)
                .onAppear {
                    delegate.onTerminate = { model.shutDown() }
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1160, height: 790)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .importExport) {
                Button("Import APO Preset…", action: model.importPreset).keyboardShortcut("o")
                Button("Export APO Preset…", action: model.exportPreset).keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Equalizer") {
                Button(model.audio.isRunning ? "Stop Processing" : "Start Processing", action: model.toggleProcessing)
                    .disabled(model.audio.isStarting)
                Toggle("Bypass EQ", isOn: $model.bypassed).keyboardShortcut("b")
            }
        }

        MenuBarExtra("Equalizer for Mac", systemImage: "slider.vertical.3") {
            EqualizerMenu(model: model, audio: model.audio)
        }

        Window("About Equalizer for Mac", id: "about") {
            VStack(spacing: 16) {
                Image(systemName: "waveform.path").font(.system(size: 48)).foregroundStyle(.tint)
                Text("Equalizer for Mac").font(.title2.bold())
                Text("0.1.0 · Free and open source").foregroundStyle(.secondary)
                Text("System-wide sound, shaped by you.")
                Text("Copyright © 2026 Equalizer for Mac contributors.\nLicensed under GNU GPL version 3 or later.\nProvided without warranty. You may redistribute and modify this software under the license terms.")
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
        Text(audio.isRunning ? "Processing system audio" : "Processing stopped")
        Button("Open Equalizer") {
            openWindow(id: "equalizer")
            NSApp.activate(ignoringOtherApps: true)
        }
        Toggle("Bypass EQ", isOn: $model.bypassed)
        Button(audio.isRunning ? "Stop Processing" : "Start Processing", action: model.toggleProcessing)
            .disabled(audio.isStarting)
        Divider()
        Menu("Presets") {
            ForEach(model.presets) { preset in Button(preset.name) { model.choose(preset) } }
            if model.presets.isEmpty { Text("Save a preset in the main window") }
        }
        Divider()
        Button("About Equalizer for Mac") { openWindow(id: "about") }
        Button("Quit") { model.shutDown(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
