import Foundation

struct GPGError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Raw result of one gpg invocation. Status lines ("[GNUPG:] ...") are split out of stderr.
struct GPGOutput {
    let exitCode: Int32
    let stdout: Data
    let log: [String]
    let status: [[String]]

    var ok: Bool { exitCode == 0 }
    var text: String { String(decoding: stdout, as: UTF8.self) }

    func status(_ keyword: String) -> [[String]] {
        status.filter { $0.first == keyword }.map { Array($0.dropFirst()) }
    }

    /// The most useful human-readable line gpg printed, for error alerts.
    var errorMessage: String {
        let lines = log.map { $0.replacingOccurrences(of: "gpg: ", with: "") }
            .filter { !$0.isEmpty && !$0.hasPrefix("WARNING: unsafe") }
        return lines.last ?? "GnuPG failed (exit code \(exitCode))."
    }
}

/// Options shared by the Notepad and the file Sign/Encrypt dialog.
struct CryptoOptions {
    var signer: String?          // fingerprint of the secret key to sign with
    var recipients: [String] = []
    var encryptToSelf = true
    var symmetric = false
    var armor = true
    var encrypt = true

    var isEncrypting: Bool { encrypt && (!recipients.isEmpty || symmetric || (encryptToSelf && signer != nil)) }
}

/// Thin wrapper around the gpg command line, like Kleopatra's own GnuPG backend.
/// Passphrases are asked by gpg-agent through pinentry (a native macOS dialog),
/// except for key generation, where the app passes the new passphrase on stdin.
enum GPG {
    static let executable: String? = [
        "/usr/local/bin/gpg", "/opt/homebrew/bin/gpg", "/usr/local/MacGPG2/bin/gpg", "/usr/bin/gpg",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    static var home: URL {
        if let h = ProcessInfo.processInfo.environment["GNUPGHOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gnupg")
    }

    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/usr/local/MacGPG2/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "")
        env["LC_ALL"] = "C"
        return env
    }

    static func run(_ args: [String], input: Data? = nil) async throws -> GPGOutput {
        guard let executable else {
            throw GPGError(message: "GnuPG was not found. Install it with “brew install gnupg” or GPG Suite.")
        }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["--no-tty", "--status-fd", "2"] + args
                process.environment = environment
                let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
                do { try process.run() } catch {
                    cont.resume(throwing: GPGError(message: "Cannot start GnuPG: \(error.localizedDescription)"))
                    return
                }
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                if let input {
                    try? inPipe.fileHandleForWriting.write(contentsOf: input)
                    try? inPipe.fileHandleForWriting.close()
                }
                group.wait()
                process.waitUntilExit()

                var log: [String] = [], status: [[String]] = []
                for line in String(decoding: errData, as: UTF8.self).split(separator: "\n") {
                    if line.hasPrefix("[GNUPG:] ") {
                        status.append(line.dropFirst(9).split(separator: " ", omittingEmptySubsequences: false).map(String.init))
                    } else {
                        log.append(String(line))
                    }
                }
                cont.resume(returning: GPGOutput(exitCode: process.terminationStatus, stdout: outData, log: log, status: status))
            }
        }
    }

    @discardableResult
    private static func check(_ args: [String], input: Data? = nil) async throws -> GPGOutput {
        let out = try await run(args, input: input)
        if !out.ok { throw GPGError(message: out.errorMessage) }
        return out
    }

    static func version() async -> String? {
        guard let out = try? await run(["--version"]) else { return nil }
        return out.text.split(separator: "\n").first.map { String($0).replacingOccurrences(of: "gpg (GnuPG) ", with: "GnuPG ") }
    }

    // MARK: - Listing

    static func listKeys() async throws -> [Key] {
        let listArgs = ["--batch", "--with-colons", "--fixed-list-mode", "--with-fingerprint", "--with-fingerprint"]
        let pub = try await run(listArgs + ["--list-keys"])
        let sec = try await run(listArgs + ["--list-secret-keys"])
        let secret = Set(parseKeys(sec.text).map(\.fingerprint))
        var keys = parseKeys(pub.text)
        for i in keys.indices { keys[i].hasSecret = secret.contains(keys[i].fingerprint) }
        return keys
    }

    static func parseKeys(_ text: String) -> [Key] {
        var keys: [Key] = []
        var inSubkey = false
        for line in text.split(separator: "\n") {
            let f = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            func field(_ i: Int) -> String { i < f.count ? f[i] : "" }
            switch field(0) {
            case "pub", "sec":
                keys.append(Key(
                    keyID: field(4), validity: field(1),
                    algorithm: algorithmName(field(3), length: field(2), curve: field(16)),
                    created: date(field(5)) ?? .distantPast, expires: date(field(6)),
                    ownertrust: field(8), capabilities: field(11)))
                inSubkey = false
            case "sub", "ssb":
                guard !keys.isEmpty else { continue }
                keys[keys.count - 1].subkeys.append(Subkey(
                    keyID: field(4), validity: field(1),
                    algorithm: algorithmName(field(3), length: field(2), curve: field(16)),
                    created: date(field(5)) ?? .distantPast, expires: date(field(6)), capabilities: field(11)))
                inSubkey = true
            case "fpr":
                guard !keys.isEmpty else { continue }
                let last = keys.count - 1
                if inSubkey, !keys[last].subkeys.isEmpty {
                    keys[last].subkeys[keys[last].subkeys.count - 1].fingerprint = field(9)
                } else if keys[last].fingerprint.isEmpty {
                    keys[last].fingerprint = field(9)
                }
            case "uid":
                guard !keys.isEmpty else { continue }
                keys[keys.count - 1].uids.append(UserID(validity: field(1), text: unescape(field(9))))
            default:
                break
            }
        }
        return keys
    }

    private static func date(_ s: String) -> Date? {
        guard let t = TimeInterval(s), t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    private static func algorithmName(_ algo: String, length: String, curve: String) -> String {
        if !curve.isEmpty { return curve }
        switch algo {
        case "1", "2", "3": return "rsa\(length)"
        case "16", "20": return "elg\(length)"
        case "17": return "dsa\(length)"
        default: return "algo \(algo)"
        }
    }

    /// gpg escapes ":" and non-printable bytes in colon listings as \xHH.
    private static func unescape(_ s: String) -> String {
        guard s.contains("\\x") else { return s }
        var bytes: [UInt8] = []
        let utf8 = Array(s.utf8)
        var i = 0
        while i < utf8.count {
            if utf8[i] == UInt8(ascii: "\\"), i + 3 < utf8.count, utf8[i + 1] == UInt8(ascii: "x"),
               let b = UInt8(String(decoding: utf8[(i + 2)...(i + 3)], as: UTF8.self), radix: 16) {
                bytes.append(b)
                i += 4
            } else {
                bytes.append(utf8[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Import / export / delete

    struct ImportResult {
        var imported = 0, unchanged = 0, secretImported = 0, considered = 0
        var fingerprints: [String] = []
        var summary: String {
            if considered == 0 { return "No certificates were found." }
            var parts = ["\(imported) imported"]
            if unchanged > 0 { parts.append("\(unchanged) unchanged") }
            if secretImported > 0 { parts.append("\(secretImported) secret key(s)") }
            return parts.joined(separator: ", ")
        }
    }

    static func importKeys(_ data: Data) async throws -> ImportResult {
        let out = try await run(["--batch", "--import"], input: data)
        var result = ImportResult()
        result.fingerprints = out.status("IMPORT_OK").compactMap { $0.count > 1 ? $0[1] : nil }
        if let r = out.status("IMPORT_RES").first {
            func n(_ i: Int) -> Int { i < r.count ? Int(r[i]) ?? 0 : 0 }
            result.considered = n(0)
            result.imported = n(2)
            result.unchanged = n(4)
            result.secretImported = n(10)
        }
        if result.considered == 0 && !out.ok { throw GPGError(message: out.errorMessage) }
        return result
    }

    static func exportPublic(_ fingerprints: [String]) async throws -> Data {
        try await check(["--batch", "--armor", "--export"] + fingerprints).stdout
    }

    static func exportSecret(_ fingerprint: String) async throws -> Data {
        let out = try await check(["--batch", "--armor", "--export-secret-keys", fingerprint])
        if out.stdout.isEmpty { throw GPGError(message: "Nothing was exported.") }
        return out.stdout
    }

    static func delete(_ key: Key) async throws {
        let op = key.hasSecret ? "--delete-secret-and-public-key" : "--delete-keys"
        try await check(["--batch", "--yes", op, key.fingerprint])
    }

    // MARK: - Key management

    /// Creates a primary key for signing/certifying plus an encryption subkey.
    /// "future-default" (ECC) makes both at once; with an explicit algorithm such as rsa4096
    /// gpg only makes the primary key, so the encryption subkey is added separately.
    static func generate(userID: String, algorithm: String, expiry: String, passphrase: String) async throws -> String {
        let loopback = ["--batch", "--yes", "--pinentry-mode", "loopback", "--passphrase-fd", "0"]
        let input = Data((passphrase + "\n").utf8)
        let isDefault = algorithm == "future-default"
        let out = try await check(loopback + [
            "--quick-generate-key", userID, algorithm, isDefault ? "default" : "sign,cert", expiry,
        ], input: input)
        let fingerprint = out.status("KEY_CREATED").first.flatMap { $0.count > 1 ? $0[1] : nil } ?? ""
        if !isDefault, !fingerprint.isEmpty {
            try await check(loopback + ["--quick-add-key", fingerprint, algorithm, "encr", expiry], input: input)
        }
        return fingerprint
    }

    static func setExpiry(_ fingerprint: String, _ expiry: String) async throws {
        try await check(["--batch", "--quick-set-expire", fingerprint, expiry])
        try await check(["--batch", "--quick-set-expire", fingerprint, expiry, "*"])
    }

    static func addUserID(_ fingerprint: String, _ uid: String) async throws {
        try await check(["--batch", "--quick-add-uid", fingerprint, uid])
    }

    static func changePassphrase(_ fingerprint: String) async throws {
        try await check(["--change-passphrase", fingerprint])
    }

    static func certify(_ fingerprint: String, signer: String, local: Bool) async throws {
        try await check(["--batch", "--yes", "--local-user", signer,
                         local ? "--quick-lsign-key" : "--quick-sign-key", fingerprint])
    }

    /// GnuPG 2.1+ stores a revocation certificate for every key it creates.
    static func revoke(_ fingerprint: String) async throws {
        let url = home.appendingPathComponent("openpgp-revocs.d/\(fingerprint).rev")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw GPGError(message: "No revocation certificate was found for this key (\(url.path)). GnuPG only creates one for keys generated on this computer.")
        }
        let armored = content.replacingOccurrences(of: ":-----BEGIN PGP PUBLIC KEY BLOCK-----",
                                                   with: "-----BEGIN PGP PUBLIC KEY BLOCK-----")
        _ = try await importKeys(Data(armored.utf8))
    }

    // MARK: - Sign / encrypt

    private static func cryptoArgs(_ o: CryptoOptions, detachedForFiles: Bool) -> [String] {
        var args = ["--batch", "--yes", "--trust-model", "always"]
        if o.armor { args.append("--armor") }
        if let s = o.signer { args += ["--local-user", s] }
        if o.isEncrypting {
            var recipients = o.recipients
            if o.encryptToSelf, let s = o.signer { recipients.append(s) }
            if !recipients.isEmpty {
                args.append("--encrypt")
                for r in recipients { args += ["--recipient", r] }
            }
            if o.symmetric { args.append("--symmetric") }
            if o.signer != nil { args.append("--sign") }
        } else {
            args.append(detachedForFiles ? "--detach-sign" : "--clearsign")
        }
        return args
    }

    static func validate(_ o: CryptoOptions) throws {
        if o.encrypt && !o.isEncrypting {
            throw GPGError(message: "Choose at least one recipient, “Encrypt for me”, or a password.")
        }
        if !o.encrypt && o.signer == nil {
            throw GPGError(message: "Choose a certificate to sign with.")
        }
    }

    static func signEncrypt(text: String, _ o: CryptoOptions) async throws -> String {
        try validate(o)
        var opts = o
        opts.armor = true
        return try await check(cryptoArgs(opts, detachedForFiles: false), input: Data(text.utf8)).text
    }

    /// Returns the output file it wrote next to the input.
    static func signEncrypt(file: URL, _ o: CryptoOptions) async throws -> URL {
        try validate(o)
        let ext = o.isEncrypting ? (o.armor ? "asc" : "gpg") : (o.armor ? "asc" : "sig")
        let output = uniqueURL(file.appendingPathExtension(ext))
        try await check(cryptoArgs(o, detachedForFiles: true) + ["--output", output.path, file.path])
        return output
    }

    // MARK: - Decrypt / verify

    static func parseResult(_ out: GPGOutput) -> VerifyResult {
        var r = VerifyResult()
        for s in out.status {
            guard let kw = s.first else { continue }
            let a = Array(s.dropFirst())
            func arg(_ i: Int) -> String { i < a.count ? a[i] : "" }
            func rest(from i: Int) -> String { a.count > i ? a[i...].joined(separator: " ") : "" }
            switch kw {
            case "BEGIN_DECRYPTION": r.wasEncrypted = true
            case "ENC_TO": r.wasEncrypted = true; r.encryptedTo.append(arg(0))
            case "DECRYPTION_OKAY": r.decrypted = true
            case "NO_SECKEY": r.missingSecretKeys.append(arg(0))
            case "PLAINTEXT": r.plaintextName = arg(2).removingPercentEncoding.flatMap { $0.isEmpty ? nil : $0 }
            case "GOODSIG": r.signatures.append(.init(state: .good, keyID: arg(0), uid: rest(from: 1)))
            case "BADSIG": r.signatures.append(.init(state: .bad, keyID: arg(0), uid: rest(from: 1)))
            case "EXPSIG": r.signatures.append(.init(state: .expiredSignature, keyID: arg(0), uid: rest(from: 1)))
            case "EXPKEYSIG": r.signatures.append(.init(state: .expiredKey, keyID: arg(0), uid: rest(from: 1)))
            case "REVKEYSIG": r.signatures.append(.init(state: .revokedKey, keyID: arg(0), uid: rest(from: 1)))
            case "ERRSIG":
                r.signatures.append(.init(state: arg(5) == "9" ? .missingKey : .error, keyID: arg(0), uid: "",
                                          fingerprint: arg(6).isEmpty || arg(6) == "-" ? nil : arg(6),
                                          date: TimeInterval(arg(4)).map { Date(timeIntervalSince1970: $0) }))
            case "VALIDSIG":
                if !r.signatures.isEmpty {
                    r.signatures[r.signatures.count - 1].fingerprint = arg(0)
                    r.signatures[r.signatures.count - 1].date = TimeInterval(arg(2)).map { Date(timeIntervalSince1970: $0) }
                }
            case let t where t.hasPrefix("TRUST_"):
                if !r.signatures.isEmpty { r.signatures[r.signatures.count - 1].trust = String(t.dropFirst(6)).lowercased() }
            default: break
            }
        }
        if !out.ok {
            if r.wasEncrypted && !r.decrypted {
                r.errorMessage = r.missingSecretKeys.count == r.encryptedTo.count && !r.encryptedTo.isEmpty
                    ? "This was not encrypted for any of your secret keys."
                    : "Decryption failed: \(out.errorMessage)"
            } else if r.signatures.isEmpty {
                r.errorMessage = out.errorMessage
            }
        }
        return r
    }

    static func decryptVerify(text: String) async throws -> (String, VerifyResult) {
        let out = try await run(["--batch", "--yes", "--decrypt"], input: Data(text.utf8))
        if out.status.isEmpty && !out.ok { throw GPGError(message: out.errorMessage) }
        return (out.text, parseResult(out))
    }

    /// Decrypts or verifies a file. Detached signatures (.sig, or .asc holding a signature)
    /// are checked against the file next to them with the extension removed.
    static func decryptVerify(file: URL) async throws -> (URL?, VerifyResult) {
        if isDetachedSignature(file) {
            let candidates = [file.deletingPathExtension(), originalName(of: file)]
            guard let data = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw GPGError(message: "This is a detached signature, but the signed file “\(originalName(of: file).lastPathComponent)” is not next to it.")
            }
            let out = try await run(["--batch", "--verify", file.path, data.path])
            return (nil, parseResult(out))
        }
        let known = ["gpg", "pgp", "asc"].contains(file.pathExtension.lowercased())
        let output = uniqueURL(known ? originalName(of: file) : file.appendingPathExtension("out"))
        let out = try await run(["--batch", "--yes", "--output", output.path, "--decrypt", file.path])
        let result = parseResult(out)
        if !result.succeeded || !FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: output)
            return (nil, result)
        }
        return (output, result)
    }

    static func isDetachedSignature(_ file: URL) -> Bool {
        let ext = file.pathExtension.lowercased()
        if ext == "sig" { return true }
        guard ext == "asc", let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 200)) ?? Data(), as: UTF8.self)
        return head.contains("-----BEGIN PGP SIGNATURE-----")
    }

    static func looksLikeKey(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        return head.contains("-----BEGIN PGP PUBLIC KEY BLOCK-----") || head.contains("-----BEGIN PGP PRIVATE KEY BLOCK-----")
    }

    /// "report.pdf (2).gpg" → "report.pdf": drops the extension Kleo added and the " (N)"
    /// that uniqueURL adds so it never overwrites an existing file.
    static func originalName(of file: URL) -> URL {
        let base = file.deletingPathExtension()
        let name = base.lastPathComponent.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
        return base.deletingLastPathComponent().appendingPathComponent(name)
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        for i in 1... {
            let name = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
