import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// FIX #1383: Checks GitHub releases API on startup to detect newer app versions.
/// Reports failures to the user so they know version check couldn't complete.
class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()

    /// Set on MainActor when a newer version is found
    @Published var updateAvailable: UpdateInfo? = nil

    /// Set on MainActor when version check fails (network, GitHub unreachable, etc.)
    @Published var checkFailed: String? = nil

    /// Whether the check completed successfully (up-to-date or update found)
    @Published var checkCompleted: Bool = false

    struct UpdateInfo {
        let current: String
        let latest: String
        let url: String
    }

    private let releasesURL = "https://api.github.com/repos/VictorLux/ZipherX/releases/latest"

    private init() {}

    /// Dismiss the failure warning
    func dismissFailure() {
        checkFailed = nil
    }

    /// Check GitHub for a newer release. Call once after startup + auth.
    func checkForUpdate() {
        Task.detached(priority: .background) {
            // Small delay to avoid contention with other startup network calls
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s

            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

            print("🔄 FIX #1383: Checking for app updates... Current=\(currentVersion) (build \(currentBuild))")

            do {
                guard let url = URL(string: self.releasesURL) else {
                    await MainActor.run {
                        self.checkFailed = "Invalid update check URL"
                    }
                    return
                }

                var request = URLRequest(url: url)
                request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 15

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    await MainActor.run {
                        self.checkFailed = "Version check failed: invalid response from GitHub"
                    }
                    return
                }

                guard httpResponse.statusCode == 200 else {
                    print("⏭️ FIX #1383: GitHub API returned HTTP \(httpResponse.statusCode)")
                    await MainActor.run {
                        self.checkFailed = "Version check failed: GitHub returned HTTP \(httpResponse.statusCode)"
                    }
                    return
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String,
                      let htmlURL = json["html_url"] as? String else {
                    print("⏭️ FIX #1383: Could not parse GitHub release JSON")
                    await MainActor.run {
                        self.checkFailed = "Version check failed: could not parse release info"
                    }
                    return
                }

                // Strip leading "v" from tag (e.g. "v2.3.0" → "2.3.0")
                let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

                print("🔄 FIX #1383: Current=\(currentVersion), Latest=\(remoteVersion)")

                if Self.isNewer(remote: remoteVersion, current: currentVersion) {
                    print("📦 FIX #1383: Update available! \(currentVersion) → \(remoteVersion)")
                    await MainActor.run {
                        self.checkCompleted = true
                        self.updateAvailable = UpdateInfo(
                            current: currentVersion,
                            latest: remoteVersion,
                            url: htmlURL
                        )
                    }
                } else {
                    print("✅ FIX #1383: App is up-to-date (\(currentVersion))")
                    await MainActor.run {
                        self.checkCompleted = true
                    }
                }
            } catch let error as URLError {
                let reason: String
                switch error.code {
                case .notConnectedToInternet:
                    reason = "No internet connection"
                case .timedOut:
                    reason = "Connection timed out"
                case .cannotFindHost, .cannotConnectToHost:
                    reason = "Cannot reach GitHub (blocked or offline)"
                case .networkConnectionLost:
                    reason = "Network connection lost"
                default:
                    reason = error.localizedDescription
                }
                print("⚠️ FIX #1383: Version check failed: \(reason)")
                await MainActor.run {
                    self.checkFailed = "Version check unavailable: \(reason)"
                }
            } catch {
                print("⚠️ FIX #1383: Version check failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.checkFailed = "Version check failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Semantic version comparison: returns true if remote > current
    static func isNewer(remote: String, current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        // Pad to 3 components (major.minor.patch)
        let r = remoteParts + Array(repeating: 0, count: max(0, 3 - remoteParts.count))
        let c = currentParts + Array(repeating: 0, count: max(0, 3 - currentParts.count))

        for i in 0..<3 {
            if r[i] > c[i] { return true }
            if r[i] < c[i] { return false }
        }
        return false // Equal
    }

    /// Open the release URL in the default browser
    func openReleaseURL() {
        guard let info = updateAvailable, let url = URL(string: info.url) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
