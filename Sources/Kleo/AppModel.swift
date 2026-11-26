import AppKit
import Observation
import SwiftUI

enum KeyTab: String, CaseIterable, Identifiable {
    case all = "Public Keys"
    case mine = "Private Keys"
    case imported = "My Keys"
    case others = "Other"
    var id: String { rawValue }
}

enum Sheet: Identifiable {
    case newKey
    case details(Key)
    case expiry(Key)
    case addUserID(Key)
    case certify(Key)
    case signEncrypt([URL])
    case decryptVerify([URL])

    var id: String {
        switch self {
        case .newKey: return "new"
        case .details(let k): return "details-\(k.id)"
        case .expiry(let k): return "expiry-\(k.id)"
        case .addUserID(let k): return "uid-\(k.id)"
        case .certify(let k): return "certify-\(k.id)"
        case .signEncrypt(let u): return "se-\(u.map(\.path).joined())"
        case .decryptVerify(let u): return "dv-\(u.map(\.path).joined())"
        }
    }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
@Observable
final class AppModel {
    var keys: [Key] = []
    var importedFingerprints = Set<String>()
    var selection = Set<Key.ID>()
    var tab: KeyTab = .all
    var search = ""
    var showNotepad = false
    var notepad = CryptoSettings()
    var notepadText = ""
    var notepadResult: VerifyResult?
    var sheet: Sheet?
    var alert: AlertInfo?
    var busy = false
    var loaded = false
    var gpgVersion: String?
    var gpgMissing: Bool { GPG.executable == nil }

    var secretKeys: [Key] { keys.filter { $0.hasSecret && $0.canSign } }
    var encryptionKeys: [Key] { keys.filter(\.canEncrypt) }
    var selectedKeys: [Key] { keys.filter { selection.contains($0.id) } }

    var visibleKeys: [Key] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let compactQ = q.replacingOccurrences(of: " ", with: "")
        return keys.filter { k in
            switch tab {
            case .all: break
            case .mine: if !k.hasSecret { return false }
            case .imported: if !importedFingerprints.contains(k.fingerprint) { return false }
            case .others: if k.hasSecret { return false }
            }
            guard !q.isEmpty else { return true }
            return k.uids.contains { $0.text.lowercased().contains(q) }
                || k.fingerprint.lowercased().contains(compactQ)
        }
    }

    func key(_ fingerprint: String) -> Key? { keys.first { $0.fingerprint == fingerprint } }

    // MARK: - Running operations

    func refresh() async {
        if gpgVersion == nil { gpgVersion = await GPG.version() }
        do {
            keys = try await GPG.listKeys()
            selection = selection.filter { id in keys.contains { $0.id == id } }
        } catch {
            show(error, title: "Could not list certificates")
        }
        loaded = true
    }

    /// Runs a GnuPG operation with a busy indicator, then reloads the key list.
    func perform(_ title: String, reload: Bool = true, _ op: @escaping () async throws -> Void) {
        Task {
            busy = true
            defer { busy = false }
            do { try await op() } catch { show(error, title: title) }
            if reload { await refresh() }
        }
    }

    func show(_ error: Error, title: String) {
        alert = AlertInfo(title: title, message: error.localizedDescription)
    }

    func info(_ title: String, _ message: String) {
        alert = AlertInfo(title: title, message: message)
    }

    // MARK: - Import / export

    func importData(_ data: Data, source: String) {
        perform("Import failed") {
            let result = try await GPG.importKeys(data)
            self.importedFingerprints.formUnion(result.fingerprints)
            if !result.fingerprints.isEmpty {
                self.tab = .imported
                self.selection = Set(result.fingerprints)
            }
            self.info("Import from \(source)", result.summary)
        }
    }

    func importFromFiles() {
        let urls = Panels.open(title: "Import Certificates", types: nil)
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            importData(data, source: url.lastPathComponent)
        }
    }

    func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            info("Clipboard is empty", "Copy a public or secret key block first.")
            return
        }
        importData(Data(text.utf8), source: "clipboard")
    }

    func exportSelected(_ keys: [Key]) {
        guard !keys.isEmpty else { return }
        let name = keys.count == 1 ? "\(Self.fileName(keys[0]))_public.asc" : "certificates.asc"
        guard let url = Panels.save(title: "Export Certificates", name: name) else { return }
        perform("Export failed", reload: false) {
            let data = try await GPG.exportPublic(keys.map(\.fingerprint))
            try data.write(to: url)
        }
    }

    func backupSecret(_ key: Key) {
        guard let url = Panels.save(title: "Backup Secret Keys", name: "\(Self.fileName(key))_SECRET.asc") else { return }
        perform("Backup failed", reload: false) {
            let data = try await GPG.exportSecret(key.fingerprint)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            self.info("Backup created", "Your secret key was saved to “\(url.lastPathComponent)”. It is still protected by your passphrase. Keep it somewhere safe.")
        }
    }

    func copyPublicKey(_ keys: [Key]) {
        perform("Copy failed", reload: false) {
            let data = try await GPG.exportPublic(keys.map(\.fingerprint))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
        }
    }

    func copyFingerprint(_ key: Key) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.fingerprint, forType: .string)
    }

    // MARK: - Key management

    func delete(_ keys: [Key]) {
        guard !keys.isEmpty else { return }
        let secret = keys.filter(\.hasSecret)
        let alert = NSAlert()
        alert.alertStyle = secret.isEmpty ? .warning : .critical
        alert.messageText = keys.count == 1 ? "Delete “\(keys[0].name)”?" : "Delete \(keys.count) certificates?"
        alert.informativeText = secret.isEmpty
            ? "The certificates are removed from your keyring. You can import them again later."
            : "This also deletes your SECRET key. Without a backup you will no longer be able to decrypt messages sent to it or sign with it. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform("Delete failed") {
            for k in keys { try await GPG.delete(k) }
        }
    }

    func revoke(_ key: Key) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Revoke “\(key.name)”?"
        alert.informativeText = "A revoked certificate can no longer be used. After revoking, export it and send it to your contacts so they know not to trust it anymore. This cannot be undone."
        alert.addButton(withTitle: "Revoke")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform("Revocation failed") { try await GPG.revoke(key.fingerprint) }
    }

    func changePassphrase(_ key: Key) {
        perform("Changing the passphrase failed", reload: false) {
            try await GPG.changePassphrase(key.fingerprint)
            self.info("Passphrase changed", "Make a new backup of this secret key.")
        }
    }

    // MARK: - Files

    func chooseFilesToSignEncrypt() {
        let urls = Panels.open(title: "Select Files to Sign and/or Encrypt", types: nil)
        if !urls.isEmpty { sheet = .signEncrypt(urls) }
    }

    func chooseFilesToDecryptVerify() {
        let urls = Panels.open(title: "Select Files to Decrypt and/or Verify", types: nil)
        if !urls.isEmpty { sheet = .decryptVerify(urls) }
    }

    /// Files dropped on the window: key files are imported, anything else is decrypted/verified.
    func handleDrop(_ urls: [URL]) {
        var others: [URL] = []
        for url in urls {
            if let data = try? Data(contentsOf: url), GPG.looksLikeKey(data) {
                importData(data, source: url.lastPathComponent)
            } else {
                others.append(url)
            }
        }
        if !others.isEmpty { sheet = .decryptVerify(others) }
    }

    static func fileName(_ key: Key) -> String {
        key.name.replacingOccurrences(of: "[^A-Za-z0-9._@-]+", with: "_", options: .regularExpression)
    }
}

@MainActor
enum Panels {
    static func open(title: String, types: [String]?) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func save(title: String, name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
