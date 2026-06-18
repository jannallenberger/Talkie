import Foundation

// MARK: - Public model

/// A published dev build available to install.
public struct UpdateRelease: Sendable, Equatable {
    public let build: Int          // parsed from the `dev-<build>` tag
    public let tag: String
    public let title: String
    public let notes: String
    public let assetName: String   // e.g. "Talkie-dev-123.zip"
    public let assetAPIURL: String // GitHub asset API URL (authed download)
    public let assetSize: Int
    /// The publisher-supplied SHA-256 of the zip, hex-encoded, or nil for older
    /// releases that predate digest publishing. GitHub's API exposes no per-asset
    /// SHA-256, so `release_dev.sh` writes it as a `sha256:<hex>` line in the
    /// release body; the installer enforces it fail-closed when present (see
    /// `UpdateInstaller.verifyArtifact`).
    public let assetSHA256: String?
}

/// How the updater is authenticated against the private repo.
public enum UpdaterAuth: Sendable, Equatable {
    case githubCLI   // `gh` is installed and logged in
    case token       // a token is stored in the Keychain
    case none        // neither — the user must set one up
}

public enum UpdaterError: Error, LocalizedError {
    case notAuthenticated
    case ghMissing
    case gh(String)
    case http(Int)
    case badArtifact(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not connected to GitHub. Add an access token or run `gh auth login`."
        case .ghMissing:
            return "The GitHub CLI (gh) wasn't found."
        case .gh(let msg):
            return "GitHub CLI error: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .http(let code):
            return code == 401 || code == 403
                ? "GitHub denied the request (\(code)). The token may be missing repo read access."
                : "GitHub request failed (HTTP \(code))."
        case .badArtifact(let why):
            return "The downloaded update looked wrong: \(why)."
        case .installFailed(let why):
            return "Couldn't install the update: \(why)."
        }
    }
}

// MARK: - GitHub JSON (decoded subset)

private struct GHRelease: Decodable {
    let tag_name: String
    let name: String?
    let body: String?
    let draft: Bool
    let assets: [GHAsset]
}

private struct GHAsset: Decodable {
    let name: String
    let url: String              // API URL (honors auth + redirects to the blob)
    let browser_download_url: String
    let size: Int
}

// MARK: - Fetcher

/// Lists releases and downloads an asset, via the `gh` CLI or a token + URLSession.
/// All `https://` and `URLSession` use is confined to this networked module.
struct ReleaseFetcher: Sendable {
    let auth: UpdaterAuth
    let token: String?

    /// The highest-build `dev-*` prerelease, or nil if the channel is empty.
    func latest() async throws -> UpdateRelease? {
        let data: Data
        switch auth {
        case .githubCLI: data = try await ghListReleases()
        case .token:     data = try await apiListReleases(token: token ?? "")
        case .none:      throw UpdaterError.notAuthenticated
        }
        let releases = try JSONDecoder().decode([GHRelease].self, from: data)
        return Self.pickLatestDev(releases)
    }

    /// Downloads the release's zip into `dir`, returning the local file URL.
    /// `progress` reports 0…1, or nil for indeterminate.
    func download(
        _ release: UpdateRelease,
        to dir: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        switch auth {
        case .githubCLI: return try await ghDownload(release, to: dir, progress: progress)
        case .token:     return try await apiDownload(release, to: dir, token: token ?? "", progress: progress)
        case .none:      throw UpdaterError.notAuthenticated
        }
    }

    // MARK: gh CLI path

    private func ghListReleases() async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let gh = GH.path() else { throw UpdaterError.ghMissing }
            let r = Shell.run(gh, [
                "api",
                "-H", "Accept: application/vnd.github+json",
                "repos/\(UpdaterRepo.slug)/releases?per_page=30",
            ])
            guard r.ok else { throw UpdaterError.gh(r.err.isEmpty ? r.out : r.err) }
            return Data(r.out.utf8)
        }.value
    }

    private func ghDownload(
        _ release: UpdateRelease,
        to dir: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        progress(nil)  // gh gives no byte progress — show an indeterminate spinner
        let assetName = release.assetName
        let tag = release.tag
        let dirPath = dir.path
        return try await Task.detached(priority: .userInitiated) {
            guard let gh = GH.path() else { throw UpdaterError.ghMissing }
            let dest = URL(fileURLWithPath: dirPath).appendingPathComponent(assetName)
            let r = Shell.run(gh, [
                "release", "download", tag,
                "--repo", UpdaterRepo.slug,
                "--pattern", assetName,
                "--dir", dirPath,
                "--clobber",
            ])
            guard r.ok else { throw UpdaterError.gh(r.err.isEmpty ? r.out : r.err) }
            guard FileManager.default.fileExists(atPath: dest.path) else {
                throw UpdaterError.gh("downloaded asset not found at \(dest.path)")
            }
            return dest
        }.value
    }

    // MARK: token + URLSession path

    private func apiListReleases(token: String) async throws -> Data {
        let url = URL(string: "https://api.github.com/repos/\(UpdaterRepo.slug)/releases?per_page=30")!
        var req = URLRequest(url: url)
        applyAPIHeaders(&req, token: token, accept: "application/vnd.github+json")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.assert2xx(resp)
        return data
    }

    private func apiDownload(
        _ release: UpdateRelease,
        to dir: URL,
        token: String,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        progress(nil)
        var req = URLRequest(url: URL(string: release.assetAPIURL)!)
        applyAPIHeaders(&req, token: token, accept: "application/octet-stream")
        // The asset API 302-redirects to a signed blob URL that rejects the
        // GitHub Authorization header — strip it on the cross-host hop.
        let (tempURL, resp) = try await URLSession.shared.download(
            for: req, delegate: RedirectAuthStripper()
        )
        try Self.assert2xx(resp)
        let dest = dir.appendingPathComponent(release.assetName)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        progress(1.0)
        return dest
    }

    private func applyAPIHeaders(_ req: inout URLRequest, token: String, accept: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Talkie-Updater", forHTTPHeaderField: "User-Agent")
    }

    // MARK: helpers

    private static func assert2xx(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw UpdaterError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw UpdaterError.http(http.statusCode) }
    }

    private static func pickLatestDev(_ releases: [GHRelease]) -> UpdateRelease? {
        var best: UpdateRelease?
        for r in releases where !r.draft {
            guard let build = devBuild(from: r.tag_name) else { continue }
            guard let asset = r.assets.first(where: { $0.name.hasSuffix(".zip") }) else { continue }
            if best == nil || build > best!.build {
                let body = (r.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                best = UpdateRelease(
                    build: build,
                    tag: r.tag_name,
                    title: r.name ?? r.tag_name,
                    notes: body,
                    assetName: asset.name,
                    assetAPIURL: asset.url,
                    assetSize: asset.size,
                    assetSHA256: sha256(fromBody: body)
                )
            }
        }
        return best
    }

    /// Parses the publisher-supplied zip digest out of the release body. GitHub's
    /// API exposes no per-asset SHA-256, so `release_dev.sh` writes a line like
    /// `sha256:0a1b2c…` (64 lowercase hex chars) into the notes. Returns the
    /// normalized hex digest, or nil if the body carries no valid digest line
    /// (older releases predating digest publishing).
    static func sha256(fromBody body: String) -> String? {
        for rawLine in body.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: "sha256:", options: .caseInsensitive),
                  range.lowerBound == line.startIndex else { continue }
            let hex = line[range.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if isHex64(hex) { return hex }
        }
        return nil
    }

    /// True for exactly 64 lowercase hex characters (a SHA-256 digest).
    private static func isHex64(_ s: String) -> Bool {
        guard s.count == 64 else { return false }
        return s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// `dev-123` → 123. Returns nil for any other tag (e.g. public `v1.2.0`),
    /// so the dev channel never collides with real releases.
    private static func devBuild(from tag: String) -> Int? {
        guard tag.hasPrefix("dev-") else { return nil }
        return Int(tag.dropFirst(4))
    }
}

/// Drops the `Authorization` header when GitHub redirects an asset download to
/// its signed storage URL (which 400s if a second auth mechanism is present).
private final class RedirectAuthStripper: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        var req = request
        req.setValue(nil, forHTTPHeaderField: "Authorization")
        return req
    }
}
