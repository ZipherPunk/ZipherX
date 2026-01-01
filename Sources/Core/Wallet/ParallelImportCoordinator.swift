//
//  ParallelImportCoordinator.swift
//  ZipherX
//
//  FIX #506: Parallel Import Architecture
//  Orchestrates parallel extraction tasks for faster import PK
//

import Foundation
import CryptoKit

/// Coordinates parallel import tasks for maximum speed
/// Runs header extraction, CMU extraction, network connection, and hash loading simultaneously
actor ParallelImportCoordinator {
    static let shared = ParallelImportCoordinator()

    private var activeJobs: [String: ImportJob] = [:]
    private let tempDB = TempImportDatabase.shared
    private var isRunning = false

    private init() {}

    // MARK: - Main Orchestration

    /// Run all extraction tasks in parallel after boost file is downloaded
    /// - Parameter boostFile: URL to the downloaded boost file
    /// - Returns: ParallelExtractionResult containing all extracted data
    func runParallelExtraction(boostFile: URL) async throws -> ParallelExtractionResult {
        guard !isRunning else {
            throw ImportError.alreadyRunning("Parallel extraction already in progress")
        }

        isRunning = true
        defer { isRunning = false }

        let startTime = Date()
        print("🚀 FIX #506: Starting PARALLEL extraction...")

        // Create temp tables first
        try await tempDB.createTempTables()
        await postProgress(type: .headers, progress: 0, status: "Initializing...")

        // PHASE 1: Run all extraction tasks IN PARALLEL using async let
        // This is the key to speedup - all 4 tasks run simultaneously
        async let headersExtraction = extractHeadersJob(boostFile: boostFile)
        async let cmusExtraction = extractCMUsJob(boostFile: boostFile)
        async let networkConnection = connectNetworkJob()
        async let hashesLoading = loadHashesJob()

        // Wait for ALL tasks to complete (or throw on first error)
        // The slowest task determines the total time
        let (headers, cmus, _, _) = try await (headersExtraction, cmusExtraction, networkConnection, hashesLoading)

        let duration = Date().timeIntervalSince(startTime)
        print("✅ FIX #506: All parallel jobs completed in \(String(format: "%.1f", duration))s")

        // Build result
        let result = ParallelExtractionResult(
            tempHeaders: headers,
            tempCMUs: cmus,
            duration: duration
        )

        // Post completion notification
        await postProgress(type: .headers, progress: 1.0, status: "Completed")

        return result
    }

    /// Build tree from temp CMUs and commit to production
    /// - Parameter tempData: Result from parallel extraction
    /// - Parameter onProgress: Progress callback for tree build
    func commitToProduction(tempData: ParallelExtractionResult, onProgress: @escaping (Double) -> Void) async throws {
        print("💾 FIX #506: Starting atomic commit to production...")

        // Step 1: Verify temp data integrity
        try await verifyTempData(tempData)

        // Step 2: Build tree from temp CMUs (only remaining sequential task)
        onProgress(0.3)
        let treeData = try await buildTreeFromTempCMUs(onProgress: onProgress)

        // Step 3: Move temp headers to HeaderStore
        onProgress(0.8)
        try await moveTempHeadersToHeaderStore(tempData: tempData)

        // Step 4: Save tree to database
        onProgress(0.9)
        try await saveTreeToDatabase(treeData)

        // Step 5: Cleanup temp tables
        onProgress(0.95)
        try await tempDB.dropTempTables()

        onProgress(1.0)
        print("✅ FIX #506: Atomic commit complete!")
    }

    // MARK: - Parallel Jobs

    /// Job 1: Extract headers from boost file to temp table
    private func extractHeadersJob(boostFile: URL) async throws -> [TempHeader] {
        let jobId = UUID().uuidString
        let job = ImportJob(id: jobId, type: .headers, status: .running)
        activeJobs[jobId] = job

        await postProgress(type: .headers, progress: 0, status: "Extracting headers from boost file...")

        do {
            let treeUpdater = CommitmentTreeUpdater.shared

            // Check if boost file has headers section
            guard await treeUpdater.hasHeadersSection() else {
                throw ImportError.missingData("Boost file missing headers section")
            }

            // Extract headers
            guard let headerData = try? await treeUpdater.extractHeaders(),
                  let blockHashesData = try? await treeUpdater.extractBlockHashes(),
                  let manifest = await treeUpdater.loadCachedManifest() else {
                throw ImportError.extractionFailed("Failed to extract headers from boost file")
            }

            let sectionInfo = manifest.sections.first { $0.type == 7 }
            guard let section = sectionInfo else {
                throw ImportError.missingData("No headers section in manifest")
            }

            await postProgress(type: .headers, progress: 0.5, status: "Parsing \(section.count) headers...")

            // Parse headers from boost data
            var headers: [TempHeader] = []
            let headerSize = 140  // bytes per header

            var offset = 0
            let startHeight = Int(section.start_height)
            let endHeight = startHeight + Int(section.count)
            for height in startHeight..<endHeight {
                guard offset + headerSize <= headerData.count else {
                    await postProgress(type: .headers, progress: 0, status: "Failed: Invalid header data")
                    throw ImportError.extractionFailed("Header data truncated at height \(height)")
                }

                let headerBytes = headerData.subdata(in: offset..<(offset + headerSize))
                let header = try parseTempHeader(headerBytes, height: height)
                headers.append(header)

                offset += headerSize

                // Report progress every 100k headers
                if headers.count % 100000 == 0 {
                    let progress = Double(headers.count) / Double(section.count)
                    await postProgress(type: .headers, progress: progress, status: "Parsed \(headers.count)/\(section.count) headers...")
                }
            }

            // Insert into temp table
            await postProgress(type: .headers, progress: 0.9, status: "Saving to temp table...")
            try await tempDB.insertTempHeaders(headers)

            // Mark job complete
            activeJobs[jobId]?.status = .completed
            activeJobs[jobId]?.completedAt = Date()
            await postProgress(type: .headers, progress: 1.0, status: "Completed: \(headers.count) headers")

            return headers

        } catch {
            activeJobs[jobId]?.status = .failed
            activeJobs[jobId]?.errorMessage = error.localizedDescription
            await postProgress(type: .headers, progress: 0, status: "Failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Job 2: Extract CMUs from boost file to temp table
    private func extractCMUsJob(boostFile: URL) async throws -> [TempCMU] {
        let jobId = UUID().uuidString
        let job = ImportJob(id: jobId, type: .cmus, status: .running)
        activeJobs[jobId] = job

        await postProgress(type: .cmus, progress: 0, status: "Extracting CMUs from boost file...")

        do {
            let treeUpdater = CommitmentTreeUpdater.shared

            // Extract CMUs in legacy format
            let cmuData = try await treeUpdater.extractCMUsInLegacyFormat { progress in
                Task { @MainActor in
                    await self.postProgress(type: .cmus, progress: progress, status: "Extracting CMUs: \(Int(progress * 100))%")
                }
            }

            await postProgress(type: .cmus, progress: 0.7, status: "Parsing \(cmuData.count) bytes of CMU data...")

            // Parse CMUs from legacy format
            var cmus: [TempCMU] = []
            let cmuSize = 44  // height(4) + output_index(4) + cmu(32) + epoch(4)

            var offset = 0
            var epoch = 0

            while offset + cmuSize <= cmuData.count {
                let heightBytes = cmuData.subdata(in: offset..<(offset + 4))
                let outputIndexBytes = cmuData.subdata(in: (offset + 4)..<(offset + 8))
                let cmu = cmuData.subdata(in: (offset + 8)..<(offset + 40))
                let epochBytes = cmuData.subdata(in: (offset + 40)..<(offset + 44))

                let height = heightBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
                let outputIndex = outputIndexBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
                let epochValue = epochBytes.withUnsafeBytes { $0.load(as: UInt32.self) }

                // Detect epoch changes (every ~500k blocks)
                if Int(epochValue) > epoch {
                    epoch = Int(epochValue)
                }

                cmus.append(TempCMU(
                    height: Int(height),
                    outputIndex: Int(outputIndex),
                    cmu: cmu,
                    epoch: epoch
                ))

                offset += cmuSize

                // Report progress every 100k CMUs
                if cmus.count % 100000 == 0 {
                    let progress = Double(offset) / Double(cmuData.count)
                    await postProgress(type: .cmus, progress: progress, status: "Parsed \(cmus.count) CMUs...")
                }
            }

            // Insert into temp table
            await postProgress(type: .cmus, progress: 0.9, status: "Saving to temp table...")
            try await tempDB.insertTempCMUs(cmus)

            // Mark job complete
            activeJobs[jobId]?.status = .completed
            activeJobs[jobId]?.completedAt = Date()
            await postProgress(type: .cmus, progress: 1.0, status: "Completed: \(cmus.count) CMUs")

            return cmus

        } catch {
            activeJobs[jobId]?.status = .failed
            activeJobs[jobId]?.errorMessage = error.localizedDescription
            await postProgress(type: .cmus, progress: 0, status: "Failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Job 3: Connect to P2P network
    private func connectNetworkJob() async throws -> Int {
        let jobId = UUID().uuidString
        let job = ImportJob(id: jobId, type: .network, status: .running)
        activeJobs[jobId] = job

        await postProgress(type: .network, progress: 0, status: "Connecting to P2P network...")

        do {
            let networkManager = NetworkManager.shared

            // Check if already connected
            let isConnected = await MainActor.run { networkManager.isConnected }
            if isConnected {
                let peerCount = await MainActor.run { networkManager.peers.count }
                activeJobs[jobId]?.status = .completed
                activeJobs[jobId]?.completedAt = Date()
                await postProgress(type: .network, progress: 1.0, status: "Already connected: \(peerCount) peers")
                return peerCount
            }

            // Connect to network
            await postProgress(type: .network, progress: 0.3, status: "Connecting to peers...")
            try await networkManager.connect()

            // Wait for connections
            await postProgress(type: .network, progress: 0.6, status: "Waiting for peer connections...")
            var waited = 0
            var peerCount = 0

            while waited < 10 {
                try await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
                peerCount = await MainActor.run { networkManager.peers.count }
                if peerCount >= 1 { break }
                waited += 1
            }

            // Mark job complete
            activeJobs[jobId]?.status = .completed
            activeJobs[jobId]?.completedAt = Date()
            await postProgress(type: .network, progress: 1.0, status: "Connected: \(peerCount) peers")

            return peerCount

        } catch {
            activeJobs[jobId]?.status = .failed
            activeJobs[jobId]?.errorMessage = error.localizedDescription
            await postProgress(type: .network, progress: 0, status: "Failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Job 4: Load bundled block hashes
    private func loadHashesJob() async throws -> Int {
        let jobId = UUID().uuidString
        let job = ImportJob(id: jobId, type: .hashes, status: .running)
        activeJobs[jobId] = job

        await postProgress(type: .hashes, progress: 0, status: "Loading bundled block hashes...")

        do {
            // Check if already loaded
            if BundledBlockHashes.shared.isLoaded {
                activeJobs[jobId]?.status = .completed
                activeJobs[jobId]?.completedAt = Date()
                let count = Int(BundledBlockHashes.shared.count)
                await postProgress(type: .hashes, progress: 1.0, status: "Already loaded: \(count) hashes")
                return count
            }

            // Load hashes
            var hashCount = 0
            try await BundledBlockHashes.shared.loadBundledHashes { current, total in
                hashCount = Int(total)
                let progress = Double(current) / Double(total)
                Task { @MainActor in
                    await self.postProgress(type: .hashes, progress: progress, status: "Loading hashes: \(current)/\(total)")
                }
            }

            // Mark job complete
            activeJobs[jobId]?.status = .completed
            activeJobs[jobId]?.completedAt = Date()
            await postProgress(type: .hashes, progress: 1.0, status: "Completed: \(hashCount) hashes")

            return hashCount

        } catch {
            activeJobs[jobId]?.status = .failed
            activeJobs[jobId]?.errorMessage = error.localizedDescription
            await postProgress(type: .hashes, progress: 0, status: "Failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Verification and Commit

    private func verifyTempData(_ tempData: ParallelExtractionResult) async throws {
        print("🔍 FIX #506: Verifying temp data...")

        // Verify header count
        let headerCount = try await tempDB.getTempHeaderCount()
        guard headerCount == tempData.headersCount else {
            throw ImportError.verificationFailed("Header count mismatch: temp=\(headerCount), expected=\(tempData.headersCount)")
        }

        // Verify CMU count
        let cmuCount = try await tempDB.getTempCMUCount()
        guard cmuCount == tempData.cmusCount else {
            throw ImportError.verificationFailed("CMU count mismatch: temp=\(cmuCount), expected=\(tempData.cmusCount)")
        }

        // Verify no duplicate heights
        guard try await tempDB.verifyNoDuplicateHeights() else {
            throw ImportError.verificationFailed("Duplicate heights detected in temp_headers")
        }

        // Verify header integrity
        guard try await tempDB.verifyTempHeaderIntegrity() else {
            throw ImportError.verificationFailed("Header integrity check failed")
        }

        print("✅ FIX #506: All temp data verified (\(headerCount) headers, \(cmuCount) CMUs)")
    }

    private func buildTreeFromTempCMUs(onProgress: @escaping (Double) -> Void) async throws -> Data {
        print("🌳 FIX #506: Building tree from temp CMUs...")

        // Build CMU data from temp table
        let cmuData = try await tempDB.buildCMUDataFromTemp()

        // Build tree using FFI
        await postProgress(type: .tree, progress: 0.1, status: "Building commitment tree...")

        // Build tree from CMUs (10-90% of progress)
        let success = ZipherXFFI.treeLoadFromCMUsWithProgress(data: cmuData) { current, total in
            let progress = Double(current) / Double(total)
            onProgress(0.1 + progress * 0.8)  // 10-90% for tree build
            Task { @MainActor in
                await self.postProgress(type: .tree, progress: progress, status: "Building tree: \(current)/\(total) CMUs")
            }
        }

        guard success else {
            throw ImportError.treeBuildFailed("FFI tree build failed")
        }

        // Serialize the tree
        guard let treeData = ZipherXFFI.treeSerialize() else {
            throw ImportError.treeBuildFailed("Failed to serialize tree")
        }
        let treeSize = ZipherXFFI.treeSize()
        print("✅ FIX #506: Tree built: \(treeSize) commitments")

        return treeData
    }

    private func moveTempHeadersToHeaderStore(tempData: ParallelExtractionResult) async throws {
        print("📋 FIX #506: Moving temp headers to HeaderStore...")

        // This is handled by HeaderStore.loadHeadersFromBoostData
        // We just need to verify the temp headers are ready
        try await tempDB.moveTempHeadersToProduction()

        print("✅ FIX #506: Temp headers ready for HeaderStore")
    }

    private func saveTreeToDatabase(_ treeData: Data) async throws {
        print("💾 FIX #506: Saving tree to database...")

        try WalletDatabase.shared.saveTreeState(treeData)
        UserDefaults.standard.set(ZipherXFFI.treeSize(), forKey: "effectiveTreeCMUCount")

        print("✅ FIX #506: Tree saved to database")
    }

    // MARK: - Progress Posting

    private func postProgress(type: ImportJobType, progress: Double, status: String) {
        DispatchQueue.main.async {
            let progressData = ImportProgress(type: type, progress: progress, status: status)
            NotificationCenter.default.post(name: .importJobProgress, object: progressData)
        }
    }

    // MARK: - Public API

    /// Get current active jobs
    func getActiveJobs() -> [ImportJob] {
        return Array(activeJobs.values)
    }

    /// Check if parallel extraction is running
    func isParallelExtractionRunning() -> Bool {
        return isRunning
    }
}

// MARK: - Import Errors

enum ImportError: LocalizedError {
    case alreadyRunning(String)
    case missingData(String)
    case extractionFailed(String)
    case verificationFailed(String)
    case treeBuildFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning(let msg):
            return "Already running: \(msg)"
        case .missingData(let msg):
            return "Missing data: \(msg)"
        case .extractionFailed(let msg):
            return "Extraction failed: \(msg)"
        case .verificationFailed(let msg):
            return "Verification failed: \(msg)"
        case .treeBuildFailed(let msg):
            return "Tree build failed: \(msg)"
        }
    }
}

// MARK: - Helper Extensions

extension ParallelImportCoordinator {
    /// Parse a temp header from raw bytes
    private func parseTempHeader(_ bytes: Data, height: Int) throws -> TempHeader {
        guard bytes.count >= 140 else {
            throw ImportError.extractionFailed("Invalid header size: \(bytes.count)")
        }

        let offset = 0

        // Parse header fields (Zclassic block header format)
        let version = bytes.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }
        let prevHash = Data(bytes.subdata(in: (offset + 4)..<(offset + 36)))
        let merkleRoot = Data(bytes.subdata(in: (offset + 36)..<(offset + 68)))
        let saplingRoot = Data(bytes.subdata(in: (offset + 68)..<(offset + 100)))
        let timestamp = bytes.subdata(in: (offset + 100)..<(offset + 104)).withUnsafeBytes { $0.load(as: UInt32.self) }
        let bits = bytes.subdata(in: (offset + 104)..<(offset + 108)).withUnsafeBytes { $0.load(as: UInt32.self) }
        let nonce = Data(bytes.subdata(in: (offset + 108)..<(offset + 140)))

        // Compute hash (double SHA256)
        let hash = Data(SHA256.hash(data: Data(SHA256.hash(data: bytes))))

        return TempHeader(
            height: height,
            version: Int(version),
            prevHash: prevHash,
            merkleRoot: merkleRoot,
            saplingRoot: saplingRoot,
            timestamp: Int(timestamp),
            bits: Int(bits),
            nonce: nonce,
            hash: hash,
            isVerified: false
        )
    }
}
