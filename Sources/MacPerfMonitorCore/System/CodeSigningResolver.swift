import Foundation
import Security

/// Resolves a binary's code-signing Team Identifier from its on-disk executable.
///
/// Signing information is world-readable for system and vendor binaries, so this
/// reads the signature directly by path — no privileged-helper round-trip. The
/// inspection (`SecStaticCode…`) is a touch slow, so results are **cached by
/// path** in bounded LRU caches, including unsigned binaries. The
/// Sampler only resolves the Team ID when it first sees a process (the
/// `StaticInfo` cache miss), keeping this off the per-tick hot path.
///
/// This is the minimal Core counterpart to the app target's richer
/// `CodeSignInfo.inspect`; it extracts only the Team ID that process groups need.
public final class CodeSigningResolver: @unchecked Sendable {
    public static let shared = CodeSigningResolver()

    private let lock = NSLock()
    private var cache = BoundedCache<String, String?>()
    private var orgCache = BoundedCache<String, String?>()
    private let resolveTeamID: (String) -> String?
    private let resolveOrganization: (String) -> String?

    public init() {
        resolveTeamID = Self.readTeamID
        resolveOrganization = Self.readOrganization
    }

    init(
        resolveTeamID: @escaping (String) -> String?,
        resolveOrganization: @escaping (String) -> String?
    ) {
        self.resolveTeamID = resolveTeamID
        self.resolveOrganization = resolveOrganization
    }

    /// The Team Identifier (e.g. "EQHXZ8M8AV") for the binary at `path`, or nil
    /// when the path is empty, the binary is unsigned / ad-hoc signed, or the
    /// signature can't be read. Cached by path, so repeat calls are free.
    public func teamID(forExecutablePath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }

        lock.lock()
        if let cached = cache.value(forKey: path) {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = resolveTeamID(path)

        lock.lock()
        cache.insert(resolved, forKey: path)
        lock.unlock()
        return resolved
    }

    /// The signing **organization** (e.g. "Anthropic PBC") for the binary at
    /// `path`, parsed from its leaf certificate's common name — the same vendor
    /// string `codesign` prints as the Developer ID authority. nil when unsigned /
    /// unreadable. Cached by path. This is a friendlier label for a Team ID than a
    /// process name, and unlike the glossary it needs no curation.
    public func organization(forExecutablePath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }

        lock.lock()
        if let cached = orgCache.value(forKey: path) {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = resolveOrganization(path)

        lock.lock()
        orgCache.insert(resolved, forKey: path)
        lock.unlock()
        return resolved
    }

    /// Drop the caches (used by `Sampler.reset`).
    public func reset() {
        lock.lock()
        cache.removeAll()
        orgCache.removeAll()
        lock.unlock()
    }

    private static func readTeamID(path: String) -> String? {
        let url = URL(fileURLWithPath: path) as CFURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return nil }

        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, infoFlags, &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return nil }

        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func readOrganization(path: String) -> String? {
        let url = URL(fileURLWithPath: path) as CFURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return nil }

        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, infoFlags, &info) == errSecSuccess,
            let dict = info as? [String: Any],
            let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certs.first
        else { return nil }

        var cn: CFString?
        guard SecCertificateCopyCommonName(leaf, &cn) == errSecSuccess,
            let commonName = cn as String?
        else { return nil }
        return organization(fromCommonName: commonName)
    }

    /// Pull the org out of a Developer ID / Mac Developer common name, e.g.
    /// "Developer ID Application: Anthropic PBC (Q6L2SF6YDW)" → "Anthropic PBC".
    /// Returns nil for common names without the "type: org (team)" shape.
    static func organization(fromCommonName commonName: String) -> String? {
        guard let colon = commonName.range(of: ": ") else { return nil }
        let rest = commonName[colon.upperBound...]
        let org: Substring
        if let paren = rest.range(of: " (") {
            org = rest[..<paren.lowerBound]
        } else {
            org = rest
        }
        let trimmed = org.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
