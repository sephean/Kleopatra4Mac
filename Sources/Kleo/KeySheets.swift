import SwiftUI

/// Common frame for every dialog: title, content, and a Cancel / action button row.
struct SheetFrame<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var actionDisabled = false
    var busy = false
    var action: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            }
            content
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(actionTitle == nil ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .keyboardShortcut(.defaultAction)
                        .disabled(actionDisabled || busy)
                }
            }
        }
        .padding(20)
    }
}

// MARK: - New key pair

struct NewKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var algorithm = "future-default"
    @State private var expiry = "2y"
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?

    private var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty && email.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter a name or an email address."
        }
        if passphrase.count < 8 { return "The passphrase must be at least 8 characters." }
        if passphrase != confirm { return "The passphrases do not match." }
        return nil
    }

    var body: some View {
        SheetFrame(title: "Create Key Pair",
                   subtitle: "Your name and email are published in the certificate you share with others.",
                   actionTitle: busy ? "Creating…" : "Create", actionDisabled: problem != nil, busy: busy, action: create) {
            Form {
                TextField("Name", text: $name)
                TextField("E-Mail", text: $email)
                Picker("Key material", selection: $algorithm) {
                    Text("ECC (Curve 25519) — recommended").tag("future-default")
                    Text("RSA 4096 bits").tag("rsa4096")
                    Text("RSA 3072 bits").tag("rsa3072")
                }
                Picker("Valid until", selection: $expiry) {
                    Text("1 year").tag("1y")
                    Text("2 years").tag("2y")
                    Text("3 years").tag("3y")
                    Text("5 years").tag("5y")
                    Text("Unlimited").tag("never")
                }
                SecureField("Passphrase", text: $passphrase)
                SecureField("Repeat passphrase", text: $confirm)
            }
            .formStyle(.grouped)
            .frame(width: 460)
            if let msg = error ?? problem.flatMap({ passphrase.isEmpty && name.isEmpty ? nil : $0 }) {
                Text(msg).font(.callout).foregroundStyle(error != nil ? .red : .secondary)
            }
        }
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let e = email.trimmingCharacters(in: .whitespaces)
        let uid = n.isEmpty ? e : (e.isEmpty ? n : "\(n) <\(e)>")
        busy = true
        error = nil
        Task {
            do {
                let fpr = try await GPG.generate(userID: uid, algorithm: algorithm, expiry: expiry, passphrase: passphrase)
                await model.refresh()
                model.tab = .mine
                if !fpr.isEmpty { model.selection = [fpr] }
                dismiss()
                model.info("Key pair created",
                           "Make a backup now: right-click your certificate › Backup Secret Keys…\n\nShare your public certificate with Export… so others can encrypt for you and verify your signatures.")
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}

// MARK: - Details

struct DetailsSheet: View {
    @Environment(AppModel.self) private var model
    let key: Key

    var body: some View {
        SheetFrame(title: key.name, subtitle: key.email.isEmpty ? nil : key.email) {
            HStack(alignment: .top, spacing: 24) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    row("Status") { StatusBadge(key: key) }
                    row("Type") { Text(key.hasSecret ? "OpenPGP certificate with secret key" : "OpenPGP certificate") }
                    row("Fingerprint") {
                        Text(key.formattedFingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                    row("Key-ID") { Text(key.formattedKeyID).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    row("Algorithm") { Text(key.algorithm) }
                    row("Valid from") { Text(key.created, format: .dateTime.year().month().day()) }
                    row("Valid until") { Text(key.expires.map { $0.formatted(date: .long, time: .omitted) } ?? "Unlimited") }
                    row("Owner trust") { Text(key.trustText) }
                }
            }
            GroupBox("User IDs") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(key.uids) { uid in
                        HStack {
                            Text(uid.text).strikethrough(uid.isRevoked).textSelection(.enabled)
                            Spacer()
                            if uid.isRevoked { Text("revoked").foregroundStyle(.red).font(.caption) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            GroupBox("Subkeys") {
                Table(key.subkeys) {
                    TableColumn("Key-ID") { s in Text(Key.group(s.keyID)).font(.system(.callout, design: .monospaced)) }
                    TableColumn("Algorithm", value: \.algorithm)
                    TableColumn("Usage", value: \.usage)
                    TableColumn("Valid Until") { s in Text(s.expires.map { $0.formatted(date: .numeric, time: .omitted) } ?? "—") }
                }
                .frame(height: 110)
            }
            HStack {
                Button("Copy Fingerprint") { model.copyFingerprint(key) }
                Button("Export…") { model.exportSelected([key]) }
                if key.hasSecret { Button("Backup Secret Keys…") { model.backupSecret(key) } }
            }
        }
        .frame(width: 620)
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value()
        }
    }
}

// MARK: - Expiry

struct ExpirySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: Key
    @State private var unlimited = false
    @State private var date = Calendar.current.date(byAdding: .year, value: 2, to: .now) ?? .now

    var body: some View {
        SheetFrame(title: "Change End of Validity Period", subtitle: key.name, actionTitle: "OK", action: save) {
            Picker("", selection: $unlimited) {
                Text("Valid until:").tag(false)
                Text("Unlimited validity").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            DatePicker("Date", selection: $date, in: Date.now..., displayedComponents: .date)
                .disabled(unlimited)
                .labelsHidden()
            HStack {
                ForEach([1, 2, 3], id: \.self) { years in
                    Button("+\(years) year\(years > 1 ? "s" : "")") {
                        unlimited = false
                        date = Calendar.current.date(byAdding: .year, value: years, to: .now) ?? date
                    }
                }
            }
            Text("The new date applies to the certificate and its subkeys. Send the updated certificate to your contacts afterwards.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(width: 440)
        .onAppear {
            unlimited = key.expires == nil
            if let e = key.expires, e > .now { date = e }
        }
    }

    private func save() {
        let value = unlimited ? "never" : date.formatted(.iso8601.year().month().day())
        dismiss()
        model.perform("Changing the validity period failed") { try await GPG.setExpiry(key.fingerprint, value) }
    }
}

// MARK: - Add user ID

struct AddUserIDSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: Key
    @State private var name = ""
    @State private var email = ""

    private var uid: String {
        let n = name.trimmingCharacters(in: .whitespaces), e = email.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? e : (e.isEmpty ? n : "\(n) <\(e)>")
    }

    var body: some View {
        SheetFrame(title: "Add User ID", subtitle: key.name, actionTitle: "OK", actionDisabled: uid.isEmpty, action: save) {
            Form {
                TextField("Name", text: $name)
                TextField("E-Mail", text: $email)
            }
            .formStyle(.grouped)
            if !uid.isEmpty { Text("Preview: \(uid)").font(.callout).foregroundStyle(.secondary) }
        }
        .frame(width: 420)
    }

    private func save() {
        let value = uid
        dismiss()
        model.perform("Adding the user ID failed") { try await GPG.addUserID(key.fingerprint, value) }
    }
}

// MARK: - Certify

struct CertifySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: Key
    @State private var signer = ""
    @State private var checked = false
    @State private var local = false

    private var signers: [Key] { model.secretKeys.filter { $0.id != key.id } }

    var body: some View {
        SheetFrame(title: "Certify Certificate",
                   subtitle: "Certifying confirms that this certificate really belongs to the person in its user IDs.",
                   actionTitle: "Certify", actionDisabled: !checked || signer.isEmpty, action: certify) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(key.uids.filter { !$0.isRevoked }) { Text($0.text).fontWeight(.medium) }
                    Text(key.formattedFingerprint)
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            Toggle("I have verified this fingerprint with the owner (in person, by phone, or another trusted channel)", isOn: $checked)
            Picker("Certify with", selection: $signer) {
                ForEach(signers) { Text("\($0.name) — \($0.formattedKeyID)").tag($0.fingerprint) }
            }
            Toggle("Certify only for myself (not exportable)", isOn: $local)
            Text("Your passphrase will be asked in a secure GnuPG window.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(width: 520)
        .onAppear { signer = signers.first?.fingerprint ?? "" }
    }

    private func certify() {
        let s = signer, l = local
        dismiss()
        model.perform("Certification failed") { try await GPG.certify(key.fingerprint, signer: s, local: l) }
    }
}
