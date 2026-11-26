import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\Key.name, comparator: .localizedStandard)]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if !model.gpgMissing {
                actionBar
                Divider()
            }
            if model.gpgMissing {
                GPGMissingView()
            } else if model.showNotepad {
                NotepadView()
            } else {
                Picker("", selection: $model.tab) {
                    ForEach(KeyTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                keyTable
            }
            Divider()
            statusBar
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search certificates")
        .sheet(item: $model.sheet) { sheet in
            sheetView(sheet).environment(model)
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
            return true
        }
        .task { await model.refresh() }
    }

    // MARK: - Table

    private var keyTable: some View {
        @Bindable var model = model
        let rows = model.visibleKeys.sorted(using: sortOrder)
        return Table(rows, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { k in
                HStack(spacing: 6) {
                    Image(systemName: k.hasSecret ? "key.fill" : "person.crop.circle")
                        .foregroundStyle(k.hasSecret ? Color.accentColor : .secondary)
                    Text(k.name).fontWeight(k.hasSecret ? .semibold : .regular)
                }
                .opacity(k.isUsable ? 1 : 0.55)
            }
            .width(min: 140, ideal: 200)
            TableColumn("E-Mail", value: \.email, comparator: .localizedStandard) { k in
                Text(k.email).opacity(k.isUsable ? 1 : 0.55)
            }
            .width(min: 120, ideal: 200)
            TableColumn("Status", value: \.statusText) { k in StatusBadge(key: k) }
                .width(min: 90, ideal: 110)
            TableColumn("Valid From", value: \.created) { k in
                Text(k.created, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
            }
            .width(min: 80, ideal: 90)
            TableColumn("Valid Until", value: \.expiresSort) { k in
                if let e = k.expires {
                    Text(e, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
                        .foregroundStyle(k.isExpired ? .red : .primary)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 90)
            TableColumn("Details", value: \.details) { k in Text(k.details).foregroundStyle(.secondary) }
                .width(min: 100, ideal: 130)
            TableColumn("Key-ID", value: \.keyID) { k in
                Text(k.formattedKeyID).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            .width(min: 150, ideal: 170)
        }
        .contextMenu(forSelectionType: Key.ID.self) { ids in
            KeyMenu(keys: model.keys.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let id = ids.first, let k = model.key(id) { model.sheet = .details(k) }
        }
        .overlay {
            if model.loaded && rows.isEmpty {
                ContentUnavailableView {
                    Label(model.keys.isEmpty ? "No Certificates" : "No Matches",
                          systemImage: model.keys.isEmpty ? "key" : "magnifyingglass")
                } description: {
                    Text(model.keys.isEmpty
                         ? "Create your own key pair, or import certificates from files or the clipboard."
                         : "No certificate in this view matches your search.")
                } actions: {
                    if model.keys.isEmpty {
                        HStack {
                            Button("New Key Pair…") { model.sheet = .newKey }
                            Button("Import…") { model.importFromFiles() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Toolbar & status bar

    /// Big labelled buttons, always showing text under the icon.
    private var actionBar: some View {
        HStack(spacing: 2) {
            ActionButton(title: "Sign / Encrypt", icon: "lock.doc.fill", help: "Sign and/or encrypt files") {
                model.chooseFilesToSignEncrypt()
            }
            ActionButton(title: "Decrypt / Verify", icon: "lock.open.fill", help: "Decrypt and/or verify files") {
                model.chooseFilesToDecryptVerify()
            }
            barSeparator
            ActionButton(title: "Import", icon: "square.and.arrow.down.fill", help: "Import certificates from files") {
                model.importFromFiles()
            }
            ActionButton(title: "Paste Key", icon: "doc.on.clipboard.fill", help: "Import a certificate copied to the clipboard") {
                model.importFromClipboard()
            }
            ActionButton(title: "Export", icon: "square.and.arrow.up.fill", help: "Export the selected certificates",
                         disabled: model.selectedKeys.isEmpty) {
                model.exportSelected(model.selectedKeys)
            }
            ActionButton(title: "Certify", icon: "checkmark.seal.fill",
                         help: "Certify the selected certificate after checking its fingerprint",
                         disabled: model.selectedKeys.count != 1 || model.secretKeys.isEmpty) {
                if let k = model.selectedKeys.first { model.sheet = .certify(k) }
            }
            barSeparator
            ActionButton(title: "Notepad", icon: "note.text", help: "Sign, encrypt, decrypt and verify text",
                         active: model.showNotepad) {
                model.showNotepad.toggle()
            }
            Spacer(minLength: 12)
            ActionButton(title: "New Key Pair", icon: "plus.circle.fill", help: "Create your own key pair", prominent: true) {
                model.sheet = .newKey
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var barSeparator: some View {
        Divider().frame(height: 28).padding(.horizontal, 4)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.showNotepad ? "Notepad" : "\(model.visibleKeys.count) of \(model.keys.count) certificates")
            Spacer()
            Text(model.gpgVersion ?? "").foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func sheetView(_ sheet: Sheet) -> some View {
        switch sheet {
        case .newKey: NewKeySheet()
        case .details(let k): DetailsSheet(key: model.key(k.id) ?? k)
        case .expiry(let k): ExpirySheet(key: k)
        case .addUserID(let k): AddUserIDSheet(key: k)
        case .certify(let k): CertifySheet(key: k)
        case .signEncrypt(let urls): SignEncryptSheet(files: urls)
        case .decryptVerify(let urls): DecryptVerifySheet(files: urls)
        }
    }
}

/// The right-click menu of the certificate list.
struct KeyMenu: View {
    @Environment(AppModel.self) private var model
    let keys: [Key]

    var body: some View {
        if keys.count == 1, let k = keys.first {
            Button("Details") { model.sheet = .details(k) }
            Divider()
            Button("Certify…") { model.sheet = .certify(k) }
                .disabled(model.secretKeys.filter { $0.id != k.id }.isEmpty || !k.isUsable)
            Button("Encrypt for This Certificate…") {
                model.notepad.recipients.insert(k.fingerprint)
                model.notepad.encrypt = true
                model.showNotepad = true
            }
            .disabled(!k.canEncrypt)
            if k.hasSecret {
                Divider()
                Button("Change End of Validity Period…") { model.sheet = .expiry(k) }
                Button("Change Passphrase…") { model.changePassphrase(k) }
                Button("Add User ID…") { model.sheet = .addUserID(k) }
                Button("Revoke Certificate…") { model.revoke(k) }.disabled(k.isRevoked)
            }
            Divider()
        }
        if !keys.isEmpty {
            Button("Export…") { model.exportSelected(keys) }
            if keys.count == 1, let k = keys.first, k.hasSecret {
                Button("Backup Secret Keys…") { model.backupSecret(k) }
            }
            Button("Copy Public Key") { model.copyPublicKey(keys) }
            if keys.count == 1, let k = keys.first {
                Button("Copy Fingerprint") { model.copyFingerprint(k) }
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(keys) }
        }
    }
}

/// A toolbar-style button with the icon above a text label, like Kleopatra's main toolbar.
struct ActionButton: View {
    let title: String
    let icon: String
    var help = ""
    var disabled = false
    var active = false
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(height: 16)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(prominent ? Color.white : (active ? Color.accentColor : Color.primary))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(minWidth: 56)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Color.accentColor.opacity(0.5) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var background: Color {
        if prominent { return hovering ? Color.accentColor.opacity(0.85) : Color.accentColor }
        if active { return Color.accentColor.opacity(0.15) }
        return hovering && !disabled ? Color.primary.opacity(0.08) : .clear
    }
}

struct StatusBadge: View {
    let key: Key
    var body: some View {
        let color: Color = switch key.statusLevel {
        case .good: .green
        case .warning: .orange
        case .bad: .red
        case .neutral: .secondary
        }
        Label(key.statusText, systemImage: key.statusLevel == .bad ? "xmark.circle.fill"
              : key.statusLevel == .good ? "checkmark.seal.fill" : "circle.dashed")
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }
}

struct GPGMissingView: View {
    var body: some View {
        ContentUnavailableView {
            Label("GnuPG Is Not Installed", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Kleo uses GnuPG to manage keys, like other OpenPGP certificate managers. Install it, then reopen Kleo:\n\nbrew install gnupg pinentry-mac\n\nor install GPG Suite from gpgtools.org.")
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
