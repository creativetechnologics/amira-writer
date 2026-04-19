import AppKit
import Foundation
import ScoreUI
import SwiftUI

@available(macOS 26.0, *)
@main
struct OperaApp: App {
    @NSApplicationDelegateAdaptor(OperaAppDelegate.self) private var appDelegate
    @State private var selectedMode: OperaMode = .write

    init() {
        // Opera is local-first in this workspace.
        // Force folder-based operation and avoid any remote/server-backed project sync in this process.
        setenv("PROJECT_SERVICE_DISABLE", "1", 1)
        setenv("NOVOTRO_DISABLE_PROJECT_SERVICE", "1", 1)
        // Note: Score API server is intentionally enabled for remote diagnostics.
    }

    var body: some Scene {
        WindowGroup("Amira Writer") {
            OperaShellView(selectedMode: $selectedMode)

        }
        .defaultSize(width: 1280, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            OperaProjectCommands()
            OperaModeCommands(selectedMode: $selectedMode)
        }
    }
}

@available(macOS 26.0, *)
    private struct OperaProjectCommands: Commands {
        var body: some Commands {
            CommandGroup(replacing: .newItem) {
            Button("Open Project…") {
                NotificationCenter.default.post(name: OperaShellSignals.openProjectFromDisk, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Recent Projects…") {
                NotificationCenter.default.post(name: OperaShellSignals.openRecentProjects, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Button("Save") {
                NotificationCenter.default.post(name: OperaShellSignals.saveProject, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)
        }
    }
}

@available(macOS 26.0, *)
private struct OperaModeCommands: Commands {
    @Binding var selectedMode: OperaMode

    var body: some Commands {
        CommandMenu("Mode") {
            ForEach(Array(OperaMode.allCases.enumerated()), id: \.element.id) { index, mode in
                Button(mode.title) {
                    selectedMode = mode
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
    }
}

private final class OperaAppDelegate: NSObject, NSApplicationDelegate {
    /// Set to true while a headless Full-Mix export task is running so the
    /// unsaved-changes quit guard does not prompt the user.
    private var isRunningHeadlessExport = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // MARK: Headless Full-Mix export hook
        // Triggered when the app is launched with:
        //   AMIRA_HEADLESS_FULLMIX_EXPORT=/absolute/path/to/output.wav
        // Optional:
        //   AMIRA_HEADLESS_FULLMIX_SONG=<relative song path or stem>  (default: first song)
        //
        // The hook loads the last-used project read-only (no saves), exports the full
        // mix WAV using the same ScoreStore.exportFullMixToWav path the GUI uses, logs
        // a final [HeadlessFullMix] done line, then terminates.
        let env = ProcessInfo.processInfo.environment
        guard let outputPath = env["AMIRA_HEADLESS_FULLMIX_EXPORT"] else { return }

        isRunningHeadlessExport = true
        let outputURL = URL(fileURLWithPath: outputPath)
        let songHint = env["AMIRA_HEADLESS_FULLMIX_SONG"]

        Task { @MainActor in
            await ScoreBootstrap.runHeadlessFullMixExport(outputURL: outputURL, songHint: songHint)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isRunningHeadlessExport else { return }
        for url in urls {
            NotificationCenter.default.post(
                name: OperaShellSignals.openProjectFromURL,
                object: nil,
                userInfo: ["url": url]
            )
        }
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        guard !isRunningHeadlessExport else {
            application.reply(toOpenOrPrint: .success)
            return
        }
        for path in filenames {
            NotificationCenter.default.post(
                name: OperaShellSignals.openProjectFromURL,
                object: nil,
                userInfo: ["url": URL(fileURLWithPath: path)]
            )
        }
        application.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Headless export calls terminate(nil) directly; skip the unsaved-changes dialog.
        if isRunningHeadlessExport { return .terminateNow }

        let hasDirty = MainActor.assumeIsolated {
            OperaShellSignals.hasUnsavedChanges?() ?? false
        }
        guard hasDirty else { return .terminateNow }

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "You have unsaved changes"
            alert.informativeText = "Do you want to save your changes before quitting?"
            alert.addButton(withTitle: "Save & Quit")
            alert.addButton(withTitle: "Quit Without Saving")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                // Save & Quit
                MainActor.assumeIsolated {
                    OperaShellSignals.saveAll?()
                }
                // Wait for saves to complete (up to 5 seconds), then terminate
                Task { @MainActor in
                    let deadline = Date().addingTimeInterval(5)
                    while (OperaShellSignals.hasUnsavedChanges?() ?? false) && Date() < deadline {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    NSApplication.shared.reply(toApplicationShouldTerminate: true)
                }
            case .alertSecondButtonReturn:
                // Quit Without Saving
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            default:
                // Cancel
                NSApplication.shared.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
