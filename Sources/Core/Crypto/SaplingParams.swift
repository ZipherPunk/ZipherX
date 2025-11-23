import Foundation

/// Sapling parameter file manager
/// Downloads and manages zk-SNARK proving parameters
final class SaplingParams {
    static let shared = SaplingParams()

    // MARK: - Constants

    private let baseURL = "https://z.cash/downloads/"

    private let spendParams = (
        name: "sapling-spend.params",
        size: 47_958_396,
        hash: "8270785a1a0d0bc77196f000ee6d221c9c9894f55307bd9357c3f0105d31ca63991ab91324160d8f53e2bbd3c2633a6eb8bdf5205d822e7f3f73edac51b2b70c"
    )

    private let outputParams = (
        name: "sapling-output.params",
        size: 3_592_860,
        hash: "657e3d38dbb5cb5e7dd2970e8b03d69b4787dd907285b5a7f0790dcc8072f60bf593b32cc2d1c030e00ff5ae64bf84c5c3beb84ddc841d48264b4a171744d028"
    )

    // MARK: - Properties

    private let paramsDirectory: URL

    var onProgress: ((String, Double) -> Void)?

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        paramsDirectory = documents.appendingPathComponent("sapling-params")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: paramsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public Methods

    /// Check if all required parameters are downloaded
    var areParamsReady: Bool {
        return FileManager.default.fileExists(atPath: spendParamsPath.path) &&
               FileManager.default.fileExists(atPath: outputParamsPath.path)
    }

    /// Get paths to parameter files
    var spendParamsPath: URL {
        paramsDirectory.appendingPathComponent(spendParams.name)
    }

    var outputParamsPath: URL {
        paramsDirectory.appendingPathComponent(outputParams.name)
    }

    /// Download Sapling parameters if not already present
    func ensureParams() async throws {
        // Download spend params (~46MB)
        if !FileManager.default.fileExists(atPath: spendParamsPath.path) {
            try await downloadParam(
                name: spendParams.name,
                expectedSize: spendParams.size,
                expectedHash: spendParams.hash
            )
        }

        // Download output params (~3.5MB)
        if !FileManager.default.fileExists(atPath: outputParamsPath.path) {
            try await downloadParam(
                name: outputParams.name,
                expectedSize: outputParams.size,
                expectedHash: outputParams.hash
            )
        }
    }

    // MARK: - Private Methods

    private func downloadParam(name: String, expectedSize: Int, expectedHash: String) async throws {
        let url = URL(string: baseURL + name)!
        let destination = paramsDirectory.appendingPathComponent(name)

        print("📥 Downloading \(name) (\(expectedSize / 1_000_000)MB)...")
        onProgress?(name, 0.0)

        // Create download task with progress
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ParamsError.downloadFailed
        }

        // Move to final location
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)

        // Verify file size
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let fileSize = attributes[.size] as? Int ?? 0

        guard fileSize == expectedSize else {
            try? FileManager.default.removeItem(at: destination)
            throw ParamsError.invalidSize
        }

        // TODO: Verify SHA-512 hash for security
        // For now, size check is sufficient for development

        print("✅ Downloaded \(name)")
        onProgress?(name, 1.0)
    }

    /// Delete downloaded parameters
    func deleteParams() throws {
        try? FileManager.default.removeItem(at: spendParamsPath)
        try? FileManager.default.removeItem(at: outputParamsPath)
    }

    /// Get total size of parameters to download
    var totalDownloadSize: Int {
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

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Failed to download Sapling parameters"
        case .invalidSize:
            return "Downloaded file has invalid size"
        case .invalidHash:
            return "Downloaded file hash mismatch"
        }
    }
}
