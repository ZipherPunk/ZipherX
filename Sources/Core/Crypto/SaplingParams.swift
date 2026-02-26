import Foundation
import CryptoKit

/// Actor for thread-safe ensuring state (eliminates priority inversion)
private actor EnsureState {
    private var isEnsuring = false

    func startEnsuring() -> Bool {
        if isEnsuring {
            return false // Already in progress
        }
        isEnsuring = true
        return true
    }

    func finishEnsuring() {
        isEnsuring = false
    }
}

/// Sapling parameter file manager
/// Uses BUNDLED params (uncompressed in app bundle) - no download needed!
/// Falls back to download only if bundle copy fails
final class SaplingParams {
    static let shared = SaplingParams()

    // MARK: - Constants

    private let baseURL = "https://z.cash/downloads/"

    // Actor-based state to prevent concurrent ensureParams calls (no priority inversion)
    private let ensureState = EnsureState()

    private let spendParams = (
        name: "sapling-spend.params",
        bundleName: "sapling-spend",  // Uncompressed in bundle (46MB)
        bundleExt: "params",
        size: 47_958_396,
        hash: "320fbb5754c8b3f4ecb3dd4c2e3dbe1d138c4b343f073c7e31612d26fe769cdba8edab426a7f2c42e317bebdb2ca6f73af1312affa1fcf599a31d499ad4cb4e5"
    )

    private let outputParams = (
        name: "sapling-output.params",
        bundleName: "sapling-output",  // Uncompressed in bundle (3.4MB)
        bundleExt: "params",
        size: 3_592_860,
        hash: "a7c87f52c0c1eb05b4da1e1e70d986bde95a2a74047b0679d0163ade7ced3cbf93c1c7e3954416e5baacff614e1d0d5dfaed7b9b7d3141fa595259b23c32f152"
    )

    // MARK: - Properties

    private let paramsDirectory: URL

    var onProgress: ((String, Double) -> Void)?

    private init() {
        // Use AppDirectories for platform-appropriate path (Application Support on macOS, Documents on iOS)
        paramsDirectory = AppDirectories.saplingParams
    }

    // MARK: - Public Methods

    /// Check if all required parameters are ready
    var areParamsReady: Bool {
        let spendReady = FileManager.default.fileExists(atPath: spendParamsPath.path) &&
                         verifyFileSize(spendParamsPath.path, expectedSize: spendParams.size)
        let outputReady = FileManager.default.fileExists(atPath: outputParamsPath.path) &&
                          verifyFileSize(outputParamsPath.path, expectedSize: outputParams.size)
        return spendReady && outputReady
    }

    /// Get paths to parameter files
    var spendParamsPath: URL {
        paramsDirectory.appendingPathComponent(spendParams.name)
    }

    var outputParamsPath: URL {
        paramsDirectory.appendingPathComponent(outputParams.name)
    }

    /// Ensure Sapling parameters are available
    /// Priority: 1. Already copied  2. Copy from bundle  3. Download
    func ensureParams() async throws {
        // Prevent concurrent calls - first one wins, others wait (actor-based, no priority inversion)
        let didStart = await ensureState.startEnsuring()
        if !didStart {
            debugLog(.params, "⏳ Params already being ensured by another call, waiting...")
            // Wait for the other call to complete
            while !areParamsReady {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            debugLog(.params, "✅ Params ready (waited for other call)")
            return
        }

        defer {
            Task { await ensureState.finishEnsuring() }
        }

        debugLog(.params, "📋 Ensuring Sapling params are ready...")

        // Check spend params
        if !FileManager.default.fileExists(atPath: spendParamsPath.path) ||
           !verifyFileSize(spendParamsPath.path, expectedSize: spendParams.size) {
            debugLog(.params, "📦 Spend params not ready, copying from bundle...")
            if !copyFromBundle(name: spendParams.bundleName, ext: spendParams.bundleExt, to: spendParamsPath, expectedSize: spendParams.size, expectedHash: spendParams.hash) {
                debugLog(.params, "⬇️ Bundle copy failed, downloading spend params...")
                try await downloadParam(
                    name: spendParams.name,
                    expectedSize: spendParams.size,
                    expectedHash: spendParams.hash
                )
            }
        } else {
            debugLog(.params, "✅ Spend params already ready")
        }

        // Check output params
        if !FileManager.default.fileExists(atPath: outputParamsPath.path) ||
           !verifyFileSize(outputParamsPath.path, expectedSize: outputParams.size) {
            debugLog(.params, "📦 Output params not ready, copying from bundle...")
            if !copyFromBundle(name: outputParams.bundleName, ext: outputParams.bundleExt, to: outputParamsPath, expectedSize: outputParams.size, expectedHash: outputParams.hash) {
                debugLog(.params, "⬇️ Bundle copy failed, downloading output params...")
                try await downloadParam(
                    name: outputParams.name,
                    expectedSize: outputParams.size,
                    expectedHash: outputParams.hash
                )
            }
        } else {
            debugLog(.params, "✅ Output params already ready")
        }

        debugLog(.params, "✅ All Sapling params ready!")
    }

    // MARK: - Bundle Copy

    /// Copy uncompressed params from app bundle to Documents directory
    /// Returns true if successful
    private func copyFromBundle(name: String, ext: String, to destination: URL, expectedSize: Int, expectedHash: String) -> Bool {
        debugLog(.params, "🔍 Looking for bundled \(name).\(ext)...")

        // Try to find in main bundle
        guard let bundleURL = Bundle.main.url(forResource: name, withExtension: ext) else {
            debugLog(.params, "⚠️ \(name).\(ext) not found in bundle")
            return false
        }

        debugLog(.params, "📂 Found bundled file at: \(bundleURL.path)")

        do {
            // Remove existing file if any
            try? FileManager.default.removeItem(at: destination)

            // Copy from bundle to Documents
            try FileManager.default.copyItem(at: bundleURL, to: destination)

            // Verify size
            let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
            let fileSize = attrs[.size] as? Int ?? 0

            guard fileSize == expectedSize else {
                debugLog(.error, "❌ Size mismatch: got \(fileSize), expected \(expectedSize)")
                try? FileManager.default.removeItem(at: destination)
                return false
            }

            // VUL-CRYPTO-004: Verify SHA-512 hash integrity
            guard verifySHA512(destination, expectedHash: expectedHash) else {
                debugLog(.error, "🚨 VUL-CRYPTO-004: Hash verification failed for bundled \(name).\(ext) — removing")
                try? FileManager.default.removeItem(at: destination)
                return false
            }

            debugLog(.params, "✅ Copied \(name).\(ext) with verified SHA-512 hash")
            return true

        } catch {
            debugLog(.error, "❌ Failed to copy \(name).\(ext): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Download Fallback

    private func downloadParam(name: String, expectedSize: Int, expectedHash: String) async throws {
        let url = URL(string: baseURL + name)!
        let destination = paramsDirectory.appendingPathComponent(name)

        debugLog(.params, "📥 Downloading \(name) (\(expectedSize / 1_000_000)MB) from \(url)...")
        onProgress?(name, 0.0)

        // Use a configuration that allows cellular and doesn't timeout quickly
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 300 // 5 minutes
        config.timeoutIntervalForResource = 600 // 10 minutes
        let session = URLSession(configuration: config)

        // Create download task with progress
        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await session.download(from: url)
        } catch {
            debugLog(.error, "❌ Download failed for \(name): \(error.localizedDescription)")
            throw ParamsError.downloadFailed
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            debugLog(.error, "❌ Invalid response type for \(name)")
            throw ParamsError.downloadFailed
        }

        debugLog(.params, "📡 HTTP Status: \(httpResponse.statusCode) for \(name)")

        guard httpResponse.statusCode == 200 else {
            debugLog(.error, "❌ HTTP error \(httpResponse.statusCode) for \(name)")
            throw ParamsError.downloadFailed
        }

        // Move to final location
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            debugLog(.params, "📂 Moved \(name) to \(destination.path)")
        } catch {
            debugLog(.error, "❌ Failed to move file: \(error.localizedDescription)")
            throw ParamsError.downloadFailed
        }

        // Verify file size
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let fileSize = attributes[.size] as? Int ?? 0

        debugLog(.params, "📏 File size: \(fileSize) bytes (expected: \(expectedSize))")

        guard fileSize == expectedSize else {
            debugLog(.error, "❌ Size mismatch! Got \(fileSize), expected \(expectedSize)")
            try? FileManager.default.removeItem(at: destination)
            throw ParamsError.invalidSize
        }

        // VUL-CRYPTO-004: Verify SHA-512 hash after download
        guard verifySHA512(destination, expectedHash: expectedHash) else {
            debugLog(.error, "🚨 VUL-CRYPTO-004: Hash verification failed for downloaded \(name) — removing")
            try? FileManager.default.removeItem(at: destination)
            throw ParamsError.invalidHash
        }

        debugLog(.params, "✅ Downloaded \(name) with verified SHA-512 hash")
        onProgress?(name, 1.0)
    }

    // MARK: - Helpers

    private func verifyFileSize(_ path: String, expectedSize: Int) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else {
            return false
        }
        return size == expectedSize
    }

    /// VUL-CRYPTO-004: Verify file integrity via SHA-512 hash
    /// One-time check after copy/download — prevents tampered param files
    private func verifySHA512(_ fileURL: URL, expectedHash: String) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else {
            debugLog(.error, "❌ VUL-CRYPTO-004: Cannot read file for hash verification: \(fileURL.lastPathComponent)")
            return false
        }
        let digest = SHA512.hash(data: data)
        let computedHash = digest.map { String(format: "%02x", $0) }.joined()
        let matches = computedHash == expectedHash
        if !matches {
            debugLog(.error, "🚨 VUL-CRYPTO-004: SHA-512 MISMATCH for \(fileURL.lastPathComponent)!")
            debugLog(.error, "   Expected: \(expectedHash.prefix(32))...")
            debugLog(.error, "   Got:      \(computedHash.prefix(32))...")
        }
        return matches
    }

    /// Delete downloaded parameters
    func deleteParams() throws {
        try? FileManager.default.removeItem(at: spendParamsPath)
        try? FileManager.default.removeItem(at: outputParamsPath)
    }

    /// Get total size of parameters to download (0 if bundled)
    var totalDownloadSize: Int {
        // If we have bundled params, no download needed
        if Bundle.main.url(forResource: spendParams.bundleName, withExtension: spendParams.bundleExt) != nil &&
           Bundle.main.url(forResource: outputParams.bundleName, withExtension: outputParams.bundleExt) != nil {
            return 0
        }

        var size = 0
        if !FileManager.default.fileExists(atPath: spendParamsPath.path) {
            size += spendParams.size
        }
        if !FileManager.default.fileExists(atPath: outputParamsPath.path) {
            size += outputParams.size
        }
        return size
    }
}

// MARK: - Errors

enum ParamsError: LocalizedError {
    case downloadFailed
    case invalidSize
    case invalidHash
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Failed to download Sapling parameters"
        case .invalidSize:
            return "Downloaded file has invalid size"
        case .invalidHash:
            return "Downloaded file hash mismatch"
        case .extractionFailed:
            return "Failed to extract bundled parameters"
        }
    }
}
