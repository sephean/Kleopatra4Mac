import SwiftUI

/// UI state for "sign as / encrypt for" choices, shared by the Notepad and the file dialog.
struct CryptoSettings {
    var sign = true
    var signer = ""
    var encrypt = true
    var encryptToSelf = true
    var recipients = Set<String>()
    var symmetric = false
    var armor = true

    func options() -> CryptoOptions {
        let me = signer.isEmpty ? nil : signer
        return CryptoOptions(
            signer: sign ? me : nil,
            recipients: encrypt ? Array(recipients) : [],
            encryptToSelf: encrypt && encryptToSelf && me != nil,
            symmetric: encrypt && symmetric,
            armor: armor,
            encrypt: encrypt)
    }
}

// Encrypting to self needs the key even when not signing, so the options carry it separately.
extension CryptoSettings {
    func resolvedOptions() -> CryptoOptions {
        var o = options()
        if o.encryptToSelf, !sign, !signer.isEmpty {
            o.recipients.append(signer)
            o.encryptToSelf = false
        }
        return o
    }
}

struct CryptoOptionsView: View {
    @Environment(AppModel.self) private var model
    @Binding var settings: CryptoSettings
    var showArmor = true
    @State private var filter = ""

    private var candidates: [Key] {
        let q = filter.lowercased()
        return model.encryptionKeys
            .filter { $0.fingerprint != settings.signer || !settings.encryptToSelf }
            .filter { q.isEmpty || $0.uids.contains { $0.text.lowercased().contains(q) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Sign") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Sign as:", isOn: $settings.sign)
                    Picker("Sign as", selection: $settings.signer) {
                        if model.secretKeys.isEmpty { Text("No secret key").tag("") }
                        ForEach(model.secretKeys) { Text("\($0.name) (\($0.formattedKeyID.suffix(9)))").tag($0.fingerprint) }
                    }
                    .labelsHidden()
                    .disabled(model.secretKeys.isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            GroupBox("Encrypt") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Encrypt", isOn: $settings.encrypt)
                    Group {
                        Toggle("Encrypt for me", isOn: $settings.encryptToSelf)
                            .disabled(settings.signer.isEmpty)
                        Text("Encrypt for others:").font(.callout).foregroundStyle(.secondary)
                        TextField("Filter certificates", text: $filter).textFieldStyle(.roundedBorder)
                        List {
                            if candidates.isEmpty {
                                Text(model.encryptionKeys.isEmpty
                                     ? "No certificates. Import the public key of the person you write to."
                                     : "No match.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(candidates) { k in
                                Toggle(isOn: Binding(
                                    get: { settings.recipients.contains(k.fingerprint) },
                                    set: { on in
                                        if on { settings.recipients.insert(k.fingerprint) } else { settings.recipients.remove(k.fingerprint) }
                                    })) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(k.name)
                                        Text(k.email.isEmpty ? k.formattedKeyID : k.email).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .help(k.statusLevel == .good ? "" : "This certificate is not certified. Make sure it really belongs to this person.")
                            }
                        }
                        .listStyle(.bordered)
                        .frame(minHeight: 120)
                        Toggle("Encrypt with password", isOn: $settings.symmetric)
                    }
                    .disabled(!settings.encrypt)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            if showArmor {
                Toggle("Text output (ASCII armor)", isOn: $settings.armor)
            }
        }
        .onAppear {
            if settings.signer.isEmpty { settings.signer = model.secretKeys.first?.fingerprint ?? "" }
            if model.secretKeys.isEmpty { settings.sign = false }
        }
    }
}

// MARK: - Signature results

struct ResultView: View {
    @Environment(AppModel.self) private var model
    let result: VerifyResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = result.errorMessage {
                banner(error, icon: "xmark.octagon.fill", color: .red)
            } else if result.wasEncrypted {
                banner("Decryption succeeded", icon: "lock.open.fill", color: .green)
            }
            if result.signatures.isEmpty && result.errorMessage == nil {
                banner("Not signed: the sender cannot be verified.", icon: "exclamationmark.triangle.fill", color: .orange)
            }
            ForEach(result.signatures) { sig in signatureRow(sig) }
        }
    }

    private func signatureRow(_ sig: SignatureInfo) -> some View {
        let signer = sig.fingerprint.flatMap { fpr in model.keys.first { $0.fingerprint == fpr || $0.subkeys.contains { $0.fingerprint == fpr } } }
            ?? model.keys.first { $0.keyID.hasSuffix(sig.keyID) || $0.subkeys.contains { $0.keyID.hasSuffix(sig.keyID) } }
        let who = signer.map { $0.primaryUID?.text ?? $0.name } ?? (sig.uid.isEmpty ? sig.keyID : sig.uid)
        let when = sig.date.map { " on \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        switch sig.state {
        case .good:
            let certified = sig.trust == "fully" || sig.trust == "ultimate"
            return banner(certified ? "Valid signature by \(who)\(when)"
                                    : "Valid signature by \(who)\(when). The certificate is not certified: check its fingerprint before trusting it.",
                          icon: certified ? "checkmark.seal.fill" : "checkmark.circle",
                          color: certified ? .green : .orange)
        case .bad:
            return banner("INVALID signature claiming to be from \(who). The content was modified or the signature is forged.",
                          icon: "xmark.seal.fill", color: .red)
        case .missingKey:
            return banner("Signed\(when) by an unknown certificate (Key-ID \(Key.group(sig.keyID))). Import the sender's certificate to verify it.",
                          icon: "questionmark.circle.fill", color: .orange)
        case .expiredKey:
            return banner("Signature by \(who)\(when), but that certificate has expired.", icon: "clock.badge.exclamationmark", color: .orange)
        case .expiredSignature:
            return banner("Signature by \(who) has expired.", icon: "clock.badge.exclamationmark", color: .orange)
        case .revokedKey:
            return banner("Signature by \(who), but that certificate has been REVOKED.", icon: "xmark.seal.fill", color: .red)
        case .error:
            return banner("The signature could not be checked.", icon: "exclamationmark.triangle.fill", color: .red)
        }
    }

    private func banner(_ text: String, icon: String, color: Color) -> some View {
        Label { Text(text).textSelection(.enabled) } icon: { Image(systemName: icon).foregroundStyle(color) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Files: sign / encrypt

struct SignEncryptSheet: View {
    @Environment(AppModel.self) private var model
    @State var files: [URL]
    @State private var settings = CryptoSettings()
    @State private var outputs: [(URL, Result<URL, Error>)] = []
    @State private var busy = false

    var body: some View {
        SheetFrame(title: "Sign / Encrypt Files", actionTitle: outputs.isEmpty ? actionTitle : nil,
                   busy: busy, action: run) {
            if outputs.isEmpty {
                FileList(files: $files)
                CryptoOptionsView(settings: $settings)
            } else {
                List(outputs, id: \.0) { input, result in
                    HStack {
                        switch result {
                        case .success(let out):
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("\(input.lastPathComponent) → \(out.lastPathComponent)")
                            Spacer()
                            Button("Show in Finder") { Panels.reveal([out]) }
                        case .failure(let error):
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text("\(input.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                }
                .frame(minHeight: 160)
            }
        }
        .frame(width: 560)
    }

    private var actionTitle: String {
        let o = settings.resolvedOptions()
        switch (o.signer != nil, o.isEncrypting) {
        case (true, true): return "Sign & Encrypt"
        case (false, true): return "Encrypt"
        default: return "Sign"
        }
    }

    private func run() {
        let opts = settings.resolvedOptions()
        busy = true
        Task {
            var results: [(URL, Result<URL, Error>)] = []
            for file in files {
                do { results.append((file, .success(try await GPG.signEncrypt(file: file, opts)))) }
                catch { results.append((file, .failure(error))) }
            }
            outputs = results
            busy = false
        }
    }
}

// MARK: - Files: decrypt / verify

struct DecryptVerifySheet: View {
    @Environment(AppModel.self) private var model
    @State var files: [URL]
    @State private var results: [(URL, URL?, Result<VerifyResult, Error>)] = []
    @State private var busy = false

    var body: some View {
        SheetFrame(title: "Decrypt / Verify Files", actionTitle: results.isEmpty ? "Decrypt / Verify" : nil,
                   busy: busy, action: run) {
            if results.isEmpty {
                FileList(files: $files)
                Text("Decrypted files are saved next to the originals. For a detached signature (.sig), the signed file must be in the same folder.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(results, id: \.0) { input, output, result in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(input.lastPathComponent).font(.headline)
                                    Spacer()
                                    if let output { Button("Show \(output.lastPathComponent) in Finder") { Panels.reveal([output]) } }
                                }
                                switch result {
                                case .success(let r): ResultView(result: r)
                                case .failure(let e):
                                    Label(e.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 420)
            }
        }
        .frame(width: 600)
    }

    private func run() {
        busy = true
        Task {
            var out: [(URL, URL?, Result<VerifyResult, Error>)] = []
            for file in files {
                do {
                    let (written, r) = try await GPG.decryptVerify(file: file)
                    out.append((file, written, .success(r)))
                } catch {
                    out.append((file, nil, .failure(error)))
                }
            }
            results = out
            busy = false
        }
    }
}

struct FileList: View {
    @Binding var files: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List {
                ForEach(files, id: \.self) { url in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                        Text(url.lastPathComponent)
                        Spacer()
                        Button { files.removeAll { $0 == url } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.bordered)
            .frame(height: 110)
            .dropDestination(for: URL.self) { urls, _ in
                files.append(contentsOf: urls.filter { !files.contains($0) })
                return true
            }
            Button("Add Files…") {
                let more = Panels.open(title: "Add Files", types: nil)
                files.append(contentsOf: more.filter { !files.contains($0) })
            }
        }
    }
}

// MARK: - Notepad

struct NotepadView: View {
    @Environment(AppModel.self) private var model
    @State private var busy = false

    var body: some View {
        @Bindable var model = model
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button { signEncrypt() } label: {
                        Label("Sign / Encrypt", systemImage: "lock.fill").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { decryptVerify() } label: {
                        Label("Decrypt / Verify", systemImage: "lock.open.fill").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    Button { model.importData(Data(model.notepadText.utf8), source: "Notepad") } label: {
                        Label("Import Key", systemImage: "square.and.arrow.down").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!GPG.looksLikeKey(Data(model.notepadText.utf8)))
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.notepadText, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    Button { model.notepadText = ""; model.notepadResult = nil } label: {
                        Label("Clear", systemImage: "trash").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(busy)
                if let r = model.notepadResult {
                    ResultView(result: r)
                }
                TextEditor(text: $model.notepadText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
            .padding(12)
            .frame(minWidth: 420)
            ScrollView {
                CryptoOptionsView(settings: $model.notepad, showArmor: false)
                    .padding(12)
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
        }
    }

    private func signEncrypt() {
        let text = model.notepadText
        guard !text.isEmpty else { return }
        let opts = model.notepad.resolvedOptions()
        busy = true
        Task {
            defer { busy = false }
            do {
                model.notepadText = try await GPG.signEncrypt(text: text, opts)
                model.notepadResult = nil
            } catch {
                model.show(error, title: "Sign / Encrypt failed")
            }
        }
    }

    private func decryptVerify() {
        let text = model.notepadText
        guard !text.isEmpty else { return }
        if GPG.looksLikeKey(Data(text.utf8)) {
            model.importData(Data(text.utf8), source: "Notepad")
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let (plain, result) = try await GPG.decryptVerify(text: text)
                model.notepadResult = result
                if result.succeeded, !plain.isEmpty { model.notepadText = plain }
            } catch {
                model.show(error, title: "Decrypt / Verify failed")
            }
        }
    }
}
