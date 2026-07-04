import Foundation

// =============================================================================
// BrandMirror — the DISPLAY brand name, mirrored into the MCP binary.
// =============================================================================
//
// MIRROR: Sources/Talkie/DesignSystem.swift (enum Brand.displayName)
//
// The app resolves its display name from `Bundle.main`'s CFBundleDisplayName.
// `talkie-mcp` is a SEPARATE, bare executable target that must NOT import the app
// target (the mirror-don't-import convention documented in `TalkieStore.swift` and
// `SemanticCore.swift`) and — critically — carries no app Info.plist of its own,
// so `Bundle.main` here is the CLI bundle and cannot read the app's display name.
// The name is therefore hard-coded as a faithful copy of the app's `"Talkie"`
// fallback.
//
// Because it's a copy, it can drift. The guard against that is this header naming
// the source plus the grep-able `MIRROR:` marker below. If the display brand ever
// changes, a real rename updates BOTH this literal and the app's Info.plist in the
// same commit — grep `MIRROR:` to find the twin. See `docs/REBRAND.md`.
//
// FROZEN — do NOT derive from this value: the MCP protocol id stays the literal
// `"talkie"` (MCPServer.swift serverInfo), the on-disk store paths stay
// `Application Support/Talkie` and `~/Talkie Meetings` (TalkieStore.swift), and the
// binary stays `talkie-mcp`. This constant is user-visible COPY only — tool
// descriptions and queue-confirmation text.
enum BrandMirror {
    /// MIRROR: Brand.displayName fallback ("Talkie") in the app target.
    static let displayName = "Talkie"
}
