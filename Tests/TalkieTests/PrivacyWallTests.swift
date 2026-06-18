import AVFoundation
import Speech
import XCTest
@testable import Talkie

/// Tests the runtime half of the privacy wall (feature 15). The point is the
/// PURE `isAllowed` policy plus the `assertLocal` pass-through contract for the
/// current local conformers. We deliberately avoid a death-test for the
/// `precondition` (which fires for a networked conformer in a local build).
final class PrivacyWallTests: XCTestCase {

    // MARK: policy

    func testLocalBackendIsAllowed() {
        XCTAssertTrue(PrivacyWall.isAllowed(requiresNetwork: false))
    }

    func testNetworkedBackendIsForbiddenInLocalBuild() {
        // In the default (non-TALKIE_CONNECTED) build the policy forbids any
        // backend that reaches off-device.
        XCTAssertFalse(PrivacyWall.isAllowed(requiresNetwork: true))
    }

    // MARK: pass-through (no behavior change for local conformers)

    func testAssertLocalSummarizerPassesThroughUnchanged() {
        let stub = LocalSummarizerStub()
        let returned = PrivacyWall.assertLocal(stub)
        // Same flag survives the guard, and it is still local.
        XCTAssertFalse(returned.requiresNetwork)
    }

    func testAssertLocalTranscriptionBackendPassesThroughUnchanged() {
        let stub = LocalBackendStub()
        let returned = PrivacyWall.assertLocal(stub)
        XCTAssertFalse(returned.requiresNetwork)
    }
}

// MARK: - Local stubs (requiresNetwork == false)

/// A minimal local `Summarizer` used to prove `assertLocal` is a pure
/// pass-through for an on-device conformer.
private struct LocalSummarizerStub: Summarizer {
    static var isAvailable: Bool { true }
    let requiresNetwork = false
    func generate(instructions: String, input: String) async -> String? { nil }
}

/// A minimal local `TranscriptionBackend` used to prove `assertLocal` is a pure
/// pass-through for an on-device conformer.
private struct LocalBackendStub: TranscriptionBackend {
    static var isAvailable: Bool { true }
    let requiresNetwork = false
    let supportsContextualStrings = false

    func setLocaleIdentifier(_ id: String) async {}
    func setContextualStrings(_ phrases: [String]) async {}

    func beginSession(
        onUpdate: (@Sendable (TranscriptUpdate) -> Void)?,
        onSegment: (@Sendable (String) -> Void)?
    ) async throws -> (format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let (_, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        return (format, continuation)
    }

    func finishSession() async -> String { "" }
    func cancelSession() async {}
}
