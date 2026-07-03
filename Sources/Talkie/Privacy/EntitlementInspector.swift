import Foundation
import Security

/// `EntitlementInspector` — reads the *running binary's own* code signature to
/// answer the only three questions the privacy proof needs: which capabilities it
/// claims, whether any of them is a network entitlement, and what its code-signature
/// hash (cdhash) is. Extracted from `PrivacySection.loadEntitlements` (I5) so both
/// the Privacy pane and the `talkie doctor` CLI (I6) describe the exact same binary
/// through one code path — the pane can never drift from what the doctor prints.
///
/// Everything here is `nonisolated` and input-free: it reads process-global state
/// (`SecCodeCopySelf`) and returns immutable values, so it's safe to call from the
/// CLI seam in `main.swift` before any actor/UI exists, and from the main actor in
/// the pane. It *inspects*; it never connects — no network symbol appears in this
/// file, so it doesn't touch the zero-network wall.
///
/// Honesty invariant (`_UNIFICATION.md` §4.3): on an ad-hoc or un-signed build the
/// signature carries no entitlements dictionary and no stable cdhash. We surface
/// that as an empty capability list / `nil` cdhash rather than inventing a green
/// value — a missing reading degrades honestly, it never fakes a pass.
enum EntitlementInspector {

    /// One capability the binary claims, as read from its signature.
    struct Capability: Sendable, Hashable {
        /// Human label ("Microphone capture").
        let label: String
        /// The raw entitlement key ("com.apple.security.device.audio-input").
        let key: String
        /// True when this key is a network entitlement — which, on a build labelled
        /// "Talkie", would be a bug worth flagging loudly.
        let isNetwork: Bool
    }

    /// The entitlement keys we probe for, with their display labels. The same four
    /// the pane checked: the one the app legitimately holds (microphone), the two
    /// network ones whose presence would be a bug, and the sandbox flag. A key not
    /// present in the signature simply doesn't appear in the returned list.
    private static let known: [(key: String, label: String)] = [
        ("com.apple.security.device.audio-input", "Microphone capture"),
        ("com.apple.security.network.client", "Outbound network"),
        ("com.apple.security.network.server", "Inbound network"),
        ("com.apple.security.app-sandbox", "App Sandbox"),
    ]

    /// Read this process's own signing information once — the entitlements
    /// dictionary and the cdhash — in a single `SecCodeCopySigningInformation`
    /// call so the pane and the doctor describe the same binary. Returns `nil` for
    /// the whole read only when the signature can't be opened at all.
    ///
    /// We ask for both `kSecCSRequirementInformation` (→ the entitlements dict) and
    /// `kSecCSSigningInformation` (→ `kSecCodeInfoUnique`, the cdhash). On an ad-hoc
    /// / un-signed build these come back absent; the caller then sees an empty
    /// capability list and a `nil` cdhash and degrades honestly.
    private static func readSigningInfo() -> (entitlements: [String: Any], cdhash: String?)? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }

        let flags = SecCSFlags(rawValue: kSecCSRequirementInformation | kSecCSSigningInformation)
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }

        // cdhash: kSecCodeInfoUnique is CFData of the code-directory hash. Rendered
        // as a lowercase hex string — the same form `codesign -dvvv` prints.
        var cdhash: String? = nil
        if let unique = dict[kSecCodeInfoUnique as String] as? Data {
            cdhash = unique.map { String(format: "%02x", $0) }.joined()
        }

        // The entitlements dictionary may be absent (un-signed build) — that's an
        // honest empty, not an error, so we return an empty dict rather than nil.
        let ents = (dict["entitlements-dict"] as? [String: Any]) ?? [:]
        return (ents, cdhash)
    }

    /// The capabilities this binary claims, in the fixed probe order. Empty on an
    /// un-signed build (no readable entitlements) — the caller shows the honest
    /// "typical of an un-signed debug build" note in that case.
    static func capabilities() -> [Capability] {
        guard let (ents, _) = readSigningInfo() else { return [] }
        var found: [Capability] = []
        for entry in known where (ents[entry.key] as? Bool) == true {
            found.append(Capability(label: entry.label, key: entry.key,
                                    isNetwork: entry.key.contains("network")))
        }
        return found
    }

    /// True iff the signature carries any network entitlement. Should always be
    /// `false` for the shipped, default-flavor build; a `true` here is the loud
    /// "that's a bug" signal in both the pane and the doctor report.
    static var hasNetworkEntitlement: Bool {
        capabilities().contains { $0.isNetwork }
    }

    /// The running build's code-signature hash (cdhash) as lowercase hex, or `nil`
    /// on an ad-hoc / un-signed build where no stable signature exists to read.
    static var cdhashHex: String? {
        readSigningInfo()?.cdhash
    }
}
