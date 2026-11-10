// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle owns validation, replacement and relaunch; normal app termination saves presets and stops audio.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    func check() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Button("Check for Updates…", action: updater.check).disabled(!updater.canCheck)
    }
}
