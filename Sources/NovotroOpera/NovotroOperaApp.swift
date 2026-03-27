import AppKit
import Foundation
import SwiftUI

@available(macOS 26.0, *)
@main
struct NovotroOperaApp: App {
    @NSApplicationDelegateAdaptor(OperaAppDelegate.self) private var appDelegate
    @State private var selectedMode: OperaMode = .write

    init() {
        // Opera is local-first in this workspace.
        // Force folder-based operation and avoid any remote/server-backed project sync in this process.
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
    private var keyMonitor: Any?

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(
                name: OperaShellSignals.openProjectFromURL,
                object: nil,
                userInfo: ["url": url]
            )
        }
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        for path in filenames {
            NotificationCenter.default.post(
                name: OperaShellSignals.openProjectFromURL,
                object: nil,
                userInfo: ["url": URL(fileURLWithPath: path)]
            )
        }
        application.reply(toOpenOrPrint: .success)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSaveMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installSaveMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.charactersIgnoringModifiers?.lowercased() == "s" else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command else { return event }
            NotificationCenter.default.post(name: OperaShellSignals.saveProject, object: nil)
            return nil
        }
    }
}
