/// The runtime half of the privacy wall (feature 15). The SwiftPM target graph
/// already keeps the default build offline structurally (the bridge/updater
/// modules are never linked — `scripts/check-no-network.sh`). This enum closes
/// the second half of the contract the protocols promise: the composition root
/// must REFUSE any backend whose `requiresNetwork` is `true` in a local build,
/// so a swapped-in conformer can't quietly defeat the wall at runtime.
///
/// Defense in depth: even if a networked conformer (`requiresNetwork == true`)
/// were ever wired into the default flavor by mistake — a programmer error or a
/// supply-chain swap — `assertLocal` trips a `precondition` at the instantiation
/// site instead of silently routing data off-device. For the current hard-coded
/// `false` conformers (`TranscriptionEngine`, `OnDeviceLLM`) this is a pure
/// pass-through with zero behavior change.
///
/// Actor-agnostic: `requiresNetwork` is `nonisolated` on every conformer, so the
/// read here is a plain synchronous property access — no `await`, no isolation
/// hop — safe to call from the @MainActor composition root under
/// `-disable-dynamic-actor-isolation`.
enum PrivacyWall {
    /// Pure, testable policy: a backend is allowed only when it does not reach
    /// off-device in a local build. In the default (and dev-tools) flavor —
    /// where `TALKIE_CONNECTED` is not defined — a backend that reaches off-device
    /// is forbidden. In a connected build flavor the gate is lifted (consent
    /// lives upstream).
    static func isAllowed(requiresNetwork: Bool) -> Bool {
        #if TALKIE_CONNECTED
        return true
        #else
        return !requiresNetwork
        #endif
    }

    /// Pass-through guard for a transcription backend at the composition root.
    /// Returns the SAME instance, preserving the concrete type `B`, so it drops
    /// in transparently at instantiation sites. Trips a `precondition` if an
    /// off-device backend is wired into a local build (programmer / supply-chain
    /// error, not a recoverable user state).
    @discardableResult
    static func assertLocal<B: TranscriptionBackend>(_ b: B) -> B {
        #if !TALKIE_CONNECTED
        precondition(
            isAllowed(requiresNetwork: b.requiresNetwork),
            "Privacy wall: networked backend in a local build"
        )
        #endif
        return b
    }

    /// Pass-through guard for a summarizer at the composition root. Returns the
    /// SAME instance, preserving the concrete type `S`. Trips a `precondition`
    /// if an off-device summarizer is wired into a local build.
    @discardableResult
    static func assertLocal<S: Summarizer>(_ s: S) -> S {
        #if !TALKIE_CONNECTED
        precondition(
            isAllowed(requiresNetwork: s.requiresNetwork),
            "Privacy wall: networked backend in a local build"
        )
        #endif
        return s
    }
}
