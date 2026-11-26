import Foundation

/// A user ID of a certificate, e.g. "Alice Example (work) <alice@example.com>".
struct UserID: Hashable, Identifiable {
    let validity: String
    let text: String

    var id: String { text }
    var isRevoked: Bool { validity == "r" }

    var email: String {
        guard let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close else {
            return text.contains("@") && !text.contains(" ") ? text : ""
        }
        return String(text[text.index(after: open)..<close])
    }

    var name: String {
        var s = text
        if let open = s.lastIndex(of: "<") { s = String(s[..<open]) }
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        s = s.trimmingCharacters(in: .whitespaces)
        return s == email ? "" : s
    }
}

struct Subkey: Hashable, Identifiable {
    var keyID: String
    var fingerprint = ""
    var validity: String
    var algorithm: String
    var created: Date
    var expires: Date?
    var capabilities: String

    var id: String { keyID }

    var usage: String {
        var parts: [String] = []
        if capabilities.contains("s") { parts.append("Sign") }
        if capabilities.contains("c") { parts.append("Certify") }
        if capabilities.contains("e") { parts.append("Encrypt") }
        if capabilities.contains("a") { parts.append("Authenticate") }
        return parts.joined(separator: ", ")
    }
}

/// An OpenPGP certificate (public key, possibly with its secret key) as listed by GnuPG.
struct Key: Hashable, Identifiable {
    var fingerprint = ""
    var keyID: String
    var validity: String
    var algorithm: String
    var created: Date
    var expires: Date?
    var ownertrust: String
    var capabilities: String
    var uids: [UserID] = []
    var subkeys: [Subkey] = []
    var hasSecret = false

    var id: String { fingerprint }

    var primaryUID: UserID? { uids.first(where: { !$0.isRevoked }) ?? uids.first }
    var name: String {
        if let n = primaryUID?.name, !n.isEmpty { return n }
        if let e = primaryUID?.email, !e.isEmpty { return e }
        return primaryUID?.text ?? formattedKeyID
    }
    var email: String { primaryUID?.email ?? "" }

    var isRevoked: Bool { validity == "r" }
    var isExpired: Bool { validity == "e" }
    var isDisabled: Bool { capabilities.contains("D") }
    var isUsable: Bool { !isRevoked && !isExpired && !isDisabled }
    var canEncrypt: Bool { isUsable && capabilities.contains("E") }
    var canSign: Bool { isUsable && capabilities.contains("S") }

    var statusText: String {
        if isDisabled { return "Disabled" }
        switch validity {
        case "r": return "Revoked"
        case "e": return "Expired"
        case "i": return "Invalid"
        case "u": return "Ultimate"
        case "f": return "Certified"
        case "m": return "Marginal"
        default: return "Not certified"
        }
    }

    enum Level { case good, neutral, warning, bad }
    var statusLevel: Level {
        if isRevoked || isExpired || isDisabled || validity == "i" { return .bad }
        switch validity {
        case "u", "f": return .good
        case "m": return .warning
        default: return .neutral
        }
    }

    var details: String { "OpenPGP · \(algorithm)" }
    var expiresSort: Date { expires ?? .distantFuture }
    var formattedKeyID: String { Key.group(keyID) }
    var formattedFingerprint: String { Key.group(fingerprint) }

    var trustText: String {
        switch ownertrust {
        case "u": return "Ultimate (your own certificate)"
        case "f": return "Full"
        case "m": return "Marginal"
        case "n": return "Never"
        default: return "Unknown"
        }
    }

    static func group(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 4).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: min(4, hex.count - i))
            return String(hex[start..<end])
        }.joined(separator: " ")
    }
}

/// One signature found while decrypting or verifying.
struct SignatureInfo: Hashable, Identifiable {
    enum State { case good, bad, expiredSignature, expiredKey, revokedKey, missingKey, error }
    var id = UUID()
    var state: State
    var keyID: String
    var uid: String
    var fingerprint: String?
    var date: Date?
    var trust: String?
}

/// What GnuPG reported about a decrypt/verify operation.
struct VerifyResult: Hashable {
    var wasEncrypted = false
    var decrypted = false
    var encryptedTo: [String] = []
    var missingSecretKeys: [String] = []
    var signatures: [SignatureInfo] = []
    var plaintextName: String?
    var errorMessage: String?

    var succeeded: Bool { errorMessage == nil && (!wasEncrypted || decrypted) }
}
