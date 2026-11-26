import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // gpg may exit before reading all of its input; don't let that kill the app.
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct KleoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Kleo", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 540)
        }
        .defaultSize(width: 1140, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Key Pair…") { model.sheet = .newKey }
                    .keyboardShortcut("n")
            }
            CommandMenu("Certificates") {
                Button("Import…") { model.importFromFiles() }
                    .keyboardShortcut("i")
                Button("Import from Clipboard") { model.importFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Export…") { model.exportSelected(model.selectedKeys) }
                    .keyboardShortcut("e")
                    .disabled(model.selectedKeys.isEmpty)
                Button("Copy Public Key") { model.copyPublicKey(model.selectedKeys) }
                    .disabled(model.selectedKeys.isEmpty)
                Divider()
                Button("Details") { if let k = model.selectedKeys.first { model.sheet = .details(k) } }
                    .keyboardShortcut("d")
                    .disabled(model.selectedKeys.count != 1)
                Button("Certify…") { if let k = model.selectedKeys.first { model.sheet = .certify(k) } }
                    .disabled(model.selectedKeys.count != 1 || model.secretKeys.isEmpty)
                Button("Delete") { model.delete(model.selectedKeys) }
                    .keyboardShortcut(.delete)
                    .disabled(model.selectedKeys.isEmpty)
                Divider()
                Button("Redisplay") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
            CommandMenu("Tools") {
                Button("Sign/Encrypt Files…") { model.chooseFilesToSignEncrypt() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Decrypt/Verify Files…") { model.chooseFilesToDecryptVerify() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button(model.showNotepad ? "Show Certificates" : "Show Notepad") { model.showNotepad.toggle() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}
