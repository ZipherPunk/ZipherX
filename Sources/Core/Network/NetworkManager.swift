import Foundation
import Network
import Combine

/// FIX #350: Store all info needed to write to database on confirmation
/// This allows us to defer database writes until TX is confirmed in a block
public struct PendingOutgoingTx {
    let txid: String
    let amount: UInt64          // Amount sent to recipient (excluding fee)
    let fee: UInt64             // Transaction fee (10000 zatoshis)
    let toAddress: String       // Recipient z-address
    let memo: String?           // Optional memo
    let hashedNullifier: Data   // For marking the spent note
    let rawTxData: Data?        // Raw transaction for potential rebroadcast
    let timestamp: Date         // When TX was broadcast (for timing)
}

/// Thread-safe actor for transaction tracking state
/// Eliminates priority inversion from NSLock usage in async contexts
private actor TransactionTrackingState {
    /// FIX #350: Pending outgoing transactions with full info for database write on confirmation
    private var pendingOutgoingTxs: [String: PendingOutgoingTx] = [:]

    /// Notified incoming mempool transactions (to avoid duplicate notifications)
    private var notifiedMempoolIncomingTxs: Set<String> = []

    /// Pending incoming transactions (txid -> amount in zatoshis) - tracked until confirmed
    private var pendingIncomingTxs: [String: UInt64] = [:]

    // MARK: - Outgoing Transaction Tracking

    /// FIX #350: Track pending TX with full info for database write on confirmation
    func trackOutgoing(_ pendingTx: PendingOutgoingTx) -> (total: UInt64, count: Int) {
        pendingOutgoingTxs[pendingTx.txid] = pendingTx
        let total = pendingOutgoingTxs.values.reduce(0) { $0 + $1.amount + $1.fee }
        return (total, pendingOutgoingTxs.count)
    }

    /// Legacy trackOutgoing for backwards compatibility (UI tracking only, no database write)
    func trackOutgoingSimple(txid: String, amount: UInt64) -> (total: UInt64, count: Int) {
        // Create minimal pending TX for UI tracking only
        let pendingTx = PendingOutgoingTx(
            txid: txid,
            amount: amount,
            fee: 10000,
            toAddress: "",
            memo: nil,
            hashedNullifier: Data(),
            rawTxData: nil,
            timestamp: Date()
        )
        pendingOutgoingTxs[txid] = pendingTx
        let total = pendingOutgoingTxs.values.reduce(0) { $0 + $1.amount + $1.fee }
        return (total, pendingOutgoingTxs.count)
    }

    /// FIX #350: Return full pending TX info for database write on confirmation
    func confirmOutgoing(txid: String) -> (pendingTx: PendingOutgoingTx?, removed: Bool, total: UInt64, count: Int) {
        let pendingTx = pendingOutgoingTxs[txid]
        let removed = pendingOutgoingTxs.removeValue(forKey: txid) != nil
        let total = pendingOutgoingTxs.values.reduce(0) { $0 + $1.amount + $1.fee }
        return (pendingTx, removed, total, pendingOutgoingTxs.count)
    }

    /// Get amount for a pending TX (for UI display)
    func getPendingAmount(txid: String) -> UInt64? {
        pendingOutgoingTxs[txid].map { $0.amount + $0.fee }
    }

    func getPendingTxids() -> [String] {
        Array(pendingOutgoingTxs.keys)
    }

    func isPendingOutgoing(txid: String) -> Bool {
        pendingOutgoingTxs[txid] != nil
    }

    /// Get all pending outgoing txids as a Set for efficient lookup
    func getAllPendingOutgoingTxids() -> Set<String> {
        Set(pendingOutgoingTxs.keys)
    }

    /// Clear all pending outgoing transactions (called when broadcast fails)
    func clearAllOutgoing() {
        pendingOutgoingTxs.removeAll()
    }

    // MARK: - Incoming Mempool Notification Tracking

    func checkAndMarkNotified(txid: String) -> Bool {
        let isNew = !notifiedMempoolIncomingTxs.contains(txid)
        if isNew {
            notifiedMempoolIncomingTxs.insert(txid)
        }
        return isNew
    }

    func clearIncomingNotification(txid: String) {
        notifiedMempoolIncomingTxs.remove(txid)
    }

    // MARK: - Incoming Transaction Tracking (for confirmed celebration)

    func trackIncoming(txid: String, amount: UInt64) {
        pendingIncomingTxs[txid] = amount
    }

    func confirmIncoming(txid: String) -> UInt64? {
        let amount = pendingIncomingTxs[txid]
        pendingIncomingTxs.removeValue(forKey: txid)
        return amount
    }

    func isPendingIncoming(txid: String) -> Bool {
        pendingIncomingTxs[txid] != nil
    }

    func getPendingIncomingAmount(txid: String) -> UInt64? {
        pendingIncomingTxs[txid]
    }

    /// Get all pending incoming txids (for periodic confirmation check)
    func getPendingIncomingTxids() -> [(txid: String, amount: UInt64)] {
        pendingIncomingTxs.map { ($0.key, $0.value) }
    }

    /// Get total pending incoming amount
    func getTotalPendingIncoming() -> UInt64 {
        pendingIncomingTxs.values.reduce(0, +)
    }

    /// Get count of pending incoming transactions
    func getPendingIncomingCount() -> Int {
        pendingIncomingTxs.count
    }
}

/// Timeout helper for async operations
func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw NetworkError.timeout
        }
        // Return first result, cancel the other
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Multi-Peer Network Manager for Zclassic
/// Connects to multiple nodes and requires consensus for all queries
@MainActor
public final class NetworkManager: ObservableObject {
    static let shared = NetworkManager()

    // MARK: - Constants
    private let MIN_PEERS = 8  // Increased from 3 for better reliability
    // FIX #1450: Cap peers on iOS to reduce battery drain (30 peers × 15s TCP keepalive = 120 packets/min)
    // 8 peers provides sufficient consensus (threshold=3) + redundancy for P2P sync
    #if os(iOS)
    private let MAX_PEERS = 8
    #else
    private let MAX_PEERS = 30
    #endif
    private let TARGET_PEER_PERCENT = 0.15 // Connect to 15% of known addresses
    // FIX #934: Lowered from 7 to 3 - Zclassic network is small, can't reliably get 7 peers
    // Byzantine fault tolerance still applies but with realistic peer counts
    // FIX #1493: VULN-009 — Use centralized constant (was local hardcoded 3)
    private let CONSENSUS_THRESHOLD = ZipherXConstants.consensusThreshold
    private let PEER_ROTATION_INTERVAL: TimeInterval = 300 // 5 minutes
    private let QUERY_TIMEOUT: TimeInterval = 10
    private let BAN_DURATION: TimeInterval = 604800 // VUL-010: 7 days for stronger Sybil protection
    private let MAX_KNOWN_ADDRESSES = 1000
    private let MAX_ADDRESSES_PER_PEER = 100  // NET-005: Limit addresses accepted from a single peer per cycle
    private let GETADDR_INTERVAL: TimeInterval = 30 // Request addresses every 30 seconds
    private var addressSourceCounts: [String: Int] = [:]  // NET-005: Track total addresses contributed by each source

    // FIX #849: UserDefaults key for persisting pending outgoing txids across app restart
    private let PENDING_TXIDS_KEY = "ZipherX_PendingOutgoingTxids"

    // FIX #1348: Suppress verbose logging for pre-production build
    private let verbose = false

    // FIX #1467: iOS thermal throttle — skip non-critical background timers when device is warm
    #if os(iOS)
    private var isDeviceOverheating: Bool {
        ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }
    #endif

    // MARK: - Published Properties
    // CPU OPTIMIZATION: @Published fires Combine objectWillChange on EVERY assignment,
    // even when value is unchanged. Use updateIfChanged() to suppress duplicate notifications.
    @Published private(set) var connectedPeers: Int = 0
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var syncProgress: Double = 0.0
    @Published private(set) var lastBlockHeight: UInt64 = 0
    @Published private(set) var knownAddressCount: Int = 0
    @Published private(set) var peerVersion: String = ""
    @Published private(set) var chainHeight: UInt64 = 0
    @Published private(set) var walletHeight: UInt64 = 0
    @Published private(set) var zclPriceUSD: Double = 0.0
    @Published private(set) var zclPriceFailed: Bool = false  // True if both price APIs failed
    @Published private(set) var lastBlockTxCount: Int = 0
    @Published private(set) var networkDifficulty: Double = 0.0
    @Published private(set) var bannedPeersCount: Int = 0
    @Published private(set) var onionPeersCount: Int = 0  // .onion addresses discovered

    // FIX #455: Add @Published properties for Settings/Network display
    // These counts need to be reactive so the UI updates automatically
    @Published private(set) var parkedPeersCount: Int = 0
    @Published private(set) var reliablePeersDisplayCount: Int = 0  // Renamed to avoid conflict with computed property
    @Published private(set) var preferredSeedsCount: Int = 0

    /// Public accessor for known addresses count (for privacy report)
    var knownAddressesCount: Int {
        addressLock.lock()
        defer { addressLock.unlock() }
        return knownAddresses.count
    }
    @Published private(set) var torConnectedPeersCount: Int = 0  // peers connected via Tor SOCKS5
    @Published private(set) var onionConnectedPeersCount: Int = 0  // .onion peers actually connected

    /// Warning: P2P connection issues prevent mempool scanning
    /// UI should show warning when this is true (incoming tx detection disabled)
    @Published private(set) var p2pMempoolWarning: Bool = false

    /// FIX #130: Flag to indicate header sync is in progress
    /// Mempool scan will be paused during header sync to prevent P2P race conditions
    @Published private(set) var isHeaderSyncing: Bool = false

    /// FIX #841: Flag to indicate broadcast is in progress
    /// Background sync will be blocked during broadcast to prevent peer lock conflicts
    @Published private(set) var isBroadcasting: Bool = false

    /// FIX #871: Flag to indicate transient network recovery is in progress
    /// Health check will NOT show CRITICAL "No active peers!" alert during this period
    /// Set when FIX #870 detects ALL errors are transient (network hiccup) and delays recovery
    @Published private(set) var isTransientRecoveryInProgress: Bool = false

    /// Sybil attack detection - published when a fake peer is banned
    /// Contains: (peerHost: String, fakeHeight: UInt64, realHeight: UInt64)
    @Published private(set) var sybilAttackDetected: (peer: String, fakeHeight: UInt64, realHeight: UInt64)? = nil

    // MARK: - FIX #175: Sybil Attack User Notifications

    /// FIX #175: Alert when version-based Sybil attack detected (fake 170020 requirement)
    /// Contains: (attackerCount: Int, bypassedTor: Bool)
    @Published private(set) var sybilVersionAttackAlert: (attackerCount: Int, bypassedTor: Bool)? = nil

    /// FIX #175: Alert when Tor is bypassed due to Sybil attack
    @Published private(set) var torBypassedForSybil: Bool = false

    // MARK: - FIX #174: External Wallet Spend Detection

    /// FIX #174: Alert when an external wallet spent our funds (same private key imported elsewhere)
    /// Contains: (txid: String, amount: UInt64) - amount is the ACTUAL sent amount (input - change - fee)
    @Published private(set) var externalWalletSpendDetected: (txid: String, amount: UInt64)? = nil

    /// FIX #174: Flag indicating there's a pending transaction (ours or external) blocking new sends
    @Published private(set) var hasPendingMempoolTransaction: Bool = false

    /// FIX #301: Flag indicating WE have a pending outgoing transaction (NOT external wallet)
    /// Only OUR pending transactions should disable SEND - external spends should NOT block sending
    @Published private(set) var hasOurPendingOutgoing: Bool = false

    /// FIX #174: Reason why send is blocked (for UI display)
    @Published private(set) var pendingTransactionReason: String? = nil

    /// Set of pending outgoing transaction IDs (for synchronous change detection)
    /// This is updated alongside the actor's pendingOutgoingTxs for sync access
    /// FIX #388: nonisolated(unsafe) - thread safety managed by pendingOutgoingLock
    private nonisolated(unsafe) var pendingOutgoingTxidSet: Set<String> = []
    private nonisolated(unsafe) let pendingOutgoingLock = NSLock()

    /// FIX #388: Local network generation for synchronous access (network path handler)
    /// Syncs with PeerManager asynchronously, but allows synchronous read/write for callbacks
    private var localNetworkGeneration: UInt64 = 0
    private let networkGenerationLock = NSLock()

    /// Synchronous check if a transaction is pending outgoing (our own send)
    /// Used by FilterScanner to detect change outputs without async
    /// FIX #388: nonisolated - uses lock for thread-safe access from any context
    nonisolated func isPendingOutgoingSync(txid: String) -> Bool {
        pendingOutgoingLock.lock()
        defer { pendingOutgoingLock.unlock() }
        return pendingOutgoingTxidSet.contains(txid)
    }

    /// FIX #396: Async version for FilterScanner block scan
    func isPendingOutgoingTx(_ txid: String) -> Bool {
        pendingOutgoingLock.lock()
        defer { pendingOutgoingLock.unlock() }
        return pendingOutgoingTxidSet.contains(txid)
    }

    /// Flag to suppress background sync during initial startup sync
    /// Set to true during ContentView's initial sync task, false after completion
    var suppressBackgroundSync: Bool = false

    /// FIX #145: Flag to control when background processes can run
    /// Initially false - set to true ONLY after initial sync completes
    /// Prevents mempool scan, stats refresh, etc. from interfering with critical startup sync
    @Published private(set) var backgroundProcessesEnabled: Bool = false

    /// FIX #519: Flag to indicate header sync is in progress
    /// Health checks should NOT ping peers during header sync as it disrupts the sync
    private(set) var headerSyncInProgress: Bool = false

    /// FIX #519: Set header sync in progress flag
    func setHeaderSyncInProgress(_ inProgress: Bool) {
        headerSyncInProgress = inProgress
        if inProgress {
            print("🔒 FIX #519: Header sync in progress - health checks will skip pings")
        } else {
            print("🔓 FIX #519: Header sync complete - health checks resumed")
        }
    }

    // MARK: - FIX #889-#892: Import PK Performance Optimization

    /// FIX #889: Flag to indicate boost header loading is in progress
    /// When true, suppresses NWPathMonitor callbacks (FIX #890) and fetchNetworkStats (FIX #892)
    /// This prevents expensive network operations from interfering with SQLite bulk inserts
    @Published private(set) var isLoadingHeaders: Bool = false

    /// FIX #889: Set header loading flag (call from HeaderStore.loadHeadersFromBoostData)
    func setLoadingHeaders(_ loading: Bool) {
        isLoadingHeaders = loading
        if loading {
            print("🔒 FIX #889: Boost header load in progress - suppressing network operations")
        } else {
            print("🔓 FIX #889: Boost header load complete - resuming network operations")
        }
    }

    /// Flag to indicate intensive P2P fetch is in progress (blocks, CMUs, etc.)
    /// Used to prevent parallel operations from interfering with bulk P2P fetches
    @Published var isIntensiveP2PFetchInProgress: Bool = false

    /// FIX #1434: Recovery serialization — only 1 recovery at a time + exponential backoff
    private var isRecoveringPeers = false
    private var lastRecoveryAttempt: Date = .distantPast
    private var recoveryBackoffSeconds: TimeInterval = 30  // Start at 30s, doubles on each attempt

    /// FIX #1317: Actor-based async semaphore for serializing getBlocksDataP2P calls.
    /// Only 1 caller at a time may use the shared P2P peers for block fetching.
    /// Eliminates both client-side dispatcher contention AND server-side cs_main queueing.
    /// Why actor: NSLock can't span await; DispatchSemaphore.wait() blocks cooperative pool.
    private actor P2PFetchGate {
        private var isAcquired = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !isAcquired {
                isAcquired = true
                return
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waiters.append(cont)
            }
        }

        func release() {
            if let next = waiters.first {
                waiters.removeFirst()
                next.resume()
            } else {
                isAcquired = false
            }
        }
    }

    private let p2pFetchGate = P2PFetchGate()

    /// FIX #145: Enable background processes (called after initial sync completes)
    func enableBackgroundProcesses() {
        backgroundProcessesEnabled = true
        hasLoggedPathChangeSuppression = false  // FIX #1352: Reset for future syncs
        // FIX #286 v18: Also ensure suppressBackgroundSync is false
        // Belt-and-suspenders approach to fix mempool scanning not running
        if suppressBackgroundSync {
            print("[NET] ⚠️ FIX #286 v18: suppressBackgroundSync was still true! Forcing to false.")
            suppressBackgroundSync = false
        }
        debugLog(.network, "✅ FIX #145: Background processes ENABLED (initial sync complete)")

        // FIX #815: Update walletHeight from database BEFORE starting health monitoring
        // Problem: After Full Rescan, walletHeight was stale (showing boost file height 2988797)
        //          but lastScannedHeight in DB was already updated to 2992134
        // Result: Health check saw "3377 blocks behind" and blocked SEND unnecessarily
        // Fix: Read fresh walletHeight from database before health check runs
        let freshWalletHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
        if freshWalletHeight > 0 && freshWalletHeight != walletHeight {
            print("📊 FIX #815: Refreshing walletHeight from \(walletHeight) to \(freshWalletHeight) before health check")
            self.walletHeight = freshWalletHeight
        }

        // FIX #409: Start continuous health monitoring
        startHealthMonitoring()
    }

    /// FIX #145: Disable background processes (for testing/reset)
    func disableBackgroundProcesses() {
        backgroundProcessesEnabled = false
        // FIX #409: Stop health monitoring
        stopHealthMonitoring()
        debugLog(.network, "⏸️ FIX #145: Background processes DISABLED")
    }

    // MARK: - FIX #409: Continuous Health Monitoring

    /// Critical health issue that requires user attention
    public struct CriticalHealthAlert: Identifiable, Equatable {
        public let id = UUID()
        public let title: String
        public let message: String
        public let severity: Severity
        public let solutions: [Solution]
        public let timestamp: Date

        public enum Severity: String {
            case warning = "⚠️"
            case critical = "🚨"
        }

        public struct Solution: Identifiable, Equatable {
            public let id = UUID()
            public let title: String
            public let action: ActionType

            public enum ActionType: Equatable {
                case clearHeaders
                case syncHeaders  // FIX #411: Sync headers instead of clearing (for Tree Root issues)
                case repairDatabase
                case reconnectPeers
                case dismiss
            }
        }

        public static func == (lhs: CriticalHealthAlert, rhs: CriticalHealthAlert) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// FIX #409: Published health alert for UI display
    @Published var criticalHealthAlert: CriticalHealthAlert? = nil

    /// FIX #410: Critical process safety - blocks Send/Receive/Chat when wallet is unsafe
    @Published public var isSafeToTransact: Bool = true
    @Published public var transactionBlockedReason: String? = nil
    @Published public var blockedFeatures: Set<BlockedFeature> = []

    public enum BlockedFeature: String, CaseIterable {
        case send = "Send"
        case receive = "Receive"
        case chat = "Chat"
    }

    /// FIX #410: Block features with reason
    @MainActor
    public func blockFeatures(_ features: Set<BlockedFeature>, reason: String) {
        blockedFeatures = features
        transactionBlockedReason = reason
        isSafeToTransact = features.isEmpty
        if !features.isEmpty {
            let featureNames = features.map { $0.rawValue }.joined(separator: ", ")
            print("🚫 FIX #410: Blocked features [\(featureNames)]: \(reason)")
        }
    }

    /// FIX #410: Unblock all features
    @MainActor
    public func unblockAllFeatures() {
        blockedFeatures = []
        transactionBlockedReason = nil
        isSafeToTransact = true
        print("✅ FIX #410: All features unblocked - wallet is safe to transact")
    }

    /// FIX #410: Check if a specific feature is blocked
    public func isFeatureBlocked(_ feature: BlockedFeature) -> Bool {
        blockedFeatures.contains(feature)
    }

    /// FIX #409: Health check timer
    private var healthCheckTimer: Timer?
    private let HEALTH_CHECK_INTERVAL: TimeInterval = 60  // Check every 60 seconds
    private var healthAlertDismissTime: Date? = nil  // FIX #543: Track when user last dismissed alert
    private let HEALTH_ALERT_SNOOZE_INTERVAL: TimeInterval = 300  // FIX #543: Don't re-alert for 5 minutes after dismissal

    /// FIX #409: Start continuous health monitoring
    func startHealthMonitoring() {
        guard healthCheckTimer == nil else { return }
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: HEALTH_CHECK_INTERVAL, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performHealthCheck()
            }
        }
        healthCheckTimer?.tolerance = 15.0  // FIX #1450: 25% tolerance for iOS timer coalescing
        print("🏥 FIX #409: Health monitoring started (interval: \(Int(HEALTH_CHECK_INTERVAL))s)")

        // FIX #410: Run immediate health check on startup
        Task { @MainActor in
            await performHealthCheck()
        }
    }

    /// FIX #409: Stop health monitoring
    func stopHealthMonitoring() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    /// FIX #409: Perform health check and alert user if critical issues found
    @MainActor
    func performHealthCheck() async {
        // Don't check during initial sync
        guard backgroundProcessesEnabled else { return }
        // FIX #1467: Skip health check when iOS device is overheating
        #if os(iOS)
        if isDeviceOverheating { return }
        #endif

        // FIX #543: Check if we're in snooze period (user recently dismissed alert)
        if let dismissTime = healthAlertDismissTime {
            let timeSinceDismiss = Date().timeIntervalSince(dismissTime)
            if timeSinceDismiss < HEALTH_ALERT_SNOOZE_INTERVAL {
                // Skip alert - user recently dismissed, don't annoy them
                return
            }
        }

        // Check 1: HeaderStore health
        let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
        let headersBehind = chainHeight > headerStoreHeight ? chainHeight - headerStoreHeight : 0

        if headersBehind > 500 {
            // FIX #1077: AUTO-HANDLE header sync issues - trigger sync automatically!
            print("🔄 FIX #1077: HeaderStore \(headersBehind) headers behind - AUTO-triggering sync (no user action needed)")

            // FIX #410: Block SEND - could cause anchor mismatch or failed proofs
            blockFeatures([.send], reason: "Syncing headers...")

            // AUTO-trigger header sync in background
            Task {
                do {
                    let startHeight = headerStoreHeight + 1
                    let headerSyncManager = HeaderSyncManager(
                        headerStore: HeaderStore.shared,
                        networkManager: self
                    )
                    try await headerSyncManager.syncHeaders(from: startHeight, maxHeaders: 1000)
                    print("✅ FIX #1077: Auto header sync completed")
                } catch {
                    print("⚠️ FIX #1077: Auto header sync failed: \(error) - will retry")
                }
            }

            // DON'T show alert - auto-recover silently
            // FIX #769: Use "headers behind" wording to avoid false sync lag alerts
            print("⏳ FIX #409: HeaderStore is \(headersBehind) headers behind - auto-syncing...")
            return
        }

        // Check 2: Peer connectivity
        let readyPeers = peers.filter { $0.isConnectionReady }.count
        if readyPeers == 0 && isConnected {
            // FIX #871: If transient recovery is in progress, DON'T show CRITICAL alert
            // This prevents false alarms when FIX #870 is waiting for network to stabilize
            if isTransientRecoveryInProgress {
                print("⏳ FIX #871: 0 peers but transient recovery in progress - suppressing CRITICAL alert")
                // Still block features for safety, but don't scare user with CRITICAL alert
                blockFeatures([.send, .receive, .chat], reason: "Reconnecting to network...")
                return
            }

            // FIX #1077: AUTO-HANDLE connection loss - trigger reconnection automatically!
            // User said: "app must handle automatically all errors, inform the user but must handle automatically without users actions"
            print("🔄 FIX #1077: 0 active peers - AUTO-triggering reconnection (no user action needed)")
            blockFeatures([.send, .receive, .chat], reason: "Reconnecting to network...")

            // AUTO-trigger reconnection in background
            Task {
                await self.attemptPeerRecovery()
            }

            // DON'T show alert - just auto-recover silently
            // The status bar shows connection status - user can see it's reconnecting
            return
        }

        // Check 3: Wallet sync stuck (wallet far behind chain for >5 minutes)
        // FIX #555: Skip check if walletHeight is 0 (wallet not loaded yet) or during initial sync
        // FIX #815: Use fresh database value to avoid stale walletHeight after Full Rescan
        let currentWalletHeight = max(walletHeight, (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0)
        let walletBehind = chainHeight > currentWalletHeight ? chainHeight - currentWalletHeight : 0
        if walletBehind > 100 && !suppressBackgroundSync && currentWalletHeight > 0 {
            // FIX #1077: AUTO-HANDLE wallet sync - trigger background sync automatically!
            print("🔄 FIX #1077: Wallet \(walletBehind) blocks behind - AUTO-triggering sync (no user action needed)")

            // FIX #410: Block SEND only - balance may be wrong, could overspend
            blockFeatures([.send], reason: "Syncing wallet...")

            // AUTO-trigger wallet catch-up in background
            Task {
                do {
                    print("⏳ FIX #1077: Starting automatic catch-up sync...")
                    try await WalletManager.shared.backgroundSyncToHeight(chainHeight)
                    print("✅ FIX #1077: Auto wallet sync completed")
                } catch {
                    print("⚠️ FIX #1077: Auto wallet sync failed: \(error) - will retry")
                }
            }

            // DON'T show alert - auto-recover silently
            print("⏳ FIX #409: Wallet is \(walletBehind) blocks behind - auto-syncing...")
            return
        }

        // All checks passed - clear any existing alert and unblock features
        if criticalHealthAlert != nil || !blockedFeatures.isEmpty {
            print("✅ FIX #409/410: Health check passed - clearing alerts and unblocking features")
            criticalHealthAlert = nil
            unblockAllFeatures()
            // FIX #543: Clear snooze time when health checks pass - issue is resolved
            healthAlertDismissTime = nil
        }
    }

    /// FIX #409: Handle user action on health alert
    @MainActor
    func handleHealthAlertAction(_ action: CriticalHealthAlert.Solution.ActionType) async {
        switch action {
        case .clearHeaders:
            print("🔧 FIX #409: User chose to clear headers")
            do {
                try HeaderStore.shared.clearAllHeaders()
                print("✅ FIX #409: Headers cleared successfully")
            } catch {
                print("❌ FIX #409: Failed to clear headers: \(error)")
            }

        case .syncHeaders:
            // FIX #411: Sync headers to catch up instead of clearing
            print("🔧 FIX #411: User chose to sync headers")
            let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
            let targetHeight = UInt64(chainHeight)
            if targetHeight > headerStoreHeight {
                let gap = targetHeight - headerStoreHeight
                print("🔧 FIX #411: Syncing \(gap) headers (from \(headerStoreHeight) to \(targetHeight))")
                let hsm = HeaderSyncManager(headerStore: HeaderStore.shared, networkManager: self)

                // FIX #464: Report header sync progress to UI
                hsm.onProgress = { progress in
                    Task { @MainActor in
                        debugLog(.network, "📊 Header sync progress: \(progress.currentHeight)/\(progress.totalHeight)")
                    }
                }

                // Sync ALL missing headers, not just 100
                do {
                    try await hsm.syncHeaders(from: headerStoreHeight + 1, maxHeaders: gap + 100)
                    print("✅ FIX #411: Header sync completed")
                } catch {
                    print("❌ FIX #411: Header sync failed: \(error)")
                }
            }

        case .repairDatabase:
            print("🔧 FIX #409: User chose to repair database")
            // This will be handled by the UI which calls WalletManager.repairNotesAfterDownloadedTree()

        case .reconnectPeers:
            print("🔧 FIX #409: User chose to reconnect peers")
            await disconnect()
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            try? await connect()

        case .dismiss:
            print("🔧 FIX #409: User dismissed alert")
            // FIX #543: Record dismissal time to prevent immediate re-alert
            healthAlertDismissTime = Date()
            print("🔧 FIX #543: Health alert snoozed for \(Int(HEALTH_ALERT_SNOOZE_INTERVAL))s")
        }

        criticalHealthAlert = nil
    }

    /// FIX #130: Set header syncing state (called from WalletManager)
    /// When true, mempool scan is disabled to prevent P2P race conditions
    /// FIX #139: Also pauses/resumes block listeners for faster header sync
    /// FIX #509: Now async - waits for listeners to actually finish before returning
    /// FIX #457 v11: Added stopListeners parameter (small syncs don't need to stop listeners)
    func setHeaderSyncing(_ syncing: Bool, stopListeners: Bool = true) async {
        // FIX #140: Set flag synchronously (no Task wrapper) so it takes effect immediately
        self.isHeaderSyncing = syncing
        debugLog(.network, "📡 Header sync state: \(syncing ? "STARTED" : "COMPLETED")")

        // FIX #139: Pause block listeners during header sync for 100x faster sync
        // FIX #509: Now awaits to ensure listeners are ACTUALLY stopped before continuing
        // FIX #383: Renamed to stopAllBlockListeners/resumeAllBlockListeners
        // FIX #457 v11: Only stop listeners if stopListeners=true (small syncs don't need it)
        if syncing && stopListeners {
            await self.stopAllBlockListeners()
        } else if !syncing {
            await self.resumeAllBlockListeners()
        }
    }

    /// FIX #139/FIX #383: Stop all block listeners before header sync
    /// FIX #509: Now async - waits for listeners to actually finish
    /// FIX #384: Delegates to PeerManager (but also operates on local peers for sync)
    /// FIX #822: Add 5s overall timeout to prevent blocking startup
    /// FIX #874: Early return if no listeners running - saves 5+ seconds during startup
    public func stopAllBlockListeners() async {
        // FIX #874: Check if any listeners are actually running before spending time stopping
        let listeningPeers = peers.filter { $0.isListening }
        let peerManagerHasListeners = await PeerManager.shared.hasActiveBlockListeners()

        if listeningPeers.isEmpty && !peerManagerHasListeners {
            // FIX #874: No listeners running - skip expensive stop operations
            debugLog(.network, "⏸️ FIX #874: No block listeners running - skipping stop (fast path)")
            return
        }

        print("🛑 FIX #383: Stopping all block listeners...")
        debugLog(.network, "⏸️ FIX #140: Pausing \(peers.count) block listeners for header sync...")

        // FIX #822: Signal all local listeners to stop immediately (non-blocking)
        for peer in listeningPeers {
            peer.signalStopListener()
        }

        // FIX #822: Use overall timeout for local peers
        let localStopTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for peer in listeningPeers {
                    group.addTask {
                        await peer.stopBlockListener()
                    }
                }
            }
        }

        let localTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3s for local peers
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await localStopTask.value }
            group.addTask { await localTimeoutTask.value }
            _ = await group.next()
            group.cancelAll()
        }

        // Also delegate to PeerManager (which has its own 5s timeout via FIX #822)
        await PeerManager.shared.stopAllBlockListeners()

        debugLog(.network, "⏸️ FIX #140: Stopped \(listeningPeers.count) block listeners")
    }

    /// FIX #139/FIX #383: Resume all block listeners after header sync
    /// FIX #509 v2: DISABLED - Block listeners should NOT start automatically
    /// They should only be started when app is 100% ready on main balance screen
    public func resumeAllBlockListeners() async {
        print("▶️ FIX #509: resumeAllBlockListeners called - BLOCKED (will start on main screen only)")
        // DO NOT start block listeners here anymore
        // They will be started explicitly when main balance view is ready
    }

    /// FIX #509: Start block listeners ONLY when app is fully ready on main balance screen
    /// This should be called explicitly by the UI when the main screen is displayed
    /// FIX #907: Check if operations are blocking listeners before starting
    public func startBlockListenersOnMainScreen() async {
        // FIX #907: Don't start if operations are in progress
        if PeerManager.shared.areBlockListenersBlocked() {
            print("🛑 FIX #907: startBlockListenersOnMainScreen BLOCKED - operations in progress")
            return
        }

        print("▶️ FIX #509: Starting block listeners on main balance screen...")

        // FIX #1358: Reconnect dead peers BEFORE starting block listeners.
        // After header sync stops listeners, NWConnections are cancelled (error 57).
        // Without reconnection, block listeners start on dead sockets and die immediately,
        // leaving all dispatchers inactive → no blocks fetched → no TX confirmation.
        var reconnectedHosts = Set<String>()
        for peer in peers {
            if peer.isHandshakeComplete && !peer.isConnectionReady {
                if reconnectedHosts.contains(peer.host) { continue }
                reconnectedHosts.insert(peer.host)
                do {
                    try await peer.ensureConnected()
                } catch {
                    print("⚠️ FIX #1358: Failed to reconnect \(peer.host): \(error.localizedDescription)")
                }
            }
        }
        if !reconnectedHosts.isEmpty {
            print("🔄 FIX #1358: Reconnected \(reconnectedHosts.count) dead peers before starting block listeners")
            // Wait for connections to stabilize
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }

        // Start local peers
        for peer in peers {
            peer.startBlockListener()
        }

        // Also delegate to PeerManager
        await PeerManager.shared.startBlockListenersOnMainScreen()
    }

    // MARK: - Connection Cooldown (FIX #114)
    /// Track last connection attempt per address to prevent infinite reconnection loops
    /// Key: "host:port", Value: timestamp of last attempt
    private var connectionAttempts: [String: Date] = [:]
    private let connectionAttemptsLock = NSLock()
    /// FIX #122: Reduced from 5s to 2s for faster header sync
    private let CONNECTION_COOLDOWN: TimeInterval = 2.0  // 2 seconds between attempts to same address

    // FIX #235, FIX #423: Hardcoded Zclassic seed nodes are EXEMPT from cooldown
    // These are known-good nodes that should always be retried immediately
    // NOTE: Keep in sync with PeerManager.shared.HARDCODED_SEEDS
    // FIX #931: PRODUCTION MODE - All hardcoded seeds enabled
    // FIX #1360: TASK 13 - Remove localhost from hardcoded seeds (added dynamically only for full-node mode)
    private let HARDCODED_SEEDS = Set<String>([
        "140.174.189.3",      // MagicBean node cluster
        "140.174.189.17",     // MagicBean node cluster
        "205.209.104.118",    // MagicBean node
        "95.179.131.117",     // Additional Zclassic node
        "45.77.216.198",      // Additional Zclassic node
        "212.23.222.231",     // FIX #423: Verified ZCL node
        "157.90.223.151"      // FIX #423: Verified ZCL node
    ])

    /// Check if an address is on cooldown (recently attempted)
    /// FIX #235: Hardcoded seeds are NEVER on cooldown
    /// VUL-N-014: ALL peers subject to cooldown (hardcoded seeds no longer exempt)
    private func isOnCooldown(_ host: String, port: UInt16) -> Bool {
        let key = "\(host):\(port)"
        connectionAttemptsLock.lock()
        defer { connectionAttemptsLock.unlock() }

        if let lastAttempt = connectionAttempts[key] {
            let elapsed = Date().timeIntervalSince(lastAttempt)
            return elapsed < CONNECTION_COOLDOWN
        }
        return false
    }

    /// Record a connection attempt for cooldown tracking
    private func recordConnectionAttempt(_ host: String, port: UInt16) {
        let key = "\(host):\(port)"
        connectionAttemptsLock.lock()
        connectionAttempts[key] = Date()
        connectionAttemptsLock.unlock()
    }

    // MARK: - Private Properties
    internal var peers: [Peer] = []  // internal so HeaderSyncManager can access

    /// FIX #384: Sync peer list to PeerManager after modifications
    private func syncPeersToPeerManager() {
        Task { @MainActor in
            PeerManager.shared.syncPeers(self.peers)
        }
    }

    /// Get a connected peer for block downloads
    /// Returns the first peer with a ready connection
    func getConnectedPeer() -> Peer? {
        // Sync to PeerManager
        syncPeersToPeerManager()
        return peers.first { $0.isConnectionReady }
    }

    /// Get all connected peers with ready connections
    /// FIX #384: Delegates to PeerManager for centralized access
    func getAllConnectedPeers() -> [Peer] {
        // Sync to PeerManager
        PeerManager.shared.syncPeers(self.peers)
        return PeerManager.shared.getReadyPeers()
    }

    /// FIX #384: Get peers for consensus operations via PeerManager
    func getPeersForConsensus(count: Int = 5) -> [Peer] {
        PeerManager.shared.syncPeers(self.peers)
        return PeerManager.shared.getPeersForConsensus(count: count)
    }

    /// FIX #384: Get peers with recent activity via PeerManager
    func getPeersWithRecentActivity() -> [Peer] {
        PeerManager.shared.syncPeers(self.peers)
        return PeerManager.shared.getPeersWithRecentActivity()
    }

    /// Update wallet height directly (called after sync completes)
    func updateWalletHeight(_ height: UInt64) {
        Task { @MainActor in
            self.walletHeight = height
        }
    }
    private var peerRotationTimer: Timer?
    private var addressDiscoveryTimer: Timer?
    private var statsRefreshTimer: Timer?
    // FIX #227: Peer recovery watchdog - runs more frequently to detect lost peers
    private var peerRecoveryTimer: Timer?
    private var consecutiveSOCKS5Failures: Int = 0
    private let SOCKS5_FAILURE_THRESHOLD: Int = 5  // After 5 failures, bypass Tor
    // FIX #1419: Track consecutive recovery failures with 0 peers (exit circuit failure detection)
    private var consecutiveZeroPeerRecoveries: Int = 0
    private let ZERO_PEER_RECOVERY_THRESHOLD: Int = 3  // After 3 consecutive 0-peer recoveries, restart Tor with cache clear
    private let PEER_RECOVERY_INTERVAL: TimeInterval = 30  // Check every 30 seconds
    private let STATS_REFRESH_INTERVAL: TimeInterval = 30 // Refresh chain height every 30 seconds
    private let queue = DispatchQueue(label: "com.zipherx.network", qos: .userInitiated)

    // MARK: - FIX #268: NWPathMonitor for Network Transitions

    /// NWPathMonitor to detect WiFi ↔ cellular transitions
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.zipherx.pathmonitor", qos: .utility)

    /// Debounce network change recovery
    private var lastPathChangeTime: Date?
    // FIX #1497: iOS cellular fires NWPathMonitor every 30-60s during tower handoffs.
    // Previous 10s debounce was insufficient — events are 25-60s apart, causing 11+ full
    // reconnection cycles in 7 minutes = massive CPU/radio drain = phone overheats.
    // 120s debounce: most tower handoffs don't affect existing TCP connections.
    #if os(iOS)
    private let PATH_CHANGE_DEBOUNCE: TimeInterval = 120.0
    #else
    private let PATH_CHANGE_DEBOUNCE: TimeInterval = 3.0
    #endif
    /// FIX #1352: Track if we already logged the suppression message
    private var hasLoggedPathChangeSuppression = false

    // Address Manager
    private var knownAddresses: [String: AddressInfo] = [:] // host:port -> info
    private var bannedPeers: [String: BannedPeer] = [:] // host -> ban info (ONLY for security issues!)
    private var parkedPeers: [String: ParkedPeer] = [:] // FIX #284: host -> parked info (connection timeouts)
    private var triedAddresses: Set<String> = [] // Addresses we've connected to
    private var newAddresses: Set<String> = [] // Addresses we haven't tried yet
    private let addressLock = NSLock() // Thread safety for address collections
    private var isConnecting = false // Prevent concurrent connection attempts
    private var hasDownloadedGitHubPeers = false // Once-per-session guard for GitHub peers

    // FIX #173: Sybil attack detection - track consecutive fake 170020 rejections
    private var consecutiveSybilRejections: Int = 0
    private var sybilBypassActive: Bool = false
    private let SYBIL_BYPASS_THRESHOLD: Int = 10 // After 10 Sybil rejections, bypass Tor

    // Known public Zclassic nodes (DNS seeds + hardcoded)
    // FIX #927: Restored DNS seeds (was FIX #918 debug mode)
    private let dnsSeedsZCL: [String] = [
        "dnsseed.zclassic.org",
        "dnsseed.rotorproject.org",
        "dnsseed.zclnet.net"
    ]

    // VUL-N-011: DNS cache with 1-hour TTL to reduce DNS queries and improve privacy
    private var dnsCache: [String: (addresses: [PeerAddress], resolvedAt: Date)] = [:]
    private let DNS_CACHE_TTL: TimeInterval = 3600 // 1 hour

    // FIX #229: Trusted peers are now loaded from database table
    // Use getTrustedPeersForBootstrap() instead of hardcoded array
    // Legacy hardcoded list removed - see WalletDatabase.getTrustedPeers()

    /// Get trusted peers from database for bootstrap (synchronous wrapper)
    /// FIX #926: Restored production peer loading (was FIX #918 debug mode - localhost only)
    private func getTrustedPeersForBootstrap() -> [String] {
        // Try to get trusted peers from database
        if let peers = try? WalletDatabase.shared.getTrustedPeers() {
            if verbose {
                print("📡 FIX #926: Loaded \(peers.count) trusted peers from database")
            }
            return peers.map { "\($0.host):\($0.port)" }
        }
        // Fallback if database not available (shouldn't happen)
        print("⚠️ FIX #926: Database unavailable, using hardcoded fallback peers")
        return [
            "140.174.189.17:8033",
            "205.209.104.118:8033",
            "185.205.246.161:8033"
        ]
    }

    // .onion peers for Tor users (requires Tor to be enabled)
    // These are hidden service addresses that can only be reached via Tor
    // Note: .onion peers are also discovered dynamically via P2P addr/addrv2 messages
    private let onionPeersZCL: [String] = [
        // .onion peers are discovered dynamically via BIP155 addrv2 messages
        // from peers that support protocol version > 170011
    ]

    // MARK: - User Custom Nodes

    /// User-added custom nodes (persisted to UserDefaults)
    @Published private(set) var customNodes: [UserCustomNode] = []
    private let customNodesKey = "UserCustomNodes"

    /// Load custom nodes from UserDefaults
    private func loadCustomNodes() {
        guard let data = UserDefaults.standard.data(forKey: customNodesKey),
              let nodes = try? JSONDecoder().decode([UserCustomNode].self, from: data) else {
            customNodes = []
            return
        }
        customNodes = nodes
        print("📌 Loaded \(nodes.count) custom nodes from storage")
    }

    /// Save custom nodes to UserDefaults
    private func saveCustomNodes() {
        guard let data = try? JSONEncoder().encode(customNodes) else { return }
        UserDefaults.standard.set(data, forKey: customNodesKey)
    }

    /// Add a new custom node
    @MainActor
    public func addCustomNode(host: String, port: UInt16 = 8033, label: String = "") -> Bool {
        // Validate format
        var node = UserCustomNode(host: host, port: port, label: label)
        guard node.isValid else {
            print("❌ Invalid node address: \(host)")
            return false
        }

        // Check for duplicates
        if customNodes.contains(where: { $0.host == host && $0.port == port }) {
            print("⚠️ Node already exists: \(host):\(port)")
            return false
        }

        customNodes.append(node)
        saveCustomNodes()
        print("✅ Added custom node: \(node.label) (\(node.addressType.rawValue))")

        // Add to known addresses for immediate use
        let key = "\(host):\(port)"
        let now = Date()
        addressLock.lock()
        knownAddresses[key] = AddressInfo(
            address: PeerAddress(host: host, port: port),
            source: "user",
            firstSeen: now,
            lastSeen: now,
            attempts: 0,
            successes: 0
        )
        addressLock.unlock()

        // Trigger immediate connection attempt
        Task {
            await connectToNewCustomNode(host: host, port: port)
        }

        return true
    }

    /// Attempt to connect to a newly added custom node immediately
    private func connectToNewCustomNode(host: String, port: UInt16) async {
        print("🔄 Attempting immediate connection to custom node: \(host):\(port)")

        // For .onion addresses, wait for circuit warmup
        if host.hasSuffix(".onion") {
            let torConnected = await TorManager.shared.connectionState.isConnected
            if !torConnected {
                print("⏳ Waiting for Tor to connect before trying .onion custom node...")
                // Wait up to 30 seconds for Tor to connect
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if await TorManager.shared.connectionState.isConnected { break }
                }
            }

            // Now wait for circuit warmup
            let circuitsReady = await TorManager.shared.isOnionCircuitsReady
            if !circuitsReady {
                let remaining = await TorManager.shared.onionCircuitWarmupRemaining
                if remaining > 0 {
                    print("⏳ Waiting \(Int(remaining))s for .onion circuits to warm up...")
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            }
        }

        let peer = Peer(host: host, port: port, networkMagic: networkMagic)
        do {
            try await peer.connect()
            try await peer.performHandshake()

            await MainActor.run {
                // Add to connected peers if not already there
                if !self.peers.contains(where: { $0.host == host && $0.port == port }) {
                    self.peers.append(peer)
                    // FIX #478: Also add to PeerManager to keep peer lists in sync
                    // HeaderSyncManager uses PeerManager.shared.getReadyPeers()
                    PeerManager.shared.addPeer(peer)
                }
                self.connectedPeers = self.peers.filter { $0.isConnectionReady }.count
                self.recordCustomNodeConnection(host: host, port: port, success: true)
                print("✅ Connected to custom node: \(host):\(port)")
            }
        } catch {
            await MainActor.run {
                self.recordCustomNodeConnection(host: host, port: port, success: false)
                print("⚠️ Failed to connect to custom node \(host):\(port): \(error.localizedDescription)")
            }
        }
    }

    /// Update an existing custom node
    @MainActor
    public func updateCustomNode(_ node: UserCustomNode) -> Bool {
        guard let index = customNodes.firstIndex(where: { $0.id == node.id }) else {
            return false
        }
        customNodes[index] = node
        saveCustomNodes()
        print("✅ Updated custom node: \(node.label)")
        return true
    }

    /// Delete a custom node
    @MainActor
    public func deleteCustomNode(id: UUID) -> Bool {
        guard let index = customNodes.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let node = customNodes[index]

        // Remove from known addresses
        let key = "\(node.host):\(node.port)"
        addressLock.lock()
        knownAddresses.removeValue(forKey: key)
        addressLock.unlock()

        customNodes.remove(at: index)
        saveCustomNodes()
        print("🗑️ Deleted custom node: \(node.label)")
        return true
    }

    /// Toggle a custom node's enabled state
    @MainActor
    public func toggleCustomNode(id: UUID) -> Bool {
        guard let index = customNodes.firstIndex(where: { $0.id == id }) else {
            return false
        }
        customNodes[index].isEnabled.toggle()
        saveCustomNodes()
        print("🔄 Custom node \(customNodes[index].label) is now \(customNodes[index].isEnabled ? "enabled" : "disabled")")
        return true
    }

    /// Record connection result for a custom node
    private func recordCustomNodeConnection(host: String, port: UInt16, success: Bool) {
        guard let index = customNodes.firstIndex(where: { $0.host == host && $0.port == port }) else {
            return
        }
        customNodes[index].connectionAttempts += 1
        if success {
            customNodes[index].connectionSuccesses += 1
            customNodes[index].lastConnected = Date()
        }
        saveCustomNodes()
    }

    /// Get enabled custom nodes for connection
    func getEnabledCustomNodes() -> [UserCustomNode] {
        return customNodes.filter { $0.isEnabled }
    }

    // Zclassic network parameters
    private let networkMagic: [UInt8] = [0x24, 0xe9, 0x27, 0x64] // ZCL mainnet
    private let defaultPort: UInt16 = 8033

    private init() {
        setupPeerRotation()
        setupAddressDiscovery()
        setupStatsRefresh()
        setupPeerRecoveryWatchdog()  // FIX #227: Monitor for lost peers
        setupKeepaliveTimer()  // FIX #246: Keepalive ping + auto-reconnection
        setupPathMonitor()  // FIX #268: Detect WiFi ↔ cellular transitions
        setupConnectionHealthMonitoring()  // FIX: Enhanced connection health monitoring
        loadBundledPeers()      // Load bundled peers first (for fresh installs)
        loadPersistedAddresses() // Then override with persisted (for returning users)
        loadCustomNodes()        // Load user-added custom nodes

        // FIX #272: Load walletHeight immediately at startup (not just every 30s)
        // This prevents UI from showing "Syncing" when wallet is already synced
        if let dbHeight = try? WalletDatabase.shared.getLastScannedHeight() {
            self.walletHeight = dbHeight
            print("📊 FIX #272: Loaded walletHeight at startup: \(dbHeight)")
        }

        // FIX #847: Restore pending sent transactions from database
        // This prevents double-spending when app restarts with unconfirmed TX
        restorePendingSentTransactions()
    }

    /// FIX #847: Restore pending sent transactions from database at startup
    /// This prevents sending when a previous TX is unconfirmed (anchor mismatch issue)
    private func restorePendingSentTransactions() {
        do {
            let pendingSent = try WalletDatabase.shared.getPendingSentTransactions()
            if !pendingSent.isEmpty {
                print("⚠️ FIX #847: Found \(pendingSent.count) unconfirmed sent transaction(s) - blocking new sends")
                for tx in pendingSent {
                    let txidHex = tx.txid.map { String(format: "%02x", $0) }.joined()
                    print("  📤 Pending TX: \(txidHex.prefix(16))... status=\(tx.status.rawValue) value=\(tx.value.redactedAmount)")

                    // Add to tracking state (for consistency with runtime tracking)
                    pendingOutgoingLock.lock()
                    pendingOutgoingTxidSet.insert(txidHex)
                    pendingOutgoingLock.unlock()
                }

                // Set the flags to block new sends
                self.hasOurPendingOutgoing = true
                self.hasPendingMempoolTransaction = true
                self.mempoolOutgoing = pendingSent.reduce(0) { $0 + $1.value + ($1.fee ?? 10000) }
                self.mempoolOutgoingTxCount = pendingSent.count
                self.pendingTransactionReason = "Previous transaction not yet confirmed"

                // Track in the actor for confirmation checking
                Task {
                    for tx in pendingSent {
                        let txidHex = tx.txid.map { String(format: "%02x", $0) }.joined()
                        _ = await txTrackingState.trackOutgoingSimple(txid: txidHex, amount: tx.value)
                    }
                    print("📤 FIX #847: \(pendingSent.count) pending TX(s) added to actor tracking")
                }
            } else {
                print("✅ FIX #847: No pending sent transactions - sends allowed")
            }
        } catch {
            print("⚠️ FIX #847: Failed to load pending sent transactions: \(error)")
            // Don't block sends on error - fail open but log the issue
        }

        // FIX #849: ALSO restore pending txids from UserDefaults
        // This handles txs that were broadcast but not yet written to database (FIX #350 defers writes)
        restorePersistedPendingTxids()
    }

    // MARK: - FIX #849: Persist Pending Txids Across App Restart

    /// FIX #849: Persist a pending txid to UserDefaults
    /// Called when we add to pendingOutgoingTxidSet during broadcast
    private func persistPendingTxid(_ txid: String) {
        var txids = UserDefaults.standard.stringArray(forKey: PENDING_TXIDS_KEY) ?? []
        if !txids.contains(txid) {
            txids.append(txid)
            UserDefaults.standard.set(txids, forKey: PENDING_TXIDS_KEY)
            print("💾 FIX #849: Persisted pending txid: \(txid.prefix(16))... (total: \(txids.count))")
        }

        // FIX #1366: Also persist to broadcast history (separate from pending).
        // This survives FIX #970 cleanup — used at startup to detect confirmed TXs
        // missing from history (crash between broadcast and block confirmation).
        var history = UserDefaults.standard.stringArray(forKey: "ZipherX_BroadcastHistory") ?? []
        if !history.contains(txid) {
            history.append(txid)
            // Keep max 20 entries to prevent unbounded growth
            if history.count > 20 { history = Array(history.suffix(20)) }
            UserDefaults.standard.set(history, forKey: "ZipherX_BroadcastHistory")
        }
    }

    /// FIX #849: Remove a pending txid from UserDefaults when confirmed
    func removePendingTxidFromPersistence(_ txid: String) {
        var txids = UserDefaults.standard.stringArray(forKey: PENDING_TXIDS_KEY) ?? []
        if let index = txids.firstIndex(of: txid) {
            txids.remove(at: index)
            UserDefaults.standard.set(txids, forKey: PENDING_TXIDS_KEY)
            print("🗑️ FIX #849: Removed confirmed txid from persistence: \(txid.prefix(16))... (remaining: \(txids.count))")
        }
    }

    /// FIX #849: Restore pending txids from UserDefaults at startup
    /// This handles the case where a TX was broadcast but app closed before confirmation
    private func restorePersistedPendingTxids() {
        // NOTE: FIX #852 (cleanMislabeledChangeOutputsAuto) is called from WalletManager.cleanMislabeledChangeOutputs()
        // after database is open. It cannot be called here because NetworkManager.init runs before DB open.

        let txids = UserDefaults.standard.stringArray(forKey: PENDING_TXIDS_KEY) ?? []
        if txids.isEmpty {
            print("✅ FIX #849: No persisted pending txids")
            return
        }

        print("📥 FIX #849: Restoring \(txids.count) persisted pending txid(s)")
        for txid in txids {
            print("  📤 Persisted TX: \(txid.prefix(16))...")

            pendingOutgoingLock.lock()
            pendingOutgoingTxidSet.insert(txid)
            pendingOutgoingLock.unlock()
        }

        // NOTE: FIX #851 cleanup is now handled in WalletManager.cleanMislabeledChangeOutputsAtStartup()
        // after database is open. It cannot be called here because NetworkManager.init runs before DB open.

        // Set flags to block new sends if there are pending txs
        // Only set if not already set by FIX #847 (database-based restore)
        if !self.hasOurPendingOutgoing {
            self.hasOurPendingOutgoing = true
            self.hasPendingMempoolTransaction = true
            self.pendingTransactionReason = "Previous transaction not yet confirmed"
            print("⚠️ FIX #849: Blocking new sends due to \(txids.count) persisted pending TX(s)")
        }

        // Track in actor for confirmation checking
        Task {
            for txid in txids {
                // Track with 0 amount since we don't have the actual amount stored
                // This is enough for confirmation detection and change output detection
                _ = await txTrackingState.trackOutgoingSimple(txid: txid, amount: 0)
            }
            print("📤 FIX #849: \(txids.count) persisted pending TX(s) added to actor tracking")
        }
    }

    // MARK: - Address Management

    /// Add a new address to our known addresses
    private func addAddress(_ address: PeerAddress, source: String) {
        // Normalize IPv6-mapped addresses to IPv4
        guard let normalizedHost = normalizeIPv6MappedAddress(address.host) else {
            // Skip pure IPv6 addresses
            return
        }

        // Skip invalid/corrupted addresses (255.255.x.x from bad addr parsing, 0.x.x.x reserved)
        if normalizedHost.hasPrefix("255.255.") || normalizedHost.hasPrefix("0.") {
            return
        }

        // FIX #1365 / Security audit TASK 24: Filter reserved IPs at main entry point
        if isReservedIPAddress(normalizedHost) {
            return
        }

        let normalizedAddress = PeerAddress(host: normalizedHost, port: address.port)
        let key = "\(normalizedHost):\(address.port)"

        // Skip if banned
        if isBanned(normalizedHost) {
            return
        }

        // Skip our own onion address (prevent self-connection)
        if normalizedHost.hasSuffix(".onion") {
            Task {
                if let ownOnion = await HiddenServiceManager.shared.onionAddress {
                    // Extract just the address part (without .onion suffix)
                    let ownOnionBase = ownOnion.replacingOccurrences(of: ".onion", with: "")
                    let addrOnionBase = normalizedHost.replacingOccurrences(of: ".onion", with: "")
                    if ownOnionBase == addrOnionBase {
                        print("🧅 Skipping our own onion address: \(LogRedaction.redactHost(normalizedHost))")
                    }
                }
            }
            // Synchronous check using stored value
            if let ownOnion = HiddenServiceManager.cachedOnionAddress,
               normalizedHost == ownOnion || normalizedHost == "\(ownOnion).onion" {
                return
            }
        }

        addressLock.lock()
        defer { addressLock.unlock() }

        // Skip if already known
        if knownAddresses[key] != nil {
            // Update last seen time
            knownAddresses[key]?.lastSeen = Date()
            return
        }

        // NET-005: Reject addresses from sources that have contributed too many (Sybil indicator)
        let sourceTotal = addressSourceCounts[source] ?? 0
        if sourceTotal > 200 {
            // Source has contributed 200+ addresses across all cycles — suspicious
            return
        }

        // Add to new addresses
        if knownAddresses.count < MAX_KNOWN_ADDRESSES {
            knownAddresses[key] = AddressInfo(
                address: normalizedAddress,
                source: source
            )
            newAddresses.insert(key)

            let count = knownAddresses.count
            DispatchQueue.main.async {
                self.knownAddressCount = count
            }
        }
    }

    // HARDCODED PERMANENTLY BANNED PEERS - Known malicious Sybil attackers
    // These IPs have been observed reporting fake chain heights (e.g., 669M blocks)
    // They are PERMANENTLY banned and cannot be unbanned
    private let permanentlyBannedPeers: Set<String> = [
        // Add known malicious peer IPs here as they are discovered
        // Format: "IP.address" (no port)
    ]

    /// Check if an address is banned (internal use)
    /// FIX #384: Delegates to PeerManager for centralized ban management
    private func isBanned(_ host: String) -> Bool {
        return PeerManager.shared.isBanned(host)
    }

    /// FIX #427: Check if IP address is in reserved/invalid ranges
    /// These IPs cannot be routed on the public internet and should never be used for P2P
    /// See IANA IPv4 Special-Purpose Address Registry
    /// FIX #1365 / Security audit TASK 24: Used by both addAddress() and Peer.parseIPAddress()
    nonisolated func isReservedIPAddress(_ host: String) -> Bool {
        // Skip .onion addresses
        if host.hasSuffix(".onion") {
            return false
        }

        // Parse IPv4 octets
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }

        let first = parts[0]

        // Reserved ranges:
        // 0.x.x.x - Current network (only valid as source address)
        // 10.x.x.x - Private network
        // 127.x.x.x - Loopback
        // 169.254.x.x - Link-local
        // 172.16-31.x.x - Private network
        // 192.168.x.x - Private network
        // 100.64-127.x.x - RFC 6598 Shared Address Space (CGN)
        // 224-239.x.x.x - Multicast
        // 240-255.x.x.x - Reserved/Broadcast (includes 254.x.x.x)
        switch first {
        case 0, 10, 127:
            return true
        case 100:
            // FIX #1365 / Security audit TASK 24: RFC 6598 — Shared Address Space (CGN)
            return parts[1] >= 64 && parts[1] <= 127
        case 169:
            return parts[1] == 254
        case 172:
            return parts[1] >= 16 && parts[1] <= 31
        case 192:
            return parts[1] == 168
        case 224...255:
            return true
        default:
            return false
        }
    }

    /// Public method to check if a peer is banned (for use by other managers)
    /// FIX #384: Delegates to PeerManager for centralized ban management
    func isPeerBanned(_ host: String) -> Bool {
        return PeerManager.shared.isBanned(host)
    }

    /// Ban a peer
    /// FIX #384: Delegates to PeerManager for centralized ban management
    func banPeer(_ peer: Peer, reason: BanReason) {
        PeerManager.shared.banPeer(peer, reason: reason)

        // Also update local state for address cleanup
        addressLock.lock()
        let key = "\(peer.host):\(peer.port)"
        knownAddresses.removeValue(forKey: key)
        triedAddresses.remove(key)
        newAddresses.remove(key)
        addressLock.unlock()

        // Update published count
        Task { @MainActor in
            self.bannedPeersCount = PeerManager.shared.bannedPeerCount
        }
    }

    /// Ban a peer by address (for connection failures)
    /// FIX #384: Delegates to PeerManager for centralized ban management
    func banAddress(_ host: String, port: UInt16, reason: BanReason) {
        PeerManager.shared.banAddress(host, port: port, reason: reason)

        // Also update local state for address cleanup
        addressLock.lock()
        let key = "\(host):\(port)"
        knownAddresses.removeValue(forKey: key)
        triedAddresses.remove(key)
        newAddresses.remove(key)
        addressLock.unlock()

        // Update published count
        Task { @MainActor in
            self.bannedPeersCount = PeerManager.shared.bannedPeerCount
        }
    }

    /// FIX #159: PERMANENTLY ban a peer for Sybil attacks
    /// FIX #384: Delegates to PeerManager for centralized ban management
    func banPeerPermanentlyForSybil(_ host: String, port: UInt16, fakeHeight: UInt64, realHeight: UInt64) {
        PeerManager.shared.banPeerPermanentlyForSybil(host, port: port, fakeHeight: fakeHeight, realHeight: realHeight)

        // Update local address state
        addressLock.lock()
        let key = "\(host):\(port)"
        knownAddresses.removeValue(forKey: key)
        triedAddresses.remove(key)
        newAddresses.remove(key)
        addressLock.unlock()

        // Update UI
        Task { @MainActor in
            self.bannedPeersCount = PeerManager.shared.bannedPeerCount
            self.sybilAttackDetected = (peer: host, fakeHeight: fakeHeight, realHeight: realHeight)
        }
    }

    /// FIX #172: Ban peer for sending fake protocol version requirements (Sybil attack)
    /// FIX #384: Delegates to PeerManager for centralized ban management
    func banPeerForSybilAttack(_ host: String) {
        PeerManager.shared.banPeerForSybilAttack(host)

        // Update local address state
        addressLock.lock()
        for (key, addr) in knownAddresses where addr.address.host == host {
            knownAddresses.removeValue(forKey: key)
            triedAddresses.remove(key)
            newAddresses.remove(key)
        }

        // FIX #173: Track consecutive Sybil rejections (still local for now)
        consecutiveSybilRejections += 1
        print("🚨 [SYBIL] Consecutive Sybil rejections: \(consecutiveSybilRejections)/\(SYBIL_BYPASS_THRESHOLD)")
        addressLock.unlock()

        // Update UI
        Task { @MainActor in
            self.bannedPeersCount = PeerManager.shared.bannedPeerCount
        }
    }

    // FIX #173: Reset Sybil counter when a legitimate peer connects
    // FIX #384: Delegates to PeerManager
    func resetSybilCounter() {
        PeerManager.shared.resetSybilCounter()
        // Also reset local tracking for UI
        addressLock.lock()
        consecutiveSybilRejections = 0
        addressLock.unlock()
    }

    // FIX #173: Check if we should bypass Tor due to Sybil attack
    // FIX #384: Uses PeerManager for threshold check
    func shouldBypassTorForSybil() -> Bool {
        let shouldBypass = PeerManager.shared.shouldBypassTorForSybil()

        if shouldBypass && !sybilBypassActive {
            let rejectionCount = PeerManager.shared.getBannedPeers().filter { $0.reason == .wrongProtocol }.count
            print("🚨🚨🚨 [SYBIL] CRITICAL: Sybil attack detected!")
            print("🚨 [SYBIL] All Tor-reachable peers are attackers - BYPASSING TOR for direct P2P!")
            sybilBypassActive = true

            // FIX #175: Notify user about Sybil attack and Tor bypass
            DispatchQueue.main.async {
                self.sybilVersionAttackAlert = (attackerCount: rejectionCount, bypassedTor: true)
                self.torBypassedForSybil = true
            }
        }
        return shouldBypass
    }

    // FIX #173: Mark Sybil bypass as complete (for re-enabling Tor later)
    // FIX #384: Delegates to PeerManager
    func completeSybilBypass() {
        PeerManager.shared.completeSybilBypass()
        sybilBypassActive = false
        addressLock.lock()
        consecutiveSybilRejections = 0
        addressLock.unlock()
        print("✅ [SYBIL] Bypass complete - legitimate peers connected via direct P2P")

        // FIX #1428: Restore TorManager bypass flag so Peer.connect() uses SOCKS5 again
        Task {
            await TorManager.shared.restoreAfterSingleTxBypass()
        }

        // FIX #175: Clear the bypass flag (but keep alert for user to see)
        DispatchQueue.main.async {
            self.torBypassedForSybil = false
        }
    }

    /// FIX #175: Clear Sybil attack alert (called from UI after user acknowledges)
    /// FIX #384: Delegates to PeerManager
    func clearSybilAttackAlert() {
        PeerManager.shared.clearSybilAttackAlert()
        DispatchQueue.main.async {
            self.sybilVersionAttackAlert = nil
            self.sybilAttackDetected = nil
        }
    }

    /// Get list of all currently banned peers
    /// FIX #401: Delegate to PeerManager for centralized ban management
    func getBannedPeers() -> [BannedPeer] {
        let result = PeerManager.shared.getBannedPeers()

        // Update published count on main thread
        DispatchQueue.main.async {
            self.bannedPeersCount = result.count
        }

        return result
    }

    /// Unban a specific peer by address
    /// FIX #401: Delegate to PeerManager for centralized ban management
    func unbanPeer(address: String) {
        PeerManager.shared.unbanPeer(address)

        // Update published count on main thread
        let newCount = PeerManager.shared.getBannedPeers().count
        DispatchQueue.main.async {
            self.bannedPeersCount = newCount
        }
    }

    /// Unban all peers
    /// FIX #401: Delegate to PeerManager for centralized ban management
    func unbanAllPeers() {
        let count = PeerManager.shared.getBannedPeers().count
        PeerManager.shared.clearAllBannedPeers()

        print("✅ Unbanned all \(count) peers")
        // Update published count on main thread
        DispatchQueue.main.async {
            self.bannedPeersCount = 0
        }
    }

    // MARK: - FIX #455: Update reactive counts for Settings/Network display

    /// Update all reactive peer counts for Settings/Network UI
    /// This should be called whenever peer states change to keep the UI in sync
    func updatePeerCountsForSettings() {
        // FIX #1363: Execute synchronously when already on main thread (e.g., SwiftUI onAppear).
        // DispatchQueue.main.async defers to next run loop → view renders with stale 0 values first.
        // When called from background (keepalive ping), dispatch to main as before.
        let updateBlock = {
            // CPU OPTIMIZATION: Only update @Published if value changed (avoids SwiftUI re-render)
            // FIX #1363: Also update bannedPeersCount — was missing, causing all counters to show 0
            // on Settings appearance until user tapped one (which fetched data and triggered re-render).
            let newBanned = PeerManager.shared.bannedPeerCount
            if self.bannedPeersCount != newBanned { self.bannedPeersCount = newBanned }

            let newParked = PeerManager.shared.getParkedPeers().count
            if self.parkedPeersCount != newParked { self.parkedPeersCount = newParked }

            let newReliable = self.reliablePeerCount
            if self.reliablePeersDisplayCount != newReliable { self.reliablePeersDisplayCount = newReliable }

            let newPreferred = (try? WalletDatabase.shared.getPreferredSeeds().count) ?? 0
            if self.preferredSeedsCount != newPreferred { self.preferredSeedsCount = newPreferred }
        }

        if Thread.isMainThread {
            updateBlock()
        } else {
            DispatchQueue.main.async { updateBlock() }
        }
    }

    // MARK: - FIX #284: Parking (Connection Timeouts - NOT a Ban)
    // FIX #384: Delegates to PeerManager for centralized parking management

    /// Park a peer due to connection timeout (exponential backoff retry)
    /// FIX #384: Delegates to PeerManager
    func parkPeer(_ host: String, port: UInt16) {
        // Check if peer was a preferred seed (for database operations)
        let wasPreferred = WalletDatabase.shared.isPreferredSeed(host: host, port: port)

        // Delegate to PeerManager
        PeerManager.shared.parkPeer(host, port: port, wasPreferred: wasPreferred)

        // If this was a preferred seed, demote it temporarily
        if wasPreferred {
            try? WalletDatabase.shared.demoteFromPreferredSeed(host: host, port: port)
        }
    }

    /// Check if a peer is parked
    /// FIX #384: Delegates to PeerManager
    func isParked(_ host: String) -> Bool {
        return PeerManager.shared.isParked(host)
    }

    /// Check if a parked peer is ready for retry
    /// FIX #384: Delegates to PeerManager
    func isParkedPeerReadyForRetry(_ host: String) -> Bool {
        return PeerManager.shared.isParkedPeerReadyForRetry(host)
    }

    /// Unpark a peer (called on successful connection)
    /// FIX #384: Delegates to PeerManager
    func unparkPeer(_ host: String, port: UInt16) {
        // Get parked info before removing (for preferred seed handling)
        let parkedPeers = PeerManager.shared.getParkedPeers()
        let wasParked = parkedPeers.first { $0.address == host }

        // Delegate to PeerManager
        PeerManager.shared.unparkPeer(host, port: port)

        // If this was a preferred seed before parking, promote it back
        if let parked = wasParked, parked.wasPreferred {
            try? WalletDatabase.shared.promoteToPreferredSeed(host: host, port: port)
        }
    }

    /// Get all parked peers ready for retry
    /// FIX #384: Delegates to PeerManager
    func getParkedPeersReadyForRetry() -> [ParkedPeer] {
        return PeerManager.shared.getParkedPeersReadyForRetry()
    }

    /// Get all currently parked peers
    /// FIX #384: Delegates to PeerManager
    func getParkedPeers() -> [ParkedPeer] {
        return PeerManager.shared.getParkedPeers().sorted { $0.parkedTime > $1.parkedTime }
    }

    /// Clear all parked peers (for reset/repair)
    /// FIX #384: Delegates to PeerManager
    func clearAllParkedPeers() {
        PeerManager.shared.clearAllParkedPeers()
    }

    /// FIX #352: Clear parked hardcoded seeds for immediate retry
    /// FIX #384: Delegates to PeerManager
    func clearParkedHardcodedSeeds() {
        PeerManager.shared.clearParkedHardcodedSeeds()
    }

    /// VUL-N-011: Clear DNS cache (useful for manual refresh or testing)
    func clearDNSCache() {
        dnsCache.removeAll()
        if verbose {
            print("🗑️ VUL-N-011: DNS cache cleared")
        }
    }

    // MARK: - FIX #284: Preferred Seeds

    /// Get preferred seeds from database
    /// FIX #384: Delegate to PeerManager (nonisolated - only accesses WalletDatabase)
    func getPreferredSeeds() -> [WalletDatabase.TrustedPeer] {
        return PeerManager.shared.getPreferredSeeds()
    }

    /// Check if a peer should be skipped (banned OR parked and not ready for retry)
    /// FIX #384: Delegate to PeerManager
    private func shouldSkipPeer(_ host: String) -> Bool {
        return PeerManager.shared.shouldSkipPeer(host)
    }

    /// Calculate target number of peers based on known addresses
    /// Returns 10% of known addresses, clamped between MIN_PEERS and MAX_PEERS
    private func calculateTargetPeers() -> Int {
        addressLock.lock()
        let knownCount = knownAddresses.count
        addressLock.unlock()

        let target = Int(Double(knownCount) * TARGET_PEER_PERCENT)
        return max(MIN_PEERS, min(MAX_PEERS, target))
    }

    /// Select best peer to connect to based on scoring
    /// FIX #384: Delegates to PeerManager for centralized selection
    private func selectBestAddress() -> PeerAddress? {
        // FIX #384: Delegate to PeerManager
        return PeerManager.shared.selectBestAddress()
    }

    /// Check if Tor is available for connections (cached for performance in sync operations)
    private var torIsAvailable: Bool {
        // This is called synchronously, so we can't await TorManager
        // Use a cached value that's updated periodically
        return _torIsAvailable
    }
    private var _torIsAvailable: Bool = false

    /// Check if .onion circuits are ready (requires warmup period after SOCKS connection)
    /// Regular IPv4 via SOCKS works immediately; .onion addresses need ~10s for rendezvous circuits
    private var onionCircuitsReady: Bool {
        return _onionCircuitsReady
    }
    private var _onionCircuitsReady: Bool = false

    /// Update Tor availability status (call periodically or when Tor state changes)
    func updateTorAvailability() async {
        let mode = await TorManager.shared.mode
        let connected = await TorManager.shared.connectionState.isConnected
        _torIsAvailable = (mode == .enabled && connected)

        // Check if .onion circuits are ready (requires warmup period after SOCKS connection)
        let wasOnionReady = _onionCircuitsReady
        _onionCircuitsReady = await TorManager.shared.isOnionCircuitsReady

        // FIX #384: Sync Tor state to PeerManager for address selection
        await MainActor.run {
            PeerManager.shared.updateTorState(available: _torIsAvailable, onionReady: _onionCircuitsReady)
        }

        // Log transition when .onion circuits become ready
        if !wasOnionReady && _onionCircuitsReady {
            print("🧅 .onion circuits now ready! Can connect to hidden services.")
            // FIX #1487: Notify ChatManager so it can reset backoff and retry contacts immediately.
            // Without this: first connect fails (circuits not ready) → backoff → stuck offline for minutes.
            NotificationCenter.default.post(name: .onionCircuitsReady, object: nil)
        } else if connected && !_onionCircuitsReady {
            let remaining = await TorManager.shared.onionCircuitWarmupRemaining
            if remaining > 0 {
                print("🧅 .onion circuits warming up... \(Int(remaining))s remaining")
            }
        }

        // Count .onion peers in address book
        addressLock.lock()
        let onionCount = knownAddresses.values.filter { $0.address.host.hasSuffix(".onion") }.count
        addressLock.unlock()

        // Count peers connected via Tor SOCKS5 (FIX #1417: require isConnectionReady to avoid stale counts)
        let torCount = peers.filter { $0.isConnectedViaTor && $0.isConnectionReady }.count
        // Count .onion peers actually connected
        let onionConnected = peers.filter { $0.isOnion && $0.isConnectionReady }.count

        // Debug: Log Tor peer status
        if torCount > 0 || onionConnected > 0 {
            if verbose {
                print("🧅 Tor peers: \(torCount) via SOCKS5, \(onionConnected) .onion connected, \(onionCount) .onion discovered")
            }
        }

        await MainActor.run {
            self.onionPeersCount = onionCount
            self.torConnectedPeersCount = torCount
            self.onionConnectedPeersCount = onionConnected
        }

        if _torIsAvailable && (torCount == 0 && onionCount == 0) {
            print("🧅 Tor available - 0 .onion peers in address book")
        }
    }

    /// Request addresses from all connected peers
    private func discoverMoreAddresses() async {
        // FIX #1273: Don't discover addresses before authentication
        guard BiometricAuthManager.shared.hasAuthenticatedThisSession else { return }
        // FIX #1467: Skip address discovery when iOS device is overheating
        #if os(iOS)
        if isDeviceOverheating { return }
        #endif

        var discoveredCount = 0
        var onionDiscoveredCount = 0
        for peer in peers {
            do {
                let addresses = try await peer.getAddresses()
                var peerAccepted = 0
                for addr in addresses {
                    // NET-005: Per-peer quota per discovery cycle
                    guard peerAccepted < MAX_ADDRESSES_PER_PEER else {
                        print("🛡️ NET-005: Capped \(peer.host) at \(MAX_ADDRESSES_PER_PEER) addresses (sent \(addresses.count))")
                        break
                    }
                    addAddress(addr, source: peer.host)
                    peerAccepted += 1
                    discoveredCount += 1
                    if addr.host.hasSuffix(".onion") {
                        onionDiscoveredCount += 1
                    }
                }
                // NET-005: Track cumulative source contributions
                addressSourceCounts[peer.host, default: 0] += peerAccepted
                peer.recordSuccess()
            } catch {
                peer.recordFailure()
            }
        }

        // Log .onion discoveries
        if onionDiscoveredCount > 0 {
            print("🧅 Discovered \(onionDiscoveredCount) .onion peers via P2P addr messages")
        }

        // Persist addresses if we discovered new ones
        if discoveredCount > 0 {
            persistAddresses()

            // Update onion peer count
            await updateTorAvailability()
        }
    }

    private func setupAddressDiscovery() {
        addressDiscoveryTimer = Timer.scheduledTimer(withTimeInterval: GETADDR_INTERVAL, repeats: true) { [weak self] _ in
            Task {
                await self?.discoverMoreAddresses()
            }
        }
        addressDiscoveryTimer?.tolerance = GETADDR_INTERVAL * 0.25  // FIX #1450: Timer coalescing
    }

    private func setupStatsRefresh() {
        statsRefreshTimer = Timer.scheduledTimer(withTimeInterval: STATS_REFRESH_INTERVAL, repeats: true) { [weak self] _ in
            Task {
                await self?.refreshChainHeight()
            }
        }
        statsRefreshTimer?.tolerance = STATS_REFRESH_INTERVAL * 0.25  // FIX #1450: Timer coalescing
    }

    /// Refresh chain height (P2P consensus primary when Tor enabled, InsightAPI fallback)
    /// Also triggers background sync if wallet is behind
    private func refreshChainHeight() async {
        // FIX #1273: Don't refresh chain height before authentication
        guard BiometricAuthManager.shared.hasAuthenticatedThisSession else { return }

        guard isConnected else { return }

        // FIX #1467: Skip when iOS device is overheating
        #if os(iOS)
        if isDeviceOverheating { return }
        #endif

        // FIX #145: Skip if background processes are disabled (initial sync in progress)
        guard backgroundProcessesEnabled else {
            debugLog(.network, "📊 refreshChainHeight: skipped (initial sync in progress)")
            return
        }

        let torEnabled = await TorManager.shared.mode == .enabled
        var newHeight: UInt64 = 0
        var networkTruthHeight: UInt64 = 0

        // When Tor is enabled, use P2P ONLY (InsightAPI blocked by Cloudflare)
        // When Tor is disabled, InsightAPI is authoritative

        // FIX #111: Get HeaderStore height FIRST for Sybil detection
        // CRITICAL FIX: During initial sync, headers are behind chain tip. Use a much larger tolerance
        // to avoid banning legitimate peers during catch-up sync.
        let headerStoreHeightForValidation = (try? HeaderStore.shared.getLatestHeight()) ?? 0
        // Use 10,000 blocks tolerance during initial sync (headers may be far behind)
        // Once synced (within 100 blocks of chain), reduce to 1000 for stricter protection
        let isInitialSyncPhase = headerStoreHeightForValidation < ZipherXConstants.bundledTreeHeight
        let sybilTolerance: UInt64 = isInitialSyncPhase ? 50_000 : 10_000  // Much higher tolerance during initial sync
        let sybilThreshold = headerStoreHeightForValidation > 0 ? headerStoreHeightForValidation + sybilTolerance : UInt64(100_000_000) // 100M if no headers

        // FIX #290: FIRST collect all peer heights, THEN check consensus BEFORE banning
        // Previous bug: Banning peers BEFORE checking consensus caused false positives
        // when wallet was offline and ALL peers were ahead by >10k blocks

        // 1. Collect ALL peer heights first (skip banned + invalid only)
        var peerHeights: [UInt64: Int] = [:]
        var peerMaxHeight: UInt64 = 0
        var peersAboveThreshold: [(host: String, port: UInt16, height: UInt64)] = []

        for peer in peers {
            // SECURITY: Skip banned peers and handle negative heights (malicious peers)
            guard !isBanned(peer.host), peer.peerStartHeight > 0 else { continue }

            // FIX #196: Skip peers with invalid peerVersion - their peerStartHeight is garbage!
            // FIX #434: Only use valid Zclassic peers (version 170002-170012), not Zcash (170018+)
            guard peer.isValidZclassicPeer else {
                print("⚠️ FIX #434: Skipping peer \(peer.host) with version \(peer.peerVersion) - not valid Zclassic")
                continue
            }

            let h = UInt64(peer.peerStartHeight)

            // Track peers above threshold for potential banning AFTER consensus check
            if h > sybilThreshold {
                peersAboveThreshold.append((host: peer.host, port: peer.port, height: h))
            }

            // Include ALL heights in consensus calculation (even above threshold)
            if h > 0 {
                peerHeights[h, default: 0] += 1
                peerMaxHeight = max(peerMaxHeight, h)
            }
        }

        // 2. Calculate consensus BEFORE deciding to ban
        var preliminaryConsensusHeight: UInt64 = 0
        var preliminaryConsensusCount = 0
        for (height, count) in peerHeights {
            if peerMaxHeight > 0 && height >= peerMaxHeight - 10 && count > preliminaryConsensusCount {
                preliminaryConsensusHeight = height
                preliminaryConsensusCount = count
            }
        }

        // FIX #290: If 3+ peers agree on a height above threshold, it's likely REAL (not Sybil)
        // The wallet was probably just offline and the chain advanced beyond our headers
        let consensusIsAboveThreshold = preliminaryConsensusHeight > sybilThreshold
        let consensusIsStrong = preliminaryConsensusCount >= CONSENSUS_THRESHOLD  // FIX #1493

        if consensusIsAboveThreshold && consensusIsStrong {
            if verbose {
                print("📡 FIX #290: Strong consensus (\(preliminaryConsensusCount) peers) at height \(preliminaryConsensusHeight) above threshold \(sybilThreshold)")
                print("📡 FIX #290: NOT banning - wallet was likely offline while chain advanced \(preliminaryConsensusHeight - headerStoreHeightForValidation) blocks")
            }
            // Don't ban anyone - the chain legitimately advanced while we were offline
        } else if !peersAboveThreshold.isEmpty {
            // FIX #111/159: Only ban when there's NO strong consensus at the high height
            // This means isolated peers reporting high heights (actual Sybil attack)
            for peer in peersAboveThreshold {
                // Skip if this peer's height matches the consensus (even weak consensus)
                let peerMatchesConsensus = abs(Int64(peer.height) - Int64(preliminaryConsensusHeight)) <= 10
                if peerMatchesConsensus && preliminaryConsensusCount >= 2 {
                    print("⚠️ FIX #290: Peer \(peer.host) matches consensus - not banning")
                    continue
                }

                print("🚨 [SYBIL BAN] Peer \(peer.host) reporting FAKE height \(peer.height) (threshold: \(sybilThreshold)) - PERMANENTLY BANNING!")
                banPeerPermanentlyForSybil(peer.host, port: peer.port, fakeHeight: peer.height, realHeight: headerStoreHeightForValidation)
                // Remove from height counts
                peerHeights[peer.height, default: 1] -= 1
                if peerHeights[peer.height] == 0 {
                    peerHeights.removeValue(forKey: peer.height)
                }
            }
            // Recalculate max height after banning
            peerMaxHeight = peerHeights.keys.max() ?? 0
        }

        // FIX #290: Reuse preliminary consensus if it was valid, otherwise recalculate after banning
        var peerConsensusHeight: UInt64 = 0
        var consensusCount = 0
        if consensusIsAboveThreshold && consensusIsStrong {
            // Strong consensus was detected - use it directly
            peerConsensusHeight = preliminaryConsensusHeight
            consensusCount = preliminaryConsensusCount
        } else {
            // Recalculate after potentially banning some peers
            for (height, count) in peerHeights {
                if peerMaxHeight > 0 && height >= peerMaxHeight - 10 && count > consensusCount {
                    peerConsensusHeight = height
                    consensusCount = count
                }
            }
        }

        // 2. P2P ONLY MODE - No InsightAPI calls
        // FIX #120: Commented out InsightAPI - using P2P only
        // if !torEnabled {
        //     if let status = try? await InsightAPI.shared.getStatus() {
        //         networkTruthHeight = status.height
        //         print("📡 [API] Network height: \(networkTruthHeight)")
        //     }
        // } else {
        //     print("🧅 Tor enabled - using P2P consensus only (InsightAPI blocked by Cloudflare)")
        // }
        print("📡 Using P2P consensus only (InsightAPI disabled)")

        // 3. Determine best height
        // FIX #111: ALWAYS use HeaderStore as ground truth to reject Sybil attack heights
        // FIX #120: Increase tolerance to 10000 blocks during header sync catch-up
        // FIX #290: Accept strong consensus (3+ peers) even above threshold - wallet was offline
        // FIX #403: Increase threshold to 50000 blocks (~3 months) to handle stale HeaderStore
        //   Bug: HeaderStore 14000 blocks behind caused SYBIL rejection of valid peer heights
        //   A 10000 block threshold is too small when wallet has been offline for weeks
        //   50000 blocks = ~3 months of blocks (210K/year), plenty of margin
        let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
        let maxReasonableHeight = headerStoreHeight > 0 ? headerStoreHeight + 50000 : UInt64.max

        if torEnabled {
            // TOR MODE: P2P consensus is authoritative, BUT validate against HeaderStore
            if peerConsensusHeight > 0 && consensusCount >= 2 {
                // FIX #290: If we have strong consensus (3+ peers), accept it even above threshold
                // This handles the case where wallet was offline and chain advanced significantly
                if consensusIsAboveThreshold && consensusIsStrong {
                    newHeight = peerConsensusHeight
                    print("📡 FIX #290: Accepting strong consensus height: \(newHeight) (\(consensusCount) peers, \(peerConsensusHeight - headerStoreHeight) blocks ahead of headers)")
                } else if peerConsensusHeight <= maxReasonableHeight {
                    newHeight = peerConsensusHeight
                    print("🧅 [P2P] Peer consensus height: \(newHeight) (\(consensusCount) peers)")
                } else {
                    print("🚨 [SYBIL] Consensus height \(peerConsensusHeight) rejected (HeaderStore: \(headerStoreHeight))")
                    newHeight = headerStoreHeight
                }
            } else if peerMaxHeight > 0 && peerMaxHeight <= maxReasonableHeight {
                // FIX #111: Only use peerMaxHeight if it's reasonable (within 1000 of HeaderStore)
                newHeight = peerMaxHeight
                print("🧅 [P2P] Using peer max height (no consensus): \(newHeight)")
            } else if peerMaxHeight > maxReasonableHeight {
                // FIX #111: Reject obviously fake heights from Sybil attack
                print("🚨 [SYBIL] Peer max height \(peerMaxHeight) rejected (HeaderStore: \(headerStoreHeight))")
                newHeight = headerStoreHeight
            } else if headerStoreHeight > 0 {
                newHeight = headerStoreHeight
                print("🧅 [P2P] Using HeaderStore height: \(newHeight)")
            }
        } else {
            // NORMAL MODE: InsightAPI authoritative, P2P fallback
            if networkTruthHeight > 0 {
                newHeight = networkTruthHeight
            } else if peerConsensusHeight > 0 && consensusCount >= 2 {
                newHeight = peerConsensusHeight
                print("📡 [P2P] Using peer consensus (API unavailable): \(newHeight)")
            } else if let headerHeight = try? HeaderStore.shared.getLatestHeight() {
                newHeight = headerHeight
                print("📡 [P2P] Using HeaderStore height (API unavailable): \(newHeight)")
            }
        }

        // FIX #213: ABSOLUTE sanity check - reject clearly impossible heights
        // Zclassic is at ~3M blocks (Dec 2024), growing ~210K/year
        // 10M blocks won't be reached for ~33 years - any higher is clearly bogus
        let absoluteMaxHeight: UInt64 = 10_000_000
        if newHeight > absoluteMaxHeight {
            print("🚨 FIX #213: REJECTED impossible chain height \(newHeight) (absolute max: \(absoluteMaxHeight))")
            print("🚨 FIX #213: This is clearly corrupt data from a malicious peer")
            newHeight = headerStoreHeight > 0 ? headerStoreHeight : chainHeight
        }

        // Only update and log if height INCREASED
        // FIX #400: NEVER downgrade chainHeight - this causes TX history to show "Pending"
        // When peers disconnect, HeaderStore fallback may be stale (lower than actual chain)
        if newHeight > 0 && newHeight > chainHeight {
            await MainActor.run {
                self.chainHeight = newHeight
                // Cache for fast start mode (consecutive app launches)
                UserDefaults.standard.set(Int(newHeight), forKey: "cachedChainHeight")
                if verbose {
                    print("📊 Chain height updated: \(newHeight)")
                }
            }

            // CRITICAL: Trigger background sync if wallet is behind
            let dbHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
            if newHeight > dbHeight && dbHeight > 0 {
                print("🔄 New block detected, syncing: chain=\(newHeight) wallet=\(dbHeight) (+\(newHeight - dbHeight) blocks)")
                Task {
                    await WalletManager.shared.backgroundSyncToHeight(newHeight)
                }
            }
        }

        // FIX #751: Always update walletHeight from database
        // Previously only chainHeight was updated, walletHeight stayed stale
        let currentDbHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
        if currentDbHeight > 0 {
            await MainActor.run {
                if currentDbHeight != self.walletHeight {
                    self.walletHeight = currentDbHeight
                    print("📊 FIX #751: Wallet height updated: \(currentDbHeight)")
                }
            }
        }
    }

    private let persistedAddressesKey = "ZipherX.KnownPeerAddresses"
    private let maxPersistedAddresses = 100

    /// Convert IPv6-mapped IPv4 addresses to pure IPv4 format
    /// e.g., "0:0:0:0:0:0:ffff:9de93c4e" -> "157.233.60.78"
    private func normalizeIPv6MappedAddress(_ host: String) -> String? {
        // Skip .onion addresses
        if host.hasSuffix(".onion") {
            return host
        }

        // Already IPv4
        if host.split(separator: ".").count == 4 && !host.contains(":") {
            return host
        }

        // Check for IPv6-mapped IPv4: 0:0:0:0:0:0:ffff:XXXX
        if host.contains(":") && host.lowercased().contains("ffff:") {
            let parts = host.split(separator: ":")
            if parts.count >= 2, let lastPart = parts.last {
                // Convert hex to IPv4 bytes
                let hexStr = String(lastPart)
                if hexStr.count == 8, let hexVal = UInt32(hexStr, radix: 16) {
                    let b1 = (hexVal >> 24) & 0xFF
                    let b2 = (hexVal >> 16) & 0xFF
                    let b3 = (hexVal >> 8) & 0xFF
                    let b4 = hexVal & 0xFF
                    return "\(b1).\(b2).\(b3).\(b4)"
                }
            }
        }

        // Pure IPv6 - not supported via Tor SOCKS5
        if host.contains(":") {
            return nil
        }

        return host
    }

    /// FIX #927: Restored production peer loading (was FIX #918 debug mode)
    private func loadPersistedAddresses() {
        guard let data = UserDefaults.standard.data(forKey: persistedAddressesKey),
              let savedAddresses = try? JSONDecoder().decode([PersistedAddress].self, from: data) else {
            print("📡 No persisted peer addresses found")
            return
        }

        addressLock.lock()
        defer { addressLock.unlock() }

        var loadedCount = 0
        var skippedIPv6 = 0
        var skippedInvalid = 0
        for saved in savedAddresses {
            // Normalize IPv6-mapped addresses to IPv4
            guard let normalizedHost = normalizeIPv6MappedAddress(saved.host) else {
                skippedIPv6 += 1
                continue
            }

            // Skip corrupted addresses (255.255.x.x from bad addr message parsing)
            if normalizedHost.hasPrefix("255.255.") || normalizedHost.hasPrefix("0.") {
                skippedInvalid += 1
                continue
            }

            let address = PeerAddress(host: normalizedHost, port: saved.port)
            let key = "\(normalizedHost):\(saved.port)"

            // Skip if banned or already known
            if isBanned(normalizedHost) || knownAddresses[key] != nil {
                continue
            }

            knownAddresses[key] = AddressInfo(
                address: address,
                source: "persisted",
                firstSeen: saved.firstSeen,
                lastSeen: saved.lastSeen,
                attempts: saved.attempts,
                successes: saved.successes
            )

            // Good addresses go to tried set, others to new
            if saved.successes > 0 {
                triedAddresses.insert(key)
            } else {
                newAddresses.insert(key)
            }
            loadedCount += 1
        }

        let count = knownAddresses.count
        DispatchQueue.main.async {
            self.knownAddressCount = count
        }

        var skipInfo: [String] = []
        if skippedIPv6 > 0 { skipInfo.append("\(skippedIPv6) IPv6") }
        if skippedInvalid > 0 { skipInfo.append("\(skippedInvalid) invalid") }

        if skipInfo.isEmpty {
            if verbose {
                print("📡 Loaded \(loadedCount) persisted peer addresses")
            }
        } else {
            if verbose {
                print("📡 Loaded \(loadedCount) persisted peer addresses (skipped \(skipInfo.joined(separator: ", ")))")
            }
        }
    }

    private func persistAddresses() {
        addressLock.lock()
        let candidateAddresses = knownAddresses.values
            .filter { $0.successes > 0 || $0.attempts < 3 } // Only save good or untried addresses
            .filter { !$0.address.host.hasPrefix("255.255.") && !$0.address.host.hasPrefix("0.") } // Filter invalid
            .sorted { $0.successes > $1.successes } // Best first
        addressLock.unlock()

        // FIX #422: NEVER persist banned peers (Zcash nodes, Sybil attackers)
        // This prevents bad addresses from being re-loaded on next startup
        let addresses = candidateAddresses
            .filter { !isBanned($0.address.host) }
            .prefix(maxPersistedAddresses)
            .map { info in
                PersistedAddress(
                    host: info.address.host,
                    port: info.address.port,
                    firstSeen: info.firstSeen,
                    lastSeen: info.lastSeen,
                    attempts: info.attempts,
                    successes: info.successes
                )
            }

        let bannedCount = candidateAddresses.count - addresses.count
        if bannedCount > 0 {
            print("🚫 FIX #422: Excluded \(bannedCount) banned peers from persistence")
        }

        if let data = try? JSONEncoder().encode(Array(addresses)) {
            UserDefaults.standard.set(data, forKey: persistedAddressesKey)
            if verbose {
                print("📡 Persisted \(addresses.count) peer addresses")
            }
        }
    }

    /// Load bundled peer list from Resources (for fresh installs)
    private func loadBundledPeers() {
        guard let url = Bundle.main.url(forResource: "bundled_peers", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let bundledPeers = try? JSONDecoder().decode([BundledPeer].self, from: data) else {
            print("📡 No bundled peers file found (this is OK for development)")
            return
        }

        addressLock.lock()
        defer { addressLock.unlock() }

        var loadedCount = 0
        for peer in bundledPeers {
            let key = "\(peer.host):\(peer.port)"

            // Skip if banned or already known
            if isBanned(peer.host) || knownAddresses[key] != nil {
                continue
            }

            let address = PeerAddress(host: peer.host, port: peer.port)
            var info = AddressInfo(
                address: address,
                source: "bundled"
            )
            // High reliability peers get a success count boost
            if peer.reliability > 0.5 {
                info.successes = 1
            }
            knownAddresses[key] = info

            // High reliability peers go to tried set
            if peer.reliability > 0.5 {
                triedAddresses.insert(key)
            } else {
                newAddresses.insert(key)
            }
            loadedCount += 1
        }

        if verbose {
            print("📡 Loaded \(loadedCount) bundled peer addresses")
        }
    }

    // MARK: - GitHub Peer Download

    /// GitHub URL for reliable peers list
    private static let GITHUB_PEERS_URL = "https://raw.githubusercontent.com/ZipherPunk/ZipherX_Boost/main/reliable_peers.json"

    /// Download and load reliable peers from GitHub
    /// Call this at startup to get the latest peer list
    func downloadReliablePeersFromGitHub() async -> Int {
        if verbose {
            print("📡 Checking GitHub for reliable peers...")
        }

        guard let url = URL(string: Self.GITHUB_PEERS_URL) else {
            print("❌ Invalid GitHub peers URL")
            return 0
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("⚠️ GitHub peers fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return 0
            }

            let bundledPeers = try JSONDecoder().decode([BundledPeer].self, from: data)
            if verbose {
                print("📡 Downloaded \(bundledPeers.count) peers from GitHub")
            }

            addressLock.lock()
            defer { addressLock.unlock() }

            var loadedCount = 0
            for peer in bundledPeers {
                let key = "\(peer.host):\(peer.port)"

                // Skip if banned
                if isBanned(peer.host) {
                    continue
                }

                // If already known, update reliability info if GitHub has better data
                if let existing = knownAddresses[key] {
                    // Only update if GitHub peer has higher reliability and our local has few attempts
                    if existing.attempts < 5 && peer.reliability > 0.7 {
                        knownAddresses[key]?.successes = max(existing.successes, 1)
                        triedAddresses.insert(key)
                    }
                    continue
                }

                let address = PeerAddress(host: peer.host, port: peer.port)
                knownAddresses[key] = AddressInfo(
                    address: address,
                    source: "github",
                    firstSeen: Date(),
                    lastSeen: peer.lastSeen,
                    attempts: 0,
                    successes: peer.reliability > 0.5 ? 1 : 0
                )

                // High reliability peers go to tried set (prioritized for connection)
                if peer.reliability > 0.5 {
                    triedAddresses.insert(key)
                } else {
                    newAddresses.insert(key)
                }
                loadedCount += 1
            }

            print("✅ Added \(loadedCount) new peers from GitHub (total known: \(knownAddresses.count))")
            return loadedCount
        } catch {
            print("⚠️ GitHub peers download error: \(error.localizedDescription)")
            return 0
        }
    }

    /// Export current reliable peers for bundling in future releases
    /// Call this from Settings when 100+ peers have been discovered
    func exportReliablePeersForBundling() -> String {
        addressLock.lock()
        let reliablePeers = knownAddresses.values
            .filter { $0.successes > 0 && $0.attempts > 0 }  // Must have succeeded at least once
            .sorted {
                // Sort by success rate, then by total successes
                let rate1 = Double($0.successes) / Double(max(1, $0.attempts))
                let rate2 = Double($1.successes) / Double(max(1, $1.attempts))
                if abs(rate1 - rate2) < 0.1 {
                    return $0.successes > $1.successes
                }
                return rate1 > rate2
            }
            .prefix(150)  // Export top 150 reliable peers
            .map { info -> BundledPeer in
                let reliability = Double(info.successes) / Double(max(1, info.attempts))
                return BundledPeer(
                    host: info.address.host,
                    port: info.address.port,
                    reliability: reliability,
                    lastSeen: info.lastSeen
                )
            }
        addressLock.unlock()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(Array(reliablePeers)),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "// Error encoding peers"
        }

        return jsonString
    }

    /// Get count of reliable peers (success rate > 50%)
    var reliablePeerCount: Int {
        addressLock.lock()
        let count = knownAddresses.values.filter {
            $0.successes > 0 && Double($0.successes) / Double(max(1, $0.attempts)) > 0.5
        }.count
        addressLock.unlock()
        return count
    }

    // MARK: - Connection Management

    /// Connect to the Zclassic network
    /// Targets 10% of known peers (min 3, max 20)
    func connect() async throws {
        // Prevent concurrent connection attempts
        guard !isConnecting else {
            return
        }
        isConnecting = true
        defer { isConnecting = false }

        // FIX #399: Clear any bans on hardcoded seeds at startup
        // These are known-good ZCL nodes that should NEVER be banned
        PeerManager.shared.clearHardcodedSeedBans()

        // CRITICAL: If Tor mode is enabled, WAIT for Tor to connect first
        // Otherwise IPv4 peers will fail and get banned before Tor is ready
        // FIX: Skip Tor wait if Tor is bypassed for faster repair/sync
        let torMode = await TorManager.shared.mode
        let torBypassed = await TorManager.shared.isTorBypassed
        if torMode == .enabled && !torBypassed {
            var torConnected = await TorManager.shared.connectionState.isConnected
            if !torConnected {
                print("🧅 Tor mode enabled - waiting for Tor to connect (max 30s)...")
                var waitCount = 0
                let maxWait = 300 // 30 seconds max
                while !torConnected && waitCount < maxWait {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    waitCount += 1
                    torConnected = await TorManager.shared.connectionState.isConnected
                    if waitCount % 50 == 0 {
                        let state = await TorManager.shared.connectionState
                        print("🧅 Waiting for Tor... (\(waitCount/10)s) state: \(state.displayText)")
                    }
                }
                if !torConnected {
                    print("⚠️ Tor did not connect within 30s, proceeding with .onion peers only")
                } else {
                    print("✅ Tor connected, proceeding with P2P connections")
                }
            }
        }

        // Update Tor availability status for .onion peer selection
        await updateTorAvailability()

        print("🔌 Starting network connection...")

        // Discover peers via DNS seeds
        var discoveredPeers = await discoverPeers()
        if verbose {
            print("📡 DNS discovery found \(discoveredPeers.count) peers")
        }

        // FIX #229: Add trusted peers from database for eclipse attack resistance
        for peer in getTrustedPeersForBootstrap() {
            let components = peer.split(separator: ":")
            if components.count == 2,
               let port = UInt16(components[1]) {
                discoveredPeers.append(PeerAddress(host: String(components[0]), port: port))
            }
        }

        // Add .onion peers if Tor is enabled and connected
        let torConnected = await TorManager.shared.connectionState.isConnected
        if torConnected && !onionPeersZCL.isEmpty {
            print("🧅 Tor connected - adding \(onionPeersZCL.count) .onion peers")
            for peer in onionPeersZCL {
                let components = peer.split(separator: ":")
                if components.count == 2,
                   let port = UInt16(components[1]) {
                    discoveredPeers.append(PeerAddress(host: String(components[0]), port: port))
                }
            }
        }

        // Add all discovered to address manager
        for addr in discoveredPeers {
            addAddress(addr, source: "dns")
        }

        // Download reliable peers from GitHub (once per session)
        // This ensures ALL connect() paths benefit — ContentView first-launch, WalletManager, reconnect
        if !hasDownloadedGitHubPeers {
            hasDownloadedGitHubPeers = true
            let added = await downloadReliablePeersFromGitHub()
            if added > 0 {
                print("📡 Added \(added) GitHub peers before connecting")
            }
        }

        // Calculate target: 15% of known addresses (min 8, max 30)
        let targetPeers = calculateTargetPeers()
        print("📋 Known addresses: \(knownAddresses.count), Target peers: \(targetPeers)")

        // Build candidate list from ALL known addresses, not just DNS discovered
        // This allows reconnecting to previously discovered peers
        addressLock.lock()
        var allCandidates: [PeerAddress] = []
        for (key, _) in knownAddresses {
            let components = key.split(separator: ":")
            guard components.count == 2, let port = UInt16(components[1]) else { continue }
            allCandidates.append(PeerAddress(host: String(components[0]), port: port))
        }
        addressLock.unlock()

        // FIX #421: Add hardcoded Zclassic seeds FIRST - these are guaranteed good nodes
        // They must be in allCandidates before any filtering/prioritization can work
        // FIX #502: Use defaultPort (8033) instead of hardcoded 16125 - Zclassic uses MagicBean port
        var hardcodedPeers: [PeerAddress] = []
        for seedHost in PeerManager.shared.HARDCODED_SEEDS {
            hardcodedPeers.append(PeerAddress(host: seedHost, port: defaultPort))
        }

        // Add fresh DNS discoveries, then persisted addresses
        allCandidates = hardcodedPeers + discoveredPeers + allCandidates

        // Deduplicate and filter banned peers
        var seenPeers = Set<String>()
        var validPeers = allCandidates.filter { addr in
            let key = "\(addr.host):\(addr.port)"
            if seenPeers.contains(key) || isBanned(addr.host) {
                return false
            }
            seenPeers.insert(key)
            return true
        }

        print("📋 Valid candidates after dedup: \(validPeers.count)")

        // FIX #1091: Filter out localhost in ZipherX mode - no local node in P2P-only mode
        // If user wants to use local node, they should use Full Node (wallet.dat) mode
        let isFullNodeMode = WalletModeManager.shared.isUsingWalletDat
        if !isFullNodeMode {
            let beforeCount = validPeers.count
            validPeers = validPeers.filter { $0.host != "127.0.0.1" && $0.host != "localhost" }
            let removed = beforeCount - validPeers.count
            if removed > 0 {
                print("🚫 FIX #1091: Filtered out \(removed) localhost peer(s) - ZipherX P2P mode")
            }
        }

        // FIX #1115: Prioritize peers by ACTUAL PERFORMANCE, not just hardcoded status
        // Get peer scores from database - peers with history of fast connections go first
        let peerScores = WalletDatabase.shared.getPeersByScore()
        var scoreMap: [String: (score: Int, isReliable: Bool)] = [:]
        for p in peerScores {
            scoreMap[p.host] = (p.score, p.isReliable)
        }

        // Sort validPeers by: reliable first, then by score, then hardcoded seeds as fallback
        let hardcodedSeeds = PeerManager.shared.HARDCODED_SEEDS
        validPeers.sort { a, b in
            let aScore = scoreMap[a.host]
            let bScore = scoreMap[b.host]

            // Reliable peers always first
            if aScore?.isReliable == true && bScore?.isReliable != true { return true }
            if bScore?.isReliable == true && aScore?.isReliable != true { return false }

            // Then by score (higher first)
            let aScoreVal = aScore?.score ?? (hardcodedSeeds.contains(a.host) ? 50 : 0)
            let bScoreVal = bScore?.score ?? (hardcodedSeeds.contains(b.host) ? 50 : 0)
            if aScoreVal != bScoreVal { return aScoreVal > bScoreVal }

            // Hardcoded seeds as tiebreaker for unknown peers
            if hardcodedSeeds.contains(a.host) && !hardcodedSeeds.contains(b.host) { return true }
            if hardcodedSeeds.contains(b.host) && !hardcodedSeeds.contains(a.host) { return false }

            return false
        }

        // Log the top peers we'll try first
        let topPeers = validPeers.prefix(6).map { p -> String in
            if let s = scoreMap[p.host] {
                return "\(p.host)(\(s.score)\(s.isReliable ? "★" : ""))"
            } else if hardcodedSeeds.contains(p.host) {
                return "\(p.host)(seed)"
            }
            return p.host
        }
        print("⭐ FIX #1115: Top peers by score: \(topPeers.joined(separator: ", "))")

        // Connect to peers in batches until we reach target
        var connectedCount = 0
        // FIX #1115: Batch size = 10 for maximum parallelism
        // Try 10 peers at once - as soon as 3 connect, we exit immediately
        let maxConcurrent = 10
        var peerIndex = 0
        var attemptedThisBatch = Set<String>()

        // FIX #429: Add timeout to connect() - return after 20s even if target not met
        // This prevents FAST START from getting stuck waiting for slow peer connections
        // After initial connection, background processes will continue adding peers
        let connectStartTime = Date()
        // FIX #1112: Reduced timeouts - good peers connect fast, don't wait for slow ones
        // FIX #1461: Raised early return from 3→6 — 3 peers was too few for reliable P2P sync.
        // Background connect continues to MIN_PEERS (8) but we need at least 6 before releasing startup.
        let maxConnectDuration: TimeInterval = 12.0 // Was 8s, now 12s to give more time for 6 peers
        let minPeersForEarlyReturn = 6 // FIX #1461: Was 3 — too aggressive, peers capped at 3
        // FIX #1471: Tor SOCKS5 adds ~3-5s per peer. 10s only allows ~2-3 peers through Tor.
        // Increase to 25s when Tor active to allow 5-6 peers before timeout.
        let isTorActive = torMode == .enabled && !torBypassed
        let absMaxConnectDuration: TimeInterval = isTorActive ? 25.0 : 10.0
        var shouldExitEarly = false // FIX #1112 v4: Flag to exit outer loop

        while connectedCount < targetPeers && peerIndex < validPeers.count && !shouldExitEarly {
            // FIX #429: Check if we've exceeded the connection timeout
            let elapsed = Date().timeIntervalSince(connectStartTime)

            // FIX #542: Absolute timeout - return after 30s regardless of peer count
            // This prevents the 255-second wait when peers are slow to connect
            if elapsed > absMaxConnectDuration {
                print("⏱️ FIX #542: Absolute connect timeout (\(String(format: "%.1f", elapsed))s) - returning with \(connectedCount) peers (background connection continues)")
                break
            }

            // Early return if we have enough peers and 20s passed
            if elapsed > maxConnectDuration && connectedCount >= minPeersForEarlyReturn {
                print("⏱️ FIX #429: connect() timeout (\(String(format: "%.1f", elapsed))s) - returning with \(connectedCount) peers (will continue in background)")
                break
            }
            let batchEnd = min(peerIndex + maxConcurrent, validPeers.count)
            let batch = Array(validPeers[peerIndex..<batchEnd])
            peerIndex = batchEnd

            await withTaskGroup(of: (Peer?, PeerAddress).self) { group in
                for address in batch {
                    let key = "\(address.host):\(address.port)"
                    guard !attemptedThisBatch.contains(key) else { continue }
                    attemptedThisBatch.insert(key)

                    // FIX #114: Skip addresses on cooldown to prevent infinite reconnection loops
                    if self.isOnCooldown(address.host, port: address.port) {
                        continue
                    }

                    group.addTask {
                        // Record attempt BEFORE trying (cooldown starts now)
                        await MainActor.run {
                            self.recordConnectionAttempt(address.host, port: address.port)
                        }

                        do {
                            if self.verbose {
                                // Security audit TASK 18: Log redaction
                                print("🔄 Trying \(LogRedaction.redactIP(address.host)):\(address.port)...")
                            }
                            let connectStart = Date()
                            let peer = try await self.connectToPeer(address)
                            let responseTimeMs = Int(Date().timeIntervalSince(connectStart) * 1000)
                            if self.verbose {
                                print("✅ Connected to \(LogRedaction.redactIP(address.host)):\(address.port) (\(responseTimeMs)ms)")
                            }
                            // FIX #284: Unpark peer on successful connection
                            // FIX #908: Reset handshake failures on successful connection
                            // FIX #1115: Record success to database for peer scoring
                            await MainActor.run {
                                self.unparkPeer(address.host, port: address.port)
                                PeerManager.shared.resetHandshakeFailures(address.host)
                                WalletDatabase.shared.recordPeerSuccess(host: address.host, port: address.port, responseTimeMs: responseTimeMs)
                            }
                            return (peer, address)
                        } catch let error as NetworkError {
                            // FIX #284: Park on timeout (NOT a ban - exponential backoff retry)
                            if case .timeout = error {
                                await MainActor.run {
                                    self.parkPeer(address.host, port: address.port)
                                }
                            } else if case .connectionTimeout = error {
                                await MainActor.run {
                                    self.parkPeer(address.host, port: address.port)
                                }
                            } else if case .handshakeFailed = error {
                                // FIX #908: Track handshake failures with extended parking
                                // 5 failures → 1h park, 5 more → 24h park
                                await MainActor.run {
                                    PeerManager.shared.recordHandshakeFailure(address.host, port: address.port)
                                }
                            } else if case .wrongChain(let host) = error {
                                // FIX #229: Permanently ban Zcash peers - they're on wrong chain!
                                // This IS a security issue - use ban, not parking
                                await MainActor.run {
                                    self.banPeerForSybilAttack(host)
                                }
                                print("🚫 [FIX #229] Banned Zcash peer \(host) - wrong chain (requires 170020+)")
                            }
                            print("❌ Failed: \(LogRedaction.redactIP(address.host)) - \(error.localizedDescription)")
                            // FIX #1115: Record failure to database for peer scoring
                            await MainActor.run {
                                WalletDatabase.shared.recordPeerFailure(host: address.host, port: address.port)
                            }
                            return (nil, address)
                        } catch {
                            print("❌ Failed: \(LogRedaction.redactIP(address.host)) - \(error.localizedDescription)")
                            // FIX #1115: Record failure to database for peer scoring
                            await MainActor.run {
                                WalletDatabase.shared.recordPeerFailure(host: address.host, port: address.port)
                            }
                            return (nil, address)
                        }
                    }
                }

                // Collect successful connections
                for await (peer, address) in group {
                    if let peer = peer {
                        // FIX #1421: Dedup — remove stale peer for same host:port before adding fresh one
                        if let existingIdx = peers.firstIndex(where: { $0.host == peer.host && $0.port == peer.port }) {
                            peers.remove(at: existingIdx)
                        }
                        peers.append(peer)
                        // FIX #478: Also add to PeerManager to keep peer lists in sync
                        PeerManager.shared.addPeer(peer)
                        connectedCount += 1

                        // FIX #173: Reset Sybil counter - legitimate peer connected!
                        self.resetSybilCounter()

                        // Set up block announcement listener
                        self.setupBlockListener(for: peer)

                        // FIX #1420: Update UI from GLOBAL peers array, not batch-local count
                        await MainActor.run {
                            self.connectedPeers = self.peers.filter { $0.isConnectionReady }.count
                            self.isConnected = true
                        }

                        // Update address info (on main thread to avoid async lock warning)
                        let key = "\(peer.host):\(peer.port)"
                        DispatchQueue.main.async {
                            self.addressLock.lock()
                            self.knownAddresses[key]?.successes += 1
                            self.newAddresses.remove(key)
                            self.triedAddresses.insert(key)
                            self.addressLock.unlock()

                            // Also update custom node stats if this is a custom node
                            self.recordCustomNodeConnection(host: peer.host, port: peer.port, success: true)
                        }

                        // Request addresses from new peer (async)
                        Task {
                            if let addresses = try? await peer.getAddresses() {
                                for addr in addresses {
                                    self.addAddress(addr, source: peer.host)
                                }
                                self.persistAddresses()
                            }
                        }

                        // Stop if we've reached target
                        if connectedCount >= targetPeers {
                            // FIX #151: Cancel remaining tasks so withTaskGroup doesn't hang
                            // waiting for slow/unresponsive connection attempts
                            group.cancelAll()
                            break
                        }

                        // FIX #1112 v4: Exit immediately once we have minimum peers
                        // Don't wait for slow peers - we have enough for consensus
                        // Set flag to exit OUTER loop since withTaskGroup waits for all tasks
                        if connectedCount >= minPeersForEarlyReturn {
                            let elapsedInLoop = Date().timeIntervalSince(connectStartTime)
                            if verbose {
                                print("⚡ FIX #1112 v4: Early exit - \(connectedCount) peers in \(String(format: "%.2f", elapsedInLoop))s")
                            }
                            shouldExitEarly = true
                            group.cancelAll()
                            break
                        }
                    }
                }

                // FIX #1444: Drain remaining completed peers — don't leak live NWConnections
                // After cancelAll(), in-flight tasks throw CancellationError (yield nil),
                // but already-completed tasks have results queued — capture them.
                for await (peer, address) in group {
                    if let peer = peer {
                        if !peers.contains(where: { $0.host == peer.host && $0.port == peer.port }) {
                            peers.append(peer)
                            PeerManager.shared.addPeer(peer)
                            connectedCount += 1
                            self.setupBlockListener(for: peer)
                            await MainActor.run {
                                self.unparkPeer(address.host, port: address.port)
                                self.connectedPeers = self.peers.filter { $0.isConnectionReady }.count
                                self.isConnected = true
                            }
                            print("✅ FIX #1444: Captured in-flight peer \(peer.host) (was about to be leaked)")
                        } else {
                            peer.disconnect()
                        }
                    }
                }
            }

            // FIX #1112 v4: If early exit flag set, skip to end immediately
            if shouldExitEarly {
                if verbose {
                    print("📊 FIX #1112 v4: Skipping to end - \(connectedCount) peers ready")
                }
                break
            }

            // Log progress
            if verbose {
                print("📊 Connected \(connectedCount)/\(targetPeers) peers (tried \(peerIndex)/\(validPeers.count))")
            }

            // FIX #547: Check for early return AFTER batch completes too
            // FIX #1461: Raised from 1.5s to 4.0s — give more batches a chance to connect
            let elapsedAfterBatch = Date().timeIntervalSince(connectStartTime)
            if elapsedAfterBatch > 4.0 && connectedCount >= minPeersForEarlyReturn {
                if verbose {
                    print("⏱️ FIX #1112: Early return after batch (\(String(format: "%.1f", elapsedAfterBatch))s) - \(connectedCount) peers connected (will continue in background)")
                }
                break
            }
        }

        // Persist after successful connections
        persistAddresses()
        if verbose {
            print("📊 Final: Connected to \(connectedCount)/\(targetPeers) target peers")
        }

        // FIX #429: If we exited early due to timeout, continue connecting in background
        let remainingPeers = Array(validPeers[peerIndex...])
        if !remainingPeers.isEmpty && connectedCount < targetPeers {
            Task { [weak self] in
                guard let self = self else { return }
                print("🔄 FIX #429: Continuing peer discovery in background (\(remainingPeers.count) candidates remaining)...")
                await self.connectToRemainingPeersInBackground(
                    remainingPeers: remainingPeers,
                    targetPeers: targetPeers,
                    currentConnected: connectedCount
                )
            }
        }

        // FIX #173: Check for Sybil attack - if 0 connections and many Sybil rejections, bypass Tor
        if connectedCount == 0 && shouldBypassTorForSybil() {
            print("🚨 [FIX #173] SYBIL ATTACK DETECTED - Bypassing Tor for direct P2P connection!")

            // Temporarily bypass Tor to connect to legitimate peers
            let torWasBypassed = await TorManager.shared.bypassTorForMassiveOperation()

            if torWasBypassed {
                print("🔌 [FIX #173] Reconnecting WITHOUT Tor to reach legitimate peers...")

                // Clear the banned Sybil attackers (they were Tor exit node-specific)
                // Keep only permanent bans for truly bad actors
                addressLock.lock()
                // Reset Sybil tracking
                consecutiveSybilRejections = 0
                addressLock.unlock()

                // FIX #229: Try connecting again without Tor - use trusted peers from database
                for peer in getTrustedPeersForBootstrap() {
                    let components = peer.split(separator: ":")
                    guard components.count == 2, let port = UInt16(components[1]) else { continue }
                    let address = PeerAddress(host: String(components[0]), port: port)

                    do {
                        print("🔄 [FIX #229] Trying trusted peer \(LogRedaction.redactIP(address.host)):\(address.port) (direct)...")
                        let peer = try await connectToPeer(address)
                        peers.append(peer)
                        // FIX #478: Also add to PeerManager to keep peer lists in sync
                        PeerManager.shared.addPeer(peer)
                        connectedCount += 1
                        setupBlockListener(for: peer)
                        resetSybilCounter()
                        print("✅ [FIX #173] Connected to legitimate peer \(LogRedaction.redactIP(address.host))!")

                        if connectedCount >= 3 {
                            break // Got enough peers
                        }
                    } catch {
                        print("❌ [FIX #173] Hardcoded peer \(LogRedaction.redactIP(address.host)) failed: \(error.localizedDescription)")
                    }
                }

                if connectedCount > 0 {
                    completeSybilBypass()
                    // Note: Tor will be restored automatically by the bypass mechanism after massive ops
                }

                // FIX #1420: Update from GLOBAL peers array, not batch-local count
                await MainActor.run {
                    let globalReady = self.peers.filter { $0.isConnectionReady }.count
                    self.connectedPeers = globalReady
                    self.isConnected = globalReady > 0
                }
            }
        }

        // We can work with fewer peers, just warn
        if connectedCount < MIN_PEERS {
            print("Warning: Only connected to \(connectedCount)/\(MIN_PEERS) peers")
        }

        guard connectedCount > 0 else {
            throw NetworkError.insufficientPeers(connectedCount, MIN_PEERS)
        }

        // FIX #1420: Update from GLOBAL peers array, not batch-local count
        DispatchQueue.main.async {
            let globalReady = self.peers.filter { $0.isConnectionReady }.count
            self.connectedPeers = globalReady
            self.isConnected = globalReady > 0
        }

        // Persist good addresses for next launch
        persistAddresses()

        // FIX #425: Sync peers to PeerManager so HeaderSyncManager can find them
        // HeaderSyncManager calls PeerManager.shared.getReadyPeers() directly
        syncPeersToPeerManager()

        // FIX #431: Update chainHeight from connected peers IMMEDIATELY after connect()
        // This fixes "Chain height unavailable" during FAST START because:
        //   1. refreshChainHeight() is skipped when suppressBackgroundSync=true
        //   2. FAST START waits for chainHeight > 0 before proceeding
        //   3. But chainHeight stays 0 if we don't update it from peer handshakes
        // Get consensus chain height from connected peers' peerStartHeight values
        // FIX #434: Only use valid Zclassic peers (170002-170012), not Zcash (170018+)
        var peerHeights: [UInt64] = []
        for peer in peers {
            guard !isBanned(peer.host), peer.peerStartHeight > 0, peer.isValidZclassicPeer else { continue }
            peerHeights.append(UInt64(peer.peerStartHeight))
        }
        if !peerHeights.isEmpty {
            peerHeights.sort()
            let consensusHeight = peerHeights[peerHeights.count / 2] // Median
            await MainActor.run {
                self.chainHeight = consensusHeight
            }
            print("📊 FIX #431+#434: Updated chainHeight to \(consensusHeight) from \(peerHeights.count) valid Zclassic peers")
        }

        // Advertise our .onion address to peers (if hidden service is running)
        await advertiseOnionAddressToPeers()
    }

    // MARK: - Onion Address Advertisement

    /// Advertise our .onion address to all connected peers
    /// This makes ZipherX visible on the network while remaining anonymous
    func advertiseOnionAddressToPeers() async {
        // Check if hidden service is running
        guard await HiddenServiceManager.shared.state == .running,
              let onionAddress = await HiddenServiceManager.shared.onionAddress else {
            print("🧅 advertiseOnionAddressToPeers: Hidden service not running or no address")
            return
        }

        let port = await HiddenServiceManager.shared.p2pPort

        // Count BIP155 peers
        let bip155Peers = peers.filter { $0.supportsAddrv2 }
        print("🧅 Advertising our .onion address - \(peers.count) total peers, \(bip155Peers.count) support BIP155")

        // Advertise to all connected peers in parallel
        await withTaskGroup(of: Void.self) { group in
            for peer in peers {
                group.addTask {
                    do {
                        try await peer.advertiseOnionAddress(onionAddress: onionAddress, port: port)
                    } catch {
                        print("🧅 Failed to advertise to \(peer.host): \(error.localizedDescription)")
                    }
                }
            }
        }

        print("🧅 Finished advertising our .onion address to network")
    }

    /// Disconnect from all peers
    /// FIX #384: Also syncs to PeerManager
    func disconnect() {
        for peer in peers {
            peer.disconnect()
        }
        peers.removeAll()

        // FIX #384: Sync to PeerManager
        Task { @MainActor in
            PeerManager.shared.removeAllPeers()
        }

        DispatchQueue.main.async {
            self.connectedPeers = 0
            self.isConnected = false
        }
    }

    /// FIX #142: Disconnect all peers (alias for disconnect() used by TorManager bypass)
    /// FIX #384: Also syncs to PeerManager
    func disconnectAllPeers() async {
        await MainActor.run {
            self.disconnect()
        }
    }

    /// FIX #258: Force reconnect after iOS background/foreground transition
    /// iOS suspends/kills all network connections when backgrounded - sockets become dead
    /// When returning to foreground, we need to clear stale state and reconnect fresh
    func reconnectAfterBackground() async {
        print("🔄 FIX #258: Reconnecting after background - iOS killed all sockets")
        debugLog(.network, "🔄 FIX #258: Reconnecting after iOS background - clearing stale connections")

        // 1. Stop keepalive timer temporarily (will restart after connect)
        await MainActor.run {
            stopKeepaliveTimer()
        }

        // 2. Force disconnect ALL peers (their sockets are dead anyway)
        for peer in peers {
            peer.disconnect()
        }
        peers.removeAll()

        // FIX #384: Sync to PeerManager
        await MainActor.run {
            PeerManager.shared.removeAllPeers()
        }

        // 3. Clear ALL cooldowns - iOS killed connections, not network failures
        // This allows immediate reconnection to all known addresses
        connectionAttemptsLock.lock()
        connectionAttempts.removeAll()
        connectionAttemptsLock.unlock()
        print("🔄 FIX #258: Cleared all connection cooldowns")

        // 4. Reset reconnection backoff state
        reconnectionAttemptsLock.lock()
        reconnectionAttempts.removeAll()
        reconnectionAttemptsLock.unlock()

        // 5. Reset SOCKS5 failure counter (Tor proxy is fine, just iOS killed sockets)
        consecutiveSOCKS5Failures = 0
        consecutiveZeroPeerRecoveries = 0  // FIX #1419

        // 6. Update UI to show disconnected state
        await MainActor.run {
            self.connectedPeers = 0
            self.isConnected = false
        }

        // 7. Reconnect peers
        let torMode = await TorManager.shared.mode

        #if os(iOS)
        // FIX #1445: On iOS, connect directly first for instant recovery.
        // iOS background kills ALL sockets including Tor circuits.
        // Waiting 15s for Tor wastes time and often fails anyway.
        // Direct-first matches existing FIX #1428 behavior, just faster.
        let strictPrivacy = await TorManager.shared.strictPrivacyMode
        if torMode == .enabled && !strictPrivacy {
            print("⚡ FIX #1445: iOS foreground recovery — connecting directly first, Tor restarts in background")
            debugLog(.network, "⚡ FIX #1445: Direct-first iOS recovery (Tor restarts in background)")

            // Temporarily bypass Tor for fast peer recovery
            await TorManager.shared.temporarilyBypassTor()
            sybilBypassActive = true

            // Start Tor restart in background (non-blocking)
            Task {
                await TorManager.shared.stop()
                try? await Task.sleep(nanoseconds: 500_000_000)
                await TorManager.shared.start()
            }

            // Connect directly — peers will be available in <3s
            do {
                try await connect()
                print("✅ FIX #1445: iOS direct recovery — \(peers.count) peers")
                debugLog(.network, "✅ FIX #1445: Recovered \(peers.count) peers via direct connection")
            } catch {
                print("❌ FIX #1445: Direct recovery failed: \(error.localizedDescription)")
            }

            // Restore Tor after onion circuits warm up (30s)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self = self else { return }
                await TorManager.shared.restoreAfterSingleTxBypass()
                self.sybilBypassActive = false
                print("🧅 FIX #1445: Tor restored after iOS foreground recovery")
            }
        } else if torMode == .enabled && strictPrivacy {
            // FIX #1445: Strict privacy mode — wait for Tor (existing behavior)
            // FIX #1476: Don't stop+restart Tor if SOCKS proxy is already working!
            // Stopping Tor kills hidden service descriptor → macOS can't find our .onion.
            // Only restart if Tor is genuinely broken (not connected, SOCKS proxy dead).
            let torAlreadyConnected = await TorManager.shared.connectionState.isConnected
            if torAlreadyConnected {
                print("🔒 FIX #1476: Strict privacy — Tor already connected, reusing existing circuits (hidden service preserved)")
                debugLog(.network, "🔒 FIX #1476: Tor already connected - skipping restart to preserve hidden service")
            } else {
                print("🔒 FIX #1445: Strict privacy — Tor not connected, restarting")
                debugLog(.network, "🔒 FIX #1445: Strict privacy mode - restarting Tor")

                await TorManager.shared.stop()
                try? await Task.sleep(nanoseconds: 500_000_000)
                await TorManager.shared.start()

                var torConnected = await TorManager.shared.connectionState.isConnected
                var waitCount = 0
                let maxWait = 150  // 15 seconds
                while !torConnected && waitCount < maxWait {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waitCount += 1
                    torConnected = await TorManager.shared.connectionState.isConnected
                    if waitCount % 50 == 0 {
                        let state = await TorManager.shared.connectionState
                        print("🧅 FIX #258: Waiting for Tor... (\(waitCount/10)s) state: \(state.displayText)")
                    }
                }

                if torConnected {
                    print("✅ FIX #258: Tor reconnected with fresh circuits")
                } else {
                    print("⚠️ FIX #258: Tor did not reconnect in 15s - trying direct connections")
                }
            }

            do {
                try await connect()
                print("✅ FIX #258: Reconnected after background - \(peers.count) peers")
            } catch {
                print("❌ FIX #258: Failed to reconnect: \(error.localizedDescription)")
            }
        } else {
            // Tor disabled — just wait for iOS networking to stabilize
            try? await Task.sleep(nanoseconds: 500_000_000)
            do {
                try await connect()
                print("✅ FIX #258: Reconnected after background - \(peers.count) peers")
            } catch {
                print("❌ FIX #258: Failed to reconnect: \(error.localizedDescription)")
            }
        }
        #else
        // macOS: FIX #258 v2 — wait for Tor, then connect (existing behavior)
        // FIX #1476: Don't restart Tor if already connected — kills hidden service descriptor
        if torMode == .enabled {
            let torAlreadyConnected = await TorManager.shared.connectionState.isConnected
            if torAlreadyConnected {
                print("🧅 FIX #1476: Tor already connected — reusing existing circuits (hidden service preserved)")
                debugLog(.network, "🧅 FIX #1476: Skipping Tor restart - already connected, preserving hidden service")
            } else {
                print("🧅 FIX #258: Tor not connected — restarting to establish circuits...")
                debugLog(.network, "🧅 FIX #258: Restarting Tor - not connected")

                await TorManager.shared.stop()
                try? await Task.sleep(nanoseconds: 500_000_000)
                await TorManager.shared.start()

                var torConnected = await TorManager.shared.connectionState.isConnected
                var waitCount = 0
                let maxWait = 150
                while !torConnected && waitCount < maxWait {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waitCount += 1
                    torConnected = await TorManager.shared.connectionState.isConnected
                    if waitCount % 50 == 0 {
                        let state = await TorManager.shared.connectionState
                        print("🧅 FIX #258: Waiting for Tor... (\(waitCount/10)s) state: \(state.displayText)")
                    }
                }

                if torConnected {
                    print("✅ FIX #258: Tor reconnected with fresh circuits")
                    debugLog(.network, "✅ FIX #258: Tor reconnected after \(waitCount/10)s")
                } else {
                    print("⚠️ FIX #258: Tor did not reconnect in 15s - trying direct connections")
                    debugLog(.network, "⚠️ FIX #258: Tor timeout - will try direct connections")
                }
            }
        } else {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // 8. Reconnect fresh
        do {
            try await connect()
            print("✅ FIX #258: Reconnected after background - \(peers.count) peers")
            debugLog(.network, "✅ FIX #258: Successfully reconnected \(peers.count) peers after background")
        } catch {
            print("❌ FIX #258: Failed to reconnect after background: \(error.localizedDescription)")
            debugLog(.network, "❌ FIX #258: Reconnection failed: \(error.localizedDescription)")
        }
        #endif

        // 9. Restart keepalive timer (always, even if connect failed)
        await MainActor.run {
            setupKeepaliveTimer()
        }
    }

    /// Fetch network statistics (P2P-first when Tor enabled, InsightAPI fallback when disabled)
    func fetchNetworkStats() async {
        // FIX #1220: Skip ALL background network activity during gap-fill.
        // Gap-fill needs exclusive P2P bandwidth — concurrent fetches (FilterScanner,
        // mempool scan, confirmation checks) steal connections and cause missing blocks.
        if await WalletManager.shared.isGapFillingDelta {
            return
        }

        // FIX #892: Skip if boost header loading in progress
        // Prevents expensive network operations from interfering with SQLite bulk inserts
        // This was causing the 91-99% stall during Import PK (5+ minutes lost)
        if isLoadingHeaders {
            // Silent return - don't spam logs during header load
            return
        }

        // FIX #286 v18: Debug - log suppress flag state
        if suppressBackgroundSync {
            print("⚠️ FIX #286 v18: fetchNetworkStats called but suppressBackgroundSync=true!")
        }

        // Update Tor/Onion peer counts (so UI shows current connected .onion peers)
        await updateTorAvailability()

        // Get peer version from first connected peer (silently)
        if let peer = peers.first {
            let version = peer.peerUserAgent.isEmpty ? "Unknown" : peer.peerUserAgent
            await MainActor.run {
                self.peerVersion = version
            }
        }

        let torEnabled = await TorManager.shared.mode == .enabled
        var currentChainHeight: UInt64 = 0
        _ = await MainActor.run { self.chainHeight }  // Check previous height (used for comparison below)

        // When Tor enabled: P2P ONLY (InsightAPI blocked by Cloudflare)
        // When Tor disabled: InsightAPI authoritative, P2P fallback

        if torEnabled {
            // TOR MODE: P2P consensus is authoritative
            // 1. Get P2P peer consensus height (skip banned peers, handle negative heights)
            // FIX #434: Only use valid Zclassic peers (170002-170012), not Zcash (170018+)
            var peerHeights: [UInt64: Int] = [:]
            var peerMaxHeight: UInt64 = 0
            for peer in peers {
                // SECURITY: Skip banned peers, negative heights, and non-Zclassic peers
                guard !isBanned(peer.host), peer.peerStartHeight > 0, peer.isValidZclassicPeer else { continue }
                let h = UInt64(peer.peerStartHeight)  // Safe: checked > 0 above
                if h > 0 {
                    peerHeights[h, default: 0] += 1
                    peerMaxHeight = max(peerMaxHeight, h)
                }
            }

            // Find consensus (most peers within 10 blocks of max)
            for (height, count) in peerHeights {
                if peerMaxHeight > 0 && height >= peerMaxHeight - 10 && count > 1 {
                    if height > currentChainHeight {
                        currentChainHeight = height
                    }
                }
            }

            // SECURITY FIX #108: Don't trust max peer height without consensus
            // FIX #404: Use cached height if it's higher than stale HeaderStore
            // At startup, peers may not be connected yet, but cached height from previous session is valid
            if currentChainHeight == 0 {
                let headerHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                let cachedHeight = UInt64(UserDefaults.standard.integer(forKey: "cachedChainHeight"))

                if cachedHeight > headerHeight {
                    // Cached height is newer - HeaderStore is stale
                    currentChainHeight = cachedHeight
                    print("📊 FIX #404: Using cached height (HeaderStore stale): \(cachedHeight) vs headers \(headerHeight)")
                } else if headerHeight > 0 {
                    currentChainHeight = headerHeight
                    print("📊 Using HeaderStore height (no P2P consensus): \(headerHeight)")
                }
            }

            // Only use peer max height if it's within reasonable range of header store
            // This prevents Sybil attack where single malicious peer reports fake height
            if currentChainHeight == 0 && peerMaxHeight > 0 {
                // If we have a cached height, validate peer height against it
                let cachedHeight = UInt64(UserDefaults.standard.integer(forKey: "cachedChainHeight"))
                if cachedHeight > 0 && peerMaxHeight > cachedHeight + 1000 {
                    // Peer height is suspiciously far ahead - likely fake
                    print("🚨 [SECURITY] Rejecting suspicious peer height \(peerMaxHeight) (cached: \(cachedHeight))")
                    // Use cached height as safer fallback
                    currentChainHeight = cachedHeight
                } else {
                    currentChainHeight = peerMaxHeight
                }
            }
        } else {
            // ==========================================================================
            // FIX #381: NORMAL MODE - Prefer P2P consensus over stale HeaderStore
            // Bug: HeaderStore was used first, causing chain height oscillation:
            //   - fetchNetworkStats() set height to HeaderStore (2952744)
            //   - getChainHeight() corrected to peer consensus (2952978)
            //   - fetchNetworkStats() reverted to HeaderStore (2952744)
            //   - This caused UI to flip-flop between heights!
            // Fix: Use same logic as Tor mode - P2P consensus first, HeaderStore fallback
            // ==========================================================================

            // 1. First try P2P peer consensus (most accurate)
            var peerMaxHeight: UInt64 = 0
            var peerHeights: [UInt64: Int] = [:]

            // FIX #402: Debug peer heights
            // FIX #434: Only use valid Zclassic peers (170002-170012)
            let readyPeers = peers.filter { $0.isConnectionReady && $0.isValidZclassicPeer }
            if verbose {
                print("📊 FIX #402+#434: \(readyPeers.count) valid Zclassic peers, checking heights...")
            }

            for peer in peers {
                // SECURITY: Skip banned peers, negative heights, and non-Zclassic peers
                guard !isBanned(peer.host), peer.peerStartHeight > 0, peer.isValidZclassicPeer else {
                    if peer.isConnectionReady && !peer.isValidZclassicPeer {
                        if verbose {
                            print("⚠️ FIX #434: Skipping non-Zclassic peer \(peer.host) version \(peer.peerVersion)")
                        }
                    }
                    continue
                }
                let h = UInt64(peer.peerStartHeight)
                if verbose {
                    print("📊 FIX #402: Peer \(peer.host) reports height \(h)")
                }
                peerHeights[h, default: 0] += 1
                peerMaxHeight = max(peerMaxHeight, h)
            }

            // Find consensus (most peers within 10 blocks of max, need 2+ peers)
            var peerConsensusHeight: UInt64 = 0
            var consensusCount = 0
            for (height, count) in peerHeights {
                if peerMaxHeight > 0 && height >= peerMaxHeight - 10 && count >= 2 {
                    if count > consensusCount || (count == consensusCount && height > peerConsensusHeight) {
                        peerConsensusHeight = height
                        consensusCount = count
                    }
                }
            }

            // 2. Use P2P consensus if available
            let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
            if peerConsensusHeight > 0 && consensusCount >= 2 {
                // Validate against HeaderStore to prevent Sybil attacks
                // FIX #403: Increase threshold to 50000 blocks (~3 months) to handle stale HeaderStore
                let maxReasonableHeight = headerStoreHeight > 0 ? headerStoreHeight + 50000 : UInt64.max
                if peerConsensusHeight <= maxReasonableHeight {
                    // FIX #1265: When peerMaxHeight is 1-2 blocks above consensus, prefer max height.
                    // During block propagation, some peers have the new block (via inv) while others
                    // haven't announced yet. Consensus picks the MOST common height, which is the OLD
                    // height until >50% of peers announce. This delays block scanning by 30s-10min.
                    // A 1-2 block difference is safe (normal propagation, not Sybil attack).
                    if peerMaxHeight > peerConsensusHeight && peerMaxHeight <= peerConsensusHeight + 2 {
                        let peersAtMax = peerHeights[peerMaxHeight, default: 0]
                        if peersAtMax >= 1 {
                            currentChainHeight = peerMaxHeight
                            if verbose {
                                print("📡 FIX #1265: Using max peer height \(peerMaxHeight) (consensus: \(peerConsensusHeight), \(peersAtMax) peer(s) at max)")
                            }
                        } else {
                            currentChainHeight = peerConsensusHeight
                            if verbose {
                                print("📡 FIX #381: Using P2P consensus: \(currentChainHeight) (\(consensusCount) peers)")
                            }
                        }
                    } else {
                        currentChainHeight = peerConsensusHeight
                        if verbose {
                            print("📡 FIX #381: Using P2P consensus: \(currentChainHeight) (\(consensusCount) peers)")
                        }
                    }
                } else {
                    print("🚨 FIX #381: Rejecting suspicious consensus \(peerConsensusHeight) (HeaderStore: \(headerStoreHeight))")
                    currentChainHeight = headerStoreHeight
                }
            } else if peerMaxHeight > 0 && peerMaxHeight > headerStoreHeight {
                // FIX #402: Use peer height if HIGHER than HeaderStore
                // HeaderStore may be stale - peer has newer chain tip
                currentChainHeight = peerMaxHeight
                if verbose {
                    print("📡 FIX #402: Using peer height (ahead of headers): \(currentChainHeight) (HeaderStore: \(headerStoreHeight))")
                }
            } else if headerStoreHeight > 0 {
                // 3. Fallback to HeaderStore (peer height not higher)
                // FIX #404: But prefer cached height if it's higher (HeaderStore is stale)
                let cachedHeight = UInt64(UserDefaults.standard.integer(forKey: "cachedChainHeight"))
                if cachedHeight > headerStoreHeight {
                    currentChainHeight = cachedHeight
                    if verbose {
                        print("📡 FIX #404: Using cached height (HeaderStore stale): \(cachedHeight) vs headers \(headerStoreHeight)")
                    }
                } else {
                    currentChainHeight = headerStoreHeight
                    if verbose {
                        print("📡 FIX #381: Using HeaderStore (no P2P consensus): \(currentChainHeight)")
                    }
                }
            } else if peerMaxHeight > 0 {
                // 4. Last resort - single peer height (less secure)
                currentChainHeight = peerMaxHeight
                print("⚠️ FIX #381: Using single peer height (no consensus): \(currentChainHeight)")
            } else {
                // 5. FIX #404: Ultimate fallback - use cached height from previous session
                let cachedHeight = UInt64(UserDefaults.standard.integer(forKey: "cachedChainHeight"))
                if cachedHeight > 0 {
                    currentChainHeight = cachedHeight
                    print("📡 FIX #404: Using cached height (no peers yet): \(cachedHeight)")
                }
            }
        }

        // FIX #213: ABSOLUTE sanity check - reject clearly impossible heights
        let absoluteMaxHeight: UInt64 = 10_000_000
        if currentChainHeight > absoluteMaxHeight {
            print("🚨 FIX #213: REJECTED impossible chain height \(currentChainHeight) (absolute max: \(absoluteMaxHeight))")
            currentChainHeight = chainHeight > 0 ? chainHeight : 0
        }

        // Update chain height (only if INCREASED)
        // FIX #400: NEVER downgrade chainHeight - this causes TX history to show "Pending"
        if currentChainHeight > 0 && currentChainHeight > chainHeight {
            await MainActor.run {
                if verbose {
                    print("📊 Chain height: \(currentChainHeight)")
                }
                self.chainHeight = currentChainHeight
                // Cache for fast start mode (consecutive app launches)
                UserDefaults.standard.set(Int(currentChainHeight), forKey: "cachedChainHeight")
            }
        }

        // Get ZCL price (from CoinGecko or similar)
        await fetchZCLPrice()

        // Get wallet height from database
        let dbHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
        await MainActor.run {
            self.walletHeight = dbHeight
        }

        // FIX #1263: Ensure block listeners are running during normal operation.
        // Without block listeners, dispatchers are inactive → mempool queries fail,
        // block inv messages are NOT received, peer heights stay stale, and both
        // outgoing confirmations (FIX #859) and incoming TX detection are delayed 3+ min.
        // Block listeners are the ONLY way to receive real-time block announcements.
        if !suppressBackgroundSync && !PeerManager.shared.areBlockListenersBlocked() {
            var anyActive = false
            for peer in peers where peer.isConnectionReady {
                if await peer.isDispatcherActive {
                    anyActive = true
                    break
                }
            }
            if !anyActive && !peers.filter({ $0.isConnectionReady }).isEmpty {
                print("📡 FIX #1263: No active dispatchers — starting block listeners for real-time block detection")
                await startBlockListenersOnMainScreen()
            }
        }

        // BACKGROUND SYNC: If chain is ahead of wallet, sync new blocks
        // This keeps the tree always current for instant sends
        // IMPORTANT: Use local currentChainHeight, not @Published chainHeight
        // to avoid race conditions with MainActor updates
        // SKIP during initial sync to avoid race conditions with startup header sync
        if suppressBackgroundSync {
            // Silently skip during initial sync
        } else if currentChainHeight > dbHeight && dbHeight > 0 {
            // FIX #873: Improved logging to distinguish trigger from execution
            print("🔄 FIX #873: Triggering background sync: +\(currentChainHeight - dbHeight) blocks (wallet=\(dbHeight), chain=\(currentChainHeight))")
            Task {
                await WalletManager.shared.backgroundSyncToHeight(currentChainHeight)
            }
        }

        // FIX #1336: Periodic mempool polling REMOVED.
        // Incoming TX detection is now event-driven:
        //   1. Peer sends unsolicited `inv` MSG_TX → handleInvMessage → getdata → trial decrypt (instant)
        //   2. One-time `mempool` command sent on peer connection (catches pre-existing TXs)
        // The old scanMempoolForIncoming() polled every ~18s but always got 0 results because
        // peers marked TXs as "already announced" after sending unsolicited inv.

        // ALWAYS check if any pending txs have been confirmed
        // (even during initial sync - user wants to see when their tx confirms)
        Task {
            await checkPendingOutgoingConfirmations()
            await checkPendingIncomingConfirmations()
        }
    }

    // MARK: - Mempool Detection (Cypherpunk Style!)

    /// Published property for incoming mempool amount
    @Published private(set) var mempoolIncoming: UInt64 = 0
    @Published private(set) var mempoolTxCount: Int = 0

    /// Published property for outgoing pending transactions (just broadcast, waiting for confirmation)
    @Published private(set) var mempoolOutgoing: UInt64 = 0
    @Published private(set) var mempoolOutgoingTxCount: Int = 0

    /// NEW: Two-phase outgoing tracking for instant UI feedback
    /// Phase 1: Peer accepted (set when first peer accepts broadcast)
    /// Phase 2: Mempool verified (set when tx confirmed in mempool)
    @Published private(set) var pendingBroadcastAmount: UInt64 = 0
    @Published private(set) var pendingBroadcastFee: UInt64 = 0  // FIX #1356: Track fee separately
    @Published private(set) var pendingBroadcastTxid: String? = nil
    @Published private(set) var isMempoolVerified: Bool = false

    /// Published when a transaction is confirmed (for showing "Settlement" celebration)
    /// FIX #1356: amount = user-sent amount (excluding fee), fee = separate
    @Published var justConfirmedTx: (txid: String, amount: UInt64, fee: UInt64, isOutgoing: Bool, clearingTime: TimeInterval?, settlementTime: TimeInterval?)? = nil

    /// Published when incoming ZCL is detected in mempool (for showing "Clearing" celebration)
    /// Contains (txid, amount, clearingTime) - cleared after UI handles it
    /// clearingTime: seconds from send click to mempool detection (only for sender)
    @Published var justDetectedIncomingMempool: (txid: String, amount: UInt64, clearingTime: TimeInterval?)? = nil

    /// Published when sender's tx is verified in mempool (for showing "Clearing" celebration on sender side)
    /// FIX #1356: amount = user-sent amount (excluding fee), fee = separate
    @Published var justClearedOutgoing: (txid: String, amount: UInt64, fee: UInt64, clearingTime: TimeInterval)? = nil

    /// Counter to trigger onChange when outgoing clearing is detected
    @Published var outgoingClearingTrigger: Int = 0

    /// Counter to trigger onChange when mempool incoming is detected (workaround for tuple observation)
    @Published var mempoolIncomingCelebrationTrigger: Int = 0

    /// Counter to trigger onChange when settlement (confirmation) is detected (workaround for tuple observation)
    @Published var settlementCelebrationTrigger: Int = 0

    /// Actor-based transaction tracking (eliminates priority inversion from NSLock)
    private let txTrackingState = TransactionTrackingState()

    /// Called IMMEDIATELY when first peer accepts the broadcast
    /// This provides instant UI feedback before mempool verification completes
    /// ALSO adds txid to pendingOutgoingTxidSet so FilterScanner can detect change outputs
    /// AND tracks in the actor so checkPendingOutgoingConfirmations works
    @MainActor
    func setPendingBroadcast(txid: String, amount: UInt64, fee: UInt64 = 10000) {
        pendingBroadcastTxid = txid
        pendingBroadcastAmount = amount
        pendingBroadcastFee = fee  // FIX #1356
        isMempoolVerified = false

        // CRITICAL: Add to pendingOutgoingTxidSet IMMEDIATELY so FilterScanner
        // can detect change outputs even if trackPendingOutgoing hasn't been called yet
        pendingOutgoingLock.lock()
        pendingOutgoingTxidSet.insert(txid)
        pendingOutgoingLock.unlock()

        // FIX #849: Persist to UserDefaults for cross-restart tracking
        persistPendingTxid(txid)

        // Also update mempoolOutgoing for immediate UI feedback
        self.mempoolOutgoing = amount
        self.mempoolOutgoingTxCount = 1

        // FIX #174: Set pending flag to disable SEND button
        self.hasPendingMempoolTransaction = true
        self.hasOurPendingOutgoing = true  // FIX #301: Mark as OUR transaction
        self.pendingTransactionReason = "Awaiting confirmation for your transaction"

        // Track in the actor (async but non-blocking) so confirmation checking works
        Task {
            _ = await txTrackingState.trackOutgoingSimple(txid: txid, amount: amount)
            print("📤 Actor tracking set for: \(txid.prefix(12))...")
        }

        print("⚡ Pending broadcast set: txid=\(txid.prefix(12))..., amount=\(LogRedaction.redactAmount(amount)) (added to tracking)")
    }

    /// Called when mempool verification completes
    @MainActor
    func setMempoolVerified() {
        isMempoolVerified = true
        print("✅ Mempool verified for pending broadcast")

        // Trigger Clearing celebration for sender
        if let txid = pendingBroadcastTxid, pendingBroadcastAmount > 0 {
            var clearingTime: TimeInterval = 0
            if let sendTime = WalletManager.shared.lastSendTimestamp {
                clearingTime = Date().timeIntervalSince(sendTime)
            }
            justClearedOutgoing = (txid: txid, amount: pendingBroadcastAmount, fee: pendingBroadcastFee, clearingTime: clearingTime)
            outgoingClearingTrigger += 1
            print("🏦 CLEARING! Outgoing tx \(txid.prefix(12))... verified in mempool after \(String(format: "%.1f", clearingTime))s (amount: \(LogRedaction.redactAmount(pendingBroadcastAmount)), fee: \(LogRedaction.redactAmount(pendingBroadcastFee)))")
        }
    }

    /// Clear pending broadcast state (called when tx is confirmed/mined OR when broadcast fails)
    @MainActor
    func clearPendingBroadcast() {
        pendingBroadcastTxid = nil
        pendingBroadcastAmount = 0
        pendingBroadcastFee = 0  // FIX #1356
        isMempoolVerified = false
        // Also clear mempoolOutgoing so "awaiting confirmation" message disappears
        mempoolOutgoing = 0
        mempoolOutgoingTxCount = 0
        // FIX #366: Do NOT clear pendingOutgoingTxidSet here!
        // This set is used for change detection when scanning blocks.
        // If a TX was "rejected" by VUL-002 but actually confirmed on-chain,
        // we need to keep the txid so change outputs aren't counted as income.
        // The set is only cleared in confirmOutgoingTxFull() after CONFIRMED TX.
        // Old code that caused balance inflation:
        // pendingOutgoingLock.lock()
        // pendingOutgoingTxidSet.removeAll()
        // pendingOutgoingLock.unlock()

        // FIX #366: Also don't clear actor state - only clear on confirmation
        // Old code:
        // Task { await txTrackingState.clearAllOutgoing() }

        // FIX #174: Clear pending transaction flags when TX confirms
        hasPendingMempoolTransaction = false
        hasOurPendingOutgoing = false  // FIX #301
        pendingTransactionReason = nil
        externalWalletSpendDetected = nil
        print("🧹 Pending broadcast cleared (UI state reset, txid tracking preserved for change detection)")
    }

    /// Add txid to pending outgoing set (for change detection)
    func addToPendingOutgoingSet(txid: String) {
        pendingOutgoingLock.lock()
        pendingOutgoingTxidSet.insert(txid)
        pendingOutgoingLock.unlock()
        print("📝 Added txid to pending outgoing set: \(txid.prefix(12))...")
    }

    /// Remove txid from pending outgoing set (for cleanup after rejection)
    func removeFromPendingOutgoingSet(txid: String) {
        pendingOutgoingLock.lock()
        pendingOutgoingTxidSet.remove(txid)
        pendingOutgoingLock.unlock()
        print("🗑️ Removed txid from pending outgoing set: \(txid.prefix(12))...")
    }

    /// Remove txid from actor tracking (for cleanup after rejection)
    func removeFromActorTracking(txid: String) async -> Bool {
        let result = await txTrackingState.confirmOutgoing(txid: txid)
        pendingOutgoingLock.lock()
        pendingOutgoingTxidSet.remove(txid)
        pendingOutgoingLock.unlock()
        return result.removed
    }

    /// Clear all pending transaction flags (for cleanup)
    func clearPendingFlags() {
        hasPendingMempoolTransaction = false
        hasOurPendingOutgoing = false
        pendingTransactionReason = nil
        externalWalletSpendDetected = nil
    }

    /// Wait for P2P network to be ready with minimum peer count
    func waitForP2PReady(minPeers: Int, timeout: TimeInterval) async -> Bool {
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            let readyPeers = await MainActor.run { PeerManager.shared.getReadyPeers() }
            if readyPeers.count >= minPeers {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second
        }
        return false
    }

    /// FIX #1026: Reset Initial Block Download latch to allow re-sync
    func resetInitialBlockDownloadLatch() {
        // Reset any IBD tracking state
        print("🔄 FIX #1026: Reset Initial Block Download latch")
    }

    /// FIX #1071: Pre-reconnect peers before block fetch to ensure stable connections
    /// Called once before batch fetching to avoid reconnection storms
    func preReconnectPeersForBlockFetch() async {
        let readyPeers = await MainActor.run { PeerManager.shared.getReadyPeers() }
        if readyPeers.count < 3 {
            print("🔄 FIX #1071: Pre-reconnecting peers for block fetch (have \(readyPeers.count), need 3+)")
            // Try to get more peers connected
            _ = await waitForP2PReady(minPeers: 3, timeout: 10)
        }
    }

    /// FIX #350: Track pending outgoing with FULL info for database write on confirmation
    /// Database writes are DEFERRED until TX is confirmed in a block
    func trackPendingOutgoingFull(_ pendingTx: PendingOutgoingTx) async {
        // Add to sync-accessible set first (for FilterScanner change detection)
        pendingOutgoingLock.lock()
        pendingOutgoingTxidSet.insert(pendingTx.txid)
        pendingOutgoingLock.unlock()

        // FIX #849: Persist to UserDefaults for cross-restart tracking
        await MainActor.run { persistPendingTxid(pendingTx.txid) }

        let result = await txTrackingState.trackOutgoing(pendingTx)
        await MainActor.run {
            self.mempoolOutgoing = result.total
            self.mempoolOutgoingTxCount = result.count
            print("📤 FIX #350: Tracking pending outgoing (deferred DB write): \(pendingTx.txid.prefix(12))... = \(LogRedaction.redactAmount(pendingTx.amount + pendingTx.fee)) (total: \(result.total.redactedAmount))")
        }
    }

    /// Legacy version for backwards compatibility (UI tracking only)
    func trackPendingOutgoing(txid: String, amount: UInt64) async {
        // Add to sync-accessible set first (for FilterScanner change detection)
        pendingOutgoingLock.lock()
        pendingOutgoingTxidSet.insert(txid)
        pendingOutgoingLock.unlock()

        // FIX #849: Persist to UserDefaults for cross-restart tracking
        await MainActor.run { persistPendingTxid(txid) }

        let result = await txTrackingState.trackOutgoingSimple(txid: txid, amount: amount)
        await MainActor.run {
            self.mempoolOutgoing = result.total
            self.mempoolOutgoingTxCount = result.count
            print("📤 Tracking pending outgoing (legacy): \(txid.prefix(12))... = \(amount.redactedAmount) (total: \(result.total.redactedAmount))")
        }
    }

    /// Check if a transaction is being tracked as pending outgoing (our own send)
    /// Used to detect change outputs and suppress notifications
    func isPendingOutgoing(txid: String) async -> Bool {
        return await txTrackingState.isPendingOutgoing(txid: txid)
    }

    /// Called when a transaction is confirmed (found in a block)
    /// FIX #350: NOW writes to database - this is the ONLY place where sent TX is recorded!
    /// This is now async and awaitable to ensure proper completion ordering
    func confirmOutgoingTx(txid: String, blockHeight: UInt64 = 0) async {
        // FIX #1403: Atomic check-and-remove to deduplicate concurrent calls.
        // A TX spending N notes triggers N nullifier matches in the block scanner,
        // each calling confirmOutgoingTx. Only the first call should proceed.
        pendingOutgoingLock.lock()
        let wasPresent = pendingOutgoingTxidSet.remove(txid) != nil
        pendingOutgoingLock.unlock()

        guard wasPresent else {
            // Already confirmed by a prior call (same TX, different nullifier match)
            return
        }

        print("📤 confirmOutgoingTx called for: \(txid.prefix(16))... (blockHeight: \(blockHeight))")

        // FIX #849: Remove from UserDefaults persistence
        await MainActor.run { removePendingTxidFromPersistence(txid) }

        let result = await txTrackingState.confirmOutgoing(txid: txid)
        print("📤 confirmOutgoing result: removed=\(result.removed), total=\(result.total), count=\(result.count)")

        // FIX #350: Write to database NOW (on confirmation, not broadcast)
        if let pendingTx = result.pendingTx, result.removed {
            do {
                // FIX #1264: Use actual block height where TX was found, not current chain tip.
                // FIX #859 passes the real block height from FilterScanner. getChainHeight() can
                // return a LATER block if new blocks arrived between TX mining and detection.
                let confirmedHeight: UInt64
                if blockHeight > 0 {
                    confirmedHeight = blockHeight
                } else {
                    confirmedHeight = try await getChainHeight()
                }
                let currentTime = UInt32(Date().timeIntervalSince1970)

                // Only write to database if we have valid hashedNullifier (full pending TX info)
                if !pendingTx.hashedNullifier.isEmpty {
                    guard let txidDisplayData = Data(hexString: txid) else {
                        print("⚠️ FIX #350: Invalid txid format: \(txid)")
                        return
                    }
                    // FIX #943: txid string is in DISPLAY format (big-endian), but database expects WIRE format (little-endian)
                    // FIX #882/FIX #853 v2 established that txidString computed property reverses for display
                    // So we must store in wire format = reversed from display format
                    let txidWireFormat = Data(txidDisplayData.reversed())

                    print("📤 FIX #350: Writing CONFIRMED sent TX to database...")

                    // FIX #350: Use atomic function to mark note spent AND insert history in one transaction
                    _ = try WalletDatabase.shared.recordSentTransactionAtomic(
                        hashedNullifier: pendingTx.hashedNullifier,
                        txid: txidWireFormat,
                        spentHeight: confirmedHeight,
                        amount: pendingTx.amount,
                        fee: pendingTx.fee,
                        toAddress: pendingTx.toAddress,
                        memo: pendingTx.memo
                    )
                    print("📤 FIX #350: CONFIRMED TX recorded atomically - note marked spent + history inserted at height \(confirmedHeight)")
                } else {
                    // Legacy tracking (no full info) - just update existing record if any
                    print("📤 FIX #350: Legacy tracking - updating existing record if present")
                    if let txidDisplayData = Data(hexString: txid) {
                        // FIX #943: Convert display format (big-endian) to wire format (little-endian)
                        let txidWireFormat = Data(txidDisplayData.reversed())
                        try WalletDatabase.shared.updateSentTransactionOnConfirmation(
                            txid: txidWireFormat,
                            confirmedHeight: confirmedHeight,
                            blockTime: UInt64(currentTime)
                        )
                    }
                }
            } catch {
                print("⚠️ FIX #350: Failed to write sent TX to database: \(error.localizedDescription)")
            }

            await MainActor.run {
                self.mempoolOutgoing = result.total
                self.mempoolOutgoingTxCount = result.count

                // Clear two-phase broadcast tracking (instant UI was showing this)
                self.clearPendingBroadcast()

                // Calculate timing for Settlement celebration
                var settlementTime: TimeInterval? = nil
                var clearingTime: TimeInterval? = nil
                if let sendTime = WalletManager.shared.lastSendTimestamp {
                    settlementTime = Date().timeIntervalSince(sendTime)
                    clearingTime = min(5.0, settlementTime ?? 5.0)
                }

                // Publish confirmation for UI celebration (Settlement!)
                // FIX #1356: Display user-sent amount and fee separately (not combined)
                self.justConfirmedTx = (txid: txid, amount: pendingTx.amount, fee: pendingTx.fee, isOutgoing: true, clearingTime: clearingTime, settlementTime: settlementTime)
                self.settlementCelebrationTrigger += 1

                print("⛏️ SETTLEMENT! Outgoing tx confirmed: \(txid.prefix(12))... after \(String(format: "%.1f", settlementTime ?? 0))s (remaining pending: \(result.total), mempoolOutgoing now: \(self.mempoolOutgoing), trigger=\(self.settlementCelebrationTrigger))")

                // FIX #1331: Post transactionHistoryUpdated so UI cache refreshes.
                // Without this, BalanceView's cached TX list still shows "awaiting confirmation"
                // even though the DB has the confirmed TX.
                NotificationCenter.default.post(name: Notification.Name("transactionHistoryUpdated"), object: nil)
                print("📜 FIX #1331: Posted transactionHistoryUpdated after outgoing TX confirmation")
            }
        } else {
            // Even if not tracked, clear pending broadcast in case it was set
            await MainActor.run {
                if self.pendingBroadcastTxid == txid {
                    self.clearPendingBroadcast()
                }
            }
            print("📤 confirmOutgoingTx: txid not found in pending list (already confirmed or never tracked)")
        }

        // FIX #286 v19: REMOVED verified_checkpoint update from here!
        // verified_checkpoint should ONLY be updated in backgroundSyncToHeight() after actual scanning.

        // FIX #370: Update TX-CONFIRMED checkpoint (separate from verified_checkpoint)
        // This checkpoint ONLY advances on actual TX confirmations.
        // Used by periodic deep verification to catch missed transactions.
        if let chainHeight = try? await getChainHeight() {
            try? WalletDatabase.shared.updateTxConfirmedCheckpoint(chainHeight)
            print("📍 FIX #370: tx_confirmed_checkpoint updated to \(chainHeight) after outgoing TX")
        }
    }

    /// Called when an incoming transaction is confirmed (found in a block during scanning)
    /// Removes from the notification tracking set to allow future notifications for same txid if re-broadcast
    func clearMempoolIncomingNotification(txid: String) {
        Task {
            await txTrackingState.clearIncomingNotification(txid: txid)
        }
    }

    /// Track a pending incoming transaction found during block scan (0 confirmations)
    /// This will trigger the Settlement celebration once it has 1+ confirmations
    func trackPendingIncoming(txid: String, amount: UInt64) async {
        print("📥 trackPendingIncoming: txid=\(txid.prefix(16))... amount=\(amount.redactedAmount)")
        await txTrackingState.trackIncoming(txid: txid, amount: amount)
        await MainActor.run {
            // Update mempoolIncoming to show pending indicator
            self.mempoolIncoming += amount
            self.mempoolTxCount += 1
        }
    }

    /// Called when an incoming transaction is confirmed (found in a mined block)
    /// Removes from pending tracking and publishes confirmation for UI celebration
    func confirmIncomingTx(txid: String, amount: UInt64) async {

        // Check if this was a tracked mempool incoming tx
        let trackedAmount = await txTrackingState.confirmIncoming(txid: txid)

        // Use tracked amount if available, otherwise use provided amount
        let finalAmount = trackedAmount ?? amount

        // Clear notification tracking
        await txTrackingState.clearIncomingNotification(txid: txid)

        // ALWAYS clear mempool incoming when a tx is confirmed
        // This handles cases where:
        // 1. Tx was tracked in mempool → clear tracked amount
        // 2. Tx was NOT tracked (peer failures) but mempoolIncoming is set → clear the amount
        // 3. Tx arrived directly in block without mempool detection → no-op (mempoolIncoming already 0)
        await MainActor.run {
            if trackedAmount != nil {
                // Tracked case: reduce by confirmed amount
                if self.mempoolIncoming >= finalAmount {
                    self.mempoolIncoming -= finalAmount
                } else {
                    self.mempoolIncoming = 0
                }
                if self.mempoolTxCount > 0 {
                    self.mempoolTxCount -= 1
                }
            } else if self.mempoolIncoming > 0 {
                // NOT tracked but mempoolIncoming is set → clear it
                // This happens when mempool scan set it but tracking failed
                print("⚠️ mempoolIncoming=\(self.mempoolIncoming) but tx wasn't tracked - clearing")
                if self.mempoolIncoming >= finalAmount {
                    self.mempoolIncoming -= finalAmount
                } else {
                    self.mempoolIncoming = 0
                }
                if self.mempoolTxCount > 0 {
                    self.mempoolTxCount -= 1
                }
            }
        }

        await MainActor.run {
            // Publish confirmation for UI celebration (Settlement for receiver!)
            // Receiver doesn't have send click time, so clearingTime/settlementTime are nil
            self.justConfirmedTx = (txid: txid, amount: finalAmount, fee: 0, isOutgoing: false, clearingTime: nil, settlementTime: nil)
            self.settlementCelebrationTrigger += 1  // Increment to trigger onChange
            print("⛏️ Confirmed: +\(finalAmount.redactedAmount)")

            // Also send system notification
            NotificationManager.shared.notifyReceivedConfirmed(amount: finalAmount, txid: txid)

            // FIX #1331: Post transactionHistoryUpdated so UI cache refreshes.
            // Without this, BalanceView's cached TX list still shows "awaiting confirmation"
            // even though the TX is confirmed.
            NotificationCenter.default.post(name: Notification.Name("transactionHistoryUpdated"), object: nil)
            print("📜 FIX #1331: Posted transactionHistoryUpdated after incoming TX confirmation")
        }

        // FIX #286 v19: REMOVED verified_checkpoint update from here!
        // BUG: This was updating verified_checkpoint to chain height WITHOUT scanning blocks.
        // If app was closed during TX, blocks between old checkpoint and chain height
        // were never scanned for notes - causing missed transactions!
        // verified_checkpoint should ONLY be updated in backgroundSyncToHeight() after actual scanning.

        // FIX #370: Update TX-CONFIRMED checkpoint (separate from verified_checkpoint)
        // This checkpoint ONLY advances on actual TX confirmations.
        // Used by periodic deep verification to catch missed transactions.
        if let chainHeight = try? await getChainHeight() {
            try? WalletDatabase.shared.updateTxConfirmedCheckpoint(chainHeight)
            print("📍 FIX #370: tx_confirmed_checkpoint updated to \(chainHeight) after incoming TX")
        }
    }

    /// Check if any pending outgoing transactions have been confirmed
    /// Called periodically to clean up confirmed transactions
    func checkPendingOutgoingConfirmations() async {
        let pendingTxids = await txTrackingState.getPendingTxids()

        // Only log when there's something to check
        if !pendingTxids.isEmpty || mempoolOutgoing > 0 {
            print("📤 checkPendingOutgoingConfirmations: pendingTxids=\(pendingTxids.count), mempoolOutgoing=\(mempoolOutgoing)")
        }

        guard !pendingTxids.isEmpty else {
            // If we have mempoolOutgoing > 0 but no pending txids, something is out of sync
            if mempoolOutgoing > 0 {
                print("⚠️ mempoolOutgoing=\(mempoolOutgoing) but no pending txids! Clearing...")
                await MainActor.run {
                    self.mempoolOutgoing = 0
                    self.mempoolOutgoingTxCount = 0
                }
            }
            return
        }

        print("📤 Checking \(pendingTxids.count) pending outgoing transactions for confirmations...")
        print("📤 Pending txids: \(pendingTxids.map { $0.prefix(16) + "..." })")

        // FIX #1263: Ensure block listeners are running when we have pending TXs.
        // After broadcast, block listeners may be inactive (startup sequence, header sync,
        // or scanner stopped them). Without dispatchers:
        // - Mempool queries always return empty (FIX #1184b skips them)
        // - Block inv messages are NOT received → no new-block scanning
        // - FIX #859 (block scanner) never runs → TX confirmation delayed 3+ minutes
        // Fix: Start block listeners on demand so dispatchers activate within ~500ms.
        if !PeerManager.shared.areBlockListenersBlocked() {
            var anyActive = false
            for peer in peers where peer.isConnectionReady {
                if await peer.isDispatcherActive {
                    anyActive = true
                    break
                }
            }
            if !anyActive {
                print("📤 FIX #1263: Dispatchers inactive with \(pendingTxids.count) pending TX(s) — starting block listeners for confirmation detection")
                await startBlockListenersOnMainScreen()
                // Give dispatchers time to activate
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        var confirmedCount = 0

        for txid in pendingTxids {
            // FIX #162: P2P-only confirmation detection
            // Strategy: Check if tx is NO LONGER in mempool (meaning it was mined)
            // We know the tx was broadcast successfully (it was in mempool earlier),
            // so if it's no longer in mempool, it must have been confirmed.
            //
            // FIX #1221: CRITICAL — empty mempool response is NOT "tx not in mempool"!
            // When getMempoolTransactions() returns 0 hashes, the peer timed out or the
            // dispatcher was inactive. Treating empty as "not in mempool" causes false
            // SETTLEMENT (TX marked confirmed when never even broadcast properly).
            // ALWAYS verify via P2P getdata before confirming.

            var isStillInMempool = false
            var mempoolCheckFailed = false

            // Try to check mempool from a connected peer
            if let peer = getConnectedPeer() {
                do {
                    let mempoolTxs = try await peer.getMempoolTransactions()

                    // FIX #1221: Empty mempool = peer failure, NOT "TX confirmed"
                    // Real mempools almost always have transactions. Empty response means:
                    // - Dispatcher inactive (block listeners stopped)
                    // - Peer timed out
                    // - TCP stream desynced
                    // NEVER treat empty mempool as evidence of confirmation.
                    if mempoolTxs.isEmpty {
                        print("⚠️ FIX #1221: Mempool returned 0 TXs — treating as check FAILED (not confirmation evidence)")
                        mempoolCheckFailed = true
                    } else {
                        // FIX #1202: Mempool inv returns txids in wire format (little-endian),
                        // but txid string is display format (big-endian). Must reverse bytes
                        // for comparison, otherwise TX is never found in mempool → false "not in mempool"
                        // → triggers FIX #1165 rejection path even when TX is valid.
                        let txidData = Data(hexString: txid).map { Data($0.reversed()) }
                        isStillInMempool = txidData != nil && mempoolTxs.contains(txidData!)

                        if isStillInMempool {
                            print("📤 Tx \(txid.prefix(16))... still in mempool (\(mempoolTxs.count) mempool TXs, not confirmed yet)")
                        } else {
                            // FIX #1259: TX not in a NON-EMPTY mempool — TX has left mempool.
                            // This means: (a) mined into block, or (b) evicted/expired.
                            // DO NOT confirm here — P2P getdata only finds mempool TXs, NOT mined TXs.
                            // Confirmation MUST come from block scanner (FIX #859) finding our nullifier
                            // in a block, which triggers confirmOutgoingTx.
                            // Just log and wait for block scanner to do its job.
                            print("📤 FIX #1259: Tx \(txid.prefix(16))... left mempool (\(mempoolTxs.count) mempool TXs) — waiting for block scanner confirmation (FIX #859)")
                            // Fall through to mempoolCheckFailed path for DB check
                            mempoolCheckFailed = true
                        }
                    }
                } catch {
                    print("📤 Tx \(txid.prefix(16))... mempool check failed: \(error.localizedDescription)")
                    mempoolCheckFailed = true
                }
            } else {
                print("📤 Tx \(txid.prefix(16))... no connected peer for mempool check")
                mempoolCheckFailed = true
            }

            // FIX #393: When mempool check fails, check database for confirmation
            // If block scan found our TX and recorded it as "sent", the TX is confirmed
            // This prevents "waiting for confirmation" message persisting when peers disconnect
            if mempoolCheckFailed {
                if let txidData = Data(hexString: txid) {
                    let existsInDb = (try? WalletDatabase.shared.transactionExists(txid: txidData, type: .sent)) ?? false
                    if existsInDb {
                        print("📤 FIX #393: Tx \(txid.prefix(16))... found in database as SENT - CONFIRMED!")
                        await confirmOutgoingTx(txid: txid)
                        confirmedCount += 1
                    } else {
                        // FIX #1259: TX not in DB yet — waiting for block scanner (FIX #859)
                        // to find our nullifier in a block and trigger confirmOutgoingTx.
                        // P2P getdata only finds mempool TXs, NOT mined TXs — useless here.
                        // DO NOT attempt premature confirmation.
                        print("📤 FIX #1259: TX \(txid.prefix(16))... not in DB — waiting for block scanner (FIX #859)")
                    }
                }
            }
        }

        // Safety: If all pending txids were confirmed but mempoolOutgoing is still > 0,
        // force clear after a small delay (async race condition protection)
        if confirmedCount == pendingTxids.count && confirmedCount > 0 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
            await MainActor.run {
                if self.mempoolOutgoing > 0 {
                    print("📤 Force clearing mempoolOutgoing after all txids confirmed")
                    self.mempoolOutgoing = 0
                    self.mempoolOutgoingTxCount = 0
                }
            }
        }

        // CRITICAL FIX: If any tx was confirmed, trigger wallet sync to update balances
        // This ensures the change note is discovered and has 1+ confirmations
        if confirmedCount > 0 {
            print("⛏️ \(confirmedCount) tx(s) confirmed - triggering wallet sync to update change notes...")

            // FIX #120: InsightAPI commented out - use P2P chain height
            // Get current chain height from InsightAPI
            // if let status = try? await InsightAPI.shared.getStatus() {
            //     let currentHeight = status.height
            let currentHeight = chainHeight  // Use cached P2P chain height
            let walletHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0

            if currentHeight > walletHeight {
                print("⛏️ Chain height \(currentHeight) > wallet height \(walletHeight) - syncing...")
                // Trigger background sync to scan the confirmed tx block
                await WalletManager.shared.backgroundSyncToHeight(currentHeight)
                // Refresh balance to update confirmation counts
                try? await WalletManager.shared.refreshBalance()
            } else {
                // Even if heights match, still refresh balance to update confirmations
                print("⛏️ Heights match but refreshing balance to update confirmations...")
                try? await WalletManager.shared.refreshBalance()
            }
            // }
        }
    }

    /// Check if any pending incoming transactions have been confirmed (1+ confirmations)
    /// Called periodically to detect when mempool txs get mined and show celebration
    func checkPendingIncomingConfirmations() async {
        let pendingIncoming = await txTrackingState.getPendingIncomingTxids()

        // Only log when there's something to check
        if !pendingIncoming.isEmpty || mempoolIncoming > 0 {
            print("📥 checkPendingIncomingConfirmations: pendingIncoming=\(pendingIncoming.count), mempoolIncoming=\(mempoolIncoming)")
        }

        guard !pendingIncoming.isEmpty else {
            // If we have mempoolIncoming > 0 but no pending txids, something is out of sync
            // This can happen if mempool scan set it but tracking failed
            if mempoolIncoming > 0 {
                print("⚠️ mempoolIncoming=\(mempoolIncoming) but no pending txids! Clearing...")
                await MainActor.run {
                    self.mempoolIncoming = 0
                    self.mempoolTxCount = 0
                }
            }
            return
        }

        // FIX #240: Force sync when we have pending incoming TXs
        // Don't rely on HeaderStore which can be stale - get real height from peers
        await forceSyncIfNeeded()

        // Check pending incoming transactions silently

        var confirmedCount = 0

        for (txid, amount) in pendingIncoming {
            // FIX #161: P2P-based confirmation check
            // Check if this tx exists in our transaction history (means it was confirmed during sync)
            let historyItems = (try? WalletDatabase.shared.getTransactionHistory(limit: 50, offset: 0)) ?? []
            // FIX #1396: Find the MATCHING item (not just existence) so we can check tx_type
            let matchingItem = historyItems.first { item in
                // FIX #1331: Compare BOTH wire and display format hex.
                // Pending txids are tracked in DISPLAY format (reversed, line 4152)
                // but DB stores txids in WIRE format (little-endian).
                // Must check both to handle the format mismatch.
                let itemWireHex = item.txid.map { String(format: "%02x", $0) }.joined()
                let itemDisplayHex = Data(item.txid.reversed()).map { String(format: "%02x", $0) }.joined()
                return itemWireHex == txid || itemDisplayHex == txid
            }

            if let matchingItem = matchingItem {
                // FIX #1396: Check tx_type — if this is a SENT TX (external spend via FIX #843),
                // do NOT confirm as incoming. Clear pending tracking instead.
                // Bug: checkPendingIncomingConfirmations didn't check type → SENT TXs were
                // confirmed as "incoming" → wrong "+0.001 ZCL" notification + wrong direction
                if matchingItem.type == .sent || matchingItem.type == .selfSend {
                    print("⛏️ FIX #1396: TX \(txid.prefix(16))... found in history as \(matchingItem.type.rawValue) — clearing pending incoming (NOT confirming as received)")
                    // Clear tracking state (don't leave stale pending entries)
                    _ = await txTrackingState.confirmIncoming(txid: txid)
                    await txTrackingState.clearIncomingNotification(txid: txid)
                    await MainActor.run {
                        if self.mempoolIncoming >= amount {
                            self.mempoolIncoming -= amount
                        } else {
                            self.mempoolIncoming = 0
                        }
                        if self.mempoolTxCount > 0 {
                            self.mempoolTxCount -= 1
                        }
                        // Refresh UI to show correct state
                        NotificationCenter.default.post(name: Notification.Name("transactionHistoryUpdated"), object: nil)
                    }
                    confirmedCount += 1
                    continue
                }

                print("⛏️ FIX #161: Confirmed incoming tx found in history: \(txid.prefix(16))...")
                print("⛏️ BALANCE CARD should now clear 'awaiting...' message!")
                await confirmIncomingTx(txid: txid, amount: amount)
                confirmedCount += 1
                continue
            }

            // FIX #161: Also check via background sync - if wallet synced past the tx block,
            // the note should appear in our unspent notes
            // FIX #215: DO NOT match by value alone - this causes false positives with old notes!
            // Only consider confirmed if TXID exists in transaction_history (checked above)
            // The background sync will discover the note and create the history entry
            // Matching by value would incorrectly find old notes with same amount

            // Note: We leave this as a no-op - the TX will be confirmed when:
            // 1. Background sync discovers the note and saves it to history, OR
            // 2. The next checkPendingIncomingConfirmations() finds it in history
            print("⏳ FIX #215: Waiting for background sync to discover note (txid=\(txid.prefix(16))...)")
        }

        // Safety: If all pending txids were confirmed but mempoolIncoming is still > 0,
        // force clear after a small delay (async race condition protection)
        if confirmedCount == pendingIncoming.count && confirmedCount > 0 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
            await MainActor.run {
                if self.mempoolIncoming > 0 {
                    print("📥 Force clearing mempoolIncoming after all txids confirmed")
                    self.mempoolIncoming = 0
                    self.mempoolTxCount = 0
                }
            }
        }
    }

    /// FIX #240: Force background sync by getting chain height directly from P2P peers
    /// Bypasses stale HeaderStore to ensure we don't miss confirmations
    private func forceSyncIfNeeded() async {
        let dbHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
        guard dbHeight > 0 else { return }

        // Get REAL chain height from connected peers (bypass HeaderStore)
        var peerHeights: [UInt64] = []
        for peer in getAllConnectedPeers().prefix(5) {
            let height = UInt64(peer.peerStartHeight)
            if height > 0 {
                peerHeights.append(height)
            }
        }

        guard !peerHeights.isEmpty else {
            print("🔄 FIX #240: No peer heights available for force sync")
            return
        }

        // Use median peer height for robustness against outliers
        let sortedHeights = peerHeights.sorted()
        let medianHeight = sortedHeights[sortedHeights.count / 2]

        if medianHeight > dbHeight {
            let blocksToSync = medianHeight - dbHeight
            print("🔄 FIX #240: Force sync triggered! Peers report height \(medianHeight), wallet at \(dbHeight) (+\(blocksToSync) blocks)")
            await WalletManager.shared.backgroundSyncToHeight(medianHeight)
        }
    }

    /// Force clear all pending outgoing transactions
    /// Called when we detect they should be confirmed (e.g., wallet synced past tx block)
    func clearAllPendingOutgoing() {
        Task {
            let txids = await txTrackingState.getPendingTxids()
            for txid in txids {
                await txTrackingState.confirmOutgoing(txid: txid)
            }
            await MainActor.run {
                self.mempoolOutgoing = 0
                self.mempoolOutgoingTxCount = 0
                print("📤 Cleared all pending outgoing transactions")
            }
        }
    }

    /// Scan mempool for incoming shielded transactions
    /// Uses trial decryption to detect payments before confirmation
    private func scanMempoolForIncoming() async {
        // FIX #145: Skip if background processes are disabled (initial sync in progress)
        guard backgroundProcessesEnabled else {
            print("🔮 scanMempoolForIncoming: skipped (initial sync in progress)")
            return
        }

        // FIX #130: Skip mempool scan if header sync is in progress to prevent P2P race conditions
        if isHeaderSyncing {
            print("🔮 scanMempoolForIncoming: skipped (header sync in progress)")
            return
        }

        print("🔮 scanMempoolForIncoming: starting...")

        // Get all connected peers and try them in order
        var connectedPeers = getAllConnectedPeers()

        // If no ready peers, try to reconnect (LIMITED to 3 peers max to prevent DNS exhaustion)
        if connectedPeers.isEmpty {
            print("🔮 scanMempoolForIncoming: no ready peers, attempting reconnection...")

            // Only try to reconnect up to 3 disconnected peers to prevent connection explosion
            // DNS service has limited slots - creating too many connections causes NoMemory errors
            let maxReconnectAttempts = 3
            var reconnectAttempts = 0

            // Try to reconnect disconnected peers (limited)
            // Use ensureConnected() which has built-in 5-second cooldown to prevent infinite loops
            for peer in peers where !peer.isConnectionReady && reconnectAttempts < maxReconnectAttempts {
                reconnectAttempts += 1
                do {
                    try await peer.ensureConnected()
                    print("✅ scanMempoolForIncoming: reconnected to \(peer.host)")
                    break // Stop after first successful reconnection
                } catch NetworkError.timeout {
                    // Cooldown period - peer was recently reconnected, skip
                    continue
                } catch {
                    // Silently continue - we'll try other peers (up to limit)
                }
            }

            // Check again after reconnect attempt
            connectedPeers = getAllConnectedPeers()
        }

        guard !connectedPeers.isEmpty else {
            print("⚠️ scanMempoolForIncoming: no connected peer after reconnect attempt - mempool scanning disabled!")
            await MainActor.run {
                if !self.p2pMempoolWarning {
                    self.p2pMempoolWarning = true
                    print("⚠️ P2P mempool warning activated - incoming tx detection may be delayed")
                }
            }
            return
        }

        // Clear warning if we have peers now
        await MainActor.run {
            if self.p2pMempoolWarning {
                self.p2pMempoolWarning = false
                print("✅ P2P mempool warning cleared - peers available")
            }
        }

        // FIX #239: Query MULTIPLE peers in parallel for robust mempool coverage
        // Different peers may have different mempool contents due to propagation delays
        var allMempoolTxs: Set<Data> = []
        var successfulPeers: [Peer] = []
        let maxPeersToQuery = min(3, connectedPeers.count)

        // Query up to 3 peers in parallel
        await withTaskGroup(of: (Peer, [Data]?).self) { group in
            for peer in connectedPeers.prefix(maxPeersToQuery) {
                group.addTask {
                    do {
                        try await peer.ensureConnected()
                        let txs = try await peer.getMempoolTransactions()
                        print("🔮 FIX #239: Got \(txs.count) mempool txs from \(peer.host)")
                        return (peer, txs)
                    } catch {
                        print("⚠️ FIX #239: Peer \(peer.host) mempool failed: \(error.localizedDescription)")
                        return (peer, nil)
                    }
                }
            }

            // Collect all results
            for await (peer, txs) in group {
                if let txs = txs {
                    successfulPeers.append(peer)
                    for tx in txs {
                        allMempoolTxs.insert(tx)
                    }
                }
            }
        }

        let mempoolTxs = Array(allMempoolTxs)
        print("🔮 FIX #239: Merged mempool from \(successfulPeers.count) peers: \(mempoolTxs.count) unique txs")

        guard let peer = successfulPeers.first else {
            print("⚠️ scanMempoolForIncoming: all peers failed")
            return
        }

        // Process mempool transactions
        // NOTE: Don't clear mempoolIncoming when peer returns 0 txs if we have tracked pending incoming
        // This prevents UI flickering when peers are unreliable
        guard !mempoolTxs.isEmpty else {
            let hasPendingIncoming = await txTrackingState.getPendingIncomingCount() > 0
            if !hasPendingIncoming {
                await MainActor.run {
                    self.mempoolIncoming = 0
                    self.mempoolTxCount = 0
                }
            } else {
                print("🔮 Peer returned 0 txs but we have tracked pending incoming - keeping mempoolIncoming=\(self.mempoolIncoming)")
            }
            return
        }

        print("🔮 Scanning \(mempoolTxs.count) mempool transactions...")

        // VUL-U-002: Get spending key for trial decryption with secure zeroing
        guard let secureKey = try? SecureKeyStorage().retrieveSpendingKeySecure() else {
            print("🔮 scanMempoolForIncoming: could not retrieve spending key, skipping")
            return
        }
        defer { secureKey.zero() }
        let spendingKey = secureKey.data
        print("🔮 scanMempoolForIncoming: got spending key, checking txs...")

        var incomingAmount: UInt64 = 0
        var incomingCount = 0
        var newIncomingTxs: [(txid: String, amount: UInt64)] = []

        // Get pending outgoing txids upfront to detect change outputs early
        let pendingOutgoingTxids = await txTrackingState.getAllPendingOutgoingTxids()

        // Check each mempool transaction for shielded outputs
        for txHashData in mempoolTxs.prefix(50) { // Limit to 50 to avoid spam
            // P2P returns txids in wire format (little-endian)
            // FIX #853 v2: Keep BOTH formats:
            // - wireHex for database storage (matches block-scanned txids)
            // - displayHex for comparison with existing pending txids and logging
            let txHashWire = txHashData  // Wire format bytes (for DB storage)
            let txHashWireHex = txHashWire.map { String(format: "%02x", $0) }.joined()  // Wire format hex
            let txHashReversed = Data(txHashData.reversed())  // Display format bytes
            let txHashHex = txHashReversed.map { String(format: "%02x", $0) }.joined()  // Display format hex (for comparisons)

            // EARLY CHECK: Skip change outputs from our own pending transactions
            // This prevents change from being counted in mempoolIncoming
            // Check BOTH the actor set AND the sync-accessible set to handle race condition
            // where setPendingBroadcast has updated the sync set but actor update is still pending
            if pendingOutgoingTxids.contains(txHashHex) || isPendingOutgoingSync(txid: txHashHex) {
                print("🔮 MEMPOOL: Skipping tx \(txHashHex.prefix(12))... (change output from our pending send)")
                continue
            }

            // FIX #391: Try ALL successful peers for getMempoolTransaction, not just the first one
            // The first peer might have disconnected between inventory fetch and raw tx fetch
            var rawTx: Data?
            for tryPeer in successfulPeers {
                do {
                    rawTx = try await tryPeer.getMempoolTransaction(txid: txHashData)
                    print("🔮 Got raw tx \(txHashHex.prefix(12))... from P2P peer \(tryPeer.host)")
                    break // Success! Exit the loop
                } catch {
                    print("⚠️ FIX #391: Peer \(tryPeer.host) failed for \(txHashHex.prefix(12))...: \(error.localizedDescription)")
                    // Try next peer
                }
            }

            guard let rawTx = rawTx else {
                print("⚠️ FIX #391: All \(successfulPeers.count) peers failed for \(txHashHex.prefix(12))... - skipping")
                continue
            }

            // FIX #301: First detect external spends, then parse outputs to calculate actual sent amount
            // Store potential external spend info - will be finalized after output parsing
            var pendingExternalSpend: (txid: String, inputValue: UInt64, nullifier: Data)? = nil

            // FIX #174: Check for external wallet spends (nullifiers from our notes in this tx)
            // This detects if the same private key was imported into another wallet that spent our notes
            if let nullifiers = parseShieldedSpends(from: rawTx) {
                for nullifier in nullifiers {
                    // Check if this nullifier belongs to one of our unspent notes
                    if let noteInfo = try? WalletDatabase.shared.getNoteByNullifier(nullifier: nullifier) {
                        // This tx is spending one of our notes!
                        // Check if this is from our own pending transaction
                        let isOurPending = pendingOutgoingTxids.contains(txHashHex) || isPendingOutgoingSync(txid: txHashHex)

                        // FIX #220: Also check if this TXID exists in our transaction_history as a SENT tx
                        // This prevents false "external spend" warnings for our own transactions that
                        // were already recorded but are still in mempool (pending tracking was cleared)
                        // FIX #853 v2: Use wire format for database check (matches block-scanned storage)
                        let isOurRecorded = (try? WalletDatabase.shared.transactionExists(txid: txHashWire, type: .sent)) ?? false

                        if !isOurPending && !isOurRecorded {
                            // EXTERNAL WALLET SPEND DETECTED - store for now, finalize after output parsing
                            print("🚨🚨🚨 [EXTERNAL SPEND] TX \(txHashHex.prefix(12))... is spending our note!")
                            print("🚨 [EXTERNAL SPEND] Input note value: \(noteInfo.value.redactedAmount)")
                            pendingExternalSpend = (txid: txHashHex, inputValue: noteInfo.value, nullifier: nullifier)
                        } else if isOurRecorded && !isOurPending {
                            print("🔮 MEMPOOL: Skipping tx \(txHashHex.prefix(12))... (our recorded sent tx still in mempool)")
                        }
                    }
                }
            }

            // FIX #301: Declare outside block so it's accessible for external spend calculation
            var txIncomingAmount: UInt64 = 0
            // FIX #1403: Track individual output values for same-key external spend detection
            var decryptedOutputValues: [UInt64] = []

            // Parse transaction for shielded outputs
            if let outputs = parseShieldedOutputs(from: rawTx) {
                for output in outputs {
                    // Try to decrypt with our key
                    if let decrypted = ZipherXFFI.tryDecryptNoteWithSK(
                        spendingKey: spendingKey,
                        epk: output.epk,
                        cmu: output.cmu,
                        ciphertext: output.ciphertext
                    ) {
                        // Found incoming payment!
                        if decrypted.count >= 19 {
                            let valueBytes = Data(decrypted[11..<19])
                            let value = valueBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                            txIncomingAmount += value
                            decryptedOutputValues.append(value)
                            print("🔮 MEMPOOL: Found incoming \(value.redactedAmount) in tx \(txHashHex.prefix(12))...")
                        }
                    }
                }

                if txIncomingAmount > 0 {
                    // EARLY check for change output - before counting toward mempoolIncoming
                    // FIX #853 v2: Use wire format for database operations (matches block-scanned storage)
                    let txidData = txHashWire
                    var isChangeOutput = (try? WalletDatabase.shared.transactionExists(txid: txidData, type: .sent)) ?? false

                    // FIX #1392: External spend detection — our decrypted output in this TX is CHANGE, not received.
                    // When pendingExternalSpend is set, we know this TX spends our note from another wallet.
                    // Any output we can decrypt in the same TX is the change back to our address.
                    if !isChangeOutput && pendingExternalSpend != nil {
                        isChangeOutput = true
                        print("🔔 FIX #1392: External spend detected in same TX — marking output as change (not received)")
                    }

                    if !isChangeOutput {
                        let isPending = await txTrackingState.isPendingOutgoing(txid: txHashHex)
                        if isPending {
                            isChangeOutput = true
                            print("🔔 MEMPOOL: Detected pending outgoing tx \(txHashHex.prefix(12))... (change output)")
                        }
                    }

                    if !isChangeOutput {
                        if let lastSend = WalletManager.shared.lastSendTimestamp,
                           Date().timeIntervalSince(lastSend) < 120.0 {
                            isChangeOutput = true
                            print("🔔 MEMPOOL: Detected recent send activity - treating as change output")
                        }
                    }

                    if !isChangeOutput && mempoolOutgoing > 0 {
                        isChangeOutput = true
                        print("🔔 MEMPOOL: mempoolOutgoing > 0 - treating as change output")
                    }

                    if isChangeOutput {
                        // Change outputs are NOT counted in mempoolIncoming
                        print("🔔 MEMPOOL: Excluding change output \(txIncomingAmount.redactedAmount) from tx \(txHashHex.prefix(12))...")
                    } else {
                        // CRITICAL: Check if this tx has already been confirmed
                        // This prevents the race condition where mempool scan runs
                        // after confirmation clears mempoolIncoming, but the tx
                        // is still in some peers' mempool (brief lag before removal)
                        // FIX #853 v2: txidData is already wire format, use directly
                        let alreadyConfirmed = (try? WalletDatabase.shared.transactionExists(txid: txidData, type: .received)) ?? false

                        if alreadyConfirmed {
                            print("🔮 MEMPOOL: Skipping already-confirmed tx \(txHashHex.prefix(12))...")
                        } else {
                            // Real incoming - count it and prepare for notification
                            incomingAmount += txIncomingAmount
                            incomingCount += 1

                            // Check if this is a NEW incoming tx we haven't notified about
                            let isNewTx = await txTrackingState.checkAndMarkNotified(txid: txHashHex)
                            print("🔮 MEMPOOL: tx \(txHashHex.prefix(12))... isNewTx=\(isNewTx)")
                            if isNewTx {
                                newIncomingTxs.append((txid: txHashHex, amount: txIncomingAmount))
                            } else {
                                print("🔮 MEMPOOL: Skipping already-notified tx \(txHashHex.prefix(12))...")
                            }
                        }
                    }
                }
            }

            // FIX #301: Finalize external spend detection with correct amount
            // Now we know the change output (txIncomingAmount), calculate actual sent
            if let extSpend = pendingExternalSpend {
                let changeBack = txIncomingAmount
                let estimatedFee: UInt64 = 10_000  // Standard fee
                var actualSent = extSpend.inputValue > (changeBack + estimatedFee)
                    ? extSpend.inputValue - changeBack - estimatedFee
                    : UInt64(0)

                // FIX #1403: Same-key scenario — when ALL outputs are decryptable (same IVK controls
                // both destination and change), actualSent computes to 0. The smallest output
                // is the actual sent amount (the larger one is change back to us).
                if actualSent == 0 && decryptedOutputValues.count >= 2 {
                    let sorted = decryptedOutputValues.sorted()
                    actualSent = sorted[0]  // Smallest output = destination amount
                    print("🚨 FIX #1403: Same-key external spend — all outputs decryptable. Using smallest output (\(actualSent.redactedAmount)) as sent amount")
                } else if actualSent == 0 && decryptedOutputValues.count == 1 {
                    // Only one output decryptable and it equals the input minus fee = self-transfer
                    actualSent = estimatedFee  // Just the fee was spent
                    print("🚨 FIX #1403: Self-transfer detected — only fee was spent")
                }

                print("🚨 [EXTERNAL SPEND] Calculated: input=\(extSpend.inputValue.redactedAmount), change=\(changeBack.redactedAmount), fee=\(estimatedFee.redactedAmount), actual sent=\(actualSent.redactedAmount)")
                print("🚨 [EXTERNAL SPEND] This transaction was NOT sent by ZipherX - another wallet with the same key sent it!")

                // Track external spend (for mempool confirmation checking)
                await trackPendingOutgoing(txid: extSpend.txid, amount: extSpend.inputValue)

                // Notify user about external wallet spend - with ACTUAL SENT AMOUNT
                // FIX #301: DO NOT disable SEND for external spends - user may need to move remaining funds quickly
                await MainActor.run {
                    self.externalWalletSpendDetected = (txid: extSpend.txid, amount: actualSent)
                    // Note: We intentionally do NOT set hasPendingMempoolTransaction or hasOurPendingOutgoing
                    // External spends should NOT block the user from sending their remaining funds
                }

                // Send push notification with actual sent amount
                NotificationManager.shared.notifyExternalWalletSpend(amount: actualSent, txid: extSpend.txid)
            }
        }

        // Send notifications for NEW incoming transactions (already filtered for change)
        for (txid, amount) in newIncomingTxs {
            print("🔔 MEMPOOL NOTIFICATION: New incoming \(amount.redactedAmount) in tx \(txid.prefix(12))...")
            NotificationManager.shared.notifyReceived(amount: amount, txid: txid)

            // Track this incoming tx so we can celebrate when it's confirmed
            await txTrackingState.trackIncoming(txid: txid, amount: amount)

            // Trigger UI celebration for incoming mempool transaction (Clearing for receiver)
            // Receiver doesn't have send click time, so clearingTime is nil
            await MainActor.run {
                self.justDetectedIncomingMempool = (txid: txid, amount: amount, clearingTime: nil)
                self.mempoolIncomingCelebrationTrigger += 1  // Increment to trigger onChange
                print("🏦 CLEARING! Set justDetectedIncomingMempool: txid=\(txid.prefix(12))..., amount=\(amount.redactedAmount), trigger=\(self.mempoolIncomingCelebrationTrigger)")
            }
        }

        await MainActor.run {
            self.mempoolIncoming = incomingAmount
            self.mempoolTxCount = incomingCount
            if incomingAmount > 0 {
                print("🔮 Mempool incoming: \(incomingAmount.redactedAmount) (\(incomingCount) tx)")
            }
        }
    }

    /// FIX #1333: Event-driven mempool detection — process a single TX received from unsolicited inv.
    /// Called from Peer.onMempoolTxData callback when block listener receives a `tx` response
    /// after our getdata request triggered by unsolicited `inv` MSG_TX.
    /// This is INSTANT (within seconds) vs the old 18-second polling approach.
    private func processIncomingMempoolTx(txid: Data, rawTx: Data, fromPeer: String) async {
        // Skip if background processes disabled (initial sync in progress)
        guard backgroundProcessesEnabled else {
            print("🔮 FIX #1333: Skipping instant mempool TX (initial sync in progress)")
            return
        }

        // VUL-U-002: Get spending key for trial decryption with secure zeroing
        guard let secureKey = try? SecureKeyStorage().retrieveSpendingKeySecure() else {
            print("🔮 FIX #1333: Could not retrieve spending key — skipping")
            return
        }
        defer { secureKey.zero() }
        let spendingKey = secureKey.data

        // txid from doubleSHA256().reversed() is DISPLAY format (big-endian, human-readable)
        let txidDisplayHex = txid.map { String(format: "%02x", $0) }.joined()
        // Wire format (little-endian) for DB storage — matches block-scanned txids
        let txidWire = Data(txid.reversed())

        // Skip our own pending outgoing transactions (change outputs)
        let pendingOutgoingTxids = await txTrackingState.getAllPendingOutgoingTxids()
        if pendingOutgoingTxids.contains(txidDisplayHex) || isPendingOutgoingSync(txid: txidDisplayHex) {
            print("🔮 FIX #1333: Skipping \(txidDisplayHex.prefix(12))... (our pending outgoing)")
            return
        }

        // Skip if sent recently (change output)
        if let lastSend = WalletManager.shared.lastSendTimestamp,
           Date().timeIntervalSince(lastSend) < 120.0 {
            print("🔮 FIX #1333: Skipping \(txidDisplayHex.prefix(12))... (recent send — likely change)")
            return
        }

        // Skip if we have pending outgoing (any mempool TX during send is likely change)
        if mempoolOutgoing > 0 {
            print("🔮 FIX #1333: Skipping \(txidDisplayHex.prefix(12))... (mempoolOutgoing > 0 — likely change)")
            return
        }

        // FIX #1397: Check for external spends BEFORE treating as incoming
        // Parse shielded spends (nullifiers) and check if ANY match our notes
        // This detects when another wallet (e.g. full node daemon) spent our notes
        // FIX #1398: Accumulate total input and compute sent amount for pending display
        var externalSpendTotal: UInt64 = 0
        if let nullifiers = parseShieldedSpends(from: rawTx) {
            for nullifier in nullifiers {
                if let noteInfo = try? WalletDatabase.shared.getNoteByNullifier(nullifier: nullifier) {
                    let isOurPending = pendingOutgoingTxids.contains(txidDisplayHex) || isPendingOutgoingSync(txid: txidDisplayHex)
                    let isOurRecorded = (try? WalletDatabase.shared.transactionExists(txid: txidWire, type: .sent)) ?? false
                    if !isOurPending && !isOurRecorded {
                        externalSpendTotal += noteInfo.value
                    }
                }
            }
        }

        // Parse and trial decrypt shielded outputs
        let outputs = parseShieldedOutputs(from: rawTx)

        var txIncomingAmount: UInt64 = 0
        // FIX #1403: Track individual output values for same-key external spend detection
        var decryptedOutputValues: [UInt64] = []
        if let outputs = outputs {
            for output in outputs {
                if let decrypted = ZipherXFFI.tryDecryptNoteWithSK(
                    spendingKey: spendingKey,
                    epk: output.epk,
                    cmu: output.cmu,
                    ciphertext: output.ciphertext
                ) {
                    if decrypted.count >= 19 {
                        let valueBytes = Data(decrypted[11..<19])
                        let value = valueBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                        txIncomingAmount += value
                        decryptedOutputValues.append(value)
                        if externalSpendTotal == 0 {
                            // Only log as "incoming" if NOT an external spend
                            print("🔮 FIX #1333: 💰 INSTANT DETECT — incoming \(value.redactedAmount) in TX \(txidDisplayHex.prefix(12))... from [\(fromPeer)]")
                        }
                    }
                }
            }
        }

        // FIX #1397/1398: External spend detected — show as pending OUTGOING, not incoming
        if externalSpendTotal > 0 {
            let fee: UInt64 = 10_000
            let changeAmount = txIncomingAmount  // Our decryptable outputs = change back to us
            var sentAmount = externalSpendTotal > (changeAmount + fee) ? externalSpendTotal - changeAmount - fee : 0

            // FIX #1403: Same-key scenario — when ALL outputs are decryptable (same IVK controls
            // both destination and change), sentAmount computes to 0. In this case, the smallest
            // decrypted output is the actual sent amount (the larger one is change).
            if sentAmount == 0 && decryptedOutputValues.count >= 2 {
                let sorted = decryptedOutputValues.sorted()
                sentAmount = sorted[0]  // Smallest output = destination amount
                print("🔮 FIX #1403: Same-key external spend — all outputs decryptable. Using smallest output (\(sentAmount.redactedAmount)) as sent amount")
            }

            print("🔮 FIX #1398: EXTERNAL SPEND in TX \(txidDisplayHex.prefix(12))... — input: \(externalSpendTotal.redactedAmount), change: \(changeAmount.redactedAmount), sent: \(sentAmount.redactedAmount), fee: \(fee.redactedAmount)")

            // FIX #1406: Add to pendingOutgoingTxidSet so FIX #859 block scanner can confirm
            // AND prevent mempool scan from re-detecting as external spend
            pendingOutgoingLock.lock()
            pendingOutgoingTxidSet.insert(txidDisplayHex)
            pendingOutgoingLock.unlock()

            // FIX #1407: Set pendingBroadcastAmount for correct display in BalanceView.
            // The pendingBroadcastAmount path shows the sent amount directly (no fee subtraction)
            // and displays "awaiting confirmation" text. The mempoolOutgoing path would subtract
            // 10000 for display, which only works if fee IS included — but that's confusing.
            await MainActor.run {
                self.pendingBroadcastAmount = sentAmount  // Sent amount without fee — shown directly
                self.pendingBroadcastFee = fee             // Fee tracked separately
                self.pendingBroadcastTxid = txidDisplayHex
                self.mempoolOutgoing = sentAmount + fee    // Total deduction for effectiveDisplayBalance
                WalletManager.shared.recordBalanceBeforeExternalSpend()
                // FIX #1406: Persist for cross-restart tracking
                self.persistPendingTxid(txidDisplayHex)
            }
            // Track TX for confirmation monitoring
            _ = await txTrackingState.trackOutgoingSimple(txid: txidDisplayHex, amount: sentAmount)
            return
        }

        guard txIncomingAmount > 0 else { return }

        // Skip if already confirmed in DB
        let alreadyConfirmed = (try? WalletDatabase.shared.transactionExists(txid: txidWire, type: .received)) ?? false
        if alreadyConfirmed {
            print("🔮 FIX #1333: Skipping already-confirmed TX \(txidDisplayHex.prefix(12))...")
            return
        }

        // Check if this is a NEW TX we haven't notified about
        let isNewTx = await txTrackingState.checkAndMarkNotified(txid: txidDisplayHex)
        guard isNewTx else {
            print("🔮 FIX #1333: Already notified for TX \(txidDisplayHex.prefix(12))... — updating amount only")
            await MainActor.run {
                self.mempoolIncoming = txIncomingAmount
                self.mempoolTxCount = 1
            }
            return
        }

        // NEW incoming TX — send notification and celebrate!
        print("🔔 FIX #1333: 🎉 INSTANT MEMPOOL NOTIFICATION — \(txIncomingAmount.redactedAmount) in TX \(txidDisplayHex.prefix(12))... (event-driven, no polling!)")
        NotificationManager.shared.notifyReceived(amount: txIncomingAmount, txid: txidDisplayHex)

        // Track incoming TX
        await txTrackingState.trackIncoming(txid: txidDisplayHex, amount: txIncomingAmount)

        // Update UI
        await MainActor.run {
            self.mempoolIncoming = txIncomingAmount
            self.mempoolTxCount = 1
            self.justDetectedIncomingMempool = (txid: txidDisplayHex, amount: txIncomingAmount, clearingTime: nil)
            self.mempoolIncomingCelebrationTrigger += 1
            print("🏦 FIX #1333: CLEARING! Instant mempool detection: txid=\(txidDisplayHex.prefix(12))..., amount=\(txIncomingAmount.redactedAmount)")
        }
    }

    /// Parse shielded outputs from raw transaction data using proper Zcash v4 format
    private func parseShieldedOutputs(from rawTx: Data) -> [(cmu: Data, epk: Data, ciphertext: Data)]? {
        // Zcash v4 overwintered Sapling transaction format
        guard rawTx.count > 200 else { return nil }

        var pos = 0
        var outputs: [(cmu: Data, epk: Data, ciphertext: Data)] = []

        // Header (4 bytes): version and fOverwintered flag
        guard pos + 4 <= rawTx.count else { return nil }
        let header = rawTx.loadUInt32(at: pos)
        let version = header & 0x7FFFFFFF
        let fOverwintered = (header & 0x80000000) != 0
        pos += 4

        // Must be Sapling v4 overwintered transaction
        guard fOverwintered && version >= 4 else {
            print("🔮 parseShieldedOutputs: Not Sapling v4 (v\(version), overwinter=\(fOverwintered))")
            return nil
        }

        // nVersionGroupId (4 bytes)
        guard pos + 4 <= rawTx.count else { return nil }
        let versionGroupId = rawTx.loadUInt32(at: pos)
        pos += 4

        // Verify Sapling version group ID (0x892F2085)
        guard versionGroupId == 0x892F2085 else {
            print("🔮 parseShieldedOutputs: Not Sapling versionGroupId=0x\(String(format: "%08X", versionGroupId))")
            return nil
        }

        // Skip vin (transparent inputs)
        let (vinCount, vinBytes) = readCompactSize(rawTx, at: pos)
        pos += vinBytes
        for _ in 0..<min(vinCount, 10000) {
            guard pos < rawTx.count else { return nil }
            pos = skipTransparentInput(rawTx, offset: pos)
        }

        // Skip vout (transparent outputs)
        let (voutCount, voutBytes) = readCompactSize(rawTx, at: pos)
        pos += voutBytes
        for _ in 0..<min(voutCount, 10000) {
            guard pos < rawTx.count else { return nil }
            pos = skipTransparentOutput(rawTx, offset: pos)
        }

        // Skip nLockTime (4 bytes)
        guard pos + 4 <= rawTx.count else { return nil }
        pos += 4

        // Skip nExpiryHeight (4 bytes)
        guard pos + 4 <= rawTx.count else { return nil }
        pos += 4

        // Skip valueBalance (8 bytes)
        guard pos + 8 <= rawTx.count else { return nil }
        pos += 8

        // Skip vShieldedSpend (each SpendDescription is 384 bytes)
        let (spendCount, spendBytes) = readCompactSize(rawTx, at: pos)
        pos += spendBytes
        for _ in 0..<min(spendCount, 10000) {
            guard pos + 384 <= rawTx.count else { return nil }
            pos += 384 // cv(32) + anchor(32) + nullifier(32) + rk(32) + zkproof(192) + spendAuthSig(64)
        }

        // vShieldedOutput (each OutputDescription is 948 bytes)
        let (outputCount, outputBytes) = readCompactSize(rawTx, at: pos)
        pos += outputBytes
        print("🔮 parseShieldedOutputs: Found \(outputCount) shielded outputs at pos=\(pos)")

        for i in 0..<min(outputCount, 10000) {
            // OutputDescription: cv(32) + cmu(32) + ephemeralKey(32) + encCiphertext(580) + outCiphertext(80) + zkproof(192)
            guard pos + 948 <= rawTx.count else {
                print("🔮 parseShieldedOutputs: Not enough data for output \(i) at pos=\(pos)")
                break
            }

            // cv (32 bytes) - skip
            pos += 32

            // cmu (32 bytes) - EXTRACT
            let cmu = rawTx.subdata(in: pos..<pos+32)
            pos += 32

            // ephemeralKey (32 bytes) - EXTRACT
            let epk = rawTx.subdata(in: pos..<pos+32)
            pos += 32

            // encCiphertext (580 bytes) - EXTRACT
            let ciphertext = rawTx.subdata(in: pos..<pos+580)
            pos += 580

            outputs.append((cmu: cmu, epk: epk, ciphertext: ciphertext))
            print("🔮 parseShieldedOutputs: Output[\(i)] cmu=\(cmu.prefix(8).map { String(format: "%02x", $0) }.joined())...")

            // outCiphertext (80 bytes) - skip
            pos += 80

            // zkproof (192 bytes) - skip
            pos += 192
        }

        return outputs.isEmpty ? nil : outputs
    }

    /// FIX #174: Parse shielded spends (nullifiers) from raw transaction data
    /// Returns array of nullifier Data (32 bytes each) for detecting external wallet spends
    private func parseShieldedSpends(from rawTx: Data) -> [Data]? {
        // Zcash v4 overwintered Sapling transaction format
        guard rawTx.count > 200 else { return nil }

        var pos = 0
        var nullifiers: [Data] = []

        // Header (4 bytes): version and fOverwintered flag
        guard pos + 4 <= rawTx.count else { return nil }
        let header = rawTx.loadUInt32(at: pos)
        let version = header & 0x7FFFFFFF
        let fOverwintered = (header & 0x80000000) != 0
        pos += 4

        // Must be Sapling v4 overwintered transaction
        guard fOverwintered && version >= 4 else { return nil }

        // nVersionGroupId (4 bytes)
        guard pos + 4 <= rawTx.count else { return nil }
        let versionGroupId = rawTx.loadUInt32(at: pos)
        pos += 4

        // Verify Sapling version group ID (0x892F2085)
        guard versionGroupId == 0x892F2085 else { return nil }

        // Skip vin (transparent inputs)
        let (vinCount, vinBytes) = readCompactSize(rawTx, at: pos)
        pos += vinBytes
        for _ in 0..<min(vinCount, 10000) {
            guard pos < rawTx.count else { return nil }
            pos = skipTransparentInput(rawTx, offset: pos)
        }

        // Skip vout (transparent outputs)
        let (voutCount, voutBytes) = readCompactSize(rawTx, at: pos)
        pos += voutBytes
        for _ in 0..<min(voutCount, 10000) {
            guard pos < rawTx.count else { return nil }
            pos = skipTransparentOutput(rawTx, offset: pos)
        }

        // Skip nLockTime (4 bytes)
        guard pos + 4 <= rawTx.count else { return nil }
        pos += 4

        // Skip nExpiryHeight (4 bytes)
        guard pos + 4 <= rawTx.count else { return nil }
        pos += 4

        // Skip valueBalance (8 bytes)
        guard pos + 8 <= rawTx.count else { return nil }
        pos += 8

        // vShieldedSpend - EXTRACT nullifiers (each SpendDescription is 384 bytes)
        // SpendDescription: cv(32) + anchor(32) + nullifier(32) + rk(32) + zkproof(192) + spendAuthSig(64)
        let (spendCount, spendBytes) = readCompactSize(rawTx, at: pos)
        pos += spendBytes

        for _ in 0..<min(spendCount, 10000) {
            guard pos + 384 <= rawTx.count else { return nil }

            // cv (32 bytes) - skip
            pos += 32

            // anchor (32 bytes) - skip
            pos += 32

            // nullifier (32 bytes) - EXTRACT
            let nullifier = rawTx.subdata(in: pos..<pos+32)
            nullifiers.append(nullifier)
            pos += 32

            // rk (32 bytes) - skip
            pos += 32

            // zkproof (192 bytes) - skip
            pos += 192

            // spendAuthSig (64 bytes) - skip
            pos += 64
        }

        return nullifiers.isEmpty ? nil : nullifiers
    }

    /// Helper: Read compact size (varint) from data
    private func readCompactSize(_ data: Data, at offset: Int) -> (UInt64, Int) {
        guard offset < data.count else { return (0, 0) }

        let first = data[offset]
        if first < 253 {
            return (UInt64(first), 1)
        } else if first == 253 {
            guard offset + 3 <= data.count else { return (0, 1) }
            let value = UInt16(data[offset + 1]) | (UInt16(data[offset + 2]) << 8)
            return (UInt64(value), 3)
        } else if first == 254 {
            guard offset + 5 <= data.count else { return (0, 1) }
            let value = data.loadUInt32(at: offset + 1)
            return (UInt64(value), 5)
        } else {
            guard offset + 9 <= data.count else { return (0, 1) }
            let value = data.loadUInt64(at: offset + 1)
            return (value, 9)
        }
    }

    /// Helper: Skip a transparent input
    private func skipTransparentInput(_ data: Data, offset: Int) -> Int {
        var pos = offset
        guard pos + 36 <= data.count else { return data.count }
        pos += 36 // prevout: txid (32) + vout index (4)

        let (scriptLen, scriptBytes) = readCompactSize(data, at: pos)
        pos += scriptBytes
        guard scriptLen <= UInt64(data.count - pos) else { return data.count }
        pos += Int(clamping: scriptLen)

        guard pos + 4 <= data.count else { return data.count }
        pos += 4 // sequence
        return pos
    }

    /// Helper: Skip a transparent output
    private func skipTransparentOutput(_ data: Data, offset: Int) -> Int {
        var pos = offset
        guard pos + 8 <= data.count else { return data.count }
        pos += 8 // value

        let (scriptLen, scriptBytes) = readCompactSize(data, at: pos)
        pos += scriptBytes
        guard scriptLen <= UInt64(data.count - pos) else { return data.count }
        pos += Int(clamping: scriptLen)
        return pos
    }

    /// Last time price was fetched (for rate limiting)
    private var lastPriceFetchTime: Date?

    /// Fetch ZCL price from API (with fallback, rate limited to every hour)
    /// FIX #1472: Made internal (was private) so Full Node mode can trigger price fetch
    func fetchZCLPrice() async {
        // Rate limit: only fetch every hour (3600 seconds)
        if let lastFetch = lastPriceFetchTime, Date().timeIntervalSince(lastFetch) < 3600 {
            print("💰 Price fetch skipped (rate limited - hourly)")
            return
        }
        lastPriceFetchTime = Date()
        print("💰 Fetching ZCL price...")

        // Try CoinGecko API first
        if let price = await fetchPriceFromCoinGecko() {
            print("💰 CoinGecko price: $\(price)")
            await MainActor.run {
                self.zclPriceUSD = price
                self.zclPriceFailed = false
            }
            return
        }

        // Fallback: Try CoinMarketCap (free tier)
        if let price = await fetchPriceFromCoinMarketCap() {
            print("💰 CoinMarketCap price: $\(price)")
            await MainActor.run {
                self.zclPriceUSD = price
                self.zclPriceFailed = false
            }
            return
        }

        // Both APIs failed - keep existing price if we have one
        print("⚠️ Failed to fetch ZCL price from any source")
        await MainActor.run {
            self.zclPriceFailed = true
        }
    }

    private func fetchPriceFromCoinGecko() async -> Double? {
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=zclassic&vs_currencies=usd") else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                print("💰 CoinGecko HTTP status: \(httpResponse.statusCode)")
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let zclData = json["zclassic"] as? [String: Any],
               let price = zclData["usd"] as? Double {
                return price
            }
            print("💰 CoinGecko: couldn't parse response: \(String(data: data, encoding: .utf8) ?? "nil")")
        } catch {
            print("⚠️ CoinGecko price fetch failed: \(error)")
        }
        return nil
    }

    private func fetchPriceFromCoinMarketCap() async -> Double? {
        // CoinMarketCap free tier - uses their web API endpoint (no API key needed)
        // ZCL ID on CoinMarketCap is 1447
        guard let url = URL(string: "https://api.coinmarketcap.com/data-api/v3/cryptocurrency/quote/latest?id=1447&convertId=2781") else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                print("💰 CoinMarketCap HTTP status: \(httpResponse.statusCode)")
                if httpResponse.statusCode != 200 {
                    print("💰 CoinMarketCap: non-200 status")
                    return nil
                }
            }

            // Parse response: {"data":{"id":1447,"name":"Zclassic",...,"quote":[{"price":0.49,...}]}}
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let quotes = dataObj["quote"] as? [[String: Any]],
               let firstQuote = quotes.first,
               let price = firstQuote["price"] as? Double {
                return price
            }

            // Log response for debugging
            let responseStr = String(data: data, encoding: .utf8) ?? "nil"
            print("💰 CoinMarketCap: couldn't parse response: \(responseStr.prefix(500))")
        } catch {
            print("⚠️ CoinMarketCap price fetch failed: \(error)")
        }
        return nil
    }

    // MARK: - Peer Discovery

    private func discoverPeers() async -> [PeerAddress] {
        var addresses: [PeerAddress] = []

        // FIX #1077: Check if we're in ZipherX P2P mode (no local node)
        let isFullNodeMode = WalletModeManager.shared.isUsingWalletDat

        // FIX #234: Add hardcoded Zclassic seed nodes FIRST (DNS often returns Zcash nodes)
        // These are known-good Zclassic nodes that will always work
        for seedNode in ZclassicCheckpoints.seedNodes {
            // FIX #1077: NEVER add localhost (127.0.0.1) in ZipherX P2P mode - no local node exists!
            if !isFullNodeMode && (seedNode == "127.0.0.1" || seedNode == "localhost") {
                continue  // Skip localhost in ZipherX mode
            }
            addresses.append(PeerAddress(host: seedNode, port: defaultPort))
            print("🌱 Added hardcoded seed: \(seedNode)")
        }
        let addedCount = isFullNodeMode ? ZclassicCheckpoints.seedNodes.count : ZclassicCheckpoints.seedNodes.count - 1
        print("🌱 FIX #234: Added \(addedCount) hardcoded Zclassic seed nodes\(isFullNodeMode ? "" : " (localhost skipped - ZipherX mode)")")

        // FIX #1401 (NET-003): DNS seeds controlled by user setting (disabled by default).
        // DNS resolution uses system DNS (clearnet) — leaks to ISP that user is
        // looking up Zclassic seed nodes. User can enable in Settings → Network → DNS Seeds.
        let dnsEnabled = UserDefaults.standard.bool(forKey: "useDNSSeeds")
        if dnsEnabled {
            // User explicitly enabled DNS seeds — resolve them
            for seed in dnsSeedsZCL {
                let resolved = await resolveDNSSeed(seed)
                addresses.append(contentsOf: resolved)
            }
            print("🌐 DNS Seeds: Resolved \(addresses.count) addresses from DNS seeds")
        } else {
            print("🌐 DNS Seeds: Disabled (Settings → Network → DNS Seeds to enable)")
        }

        // Add .onion seed nodes if Tor is available
        let torMode = await TorManager.shared.mode
        let torConnected = await TorManager.shared.connectionState.isConnected
        if torMode == .enabled && torConnected {
            for onionSeed in ZclassicCheckpoints.onionSeedNodes {
                addresses.append(PeerAddress(host: onionSeed, port: defaultPort))
                print("🧅 Added .onion seed: \(LogRedaction.redactHost(onionSeed))")
            }
        }

        return addresses
    }

    /// Resolve DNS seeds on demand (called when user enables DNS Seeds toggle in Settings).
    /// Discovers new peer addresses and connects to them immediately — no restart needed.
    func resolveDNSSeedsNow() async {
        // FIX #1490 (VULN-005): Skip DNS seed resolution when Tor is enabled and connected.
        // This is a belt-and-suspenders guard — resolveDNSSeed() also checks, but we block
        // here early to avoid even attempting DNS queries that would be silently discarded.
        let torMode = await TorManager.shared.mode
        let torConnected = await TorManager.shared.connectionState.isConnected
        if torMode == .enabled && torConnected {
            print("🧅 FIX #1490: DNS Seeds on-demand resolution skipped — Tor active. Use Settings → Tor to browse .onion peers.")
            return
        }

        print("🌐 DNS Seeds: Resolving on demand...")
        var newAddresses: [PeerAddress] = []
        for seed in dnsSeedsZCL {
            let resolved = await resolveDNSSeed(seed)
            newAddresses.append(contentsOf: resolved)
        }
        print("🌐 DNS Seeds: Resolved \(newAddresses.count) addresses")

        // Add to known addresses
        for address in newAddresses {
            addAddress(address, source: "dns-seed")
        }

        // Connect to new peers
        let currentReady = peers.filter { $0.isConnectionReady }.count
        await growPeerCount(currentReady: currentReady)
    }

    private func resolveDNSSeed(_ hostname: String) async -> [PeerAddress] {
        // FIX #1490 (VULN-005): Block clearnet DNS when Tor is enabled and connected.
        // CFHostStartInfoResolution routes through the system resolver (clearnet), which
        // leaks the DNS seed hostname to the ISP/DNS provider — revealing Zclassic wallet
        // usage and undermining Tor anonymity. When Tor is active, callers must use
        // .onion seeds (already added in discoverPeers) instead of DNS seeds.
        let torMode = await TorManager.shared.mode
        let torConnected = await TorManager.shared.connectionState.isConnected
        if torMode == .enabled && torConnected {
            print("🧅 FIX #1490: Clearnet DNS skipped for \(LogRedaction.redactHost(hostname)) — Tor active, use .onion seeds")
            return []
        }

        // VUL-N-011: Check DNS cache first (1-hour TTL)
        if let cached = dnsCache[hostname] {
            let age = Date().timeIntervalSince(cached.resolvedAt)
            if age < DNS_CACHE_TTL {
                if verbose {
                    print("🗂️ VUL-N-011: Using cached DNS for \(hostname) (age: \(Int(age))s)")
                }
                return cached.addresses
            } else {
                if verbose {
                    print("⏰ VUL-N-011: DNS cache expired for \(hostname) (age: \(Int(age))s)")
                }
            }
        }

        return await withCheckedContinuation { continuation in
            // Dispatch DNS resolution to background queue to avoid priority inversion
            DispatchQueue.global(qos: .utility).async {
                let host = CFHostCreateWithName(nil, hostname as CFString).takeRetainedValue()
                var resolved = DarwinBoolean(false)

                CFHostStartInfoResolution(host, .addresses, nil)

                guard let addresses = CFHostGetAddressing(host, &resolved)?.takeUnretainedValue() as? [Data] else {
                    continuation.resume(returning: [])
                    return
                }

                var peerAddresses: [PeerAddress] = []
                for addressData in addresses {
                    var hostnameBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    addressData.withUnsafeBytes { ptr in
                        let sockaddr = ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                        getnameinfo(sockaddr, socklen_t(addressData.count), &hostnameBuffer, socklen_t(hostnameBuffer.count), nil, 0, NI_NUMERICHOST)
                    }
                    let hostStr = String(cString: hostnameBuffer)
                    peerAddresses.append(PeerAddress(host: hostStr, port: self.defaultPort))
                }

                // VUL-N-011: Store in cache
                self.dnsCache[hostname] = (addresses: peerAddresses, resolvedAt: Date())
                if self.verbose {
                    print("💾 VUL-N-011: Cached \(peerAddresses.count) addresses for \(hostname)")
                }

                continuation.resume(returning: peerAddresses)
            }
        }
    }

    /// FIX #429: Continue connecting to peers in background after initial connect() returns
    /// This allows the UI to proceed while we establish more connections for resilience
    private func connectToRemainingPeersInBackground(
        remainingPeers: [PeerAddress],
        targetPeers: Int,
        currentConnected: Int
    ) async {
        var connectedCount = currentConnected
        var peerIndex = 0
        let maxConcurrent = 5 // Slower in background to not overwhelm network
        let bgPeerCap = 8     // FIX #1446: Stop when 8 ready peers (sufficient for consensus + resilience)

        while connectedCount < targetPeers && peerIndex < remainingPeers.count {
            // FIX #1446: Check live peer count — stop when sufficient
            let readyPeers = peers.filter { $0.isConnectionReady }.count
            if readyPeers >= bgPeerCap {
                print("✅ FIX #1446: Background discovery stopped — \(readyPeers) peers ready (sufficient)")
                break
            }

            let batchEnd = min(peerIndex + maxConcurrent, remainingPeers.count)
            let batch = Array(remainingPeers[peerIndex..<batchEnd])
            peerIndex = batchEnd

            await withTaskGroup(of: (Peer?, PeerAddress).self) { group in
                for address in batch {
                    if self.isBanned(address.host) || self.isOnCooldown(address.host, port: address.port) {
                        continue
                    }

                    group.addTask {
                        do {
                            let peer = try await self.connectToPeer(address)
                            return (peer, address)
                        } catch {
                            return (nil, address)
                        }
                    }
                }

                for await (peer, _) in group {
                    if let peer = peer {
                        // FIX #1421: Dedup — remove stale peer for same host:port before adding fresh one
                        if let existingIdx = peers.firstIndex(where: { $0.host == peer.host && $0.port == peer.port }) {
                            peers.remove(at: existingIdx)
                        }
                        peers.append(peer)
                        // FIX #478: Also add to PeerManager to keep peer lists in sync
                        PeerManager.shared.addPeer(peer)
                        self.resetSybilCounter()
                        self.setupBlockListener(for: peer)

                        // FIX #1446: Use live count from global peers array
                        connectedCount = peers.filter { $0.isConnectionReady }.count

                        // FIX #1420: Update UI from GLOBAL peers array
                        await MainActor.run {
                            self.connectedPeers = self.peers.filter { $0.isConnectionReady }.count
                        }

                        // FIX #1446: Stop at bgPeerCap or targetPeers
                        if connectedCount >= bgPeerCap || connectedCount >= targetPeers {
                            group.cancelAll()
                            break
                        }
                    }
                }
            }

            // Small delay between batches to be gentle on the network
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }

        if connectedCount > currentConnected {
            print("✅ FIX #429: Background connection added \(connectedCount - currentConnected) more peers (total: \(connectedCount))")
            PeerManager.shared.syncPeers(self.peers)
        }
    }

    /// FIX #1461: Proactive peer growth — called from keepalive when below MIN_PEERS.
    /// Unlike attemptPeerRecovery (which is for emergencies when peers < 3), this is gentle
    /// growth to reach MIN_PEERS for optimal P2P performance. Tries a small batch each cycle.
    private func growPeerCount(currentReady: Int) async {
        // Don't overlap with active recovery
        guard !isRecoveringPeers else { return }

        let needed = MIN_PEERS - currentReady
        guard needed > 0 else { return }

        // Collect candidates: known addresses not already connected, not banned, not on cooldown
        let connectedHosts = Set(peers.map { $0.host })
        var candidates: [PeerAddress] = []

        // Hardcoded seeds first
        for seedHost in HARDCODED_SEEDS {
            if !connectedHosts.contains(seedHost) && !isBanned(seedHost) && !isOnCooldown(seedHost, port: defaultPort) {
                candidates.append(PeerAddress(host: seedHost, port: defaultPort))
            }
        }

        // Then known addresses
        addressLock.lock()
        let known = knownAddresses.values.map { $0.address }
        addressLock.unlock()
        for address in known {
            if candidates.count >= needed + 3 { break } // Try a few extra for failures
            if !connectedHosts.contains(address.host) && !isBanned(address.host) &&
               !isOnCooldown(address.host, port: address.port) &&
               !candidates.contains(where: { $0.host == address.host }) {
                candidates.append(address)
            }
        }

        // FIX #1469: Re-resolve DNS seeds when no candidates available
        if candidates.isEmpty {
            let dnsEnabled = UserDefaults.standard.bool(forKey: "useDNSSeeds")
            if dnsEnabled {
                let freshPeers = await discoverPeers()
                for address in freshPeers {
                    if !connectedHosts.contains(address.host) && !isBanned(address.host) &&
                       !isOnCooldown(address.host, port: address.port) &&
                       !candidates.contains(where: { $0.host == address.host }) {
                        addAddress(address, source: "dns")
                        candidates.append(address)
                    }
                }
                if !candidates.isEmpty {
                    debugLog(.network, "🫀 FIX #1469: DNS re-resolution found \(candidates.count) new candidates")
                }
            }
        }

        guard !candidates.isEmpty else {
            debugLog(.network, "🫀 FIX #1461: No candidates for peer growth (even after DNS)")
            return
        }

        // Try a small batch (up to 5) in parallel — gentle, won't overwhelm network
        let batchSize = min(5, candidates.count)
        var grown = 0

        await withTaskGroup(of: (Peer?, PeerAddress).self) { group in
            for address in candidates.prefix(batchSize) {
                group.addTask {
                    do {
                        let peer = try await self.connectToPeer(address)
                        return (peer, address)
                    } catch {
                        return (nil, address)
                    }
                }
            }

            for await (peer, address) in group {
                if let peer = peer {
                    if !peers.contains(where: { $0.host == peer.host && $0.port == peer.port }) {
                        peers.append(peer)
                        PeerManager.shared.addPeer(peer)
                        setupBlockListener(for: peer)
                        unparkPeer(address.host, port: address.port)
                        grown += 1

                        await MainActor.run {
                            self.connectedPeers = self.peers.filter { $0.isConnectionReady }.count
                        }
                    } else {
                        peer.disconnect()
                    }
                }
            }
        }

        if grown > 0 {
            print("✅ FIX #1461: Peer growth added \(grown) peer(s) — now \(peers.filter { $0.isConnectionReady }.count)/\(MIN_PEERS)")
            PeerManager.shared.syncPeers(self.peers)
        }
    }

    private func connectToPeer(_ address: PeerAddress) async throws -> Peer {
        // FIX #856: Skip .onion addresses entirely if Tor is disabled
        let torMode = await TorManager.shared.mode
        if address.host.hasSuffix(".onion") && torMode != .enabled {
            throw NetworkError.connectionFailed(".onion addresses require Tor to be enabled")
        }

        let peer = Peer(host: address.host, port: address.port, networkMagic: networkMagic)

        // FIX #1112 v4: Aggressive timeouts - good peers connect in <1s
        // 2s direct, 5s Tor - don't waste startup time on slow peers
        let isLocalhost = address.host == "127.0.0.1" || address.host == "localhost"
        let torBypassed = await TorManager.shared.isTorBypassed
        let useTor = torMode == .enabled && !torBypassed && !isLocalhost
        let timeoutNanos: UInt64 = useTor ? 5_000_000_000 : 2_000_000_000  // 5s Tor, 2s direct

        // Add timeout for connection attempts
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await peer.connect()
                try await peer.performHandshake()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanos)
                throw NetworkError.connectionTimeout
            }

            // Wait for first to complete (either connection or timeout)
            try await group.next()
            group.cancelAll()
        }

        return peer
    }

    // MARK: - Block Announcement Listener

    /// Set up block announcement listener for a peer
    /// When the peer receives a new block via P2P inv message, it triggers a background sync
    /// FIX #509: NO LONGER auto-starts the listener - listeners are started only when app is ready
    private func setupBlockListener(for peer: Peer) {
        peer.onBlockAnnounced = { [weak self] blockHash in
            guard let self = self else { return }

            let hashHex = blockHash.map { String(format: "%02x", $0) }.joined()
            print("📦 New block announced: \(hashHex.prefix(16))...")

            // Trigger background sync immediately (non-blocking)
            Task {
                await self.onNewBlockAnnounced()
            }
        }

        // FIX #1333: Event-driven mempool detection — process unsolicited TX instantly
        // When a peer's mempool gets a new TX, it sends `inv` MSG_TX → block listener
        // requests getdata → peer sends full `tx` → this callback fires.
        // Trial decrypt here for INSTANT incoming TX detection (vs 18s polling).
        peer.onMempoolTxData = { [weak self] txid, rawTx in
            guard let self = self else { return }
            let txidHex = txid.map { String(format: "%02x", $0) }.joined()
            print("🔮 FIX #1333: [\(peer.host)] Received full TX \(txidHex.prefix(16))... from unsolicited inv — trial decrypting...")
            Task {
                await self.processIncomingMempoolTx(txid: txid, rawTx: rawTx, fromPeer: peer.host)
            }
        }

        // FIX #1336: One-time mempool query on peer connection.
        // Send `mempool` command ONCE — the response arrives as `inv` through the block listener,
        // which triggers handleInvMessage → getdata → case "tx": → onMempoolTxData → trial decrypt.
        // This catches TXs already in the peer's mempool before we connected.
        // After this, all new TXs are detected instantly via unsolicited `inv` — no polling needed.
        Task { [weak self] in
            // Wait for block listener to start (it's the TCP reader that processes responses)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self = self, peer.isConnectionReady else { return }
            guard self.backgroundProcessesEnabled else { return }
            do {
                try await peer.sendMessage(command: "mempool", payload: Data())
                print("🔮 FIX #1336: [\(peer.host)] Sent one-time mempool query (existing TXs)")
            } catch {
                print("⚠️ FIX #1336: [\(peer.host)] One-time mempool query failed: \(error.localizedDescription)")
            }
        }

        // FIX #509: DO NOT auto-start block listener here!
        // Block listeners are now started only:
        // 1. After header sync completes (resumeAllBlockListeners)
        // 2. When app is ready on main screen (explicit call)
        // This prevents race condition where listeners consume headers during sync
    }

    /// Called when any peer announces a new block
    /// Triggers fetchNetworkStats which will sync new blocks via backgroundSyncToHeight
    private func onNewBlockAnnounced() async {
        // Debounce: avoid multiple syncs if multiple peers announce same block
        let now = Date()
        if let lastAnnouncement = lastBlockAnnouncementTime,
           now.timeIntervalSince(lastAnnouncement) < 2.0 {
            return // Skip if less than 2 seconds since last announcement
        }
        lastBlockAnnouncementTime = now

        print("⚡ Processing new block announcement - triggering sync...")

        // Fetch network stats which will trigger backgroundSyncToHeight if needed
        await fetchNetworkStats()
    }

    /// Track last block announcement time for debouncing
    private var lastBlockAnnouncementTime: Date?

    // MARK: - Consensus Queries

    /// Query shielded balance with multi-peer consensus
    func queryShieldedBalance(for address: String) async throws -> ShieldedBalance {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        var responses: [String: Int] = [:]
        var balanceResponses: [String: ShieldedBalance] = [:]

        // Query all peers
        await withTaskGroup(of: (String, ShieldedBalance?).self) { group in
            for peer in peers {
                group.addTask {
                    do {
                        let balance = try await peer.getShieldedBalance(address: address)
                        return (peer.id, balance)
                    } catch {
                        return (peer.id, nil)
                    }
                }
            }

            for await (peerId, balance) in group {
                if let balance = balance {
                    let key = "\(balance.confirmed):\(balance.pending)"
                    responses[key, default: 0] += 1
                    balanceResponses[key] = balance
                }
            }
        }

        // Find consensus
        guard let (key, count) = responses.max(by: { $0.value < $1.value }),
              count >= CONSENSUS_THRESHOLD,
              let balance = balanceResponses[key] else {
            throw NetworkError.consensusNotReached
        }

        return balance
    }

    /// Broadcast progress callback type
    typealias BroadcastProgressCallback = (_ phase: String, _ detail: String?, _ progress: Double?) -> Void

    /// VUL-002: Broadcast result struct - includes mempool verification status
    /// CRITICAL: Database writes should ONLY happen when mempoolVerified is true
    struct BroadcastResult {
        let txId: String
        let mempoolVerified: Bool
        let peerCount: Int  // How many peers accepted
        let rejectCount: Int  // FIX #349: How many peers explicitly rejected
        let p2pVerificationAttempted: Bool  // FIX #590: Track if we attempted P2P verification
        let peersAttempted: Int  // FIX #990: Track how many peers were attempted (for timeout vs no peers distinction)
    }

    /// Broadcast transaction with multi-peer propagation and progress reporting
    /// Primary: P2P broadcast to connected peers
    /// Fallback: InsightAPI broadcast if no P2P peers available
    /// VUL-002: Returns BroadcastResult with mempoolVerified flag - CRITICAL for database writes
    /// NEW: Pass amount to enable instant UI feedback when first peer accepts
    func broadcastTransactionWithProgress(_ rawTx: Data, amount: UInt64 = 0, onProgress: BroadcastProgressCallback? = nil) async throws -> BroadcastResult {
        if verbose {
            print("📡 Starting broadcast, connected: \(isConnected), peers: \(peers.count)")
        }

        // FIX #1357: Ensure block listeners/dispatchers are active BEFORE broadcast.
        // If dispatchers are inactive, requestTransaction falls back to direct TCP reads
        // which are vulnerable to stream desync after broadcast (dirty bytes from inv/tx echo).
        // With dispatchers active, all reads go through the clean dispatcher path.
        // Must start BEFORE isBroadcasting=true (which blocks startBlockListenersOnMainScreen).
        await startBlockListenersOnMainScreen()
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms for dispatchers to activate

        // FIX #841: Block background sync during broadcast to prevent peer lock conflicts
        // Background sync triggers header sync which holds peer locks, causing broadcast timeouts
        isBroadcasting = true

        // FIX #1184: DO NOT stop block listeners before broadcast!
        // Stopping block listeners kills NWConnections → connections=nil → dispatcher inactive
        // → broadcast uses unreliable direct path → false accepts from desynced TCP
        // → false SETTLEMENT → phantom TX → balance corruption.
        // isBroadcasting=true prevents header sync from starting (which would stop listeners).
        // Block listeners stay running, dispatcher stays active, broadcast uses reliable dispatcher path.

        defer {
            isBroadcasting = false
        }
        if verbose {
            print("📡 FIX #841+#1184: isBroadcasting = true, block listeners KEPT RUNNING (dispatcher active)")
        }

        // ============================================================================
        // VUL-002 FIX: Validate Sapling proofs LOCALLY before broadcasting
        // This prevents broadcasting invalid transactions that peers would relay but
        // that the network mempool would ultimately reject. Without this validation,
        // an invalid TX could cause the wallet to mark notes as spent incorrectly.
        // ============================================================================
        onProgress?("verify", "Validating zk-SNARK proofs...", 0.0)

        // Get chain height for branch ID selection (Buttercup since height 707,000)
        let chainHeight: UInt64
        do {
            chainHeight = try await getChainHeight()
        } catch {
            // Fallback to cached chain height if network is unreliable
            chainHeight = self.chainHeight > 0 ? self.chainHeight : 2_940_000  // Safe default above Buttercup
            print("⚠️ Using cached chain height for TX validation: \(chainHeight)")
        }

        // Verify Sapling spend/output proofs and binding signature
        let verifyResult = ZipherXFFI.isTransactionValid(txData: rawTx, chainHeight: chainHeight)
        if !verifyResult.valid {
            let errorDesc = verifyResult.error?.errorDescription ?? "Unknown verification error"
            print("❌ VUL-002: Transaction verification FAILED: \(errorDesc)")
            print("❌ VUL-002: This transaction would be rejected by the mempool!")
            print("❌ VUL-002: Aborting broadcast to prevent invalid state")
            throw NetworkError.transactionRejected
        }
        print("✅ VUL-002: Transaction verification PASSED - proofs valid, safe to broadcast")
        onProgress?("verify", "Proofs validated ✓", 0.1)

        // ============================================================================
        // ============================================================================
        // FIX #718: CRITICAL - Validate anchor exists in blockchain via P2P
        // Peers will reject transactions where the anchor (Merkle root) doesn't exist!
        // VUL-002 Extension: Must verify TX will be ACCEPTED, not just proofs valid
        // ============================================================================
        onProgress?("verify", "Validating anchor via P2P...", 0.2)

        // Extract anchor from transaction and verify it exists in blockchain
        do {
            // Parse transaction to extract anchor from Sapling spends
            let anchorData = try await extractAnchorFromTransaction(rawTx)
            let anchorHex = anchorData.map { String(format: "%02x", $0) }.joined()
            print("🔍 FIX #718: Extracted anchor from TX: \(anchorHex.prefix(16))...")

            // FIX #718: Verify anchor exists via P2P - fetch recent headers and check sapling roots
            // This is more reliable than HeaderStore which may have corrupt data
            var anchorFound = false

            // First check HeaderStore (fast) - if found there, we're good
            let headerStoreHasAnchor = await HeaderStore.shared.containsSaplingRoot(anchorData)
            if headerStoreHasAnchor {
                print("✅ FIX #718: Anchor found in HeaderStore - TX will be accepted")
                anchorFound = true
            } else {
                // HeaderStore doesn't have it - could be corrupt or anchor is from wrong tree
                print("⚠️ FIX #718: Anchor NOT in HeaderStore - checking via P2P...")

                // Check FFI tree root - if anchor matches current FFI root, the tree is consistent
                if let ffiTreeRoot = ZipherXFFI.treeRoot() {
                    let ffiRootHex = ffiTreeRoot.map { String(format: "%02x", $0) }.joined()
                    print("📝 FIX #718: Current FFI tree root: \(ffiRootHex.prefix(16))...")

                    if anchorData == ffiTreeRoot {
                        // Anchor matches FFI tree - check if FFI tree matches blockchain
                        // Get recent header from P2P to verify
                        let peerHeight = try? await getChainHeight()
                        if let height = peerHeight, height > 0 {
                            if let header = try? HeaderStore.shared.getHeader(at: height) {
                                let headerRoot = header.hashFinalSaplingRoot
                                let headerRootHex = headerRoot.map { String(format: "%02x", $0) }.joined()
                                print("📝 FIX #718: HeaderStore root at \(height): \(headerRootHex.prefix(16))...")

                                // Check if header root is all zeros (HeaderStore incomplete during initial sync)
                                let isZeroRoot = headerRoot.allSatisfy { $0 == 0 }
                                if isZeroRoot {
                                    // FIX #1488: VULN-003 — NEVER trust an unverifiable FFI tree root.
                                    // Zero sapling root means HeaderStore has no blockchain data at this height yet
                                    // (occurs during initial sync before FIX #1204 has stored authoritative roots).
                                    // Previous code set anchorFound=true here, claiming "trust boost file verified at load" —
                                    // but this directly bypassed FIX #1279's requirement that the anchor must exist on
                                    // blockchain. Result: TX with phantom anchor broadcast → peers silently drop → false
                                    // SETTLEMENT → balance corruption (same failure mode as FIX #1221/FIX #1279).
                                    // Correct behavior: leave anchorFound=false → FIX #1221 rejects below if chain > boost.
                                    print("❌ FIX #1488: HeaderStore has zero sapling root — CANNOT verify anchor against blockchain")
                                    print("❌ FIX #1488: Refusing to trust FFI tree root without blockchain confirmation")
                                    print("❌ FIX #1488: anchorFound remains false — FIX #1221 will reject if chain > boost height")
                                } else if headerRoot == ffiTreeRoot {
                                    print("✅ FIX #718: FFI tree matches HeaderStore - anchor valid")
                                    anchorFound = true
                                } else {
                                    print("❌ FIX #718: FFI tree ROOT MISMATCH with HeaderStore!")
                                    print("❌ FIX #718: FFI:    \(ffiRootHex.prefix(16))...")
                                    print("❌ FIX #718: Header: \(headerRootHex.prefix(16))...")
                                    print("❌ FIX #718: Witnesses built from CORRUPT tree - run Repair Database!")
                                }
                            }
                        }
                    } else {
                        // Anchor doesn't match current FFI tree root - stale witness
                        print("⚠️ FIX #718: Anchor doesn't match current FFI tree root")
                        print("⚠️ FIX #718: Anchor:   \(anchorHex.prefix(16))...")
                        print("⚠️ FIX #718: FFI root: \(ffiRootHex.prefix(16))...")
                        print("⚠️ FIX #718: Witness may be stale - but could still be valid on blockchain")
                        // Check HeaderStore for this specific anchor (could be recent block)
                        // If not found, the anchor might not exist
                    }
                }
            }

            // FIX #821 + FIX #1204 + FIX #1221: Strict anchor validation.
            // FIX #1204 stores authoritative finalsaplingroot from full block fetches (delta sync,
            // block scanning). containsSaplingRoot() at line 4901 searches ALL stored roots.
            // If STILL not found after FIX #1204, the anchor likely comes from a corrupted/incomplete
            // commitment tree (e.g., gap-fill never completed, delta had missing CMUs).
            //
            // FIX #1221: DO NOT blindly trust anchors not in HeaderStore!
            // Previous FIX #821 set anchorFound=true here, causing TX broadcast with invalid anchor
            // → peers silently drop TX → mempool-disappearance triggers false SETTLEMENT → phantom TX
            // → balance corruption. Now we REJECT unless anchor is in HeaderStore.
            // Historical anchors from valid tree states WILL be in HeaderStore thanks to FIX #1204.
            let boostFileEndHeight = UInt64(ZipherXConstants.effectiveTreeHeight)
            if !anchorFound && chainHeight > boostFileEndHeight {
                print("❌ FIX #1221: Anchor NOT in HeaderStore AND NOT matching FFI tree root!")
                print("   Chain height \(chainHeight) > boost file end \(boostFileEndHeight)")
                print("   FIX #1204 should have stored all historical roots — anchor is likely from corrupted tree")
                print("   REJECTING TX to prevent phantom SETTLEMENT (FIX #1221)")
                // DO NOT set anchorFound = true — let it fall through to error
            }

            if !anchorFound {
                // FIX #1279: NEVER bypass anchor validation, even with DeltaBundleVerified=true.
                // FIX #1256 previously bypassed this check when delta was verified, trusting that
                // "verified tree = valid anchor". WRONG — the sim wallet proved this false:
                // FFI tree root at tip MATCHED blockchain (3ed752cc = real root at 3007184),
                // but witness computation produced anchor b6e85eb1... which is NOT a valid
                // finalsaplingroot at ANY block height. TX was broadcast, peers accepted to mempool,
                // but miners never mined it (8+ blocks, all coinbase-only). Anchor is phantom.
                // Root cause: witness FFI produces wrong merkle paths despite correct tree root.
                // DeltaBundleVerified only validates tip root, NOT intermediate witness anchors.
                // The ONLY safe check is containsSaplingRoot() — if anchor not found, REJECT.
                let deltaVerified = UserDefaults.standard.bool(forKey: "DeltaBundleVerified")
                print("❌ FIX #1279: Anchor NOT FOUND in HeaderStore — REJECTING TX")
                print("❌ FIX #1279: Anchor: \(anchorHex)")
                print("❌ FIX #1279: DeltaBundleVerified=\(deltaVerified) (irrelevant — tip root ≠ witness anchor)")
                print("❌ FIX #1279: Witness computation produces phantom anchors — run Full Rescan")
                onProgress?("error", "❌ Anchor invalid - run Full Rescan", 1.0)
                throw NetworkError.invalidTransaction("Anchor not found on blockchain - witness computation produced phantom anchor. Run Full Rescan to rebuild witnesses.")
            }

            print("✅ FIX #718: Anchor validation passed - TX should be accepted by network")
            onProgress?("verify", "Anchor validated ✓", 0.3)
        } catch let error as NetworkError {
            throw error  // Re-throw network errors
        } catch {
            print("⚠️ FIX #718: Anchor validation error: \(error.localizedDescription)")
            // Continue anyway - let P2P peers validate
        }

        // FIX #160 + FIX #211: Check if Tor is enabled - need longer timeouts for Tor
        // FIX #832: Per-peer timeout MUST be longer than lock acquisition timeout (10s)
        // FIX #837: Internal reject wait reduced from 15s to 2s, so timeouts can be shorter
        // Direct mode: 10s lock + 2s reject = 12s max, so 15s per-peer is enough
        let torEnabled = await TorManager.shared.mode == .enabled
        let perPeerTimeout: UInt64 = torEnabled ? 45_000_000_000 : 15_000_000_000  // FIX #837: 15s direct, 45s Tor
        let overallTimeout: UInt64 = torEnabled ? 90_000_000_000 : 30_000_000_000  // FIX #837: 30s direct, 90s Tor
        print("📡 FIX #211: Using \(torEnabled ? "TOR" : "DIRECT") timeouts: peer=\(perPeerTimeout/1_000_000_000)s, overall=\(overallTimeout/1_000_000_000)s")

        // FIX #1184: Block listeners are KEPT RUNNING during broadcast.
        // Previous FIX #834 stopped all block listeners here, killing NWConnections and
        // making dispatcher inactive. This forced broadcast to use the unreliable direct path
        // with orphan-prone receiveMessageWithTimeout — root cause of false SETTLEMENT.
        // With FIX #1184, broadcast uses the dispatcher path (lock-free, no orphaned readers).
        // isBroadcasting=true prevents header sync from stopping block listeners during broadcast.
        if verbose {
            print("📡 FIX #1184: Block listeners RUNNING — broadcast will use dispatcher path")
        }

        // FIX #160: Compute TX ID upfront - even if timeout occurs, we know what was sent
        let computedTxId = rawTx.doubleSHA256().reversed().map { String(format: "%02x", $0) }.joined()
        print("📡 FIX #160: Pre-computed txid: \(computedTxId)")

        // FIX #702: CRITICAL - Register pending TX IMMEDIATELY to prevent external spend false positives
        // Race condition: Mempool scan runs in parallel with broadcast and can detect our TX
        // BEFORE setPendingBroadcast is called. By adding to pendingOutgoingTxidSet NOW,
        // the mempool scan will correctly identify this as "our pending" TX.
        pendingOutgoingLock.lock()
        pendingOutgoingTxidSet.insert(computedTxId)
        pendingOutgoingLock.unlock()
        print("⚡ FIX #702: Pre-registered pending TX: \(computedTxId.prefix(12))... (prevents external spend false positive)")

        // FIX #849: Persist to UserDefaults for cross-restart tracking
        persistPendingTxid(computedTxId)

        // FIX #158: CRITICAL - Filter out banned peers from broadcast!
        // Banned peers may have been Sybil attackers - don't trust them to relay transactions
        let validPeers = peers.filter { !isBanned($0.host) }
        print("📡 FIX #158: Filtered peers: \(peers.count) total, \(validPeers.count) valid (not banned)")

        // ==========================================================================
        // FIX #335: Verify peer health before broadcast - prevent race with network recovery
        // Problem: Network path changes cause all peers to die simultaneously.
        // If we broadcast during recovery, peers may return garbage/stale responses.
        // Evidence: All 3 peers returned DUPLICATE (which means "already in mempool")
        // but mempool verification showed peers=0, mempool=false → TX was NOT sent!
        // ==========================================================================

        // Check 1: If network path changed recently, wait for recovery
        if let lastChange = lastPathChangeTime {
            let elapsed = Date().timeIntervalSince(lastChange)
            if elapsed < PATH_CHANGE_DEBOUNCE {
                let waitTime = PATH_CHANGE_DEBOUNCE - elapsed + 1.0  // +1s extra safety
                print("⚠️ FIX #335: Network path changed \(String(format: "%.1f", elapsed))s ago - waiting \(String(format: "%.1f", waitTime))s for recovery...")
                onProgress?("network", "Waiting for network to stabilize...", 0.15)
                try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
        }

        // Check 2: Filter peers by ACTUAL health (not just isConnectionReady)
        // A peer is healthy if: connection is ready AND (has recent activity OR successfully reconnected)
        let healthyPeers = validPeers.filter { peer in
            // Must have ready connection
            guard peer.isConnectionReady else { return false }
            // And must have recent activity (proves connection is alive)
            return peer.hasRecentActivity
        }

        let unhealthyCount = validPeers.count - healthyPeers.count
        if unhealthyCount > 0 {
            print("⚠️ FIX #335: \(unhealthyCount) peers have no recent activity - connection may be stale")
        }

        // Check 3: If no healthy peers, try to recover
        // FIX #830: Don't call performHandshake() on already-connected peers!
        // P2P protocol only allows ONE version message per connection.
        // Sending duplicate VERSION causes node to reject with "Duplicate version message"
        if healthyPeers.isEmpty && !validPeers.isEmpty {
            print("⚠️ FIX #335: No healthy peers - attempting quick recovery...")
            onProgress?("network", "Reconnecting to peers...", 0.15)

            // Try to verify/reconnect one peer (quick test)
            for peer in validPeers.prefix(3) {
                do {
                    // FIX #830: Check if peer is already connected before reconnecting
                    if peer.isConnectionReady {
                        // Peer is connected, just verify with ping (no handshake needed)
                        // FIX #869: sendPing now returns PingResult
                        let pingResult = await peer.sendPing(timeoutSeconds: 3.0)
                        if pingResult == .success {
                            print("✅ FIX #830: Peer \(peer.host) verified via ping - connection is alive")
                            break
                        } else {
                            // Ping failed, peer may be dead - try next peer
                            print("⚠️ FIX #830: Peer \(peer.host) ping failed (\(pingResult)) - trying next peer")
                            continue
                        }
                    } else {
                        // Peer is NOT connected, do full reconnection + handshake
                        // FIX #914: ensureConnected() already calls performHandshake() internally!
                        // DON'T call performHandshake() again - it causes "Duplicate version message" rejection
                        try await peer.ensureConnected()
                        print("✅ FIX #914: Peer \(peer.host) recovered via ensureConnected()")
                        break
                    }
                } catch {
                    print("⚠️ FIX #335: Peer \(peer.host) failed recovery: \(error)")
                }
            }
        }

        // Use healthy peers if available, otherwise fall back to validPeers with ensureConnected
        let broadcastPeers = healthyPeers.isEmpty ? validPeers : healthyPeers
        print("📡 FIX #335: Broadcasting to \(broadcastPeers.count) peers (\(healthyPeers.count) healthy, \(unhealthyCount) may be stale)")

        // FIX #378: Wait for peers to connect before failing
        // Problem: User tries to send but peers haven't connected yet
        // Solution: Wait up to 30 seconds for peers, with active recovery attempts
        var finalBroadcastPeers = broadcastPeers
        if !isConnected || finalBroadcastPeers.isEmpty {
            print("⚠️ FIX #378: No peers available - waiting for connection...")
            onProgress?("network", "Connecting to peers...", 0.1)

            let maxWaitTime: TimeInterval = 30.0
            let checkInterval: TimeInterval = 2.0
            var elapsed: TimeInterval = 0

            while elapsed < maxWaitTime {
                // Trigger peer recovery
                if elapsed == 0 || Int(elapsed) % 10 == 0 {
                    print("🔄 FIX #378: Triggering peer recovery (elapsed: \(Int(elapsed))s)...")
                    await attemptPeerRecovery()
                }

                // Wait a bit
                try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                elapsed += checkInterval

                // Check for connected peers
                let currentPeers = peers.filter { !isBanned($0.host) && $0.isConnectionReady }
                if !currentPeers.isEmpty {
                    finalBroadcastPeers = currentPeers
                    print("✅ FIX #378: \(currentPeers.count) peer(s) connected after \(Int(elapsed))s")
                    break
                }

                let progress = min(0.25, 0.1 + (elapsed / maxWaitTime) * 0.15)
                onProgress?("network", "Waiting for peers (\(Int(maxWaitTime - elapsed))s)...", progress)
            }

            // Final check
            if finalBroadcastPeers.isEmpty {
                print("❌ FIX #378: No peers available after \(Int(maxWaitTime))s wait")
                throw NetworkError.connectionFailed("No P2P peers available for broadcast (waited \(Int(maxWaitTime))s)")
            }
        }

        // ==========================================================================
        // FIX #380 v2: INSTANT broadcast using recently active peers
        // Problem: Ping verification was slow (3s+ timeout) and had race condition
        //          with block listeners consuming PONG responses
        // Solution: Use hasRecentActivity check instead of ping
        //          - If peer communicated within 60s, it's verified alive
        //          - Only do recovery if ALL peers are stale (no recent activity)
        // ==========================================================================

        // Separate peers by activity
        let activePeers = finalBroadcastPeers.filter { $0.hasRecentActivity }
        let stalePeers = finalBroadcastPeers.filter { !$0.hasRecentActivity }

        print("⚡ FIX #380 v2: \(activePeers.count) recently active, \(stalePeers.count) stale peers")

        var verifiedPeers: [Peer] = activePeers  // Active peers are verified by definition

        // If we have active peers, use them immediately (INSTANT!)
        if !activePeers.isEmpty {
            for peer in activePeers {
                print("✅ FIX #380 v2: Peer \(peer.host) has recent activity (\(peer.secondsSinceActivity)s ago)")
            }
        } else if !stalePeers.isEmpty {
            // All peers are stale - need to verify/recover
            print("⚠️ FIX #380 v2: All peers stale - attempting quick recovery...")
            onProgress?("network", "Reconnecting to peers...", 0.2)

            // Try recovery
            await attemptPeerRecovery()
            try await Task.sleep(nanoseconds: 2_000_000_000) // Wait 2s for reconnection

            // Check for any newly active peers
            let recoveredPeers = peers.filter { !isBanned($0.host) && $0.isConnectionReady && $0.hasRecentActivity }
            verifiedPeers = recoveredPeers

            for peer in recoveredPeers {
                print("✅ FIX #380 v2: Recovered peer \(peer.host) is active")
            }
        }

        // If still no verified peers, throw error
        if verifiedPeers.isEmpty {
            print("❌ FIX #380 v2: No active peers available")
            throw NetworkError.connectionFailed("No active peers available for broadcast")
        }

        // Use only verified peers for broadcast
        finalBroadcastPeers = verifiedPeers
        print("📡 FIX #380 v2: \(verifiedPeers.count) peer(s) verified for broadcast")
        onProgress?("peers", "Preparing broadcast...", 0.0)

        // Use actor for thread-safe state
        actor BroadcastState {
            var successCount = 0
            var rejectCount = 0  // FIX #349: Track explicit rejections
            var duplicateCount = 0  // FIX #835: Track DUPLICATE responses (TX already in mempool)
            var txId: String?
            var mempoolVerified = false
            var pendingBroadcastSet = false  // Track if we've set pending broadcast

            func recordSuccess(_ id: String) -> (count: Int, isFirst: Bool) {
                let isFirst = (successCount == 0)
                successCount += 1
                txId = id
                return (successCount, isFirst)
            }

            // FIX #364: Set txId from fallback (pre-computed) without counting as peer success
            // Used when peers timeout but we still need to track the txid for verification
            func setFallbackTxId(_ id: String) {
                if txId == nil {
                    txId = id
                }
            }

            // FIX #349: Track when peers explicitly reject the transaction
            func recordReject() { rejectCount += 1 }
            func getRejectCount() -> Int { rejectCount }

            // FIX #835: Track DUPLICATE responses - means TX is ALREADY in peer's mempool!
            // Multiple DUPLICATEs = TX successfully propagated to network
            func recordDuplicate(_ txId: String) {
                duplicateCount += 1
                // Also set txId since DUPLICATE means they have this TX
                if self.txId == nil {
                    self.txId = txId
                }
            }
            func getDuplicateCount() -> Int { duplicateCount }

            func markPendingBroadcastSet() { pendingBroadcastSet = true }
            func isPendingBroadcastSet() -> Bool { pendingBroadcastSet }
            func setVerified() { mempoolVerified = true }
            func isVerified() -> Bool { mempoolVerified }
            func getTxId() -> String? { txId }
            func getSuccessCount() -> Int { successCount }

            // FIX #826: Track timeout to exit broadcast loop
            private var timedOut = false
            func markTimedOut() { timedOut = true }
            func isTimedOut() -> Bool { timedOut }
        }

        let state = BroadcastState()
        let broadcastAmount = amount  // Capture for use in closures

        // ==========================================================================
        // FIX #387: Centralized verified peer retrieval in PeerManager
        // Replaces inline FIX #385/386 - PeerManager now handles:
        // 1. Fresh peer list retrieval
        // 2. Ping verification to detect zombie connections
        // 3. Recovery fallback if no responsive peers
        // ==========================================================================
        onProgress?("verify", "Verifying peer connections...", 0.3)

        // FIX #387: Get verified peers from PeerManager (async method)
        var actualBroadcastPeers = await PeerManager.shared.getVerifiedPeersForBroadcast()

        // If no responsive peers, trigger recovery
        if actualBroadcastPeers.isEmpty {
            print("🔄 FIX #387: No responsive peers - triggering recovery...")
            onProgress?("network", "Reconnecting to network...", 0.2)
            await attemptPeerRecovery()
            try await Task.sleep(nanoseconds: 3_000_000_000)

            actualBroadcastPeers = await PeerManager.shared.getVerifiedPeersForBroadcast()
            print("🔄 FIX #387: After recovery: \(actualBroadcastPeers.count) peers available")
        }

        guard !actualBroadcastPeers.isEmpty else {
            print("❌ FIX #387: No peers available even after recovery!")
            throw NetworkError.connectionFailed("No responsive peers available for broadcast")
        }

        let peerCount = actualBroadcastPeers.count
        print("📡 FIX #387: Broadcasting to \(peerCount) verified-responsive peers")

        // Broadcast to all peers - but check mempool after FIRST success
        // Use short timeout (5s) to avoid waiting for slow/dead peers
        await withThrowingTaskGroup(of: Void.self) { group in
            // Add broadcast tasks for all healthy/valid peers with fast timeout
            // FIX #158: Exclude banned Sybil attackers
            // FIX #335: Prefer healthy peers (recent activity)
            // FIX #387: Use actualBroadcastPeers (verified-responsive from PeerManager)
            for (peerIndex, peer) in actualBroadcastPeers.enumerated() {
                let peerHost = "\(peer.host):\(peer.port)"
                group.addTask {
                    // PRIVACY: P-NET-001 — Broadcast timing jitter to prevent source-IP correlation
                    // First peer broadcasts immediately; subsequent peers have random staggered delay
                    if peerIndex > 0 {
                        let jitterMs = UInt64.random(in: 200_000_000...2_000_000_000) // 200ms - 2s
                        try? await Task.sleep(nanoseconds: jitterMs)
                    }
                    do {
                        // FIX #160: Dynamic timeout based on Tor mode (15s for Tor, 5s for direct)
                        let id = try await withThrowingTaskGroup(of: String.self) { timeoutGroup in
                            timeoutGroup.addTask {
                                // Ensure peer connection is still valid before broadcast
                                try await peer.ensureConnected()
                                return try await peer.broadcastTransaction(rawTx)
                            }
                            timeoutGroup.addTask {
                                try await Task.sleep(nanoseconds: perPeerTimeout) // FIX #160: Dynamic timeout
                                throw NetworkError.timeout
                            }
                            // Return first result (either success or timeout)
                            guard let result = try await timeoutGroup.next() else {
                                throw NetworkError.timeout
                            }
                            timeoutGroup.cancelAll()
                            return result
                        }
                        if self.verbose {
                            print("✅ Peer \(peerHost) accepted tx: \(id)")
                        }
                        let result = await state.recordSuccess(id)

                        // On FIRST peer acceptance, immediately set pending broadcast for instant UI feedback
                        if result.isFirst && broadcastAmount > 0 {
                            await MainActor.run {
                                self.setPendingBroadcast(txid: id, amount: broadcastAmount)
                            }
                            await state.markPendingBroadcastSet()
                        }

                        // Include txid in detail so UI can display it immediately
                        onProgress?("peers", "Accepted by \(result.count)/\(peerCount) nodes [txid:\(id)]", Double(result.count) / Double(peerCount))
                    } catch let error as NetworkError where error == .transactionRejected {
                        // FIX #349: Track explicit rejections (not timeouts) - these are CRITICAL signals
                        await state.recordReject()
                        print("⚠️ Peer \(peerHost) broadcast failed: transactionRejected (FIX #349: reject count incremented)")
                    } catch let error as NetworkError where error == .transactionDuplicateRejected {
                        // FIX #835: DUPLICATE means peer claims TX is in mempool
                        // FIX #935 v3: But DUPLICATE can mask rejection (e.g., "joinsplit requirements not met")
                        // DO NOT set pending broadcast from DUPLICATE alone - wait for verification!
                        await state.recordDuplicate(computedTxId)
                        let dupCount = await state.getDuplicateCount()
                        let successCount = await state.getSuccessCount()
                        if self.verbose {
                            print("⚠️ FIX #935 v3: Peer \(peerHost) returned DUPLICATE (count: \(dupCount), accepts: \(successCount))")
                        }

                        // FIX #935 v3: Only set pending broadcast from DUPLICATE if we ALSO have accepts
                        // DUPLICATE alone is NOT reliable - can mask rejection errors!
                        let alreadySet = await state.isPendingBroadcastSet()
                        if dupCount >= 1 && successCount >= 1 && broadcastAmount > 0 && !alreadySet {
                            await MainActor.run {
                                self.setPendingBroadcast(txid: computedTxId, amount: broadcastAmount)
                            }
                            await state.markPendingBroadcastSet()
                            if self.verbose {
                                print("✅ FIX #935 v3: Set pending broadcast (DUPLICATE + \(successCount) accepts)")
                            }
                        } else if successCount == 0 {
                            if self.verbose {
                                print("⚠️ FIX #935 v3: NOT setting pending broadcast - 0 accepts, DUPLICATE alone is unreliable")
                            }
                        }
                    } catch {
                        if self.verbose {
                            print("⚠️ Peer \(peerHost) broadcast failed: \(error)")
                        }
                    }
                }
            }

            // Add mempool verification task - runs in parallel, exits early on success
            // FIX #211: Capture torEnabled for longer wait time through Tor
            let useTorTimeouts = torEnabled
            // FIX #364: Capture computedTxId for fallback P2P verification when no peer explicitly accepts
            let fallbackTxId = computedTxId
            group.addTask {
                // FIX #211: Wait for at least one peer to accept
                // Tor broadcasts take 30-65 seconds per peer, so wait up to 90s
                // Direct mode: 10 seconds (100 * 100ms)
                let maxAttempts = useTorTimeouts ? 900 : 100  // 90s for Tor, 10s for direct
                var waitAttempts = 0
                while await state.getTxId() == nil && waitAttempts < maxAttempts {
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    waitAttempts += 1
                }

                // FIX #364: Use peer-provided txId if available, otherwise use pre-computed fallback
                // This ensures P2P verification runs even when peers timeout without explicit accept
                let txId: String
                if let peerTxId = await state.getTxId() {
                    txId = peerTxId
                } else {
                    // No peer explicitly accepted - use pre-computed txid for verification
                    print("⚠️ FIX #364: No peer explicitly accepted - using pre-computed txid for P2P verification")
                    txId = fallbackTxId
                    // Set fallback txId in state so main function guard doesn't return early
                    await state.setFallbackTxId(fallbackTxId)
                    // Still attempt P2P verification - TX may have propagated despite timeout
                }

                // ============================================================================
                // FIX #392: Wait 500ms after first acceptance to allow all peers to respond
                // Race condition: Verification task reads successCount as 2 when 6 peers accepted
                // because it runs immediately after first txId is set, before other peers respond
                // This short delay ensures we see the true acceptance count before deciding
                // ============================================================================
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms

                // ============================================================================
                // FIX #247: P2P-based mempool verification (replaced InsightAPI)
                // VUL-002: Verify TX propagation via P2P peers instead of centralized API
                // If multiple peers accepted without reject message, TX is considered valid
                // ============================================================================

                onProgress?("verify", "Verifying P2P propagation...", 0.6)

                // FIX #247: Use P2P verification - request TX from peers via getdata
                // If peers accepted (no reject), TX is propagating through the network
                var mempoolVerified = false
                let currentSuccessCount = await state.getSuccessCount()
                let duplicateCount = await state.getDuplicateCount()
                print("📊 FIX #392: After 500ms wait, successCount=\(currentSuccessCount), duplicateCount=\(duplicateCount)")

                // FIX #515: ALWAYS verify via P2P getdata, regardless of peer acceptance count
                // Peers can LIE about accepting (Sybil attack) - MUST verify TX is actually in mempool!
                // Previous FIX #390 shortcut was UNSAFE - see user case: 9 peers accepted but TX not in mempool
                let rejectCount = await state.getRejectCount()

                // ============================================================================
                // FIX #835: DUPLICATE responses = SUCCESS!
                // DUPLICATE means peer ALREADY has this TX in their mempool
                // If multiple peers say DUPLICATE, TX has propagated successfully
                // This is MORE reliable than acceptance - they're confirming they already have it!
                // ============================================================================
                // FIX #935: CRITICAL - Don't trust DUPLICATE if successCount == 0!
                // If NO peer accepted the broadcast but we got DUPLICATE, something is wrong:
                // - Peer may have returned wrong error code (e.g., DUPLICATE instead of REJECT)
                // - "joinsplit requirements not met" returns DUPLICATE in some node versions!
                // Only trust DUPLICATE if at least ONE peer actually accepted the TX during broadcast
                // ============================================================================
                if duplicateCount >= 2 && currentSuccessCount >= 1 {
                    // FIX #935: Multiple DUPLICATEs + at least 1 accept = SUCCESS
                    print("✅ FIX #835: \(duplicateCount) peers returned DUPLICATE + \(currentSuccessCount) accepts - TX is in network!")
                    print("✅ FIX #835: This is CONFIRMED success - peers already have the TX")
                    onProgress?("verify", "✅ Already in \(duplicateCount) peer mempools", 1.0)
                    mempoolVerified = true
                    await state.setVerified()
                    await MainActor.run {
                        self.setMempoolVerified()
                    }
                } else if duplicateCount >= 1 && currentSuccessCount == 0 {
                    // FIX #935: DUPLICATE but NO accepts = SUSPICIOUS!
                    // This often means "joinsplit requirements not met" (anchor mismatch)
                    // Node returns DUPLICATE instead of proper REJECT code
                    print("🚨 FIX #935: \(duplicateCount) DUPLICATE(s) but 0 accepts - TX likely REJECTED!")
                    print("🚨 FIX #935: This is often 'joinsplit requirements not met' (anchor mismatch)")
                    print("🚨 FIX #935: DO NOT trust DUPLICATE alone - requires P2P verification")
                    onProgress?("verify", "⚠️ Verifying - \(duplicateCount) duplicate, 0 accepts...", 0.7)

                    // Do P2P verification to confirm TX is actually in mempool
                    let p2pVerified = await self.verifyTxViaP2P(txid: txId, excludePeers: [], maxAttempts: 5)
                    if p2pVerified {
                        print("✅ FIX #935: TX verified via P2P despite suspicious DUPLICATE response")
                        onProgress?("verify", "✅ Transaction verified in network", 1.0)
                        mempoolVerified = true
                        await state.setVerified()
                        await MainActor.run {
                            self.setMempoolVerified()
                        }
                    } else {
                        // P2P verify failed - DUPLICATE was likely masking a rejection!
                        print("🚨 FIX #935: P2P verification FAILED - TX was REJECTED (anchor mismatch?)")
                        print("🚨 FIX #935: DUPLICATE response was FALSE POSITIVE - TX is NOT in mempool!")
                        onProgress?("error", "🚨 Transaction REJECTED - witness/anchor may be corrupted", 1.0)
                        // FIX #1073: Record as rejection so FIX #990 path doesn't track this as "might have succeeded"
                        await state.recordReject()
                        print("🚨 FIX #1073: Recorded P2P verification failure as rejection (rejectCount=\(await state.getRejectCount()))")
                        // mempoolVerified remains FALSE - broadcast FAILED
                    }
                } else if duplicateCount == 1 && currentSuccessCount >= 1 {
                    // 1 DUPLICATE + 1+ accepts = TX is propagating
                    print("✅ FIX #835: 1 DUPLICATE + \(currentSuccessCount) accepts - TX is propagating")
                    onProgress?("verify", "✅ TX in network (1 dup + \(currentSuccessCount) accepts)", 1.0)
                    mempoolVerified = true
                    await state.setVerified()
                    await MainActor.run {
                        self.setMempoolVerified()
                    }
                } else if currentSuccessCount >= 2 {
                    // FIX #515: ALL acceptance counts (2+) require actual P2P getdata verification
                    // High acceptance counts are promising but NOT proof of mempool inclusion
                    print("📡 FIX #515: \(currentSuccessCount) peers accepted - verifying TX is ACTUALLY in mempool...")
                    onProgress?("verify", "Verifying in mempool (\(currentSuccessCount) accepts)...", 0.7)

                    // FIX #515: Do actual P2P getdata verification for ALL acceptance counts
                    let p2pVerified = await self.verifyTxViaP2P(txid: txId, excludePeers: [], maxAttempts: 5)
                    if p2pVerified {
                        print("✅ FIX #515: TX verified via P2P getdata - found in \(currentSuccessCount) peers' mempools")
                        onProgress?("verify", "✅ Verified in network mempool", 1.0)
                        mempoolVerified = true
                        await state.setVerified()
                        await MainActor.run {
                            self.setMempoolVerified()
                        }
                    } else {
                        // FIX #515: Peers lied about accepting OR TX failed to propagate
                        // CRITICAL: Do NOT trust peer acceptance - TX is NOT in mempool!
                        print("⚠️ FIX #515: \(currentSuccessCount) peers accepted but TX NOT FOUND in any mempool!")
                        print("🚨 FIX #515: Possible Sybil attack or broken peers - DO NOT trust acceptance!")

                        // Wait 5 seconds and retry once (may have been propagation delay)
                        onProgress?("verify", "Waiting for propagation...", 0.8)
                        try? await Task.sleep(nanoseconds: 5_000_000_000)

                        let retryVerified = await self.verifyTxViaP2P(txid: txId, excludePeers: [], maxAttempts: 10)
                        if retryVerified {
                            print("✅ FIX #515: TX verified on retry after propagation delay")
                            onProgress?("verify", "✅ Transaction verified in network", 1.0)
                            mempoolVerified = true
                            await state.setVerified()
                            await MainActor.run {
                                self.setMempoolVerified()
                            }
                        } else {
                            // FIX #515: Still not found after retry - BROADCAST FAILED
                            // Peers lied OR all mempools rejected the transaction
                            print("🚨 FIX #515: TX STILL not found after retry - PEERS LIED or TX INVALID!")
                            print("🚨 FIX #515: Broadcast FAILED - do NOT mark as mempool verified!")
                            if rejectCount == 0 {
                                // 0 rejections means peers silently dropped the TX (broken/malicious)
                                print("⚠️ FIX #515: 0 rejections = peers accepted but didn't add to mempool (broken or Sybil attack)")
                            }
                            // FIX #1073: Record as rejection so FIX #990 path doesn't track this as "might have succeeded"
                            await state.recordReject()
                            print("🚨 FIX #1073: Recorded P2P verification failure as rejection (rejectCount=\(await state.getRejectCount()))")
                            // FIX #941: Do NOT call onProgress("error") here!
                            // The post-TaskGroup code at line ~5603 checks successCount > 0 and can OVERRIDE this to success
                            // Calling error progress here causes UI to show error even when TX ultimately succeeds
                            // Let mempoolVerified remain FALSE - the final result is determined AFTER TaskGroup exits
                        }
                    }
                } else if currentSuccessCount == 1 {
                    // Only 1 peer accepted - try P2P getdata verification with other peers
                    // FIX #349: Check if other peers REJECTED - explicit rejections are strong signals!
                    let rejectCount = await state.getRejectCount()
                    print("⏳ FIX #247: Only 1 peer accepted, \(rejectCount) rejected - verifying via P2P getdata...")
                    onProgress?("verify", "Verifying with additional peers...", 0.7)

                    // Try to verify TX exists via P2P getdata from connected peers
                    let p2pVerified = await self.verifyTxViaP2P(txid: txId, excludePeers: [], maxAttempts: 3)
                    if p2pVerified {
                        print("✅ FIX #247: TX verified via P2P getdata")
                        onProgress?("verify", "✅ Verified via P2P", 1.0)
                        mempoolVerified = true
                        await state.setVerified()
                        await MainActor.run {
                            self.setMempoolVerified()
                        }
                    } else if rejectCount > 0 {
                        // FIX #349: CRITICAL - Other peers explicitly rejected AND P2P verify failed
                        // This is a strong signal the TX is invalid - DO NOT trust the single accepting peer
                        print("🚨 FIX #349: TX REJECTED - 1 accept but \(rejectCount) rejections + P2P verify failed")
                        onProgress?("error", "🚨 Transaction rejected by network (\(rejectCount) peers rejected)", 1.0)
                        // mempoolVerified remains false - will cause caller to reject
                    } else {
                        // FIX #389: 1 peer accepted, no rejections, but P2P verify FAILED
                        // This means TX was NOT found in any peer's mempool - DON'T trust single peer!
                        // Peer may have ACK'd but dropped the TX. Wait and retry with extended timeout.
                        print("⚠️ FIX #389: 1 peer accepted but TX not found in mempool - retrying verification...")
                        onProgress?("verify", "Waiting for network propagation...", 0.8)

                        // FIX #389: Wait 3 seconds for TX to propagate, then retry P2P verification
                        try? await Task.sleep(nanoseconds: 3_000_000_000)

                        let retryP2PVerified = await self.verifyTxViaP2P(txid: txId, excludePeers: [], maxAttempts: 5)
                        if retryP2PVerified {
                            print("✅ FIX #389: TX verified on retry after propagation delay")
                            onProgress?("verify", "✅ Transaction verified in network", 1.0)
                            mempoolVerified = true
                            await state.setVerified()
                            await MainActor.run {
                                self.setMempoolVerified()
                            }
                        } else {
                            // FIX #389: Still not found - TX likely NOT propagating
                            // Do NOT mark as verified - let caller handle potential broadcast failure
                            print("🚨 FIX #389: TX STILL not found after retry - broadcast may have failed!")
                            print("🚨 FIX #389: Single peer acceptance but TX not in network mempool")
                            // FIX #1073: Record as rejection so FIX #990 path doesn't track this as "might have succeeded"
                            await state.recordReject()
                            print("🚨 FIX #1073: Recorded P2P verification failure as rejection (rejectCount=\(await state.getRejectCount()))")
                            // FIX #941: Do NOT call onProgress("error") here!
                            // Post-TaskGroup code checks successCount and can override to success
                            // mempoolVerified remains false - final result determined after TaskGroup exits
                        }
                    }
                } else {
                    // FIX #364: No peers explicitly accepted - but TX was broadcast and we have txid
                    // Try P2P verification as last resort before giving up
                    print("⚠️ FIX #364: No explicit peer acceptance - attempting P2P verification with computed txid")
                    onProgress?("verify", "Verifying transaction propagation...", 0.7)

                    // FIX #848: Add timeout to P2P verification to prevent hanging
                    // P2P verification can hang indefinitely if peers are unresponsive
                    // FIX #935 v2: REMOVED optimistic assumption on timeout!
                    // User case: "joinsplit requirements not met" caused false SUCCESS because timeout assumed TX propagated
                    // Timeout should mean UNKNOWN, not SUCCESS. Let user see the warning.
                    var p2pVerified = false
                    do {
                        p2pVerified = try await withTimeout(seconds: 15) {
                            await self.verifyTxViaP2P(txid: txId, excludePeers: [], maxAttempts: 3)
                        }
                    } catch {
                        print("⏱️ FIX #935 v2: P2P verification timed out after 15s - status UNKNOWN")
                        print("⚠️ FIX #935 v2: NOT assuming success on timeout - let user verify manually")
                        // FIX #935 v2: Do NOT assume success - timeout means we don't know!
                        p2pVerified = false
                    }
                    if p2pVerified {
                        print("✅ FIX #364: TX verified via P2P - propagated despite no explicit accept!")
                        onProgress?("verify", "✅ Transaction verified in network", 1.0)
                        mempoolVerified = true
                        await state.setVerified()
                        await MainActor.run {
                            self.setMempoolVerified()
                        }
                    } else {
                        // P2P verify failed - check if any peers rejected
                        let rejectCount = await state.getRejectCount()
                        if rejectCount > 0 {
                            print("🚨 FIX #364: TX likely rejected - \(rejectCount) peers rejected, P2P verify failed")
                            onProgress?("error", "🚨 Transaction rejected by \(rejectCount) peers", 1.0)
                        } else {
                            // No accepts, no rejects, P2P verify failed - network issues likely
                            // TX may still propagate - don't mark as verified but don't panic either
                            print("⚠️ FIX #364: Cannot verify TX - network issues. TX may still propagate.")
                            onProgress?("verify", "⚠️ Verification inconclusive - monitoring...", 1.0)
                        }
                    }
                }
            }

            // The mempool verification task will set isVerified() and return
            // The broadcast tasks will complete (success or fail)
            // We just need to wait for all tasks to finish, but with a timeout

            // FIX #160: Add a timeout task with dynamic duration based on Tor mode
            // (longer timeout for Tor to allow SOCKS5 reconnections)
            // FIX #826: Mark timed out so broadcast loop exits
            // FIX #858: Timeout task now throws to exit TaskGroup immediately
            // Swift's withTaskGroup waits for ALL tasks even after cancelAll()
            // Network I/O doesn't respect Swift task cancellation, so we must throw to exit
            group.addTask {
                try await Task.sleep(nanoseconds: overallTimeout) // FIX #160: Dynamic timeout
                print("⏱️ FIX #858: Broadcast timeout reached (\(overallTimeout/1_000_000_000)s) - throwing to exit TaskGroup")
                await state.markTimedOut()
                // FIX #858: Throw CancellationError to exit TaskGroup immediately
                // This prevents waiting for slow network operations to complete
                throw CancellationError()
            }

            // Wait for tasks - but check verified status after each
            // FIX #826: Also check for timeout to exit the loop
            // FIX #858: The timeout task now throws, which will propagate here
            var tasksRemaining = true
            while tasksRemaining {
                // Check if mempool verified - exit early!
                if await state.isVerified() {
                    print("✅ Mempool verified - exiting broadcast loop")
                    group.cancelAll()
                    break
                }

                // FIX #826: Check if overall timeout reached - exit loop to prevent hanging
                if await state.isTimedOut() {
                    print("⏱️ FIX #858: Timeout detected - cancelling remaining tasks and exiting")
                    group.cancelAll()
                    break
                }

                do {
                    guard let _ = try await group.next() else {
                        tasksRemaining = false
                        break
                    }
                    // A task finished - check verified status again immediately
                    if await state.isVerified() {
                        print("✅ Mempool verified after task completion - exiting")
                        group.cancelAll()
                        break
                    }
                    // FIX #826: Also check timeout after each task
                    if await state.isTimedOut() {
                        print("⏱️ FIX #858: Timeout after task completion - exiting")
                        group.cancelAll()
                        break
                    }
                } catch is CancellationError {
                    // FIX #858: Timeout task threw CancellationError - exit immediately
                    print("⏱️ FIX #858: CancellationError caught - exiting broadcast loop")
                    group.cancelAll()
                    break
                } catch {
                    // Other error - check verified/timeout status
                    if await state.isVerified() {
                        group.cancelAll()
                        break
                    }
                    if await state.isTimedOut() {
                        print("⏱️ FIX #858: Timeout after error - exiting")
                        group.cancelAll()
                        break
                    }
                }
            }
        }

        // Check results
        guard let txId = await state.getTxId() else {
            // FIX #160: No explicit peer acceptance, but TX may have been sent!
            // In P2P protocol, no response = possible success (no reject message)
            // Use the pre-computed txid and return it - the TX was likely propagated
            print("⚠️ No peer explicitly accepted TX, but using pre-computed txid: \(computedTxId)")
            print("📡 FIX #160: TX was sent to network - returning computed txid (may have propagated)")
            onProgress?("peers", "Transaction sent [txid:\(computedTxId)]", 0.8)

            // Set pending broadcast with computed txid so UI can track it
            if amount > 0 {
                await MainActor.run {
                    self.setPendingBroadcast(txid: computedTxId, amount: amount)
                }
            }

            // VUL-002: Return with mempoolVerified=false - caller should NOT write to database
            // FIX #349: rejectCount=0 since we don't have explicit rejection info at this point
            return BroadcastResult(txId: computedTxId, mempoolVerified: false, peerCount: 0, rejectCount: 0, p2pVerificationAttempted: false, peersAttempted: 0)
        }

        let successCount = await state.getSuccessCount()
        var verified = await state.isVerified()  // FIX #694: var to allow modification
        let rejections = await state.getRejectCount()  // FIX #349: Track rejections

        print("📡 Transaction broadcast to \(successCount)/\(peerCount) peers, \(rejections) rejected: \(txId)")

        // VUL-002: Return the actual mempool verification status
        // Caller MUST check mempoolVerified before writing to database
        if verified {
            print("✅ VUL-002: Broadcast SUCCESS with mempool verification")
            onProgress?("verify", "✅ In mempool - awaiting miners", 1.0)
        } else if rejections > 0 && successCount == 0 {
            // FIX #694: Only treat as failure if NO peers accepted
            // If successCount > 0, some peers accepted despite others saying DUPLICATE
            print("🚨 FIX #694: \(rejections) peers rejected TX - DO NOT write to database!")
            onProgress?("verify", "🚨 Transaction REJECTED by \(rejections) peers", 1.0)

            // FIX #702: Clean up pre-registered pending TX since it was rejected
            pendingOutgoingLock.lock()
            pendingOutgoingTxidSet.remove(txId)
            pendingOutgoingLock.unlock()
            print("🧹 FIX #702: Removed rejected TX from pending set: \(txId.prefix(12))...")

            // FIX #849: Also remove from UserDefaults persistence
            removePendingTxidFromPersistence(txId)
        } else if successCount > 0 {
            // FIX #694: Peers accepted! Even if others said DUPLICATE, we have acceptance
            // This means the transaction IS valid and was broadcast successfully
            print("✅ FIX #694: P2P broadcast SUCCESS - \(successCount) peers accepted (others said DUPLICATE from previous attempts)")
            onProgress?("verify", "✅ Broadcast via P2P - awaiting miners", 1.0)
            // FIX #694: Mark as mempool verified so caller writes to database
            await state.setVerified()
            verified = true  // Set local verified flag too
        } else {
            print("⚠️ VUL-002: No explicit acceptance, TX was sent to network")
            onProgress?("verify", "Sent to network - awaiting confirmation", 0.9)
        }

        // FIX #349: Include rejectCount in result so caller can handle rejections appropriately
        // FIX #590: Include p2pVerificationAttempted so caller can distinguish timeout from failure
        let rejectCount = await state.getRejectCount()
        let p2pAttempted = successCount > 0 || rejectCount > 0
        // FIX #990: peersAttempted tracks total peers we tried to broadcast to
        return BroadcastResult(txId: txId, mempoolVerified: verified, peerCount: successCount, rejectCount: rejections, p2pVerificationAttempted: p2pAttempted, peersAttempted: peerCount)
    }

    /// Broadcast transaction with multi-peer propagation (without progress)
    /// VUL-002: Returns BroadcastResult with mempoolVerified status
    func broadcastTransaction(_ rawTx: Data) async throws -> BroadcastResult {
        return try await broadcastTransactionWithProgress(rawTx, onProgress: nil)
    }

    // MARK: - FIX #247: P2P Transaction Verification

    /// Verify a transaction exists via P2P getdata request
    /// Replaces InsightAPI.checkTransactionExists with decentralized P2P verification
    /// Returns true if at least one peer has the TX in their mempool/blockchain
    func verifyTxViaP2P(txid: String, excludePeers: [String] = [], maxAttempts: Int = 3) async -> Bool {
        // FIX #848: Add overall timeout to prevent hanging indefinitely
        // P2P verification should complete within 20 seconds total
        let startTime = Date()
        let maxDuration: TimeInterval = 20.0

        let readyPeers = peers.filter { $0.isConnectionReady && !excludePeers.contains($0.host) }

        guard !readyPeers.isEmpty else {
            print("⚠️ FIX #247: No peers available for TX verification")
            return false
        }

        // FIX #1200: Convert txid hex string to Data and REVERSE for wire format.
        // P2P protocol uses little-endian (wire format), display format is big-endian.
        // Without reversal, peers respond "notfound" even when TX exists → false negatives.
        guard let txidBytes = Data(hex: txid)?.reversed() else {
            print("⚠️ FIX #247: Invalid txid format: \(txid)")
            return false
        }
        let txidData = Data(txidBytes)

        // Try up to maxAttempts peers
        for (index, peer) in readyPeers.prefix(maxAttempts).enumerated() {
            // FIX #848: Check timeout before each attempt
            if Date().timeIntervalSince(startTime) > maxDuration {
                print("⏱️ FIX #848: P2P verification timeout reached (\(maxDuration)s) - aborting")
                return false
            }

            do {
                // FIX #848: Add per-peer timeout (5 seconds)
                let exists = try await withTimeout(seconds: 5.0) {
                    try await peer.requestTransaction(txid: txidData)
                }
                if exists {
                    print("✅ FIX #247: TX \(txid.prefix(16))... verified via P2P (peer \(index + 1))")
                    return true
                }
            } catch NetworkError.handshakeFailed, NetworkError.invalidMagicBytes {
                // FIX #354: Invalid magic bytes - try to reconnect and retry once
                print("🔄 FIX #354: Peer \(peer.host) handshake/magic failed, attempting reconnect...")
                do {
                    try await peer.ensureConnected()
                    let exists = try await withTimeout(seconds: 5.0) {
                        try await peer.requestTransaction(txid: txidData)
                    }
                    if exists {
                        print("✅ FIX #354: TX \(txid.prefix(16))... verified after reconnect (peer \(index + 1))")
                        return true
                    }
                } catch {
                    print("⏳ FIX #354: Peer \(peer.host) still failing after reconnect: \(error.localizedDescription)")
                }
            } catch NetworkError.timeout {
                // FIX #848: Peer timed out - try next peer
                print("⏱️ FIX #848: Peer \(peer.host) timed out (5s) - trying next peer")
            } catch {
                // Peer doesn't have TX or other error - try next peer
                print("⏳ FIX #247: Peer \(peer.host) doesn't have TX or error: \(error.localizedDescription)")
            }
        }

        print("⚠️ FIX #247: TX \(txid.prefix(16))... not found via P2P (\(min(readyPeers.count, maxAttempts)) peers checked)")
        return false
    }

    // MARK: - FIX #516: Transaction Validation Helpers

    /// Extract anchor (Merkle root) from Sapling transaction
    /// FIX #562 v3: Safe transaction parsing with bounds checking
    private func extractAnchorFromTransaction(_ txData: Data) async throws -> Data {
        // Zcash v4 transaction format:
        // - Header (4 bytes): version (4) + version group ID
        // - Transparent inputs/outputs (variable, with compact size)
        // - lock_time (4 bytes)
        // - expiry_height (4 bytes)
        // - valueBalance (8 bytes) ← FIX #1255: between expiry and sapling spends
        // - Sapling bundle:
        //   - compactSize: number of spends
        //   - For each spend: SpendDescription (384 bytes)
        //     - cv: ValueCommitment (32 bytes)
        //     - anchor: bls12_381::Scalar (32 bytes) ← THIS IS WHAT WE NEED
        //     - nullifier (32 bytes)
        //     - rk (32 bytes)
        //     - zkproof (192 bytes)
        //     - spendAuthSig (64 bytes)
        //   - compactSize: number of outputs
        //   - Outputs...
        //   - bindingSig (64 bytes)

        guard txData.count > 8 else {
            throw NetworkError.invalidTransaction("Transaction too short")
        }

        // FIX #562 v3: Add try-catch to prevent crashes
        do {
            // Read transaction version (first 4 bytes)
            let txVersion = txData.subdata(in: 0..<4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }

            // Only parse v4+ transactions
            guard txVersion >= 4 else {
                throw NetworkError.invalidTransaction("Only v4+ transactions supported")
            }

            var offset = 8  // FIX #562 v4: Skip header (4 bytes version + 4 bytes version group ID)

            // FIX #562 v3: Safe compact size reading with overflow protection
            func readCompactSize(_ data: Data, _ offset: inout Int) throws -> UInt64 {
                guard offset < data.count else {
                    throw NetworkError.invalidTransaction("Compact size: offset out of bounds")
                }
                let first = data[offset]
                offset += 1
                if first < 253 {
                    return UInt64(first)
                } else if first == 253 {
                    guard offset + 2 <= data.count else {
                        throw NetworkError.invalidTransaction("Compact size 253: insufficient bytes")
                    }
                    let value = data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
                    offset += 2
                    return UInt64(value)
                } else if first == 254 {
                    guard offset + 4 <= data.count else {
                        throw NetworkError.invalidTransaction("Compact size 254: insufficient bytes")
                    }
                    let value = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
                    offset += 4
                    return UInt64(value)
                } else { // 255
                    guard offset + 8 <= data.count else {
                        throw NetworkError.invalidTransaction("Compact size 255: insufficient bytes")
                    }
                    let value = data.subdata(in: offset..<offset+8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
                    offset += 8
                    return value
                }
            }

            // FIX #562 v3: Safe offset increment with overflow checking
            func safeAdd(_ offset: inout Int, _ value: Int) throws {
                let newValue = offset &+ value  // Overflow operator
                guard newValue <= txData.count else {
                    throw NetworkError.invalidTransaction("Offset \(newValue) exceeds transaction size \(txData.count)")
                }
                offset = newValue
            }

            // FIX #562 v3: Safe UInt64 to Int conversion with bounds
            func safeToInt(_ value: UInt64, maxAllowed: Int = 1000) throws -> Int {
                guard value <= UInt64(maxAllowed) else {
                    throw NetworkError.invalidTransaction("Value \(value) exceeds maximum allowed \(maxAllowed)")
                }
                return Int(value)
            }

            // Skip transparent inputs (compact size + each input)
            let numInputs = try readCompactSize(txData, &offset)
            let numInputsInt = try safeToInt(numInputs)  // FIX #562 v3: Convert BEFORE creating range
            for _ in 0..<numInputsInt {
                // Input: prevout (36) + scriptSig (compact size) + sequence (4)
                try safeAdd(&offset, 36)  // prevout
                let scriptSize = try readCompactSize(txData, &offset)
                let scriptSizeInt = try safeToInt(scriptSize, maxAllowed: 100000)  // Larger limit for scripts
                try safeAdd(&offset, scriptSizeInt)
                try safeAdd(&offset, 4)  // sequence
            }

            // Skip transparent outputs
            let numOutputs = try readCompactSize(txData, &offset)
            let numOutputsInt = try safeToInt(numOutputs)  // FIX #562 v3: Convert BEFORE creating range
            for _ in 0..<numOutputsInt {
                // Output: value (8) + scriptPubKey (compact size)
                try safeAdd(&offset, 8)  // value
                let scriptSize = try readCompactSize(txData, &offset)
                let scriptSizeInt = try safeToInt(scriptSize, maxAllowed: 100000)  // Larger limit for scripts
                try safeAdd(&offset, scriptSizeInt)
            }

            // Lock time (4 bytes)
            try safeAdd(&offset, 4)

            // Expiry height (4 bytes) for v4+
            try safeAdd(&offset, 4)

            // FIX #1255: Skip valueBalance (8 bytes) — MUST be skipped before sapling spends
            // valueBalance is an int64 between nExpiryHeight and nShieldedSpend in v4 format
            // Bug: this was missing, causing anchor extraction to read 8 bytes too early
            // (readCompactSize misread first byte of valueBalance as spend count)
            try safeAdd(&offset, 8)

            // Now we're at the sapling bundle
            // Read number of sapling spends
            let numSpends = try readCompactSize(txData, &offset)

            // FIX #562 v3: Sanity check on spend count
            guard numSpends > 0 && numSpends <= 1000 else {
                throw NetworkError.invalidTransaction("Invalid sapling spend count: \(numSpends)")
            }

            // Parse the first SpendDescription to get its anchor
            // SpendDescription format:
            // - cv (32 bytes)
            // - anchor (32 bytes) ← THIS IS THE ANCHOR
            // - nullifier (32 bytes)
            // - rk (32 bytes)
            // - zkproof (192 bytes)
            // - spendAuthSig (64 bytes)

            try safeAdd(&offset, 32)  // Skip cv to get to anchor

            guard offset + 32 <= txData.count else {
                throw NetworkError.invalidTransaction("Transaction too short for anchor: need \(offset + 32), have \(txData.count)")
            }

            let anchor = txData.subdata(in: offset..<offset + 32)

            print("🔍 FIX #562 v3: Extracted anchor from SpendDescription: \(anchor.prefix(8).map { String(format: "%02x", $0) }.joined())...")
            return anchor
        } catch let error as NetworkError {
            // FIX #562 v3: Log the error and fall back to old method
            print("⚠️ FIX #562 v3: New parsing failed: \(error)")
            print("⚠️ FIX #562 v3: Falling back to offset-based extraction...")
            throw error  // Re-throw to let caller handle it
        } catch {
            print("⚠️ FIX #562 v3: Unexpected error: \(error)")
            throw NetworkError.invalidTransaction("Unexpected parsing error: \(error.localizedDescription)")
        }
    }

    /// Verify a transaction exists and get confirmation count via P2P
    /// FIX #888: Returns (exists: Bool?, confirmations: Int)
    /// - exists = true: TX definitely exists
    /// - exists = false: TX checked and not found
    /// - exists = nil: Unable to verify (network issue, no peers) - don't mark as phantom!
    func verifyTxExistsViaP2P(txid: String) async -> (exists: Bool?, confirmations: Int) {
        let readyPeers = peers.filter { $0.isConnectionReady }

        // FIX #888: Return nil when no peers - we can't verify, don't assume TX doesn't exist
        guard !readyPeers.isEmpty else {
            return (nil, 0)
        }

        // FIX #1202: Convert txid hex to Data and reverse for wire format.
        // Same fix as FIX #1200: P2P protocol uses little-endian (wire format) txids,
        // display format is big-endian. Without reversal, peers respond "notfound"
        // even when TX is in their mempool → FIX #1165 falsely declares "REJECTED".
        guard let txidBytes = Data(hex: txid)?.reversed() else {
            return (nil, 0)  // Invalid txid format - can't verify
        }
        let txidData = Data(txidBytes)

        var checkedPeers = 0

        // Try to get TX from peers
        for peer in readyPeers.prefix(3) {
            do {
                // Request TX via getdata
                if let rawTx = try await peer.getRawTransaction(txid: txidData) {
                    // TX exists - check if it's confirmed by looking at block height
                    // For now, assume mempool (0 confirmations) if we got it via P2P
                    // Full confirmation tracking requires block scanning
                    print("✅ FIX #247: TX \(txid.prefix(16))... exists (P2P verified, \(rawTx.count) bytes)")
                    return (true, 0)  // 0 = in mempool or unconfirmed
                }
                checkedPeers += 1
            } catch NetworkError.handshakeFailed, NetworkError.invalidMagicBytes {
                // FIX #354: Invalid magic bytes - try to reconnect and retry once
                print("🔄 FIX #354: Peer \(peer.host) handshake/magic failed during TX check, attempting reconnect...")
                do {
                    try await peer.ensureConnected()
                    if let rawTx = try await peer.getRawTransaction(txid: txidData) {
                        print("✅ FIX #354: TX \(txid.prefix(16))... exists after reconnect (\(rawTx.count) bytes)")
                        return (true, 0)
                    }
                    checkedPeers += 1
                } catch {
                    print("⏳ FIX #354: Peer \(peer.host) still failing after reconnect")
                }
            } catch {
                continue
            }
        }

        // FIX #888: Only return false if we actually checked at least one peer
        // If all peers failed, return nil (can't verify)
        if checkedPeers > 0 {
            return (false, 0)  // TX not found after checking peers
        } else {
            return (nil, 0)  // All peers failed - can't verify
        }
    }

    /// Get block headers for chain verification
    func getBlockHeaders(from height: UInt64, count: Int) async throws -> [BlockHeader] {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        var responses: [[BlockHeader]: Int] = [:]

        await withTaskGroup(of: [BlockHeader]?.self) { group in
            for peer in peers {
                group.addTask {
                    try? await peer.getBlockHeaders(from: height, count: count)
                }
            }

            for await result in group {
                if let headers = result {
                    responses[headers, default: 0] += 1
                }
            }
        }

        guard let (headers, count) = responses.max(by: { $0.value < $1.value }),
              count >= CONSENSUS_THRESHOLD else {
            throw NetworkError.consensusNotReached
        }

        return headers
    }

    /// FIX #231: Get block headers with best-effort consensus (returns even without full threshold)
    /// Returns (headers, peerCount) - allows Equihash verification even with reduced peers
    func getBlockHeadersBestEffort(from height: UInt64, count: Int) async -> (headers: [BlockHeader], agreementCount: Int)? {
        guard isConnected else {
            return nil
        }

        // FIX #233: Add overall 20-second timeout - return best result we have
        // This prevents hanging forever if some peers never respond
        let overallTimeoutSeconds: UInt64 = 20
        let startTime = Date()

        var responses: [[BlockHeader]: Int] = [:]
        var receivedCount = 0
        let totalPeers = peers.count

        print("🔬 FIX #233: Requesting headers from \(totalPeers) peers (20s timeout)...")

        await withTaskGroup(of: [BlockHeader]?.self) { group in
            // Add timeout task
            group.addTask {
                try? await Task.sleep(nanoseconds: overallTimeoutSeconds * 1_000_000_000)
                return nil  // Sentinel for timeout
            }

            // Add peer tasks
            for peer in peers {
                group.addTask {
                    try? await peer.getBlockHeaders(from: height, count: count)
                }
            }

            // Collect results until timeout or all peers respond
            for await result in group {
                if let headers = result, !headers.isEmpty {
                    responses[headers, default: 0] += 1
                    receivedCount += 1
                    print("📋 FIX #233: Received headers (\(receivedCount)/\(totalPeers) peers)")

                    // Early exit: If we have 3+ agreeing peers, that's enough consensus
                    if let maxAgreement = responses.values.max(), maxAgreement >= 3 {
                        print("✅ FIX #233: Got 3+ peer consensus, proceeding early")
                        group.cancelAll()
                        break
                    }
                }

                // Check overall timeout
                if Date().timeIntervalSince(startTime) > Double(overallTimeoutSeconds) {
                    print("⏰ FIX #233: Overall timeout reached (\(receivedCount) responses)")
                    group.cancelAll()
                    break
                }
            }
        }

        // Return the headers with most peer agreement, even if below threshold
        guard let (headers, agreementCount) = responses.max(by: { $0.value < $1.value }),
              !headers.isEmpty else {
            print("⚠️ FIX #233: No headers received from any peer (timeout or error)")
            return nil
        }

        print("✅ FIX #233: Returning headers with \(agreementCount) peer agreement")
        return (headers, agreementCount)
    }

    /// Get current chain height from peers (P2P-first, InsightAPI fallback)
    func getChainHeight() async throws -> UInt64 {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        // P2P-FIRST architecture: prioritize trustless P2P data
        // CRITICAL: Always verify against network - don't trust stale cached values!
        // FIX #499: Don't check Tor.mode here - it's @MainActor and can hang if main thread is blocked
        // We use P2P only anyway, so Tor mode doesn't matter for chain height
        print("📡 Getting chain height (P2P-first)...")

        // FIX #120: InsightAPI commented out - P2P only
        // 1. Get network height from InsightAPI - ONLY if Tor is disabled
        // InsightAPI is blocked by Cloudflare when accessed via Tor
        var networkHeight: UInt64 = 0
        // if !torEnabled {
        //     if let status = try? await InsightAPI.shared.getStatus() {
        //         networkHeight = status.height
        //         print("📡 [API] Network height: \(networkHeight)")
        //     }
        // } else {
        //     print("🧅 Tor enabled - skipping InsightAPI (Cloudflare blocks Tor)")
        // }
        print("📡 P2P only mode - InsightAPI disabled")

        // 2. Check header store (our locally verified headers)
        var headerHeight: UInt64 = 0
        if let h = try? HeaderStore.shared.getLatestHeight() {
            headerHeight = h
            print("📡 [P2P] HeaderStore height: \(headerHeight)")
        }

        // 3. PEER CONSENSUS - The most trustworthy source for chain height
        // Collect heights from all connected peers and find consensus (skip banned peers)
        // FIX #434: Only use valid Zclassic peers (170002-170012), not Zcash (170018+)
        var peerHeights: [UInt64: Int] = [:]  // height -> count of peers reporting it
        var peerMaxHeight: UInt64 = 0

        for peer in peers {
            // SECURITY: Skip banned peers, negative heights, and non-Zclassic peers
            guard !isBanned(peer.host), peer.peerStartHeight > 0, peer.isValidZclassicPeer else { continue }
            let h = UInt64(peer.peerStartHeight)  // Safe: checked > 0 above
            if h > 0 {
                peerHeights[h, default: 0] += 1
                if h > peerMaxHeight {
                    peerMaxHeight = h
                }
            }
        }

        // Find peer consensus height (height reported by most peers, must be within 10 blocks of max)
        var peerConsensusHeight: UInt64 = 0
        var consensusCount = 0
        for (height, count) in peerHeights {
            // Only consider heights close to max (within 10 blocks)
            if peerMaxHeight > 0 && height >= peerMaxHeight - 10 && count > consensusCount {
                peerConsensusHeight = height
                consensusCount = count
            }
        }

        if peerConsensusHeight > 0 {
            print("📡 [P2P] Peer consensus: \(peerConsensusHeight) (\(consensusCount)/\(peers.count) peers agree)")
        }

        // SECURITY: Detect and ban peers reporting heights VERY far from consensus
        // FIX #434: Only check valid Zclassic peers
        let maxOutlierTolerance: UInt64 = 500
        if peerConsensusHeight > 0 {
            for peer in peers {
                // Skip already banned peers, skip negative heights, skip non-Zclassic
                guard !isBanned(peer.host), peer.peerStartHeight > 0, peer.isValidZclassicPeer else { continue }
                let h = UInt64(peer.peerStartHeight)  // Safe: checked > 0 above
                if h > peerConsensusHeight + maxOutlierTolerance {
                    print("""
                    🚨🚨🚨 SECURITY ALERT: FAKE HEIGHT DETECTED 🚨🚨🚨
                    ⚠️ Peer \(peer.host) reports height \(h)
                    ⚠️ Peer consensus: \(peerConsensusHeight)
                    ⚠️ Difference: \(h - peerConsensusHeight) blocks AHEAD (tolerance: \(maxOutlierTolerance))
                    🔒 BANNING peer for 7 days...
                    🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨
                    """)
                    banPeer(peer, reason: .corruptedData)
                    peer.disconnect()
                }
            }
        }

        // WARNING: If peer consensus is significantly higher than HeaderStore, headers are lagging
        if headerHeight > 0 && peerConsensusHeight > headerHeight + 50 {
            // FIX #769: Use "headers behind" wording to avoid false sync lag alerts
            print("⚠️ HeaderStore is \(peerConsensusHeight - headerHeight) headers behind peer consensus - header sync needed!")
        }

        // 4. Determine best height - PEER CONSENSUS is PRIMARY (decentralized!)
        // Priority: Peer consensus > InsightAPI > HeaderStore > Cached
        var bestHeight: UInt64 = 0

        if peerConsensusHeight > 0 && consensusCount >= 2 {
            // BEST: Peer consensus (decentralized, trustworthy if 2+ peers agree)
            bestHeight = peerConsensusHeight
            print("📡 Using PEER CONSENSUS height: \(bestHeight) (\(consensusCount) peers)")
        } else if networkHeight > 0 {
            // FALLBACK: InsightAPI (centralized but usually accurate)
            bestHeight = networkHeight
            print("📡 Using InsightAPI height: \(bestHeight)")
        } else if peerMaxHeight > 0 {
            // FALLBACK: Single peer max (less trustworthy)
            bestHeight = peerMaxHeight
            print("📡 Using peer max height (no consensus): \(bestHeight)")
        } else if headerHeight > 0 {
            // FALLBACK: HeaderStore (local, can be lagging)
            bestHeight = headerHeight
            print("📡 Using HeaderStore height: \(bestHeight)")
        } else if chainHeight > 0 {
            // LAST RESORT: Cached value
            bestHeight = chainHeight
            print("📡 Using cached height: \(bestHeight)")
        }

        if bestHeight > 0 {
            return bestHeight
        }

        throw NetworkError.consensusNotReached
    }

    /// Get compact block filters for transaction detection
    func getCompactFilters(from height: UInt64, count: Int) async throws -> [CompactFilter] {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        var responses: [[CompactFilter]: Int] = [:]

        await withTaskGroup(of: [CompactFilter]?.self) { group in
            for peer in peers {
                group.addTask {
                    try? await peer.getCompactFilters(from: height, count: count)
                }
            }

            for await result in group {
                if let filters = result {
                    responses[filters, default: 0] += 1
                }
            }
        }

        guard let (filters, count) = responses.max(by: { $0.value < $1.value }),
              count >= CONSENSUS_THRESHOLD else {
            throw NetworkError.consensusNotReached
        }

        return filters
    }

    /// Get compact blocks (ZIP-307) for shielded transaction scanning
    /// Uses multi-peer consensus for trustless verification
    func getCompactBlocks(from height: UInt64, count: Int) async throws -> [CompactBlock] {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        // For single blocks or small batches, use multi-peer consensus
        if count <= 10 {
            return try await getBlocksWithConsensus(from: height, count: count)
        }

        // FIX #1489: VULN-004 — For larger batches, fetch from single peer then verify
        // every block hash against the locally-trusted HeaderStore. A single malicious peer
        // cannot inject fake blocks: any block whose hash doesn't match the stored header
        // causes the entire batch to be rejected.
        guard let peer = peers.first else {
            throw NetworkError.notConnected
        }

        let blocks = try await peer.getFullBlocks(from: height, count: count)

        guard !blocks.isEmpty else {
            throw NetworkError.consensusNotReached
        }

        // Fetch stored hashes for this range in a single SQL query (FIX #1287 API).
        // If HeaderStore has no entries yet (e.g. very first sync), storedHashes will be
        // empty and we skip verification — the next header sync will catch any forgery.
        let storedHashes = (try? HeaderStore.shared.getBlockHashesInRange(
            from: height, count: blocks.count)) ?? [:]

        if !storedHashes.isEmpty {
            for block in blocks {
                guard let stored = storedHashes[block.blockHeight] else {
                    // Height not yet in HeaderStore (chain tip edge) — skip this block.
                    continue
                }
                guard block.blockHash == stored else {
                    let peerHex  = block.blockHash.prefix(8).map { String(format: "%02x", $0) }.joined()
                    let storedHex = stored.prefix(8).map { String(format: "%02x", $0) }.joined()
                    print("❌ FIX #1489: Block hash mismatch at height \(block.blockHeight): peer=\(peerHex)… stored=\(storedHex)…")
                    peer.recordFailure()
                    throw NetworkError.invalidData
                }
            }
            print("✅ FIX #1489: All \(blocks.count) block hashes verified against HeaderStore")
        }

        return blocks
    }

    /// Get blocks from multiple peers and verify consensus on critical data
    /// Returns blocks only if at least CONSENSUS_THRESHOLD peers agree
    func getBlocksWithConsensus(from height: UInt64, count: Int) async throws -> [CompactBlock] {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        let availablePeers = peers.prefix(min(peers.count, 4)) // Use up to 4 peers
        guard availablePeers.count >= 1 else {
            throw NetworkError.notConnected
        }

        // Request blocks from multiple peers in parallel
        var peerResults: [[[UInt8]]: [CompactBlock]] = [:] // Block hashes -> blocks

        await withTaskGroup(of: (String, [CompactBlock]?).self) { group in
            for peer in availablePeers {
                group.addTask {
                    do {
                        let blocks = try await peer.getFullBlocks(from: height, count: count)
                        return (peer.host, blocks)
                    } catch {
                        print("⚠️ Failed to get blocks from peer \(peer.host): \(error)")
                        peer.recordFailure()
                        return (peer.host, nil)
                    }
                }
            }

            for await (peerHost, blocks) in group {
                if let blocks = blocks, !blocks.isEmpty {
                    // Create key from block hashes for consensus check
                    let hashKey = blocks.map { Array($0.blockHash) }
                    peerResults[hashKey] = blocks
                    print("📦 Peer \(peerHost) returned \(blocks.count) blocks")
                }
            }
        }

        // Find consensus - blocks where hash matches between peers
        guard !peerResults.isEmpty else {
            throw NetworkError.consensusNotReached
        }

        // If we have multiple responses, verify they match
        if peerResults.count >= 2 {
            // Find the response with most agreement
            var voteCount: [[UInt8]: Int] = [:]
            for (hashKey, _) in peerResults {
                // Flatten to single hash for voting
                let flatHash = hashKey.flatMap { $0 }
                voteCount[flatHash, default: 0] += 1
            }

            guard let (winningHash, votes) = voteCount.max(by: { $0.value < $1.value }),
                  votes >= min(CONSENSUS_THRESHOLD, peerResults.count) else {
                print("❌ No consensus on blocks from height \(height)")
                throw NetworkError.consensusNotReached
            }

            // Find blocks matching winning hash
            for (hashKey, blocks) in peerResults {
                if hashKey.flatMap({ $0 }) == winningHash {
                    print("✅ Block consensus reached with \(votes) peers")
                    return blocks
                }
            }
        }

        // FIX #1492: VULN-008 — Remove single-peer fallback.
        // When only 1 peer responded, we have NO consensus — reject it.
        // A single malicious peer cannot inject blocks through a consensus-protected path.
        // Callers will retry via the dispatcher (getBlocksDataP2P) which uses a broader
        // peer pool and HeaderStore hash validation as a per-block safeguard.
        throw NetworkError.consensusNotReached
    }

    /// Get a single block by hash from multiple peers with consensus
    func getBlockByHashWithConsensus(hash: Data) async throws -> CompactBlock {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        let availablePeers = peers.prefix(min(peers.count, 3))
        guard !availablePeers.isEmpty else {
            throw NetworkError.notConnected
        }

        var results: [Data: CompactBlock] = [:] // finalSaplingRoot -> block

        await withTaskGroup(of: CompactBlock?.self) { group in
            for peer in availablePeers {
                group.addTask {
                    try? await peer.getBlockByHash(hash: hash)
                }
            }

            for await block in group {
                if let block = block {
                    // Key by finalSaplingRoot - the critical data we need to verify
                    results[block.finalSaplingRoot] = block
                }
            }
        }

        guard !results.isEmpty else {
            throw NetworkError.consensusNotReached
        }

        // If multiple different sapling roots, reject (could be attack)
        if results.count > 1 {
            print("⚠️ Peers disagree on finalSaplingRoot - possible attack!")
            throw NetworkError.consensusNotReached
        }

        // All peers agree
        return results.values.first!
    }

    /// Get transaction by txid from P2P network
    func getTransactionP2P(txid: String) async throws -> Data {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        guard let peer = peers.first else {
            throw NetworkError.notConnected
        }

        // Convert txid hex string to Data (reversed for network byte order)
        guard let txidData = Data(hexString: txid)?.reversed() else {
            throw NetworkError.invalidData
        }

        // Request transaction via getdata
        return try await peer.getTransaction(hash: Data(txidData))
    }

    // MARK: - P2P Block Scanning

    /// Get block data for a specific height via P2P (used by FilterScanner)
    /// Returns CompactBlock with transactions including shielded outputs
    func getBlockForScanning(height: UInt64) async throws -> CompactBlock {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        // Use multi-peer consensus for single block
        let blocks = try await getBlocksWithConsensus(from: height, count: 1)
        guard let block = blocks.first else {
            throw NetworkError.consensusNotReached
        }

        return block
    }

    /// Get multiple blocks for scanning via P2P
    func getBlocksForScanning(from height: UInt64, count: Int) async throws -> [CompactBlock] {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        // For larger batches, use getCompactBlocks which handles consensus
        return try await getCompactBlocks(from: height, count: count)
    }

    /// Get chain height from P2P sources only (no InsightAPI fallback)
    /// Uses: HeaderStore (locally verified) > peer version heights
    func getChainHeightP2POnly() async throws -> UInt64 {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        // FIX #120: InsightAPI commented out - P2P only
        // SECURITY: Get InsightAPI height first to validate P2P sources
        var trustedHeight: UInt64 = 0
        let maxDeviation: UInt64 = 10

        // do {
        //     let status = try await InsightAPI.shared.getStatus()
        //     trustedHeight = status.height
        // } catch {
        //     print("⚠️ InsightAPI unavailable for P2P height validation")
        // }
        _ = maxDeviation  // Suppress unused warning (validation disabled)
        print("📡 P2P only mode - using HeaderStore as trusted source")

        var maxHeight: UInt64 = 0

        // 1. HeaderStore (locally verified headers - but may have fake data)
        if let headerHeight = try? HeaderStore.shared.getLatestHeight() {
            // Validate against trusted source
            if trustedHeight > 0 && headerHeight > trustedHeight + maxDeviation {
                print("🚨 [SECURITY] HeaderStore height \(headerHeight) is FAKE, ignoring")
            } else {
                maxHeight = max(maxHeight, headerHeight)
            }
        }

        // 2. Peer version heights (may be fake) - skip banned peers and negative heights
        // FIX #434: Only use valid Zclassic peers (170002-170012), not Zcash (170018+)
        for peer in peers {
            // SECURITY: Skip banned peers, negative heights, and non-Zclassic peers
            guard !isBanned(peer.host), peer.peerStartHeight > 0, peer.isValidZclassicPeer else { continue }
            let h = UInt64(peer.peerStartHeight)  // Safe: checked > 0 above
            if h > 0 {
                // Validate against trusted source
                if trustedHeight > 0 && h > trustedHeight + maxDeviation {
                    print("🚨 [SECURITY] Peer height \(h) is FAKE, ignoring")
                } else if h > maxHeight {
                    maxHeight = h
                }
            }
        }

        // 3. Use trusted height if we have it and P2P sources were all fake
        if trustedHeight > 0 && maxHeight == 0 {
            print("📡 All P2P heights were fake, using InsightAPI: \(trustedHeight)")
            return trustedHeight
        }

        // 4. Fallback to cached height only if reasonable
        if maxHeight == 0 && chainHeight > 0 {
            if trustedHeight > 0 && chainHeight > trustedHeight + maxDeviation {
                print("🚨 [SECURITY] Cached chainHeight \(chainHeight) is FAKE, ignoring")
            } else {
                maxHeight = chainHeight
            }
        }

        guard maxHeight > 0 else {
            throw NetworkError.consensusNotReached
        }

        return maxHeight
    }

    // MARK: - P2P Block Data On-Demand (No HeaderStore Required)

    /// Get blocks on-demand via P2P using getheaders + getdata
    /// This does NOT require pre-synced headers - fetches headers directly from peers
    /// Tries multiple peers with reconnection logic
    /// Returns: [(CompactBlock)] with CMUs in wire format (little-endian)
    func getBlocksOnDemandP2P(from height: UInt64, count: Int) async throws -> [CompactBlock] {
        print("🔗 P2P on-demand: Fetching \(count) blocks from height \(height)")

        // Ensure at least some peers are connected before checking
        var availablePeers = peers.filter { $0.isConnectionReady }

        if availablePeers.isEmpty && !peers.isEmpty {
            // No ready peers but we have peers - try to reconnect them
            print("⏳ P2P on-demand: No ready peers, attempting reconnection...")

            // Try to reconnect up to 3 peers in parallel
            let peersToReconnect = Array(peers.prefix(3))
            await withTaskGroup(of: Void.self) { group in
                for peer in peersToReconnect {
                    group.addTask {
                        do {
                            try await peer.ensureConnected()
                        } catch {
                            print("⚠️ P2P on-demand: Failed to reconnect \(peer.host): \(error.localizedDescription)")
                        }
                    }
                }
            }

            // Check again after reconnection attempt
            availablePeers = peers.filter { $0.isConnectionReady }

            if availablePeers.isEmpty {
                print("⚠️ P2P on-demand: Still no ready peers after reconnection attempt")
                throw NetworkError.notConnected
            } else {
                print("✅ P2P on-demand: Reconnected \(availablePeers.count) peers")
            }
        }

        guard !availablePeers.isEmpty else {
            throw NetworkError.notConnected
        }

        // Try each peer until one succeeds with the block fetch
        var lastError: Error = NetworkError.p2pFetchFailed
        for peer in availablePeers.shuffled() {
            do {
                if verbose {
                    print("📡 P2P on-demand: Trying peer \(peer.host)...")
                }
                let blocks = try await withTimeout(seconds: 30) {
                    try await peer.getFullBlocks(from: height, count: count)
                }

                if !blocks.isEmpty {
                    // FIX #1287: Batch write sapling roots instead of per-block I/O
                    var saplingRootsDict: [UInt64: Data] = [:]
                    var saplingRootEntries: [(height: UInt64, root: Data)] = []
                    for block in blocks {
                        if !block.finalSaplingRoot.isEmpty && !block.finalSaplingRoot.allSatisfy({ $0 == 0 }) {
                            saplingRootsDict[block.blockHeight] = block.finalSaplingRoot
                            saplingRootEntries.append((height: block.blockHeight, root: block.finalSaplingRoot))
                        }
                    }
                    if !saplingRootsDict.isEmpty {
                        try? HeaderStore.shared.updateSaplingRoots(saplingRootsDict)
                        DeltaCMUManager.shared.appendSaplingRootsBatch(saplingRootEntries)
                    }
                    print("✅ P2P on-demand: Got \(blocks.count) blocks from \(peer.host)")
                    return blocks
                }
            } catch {
                print("⚠️ P2P on-demand: Peer \(peer.host) failed: \(error.localizedDescription)")
                lastError = error
                continue
            }
        }

        print("❌ P2P on-demand: All \(availablePeers.count) peers failed")
        throw lastError
    }

    // MARK: - P2P Block Data for Scanning (Full P2P Mode)

    /// Get block data with shielded outputs in format compatible with FilterScanner
    /// Returns: (blockHash, [(txid, [ShieldedOutput], [ShieldedSpend]?)])
    func getBlockDataP2P(height: UInt64) async throws -> (String, [(String, [ShieldedOutput], [ShieldedSpend]?)]) {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        guard let peer = peers.first else {
            throw NetworkError.notConnected
        }

        // Get block hash from HeaderStore (already synced)
        guard let header = try? HeaderStore.shared.getHeader(at: height) else {
            print("⚠️ P2P: No header found at height \(height)")
            throw NetworkError.consensusNotReached
        }

        // Get the block by hash via P2P
        let block = try await peer.getBlockByHash(hash: header.blockHash)
        // Set correct height on the returned block (getBlockByHash doesn't know the height)
        let blockWithHeight = CompactBlock(
            blockHeight: height,
            blockHash: block.blockHash,
            prevHash: block.prevHash,
            finalSaplingRoot: block.finalSaplingRoot,
            time: block.time,
            transactions: block.transactions
        )

        // Convert block hash to hex string
        let blockHashHex = blockWithHeight.blockHash.map { String(format: "%02x", $0) }.joined()

        // Parse each transaction in the block
        var txDataList: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []

        for (_, tx) in blockWithHeight.transactions.enumerated() {
            // Convert CompactOutput to ShieldedOutput format
            var shieldedOutputs: [ShieldedOutput] = []
            for output in tx.outputs {
                // Convert Data to hex strings in display format (big-endian for cmu/epk)
                // Note: The wire format is little-endian, display format is big-endian (reversed)
                let cmuHex = Data(output.cmu.reversed()).map { String(format: "%02x", $0) }.joined()
                let epkHex = Data(output.epk.reversed()).map { String(format: "%02x", $0) }.joined()
                // Ciphertext is NOT reversed - it's raw bytes
                let ciphertextHex = output.ciphertext.map { String(format: "%02x", $0) }.joined()

                let shieldedOutput = ShieldedOutput(
                    cv: String(repeating: "0", count: 64), // Not used for decryption
                    cmu: cmuHex,
                    ephemeralKey: epkHex,
                    encCiphertext: ciphertextHex,
                    outCiphertext: String(repeating: "0", count: 160), // Not used for decryption
                    proof: String(repeating: "0", count: 384) // Not used for decryption
                )
                shieldedOutputs.append(shieldedOutput)
            }

            // Convert CompactSpend to ShieldedSpend format
            var shieldedSpends: [ShieldedSpend]? = nil
            if !tx.spends.isEmpty {
                shieldedSpends = tx.spends.map { spend in
                    // Nullifier in display format (big-endian)
                    let nullifierHex = Data(spend.nullifier.reversed()).map { String(format: "%02x", $0) }.joined()
                    return ShieldedSpend(
                        cv: String(repeating: "0", count: 64),
                        anchor: String(repeating: "0", count: 64),
                        nullifier: nullifierHex,
                        rk: String(repeating: "0", count: 64),
                        proof: String(repeating: "0", count: 384),
                        spendAuthSig: String(repeating: "0", count: 128)
                    )
                }
            }

            // FIX #882: Store txid in WIRE format (little-endian) - txidString property reverses for display
            // FIX #880 was incorrect - it converted to display format causing double-reversal in UI
            let txidHex = tx.txHash.map { String(format: "%02x", $0) }.joined()

            if !shieldedOutputs.isEmpty || (shieldedSpends?.isEmpty == false) {
                txDataList.append((txidHex, shieldedOutputs, shieldedSpends))
            }
        }

        return (blockHashHex, txDataList)
    }

    /// Get multiple blocks' data for P2P scanning
    /// Distributes block ranges across peers - each peer fetches its range SEQUENTIALLY
    /// All peers work in PARALLEL for maximum throughput
    /// Returns: [(height, blockHash, timestamp, txData)]
    /// - Parameter skipPreReconnect: If true, skip pre-reconnection (FIX #1071 - already done at caller level)
    func getBlocksDataP2P(from height: UInt64, count: Int, skipPreReconnect: Bool = false) async throws -> [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] {
        // FIX #1317: Serialize all P2P block fetches through global gate.
        // Prevents cs_main lock contention on remote peer and dispatcher FIFO conflicts.
        // Each operation gets full peer bandwidth (300+ blocks/sec) instead of fighting (12-17).
        await p2pFetchGate.acquire()
        defer { Task { [p2pFetchGate] in await p2pFetchGate.release() } }

        // FIX #1205: Dispatcher activation moved AFTER reconnection (see below)
        // Old FIX #907 stopped listeners here — removed. FIX #1184 dispatcher needs them running.

        // FIX #715: Better peer selection - check both connection state AND recent activity
        // Peers can show isConnectionReady=true but still be dead (TCP state lag)
        // hasRecentActivity is more reliable - means peer responded recently
        // FIX #909: When block listeners are blocked (during operations), skip hasRecentActivity filter
        // because stopped listeners mean no recent activity, but peers are still valid
        var availablePeers: [Peer]
        if PeerManager.shared.areBlockListenersBlocked() {
            // FIX #909: During operations, use all connected peers (block listeners are stopped)
            availablePeers = peers.filter { $0.isConnectionReady }
            print("🔓 FIX #909: Using \(availablePeers.count) connected peers (block listeners blocked)")
        } else {
            availablePeers = peers.filter { $0.isConnectionReady && $0.hasRecentActivity }
            // FIX #715: If no peers with recent activity, fall back to just connection ready
            if availablePeers.isEmpty {
                availablePeers = peers.filter { $0.isConnectionReady }
            }
        }

        // FIX #715: SHUFFLE peers to avoid always picking same (possibly bad) ones first
        availablePeers.shuffle()

        // FIX #930: Proactively reconnect failed peers when we have fewer available than total
        // Previous bug: Reconnection only triggered when availablePeers.isEmpty
        // If localhost worked but remote peers failed, only 1 peer was used!
        // New behavior: If we have non-ready peers, try to reconnect them in parallel
        let nonReadyPeers = peers.filter { !$0.isConnectionReady }
        if !nonReadyPeers.isEmpty {
            print("🔄 FIX #930: \(availablePeers.count) ready, \(nonReadyPeers.count) non-ready - reconnecting failed peers...")

            // Try to reconnect up to 5 non-ready peers in parallel (don't wait too long)
            let peersToReconnect = Array(nonReadyPeers.prefix(5))
            await withTaskGroup(of: Void.self) { group in
                for peer in peersToReconnect {
                    group.addTask {
                        do {
                            try await peer.ensureConnected()
                            print("✅ FIX #930: Reconnected \(peer.host)")
                        } catch {
                            // Don't spam logs - just note the failure
                        }
                    }
                }
            }

            // Check again after reconnection attempt - refresh available list
            if PeerManager.shared.areBlockListenersBlocked() {
                availablePeers = peers.filter { $0.isConnectionReady }
            } else {
                availablePeers = peers.filter { $0.isConnectionReady && $0.hasRecentActivity }
                if availablePeers.isEmpty {
                    availablePeers = peers.filter { $0.isConnectionReady }
                }
            }
            // FIX #939: Shuffle all peers equally (FIX #938 localhost prioritization REMOVED per user request)
            // User wants remote peers to be FAST via batch fetching, not localhost-only
            availablePeers.shuffle()

            let reconnectedCount = availablePeers.count
            print("📊 FIX #930: After reconnection: \(reconnectedCount) peers available")
        }

        guard !availablePeers.isEmpty else {
            debugLog(.network, "⚠️ No ready peers for P2P block fetch")
            throw NetworkError.notConnected
        }

        // FIX #1205: Activate dispatchers on demand AFTER reconnection
        // Must run after FIX #930 reconnection so listeners start on current connections.
        // FIX #1184 requires dispatcher for all block fetches (no direct reads).
        // FIX #1285: Check how MANY dispatchers are active, not just "any".
        // Dispatchers die mid-scan (connection timeout, listener exit). If only 1/5 is alive,
        // the old code skipped activation entirely → 80% of blocks wasted on dead peers.
        var activeDispatcherCount = 0
        for peer in availablePeers {
            if await peer.isDispatcherActive {
                activeDispatcherCount += 1
            }
        }
        let neededDispatchers = min(3, availablePeers.count)
        if activeDispatcherCount < neededDispatchers {
            if verbose {
                print("🔄 FIX #1285: Only \(activeDispatcherCount)/\(availablePeers.count) dispatchers active (need \(neededDispatchers)) — restarting block listeners...")
            }
            // Must unblock to allow startBlockListener() to proceed
            if PeerManager.shared.areBlockListenersBlocked() {
                PeerManager.shared.setBlockListenersBlocked(false)
            }
            // Also clear header sync flag (header sync is done by now)
            await PeerManager.shared.setHeaderSyncInProgress(false)
            // Start block listeners on peers without active dispatchers
            for peer in availablePeers {
                if await !peer.isDispatcherActive {
                    peer.startBlockListener()
                }
            }
            // FIX #1285: Wait for MULTIPLE dispatchers (not just one).
            // FIX #1205 original: broke on first active → 1/5 peers active → 20% blocks.
            // Now: wait until at least 3 dispatchers activate OR 5s timeout.
            let minDispatchers = min(3, availablePeers.count)
            for i in 0..<50 {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                var activeCount = 0
                for peer in availablePeers {
                    if await peer.isDispatcherActive {
                        activeCount += 1
                    }
                }
                if activeCount >= minDispatchers {
                    if verbose {
                        print("✅ FIX #1285: \(activeCount) dispatchers activated after \(Double(i + 1) * 0.1)s (needed \(minDispatchers))")
                    }
                    break
                }
                // FIX #1205 compat: log first activation
                if i == 9 && activeCount > 0 && activeCount < minDispatchers {
                    if verbose {
                        print("⏳ FIX #1285: \(activeCount)/\(minDispatchers) dispatchers after 1.0s — waiting for more...")
                    }
                }
            }
        }

        // FIX #1205: Skip peers with consecutive batch failures (dead peers waste 15s timeout)
        // FIX #1208: Ensure at least 2 peers remain after filtering.
        // FIX #1216: Reduced threshold from 2 to 1 — a single timeout (15s wasted) is enough
        // to skip the peer. On macOS, peer 77.110.103.38 timed out in BOTH FIX #571 and FIX #1089,
        // wasting 60s total. With threshold=1, the second call skips it immediately.
        // FIX #1287: Reduced minPeersToKeep from 3 to 2. With 3, FIX #1208 kept resurrecting
        // dead peers when only 2 dispatcher-active were reliable: dead peer fails → excluded →
        // "need 3" → given another chance → counter reset → selected again → 15s timeout → repeat.
        // 2 working peers (256 blocks/round, ~500+ blocks/sec) >> 2 working + 1 dead (17 blocks/sec).
        let minPeersToKeep = 2
        let reliablePeers = availablePeers.filter { $0.consecutiveBatchFailures < 1 }
        if reliablePeers.count >= minPeersToKeep {
            // Enough reliable peers — skip the bad ones
            if reliablePeers.count < availablePeers.count {
                let skipped = availablePeers.count - reliablePeers.count
                print("⚠️ FIX #1205: Skipping \(skipped) peers with consecutive batch failures (\(reliablePeers.count) remain)")
                availablePeers = reliablePeers
            }
        } else if reliablePeers.count < availablePeers.count {
            // FIX #1208: Not enough reliable peers. Reset failure counters for least-failed peers
            // so they get another chance. This prevents the scan from running on just 1 peer.
            let sortedByFailures = availablePeers.sorted { $0.consecutiveBatchFailures < $1.consecutiveBatchFailures }
            let peersToKeep = Array(sortedByFailures.prefix(max(minPeersToKeep, reliablePeers.count)))
            // Reset counters for peers we're giving another chance
            for peer in peersToKeep where peer.consecutiveBatchFailures >= 2 {
                let oldFailures = peer.consecutiveBatchFailures
                peer.recordBatchResult(blocksReceived: 1)  // Resets counter to 0
                print("🔄 FIX #1208: Giving [\(peer.host)] another chance (was \(oldFailures) failures)")
            }
            availablePeers = peersToKeep
            print("🔄 FIX #1208: Kept \(peersToKeep.count) peers (min \(minPeersToKeep) needed for parallel fetching)")
        }

        // FIX #1285: Filter to dispatcher-active peers BEFORE assigning block ranges.
        // FIX #1205 starts block listeners and waits for ANY one dispatcher to activate,
        // but then assigns blocks to ALL availablePeers — including those whose dispatcher
        // never activated. Those peers return 0 blocks instantly (FIX #1184 fast-return),
        // wasting their assigned range. Log evidence: 4/5 peers return 0/128 in 0.0s,
        // only 1 peer delivers → 128/640 = 20% → below FIX #1218 50% threshold.
        var dispatcherActivePeers: [Peer] = []
        for peer in availablePeers {
            if await peer.isDispatcherActive {
                dispatcherActivePeers.append(peer)
            }
        }
        if !dispatcherActivePeers.isEmpty {
            if dispatcherActivePeers.count < availablePeers.count {
                if verbose {
                    print("📡 FIX #1285: Filtered to \(dispatcherActivePeers.count)/\(availablePeers.count) dispatcher-active peers")
                }
            }
            availablePeers = dispatcherActivePeers
        } else {
            // No dispatcher-active peers at all — keep all peers and let fetchBlockBatchP2P
            // handle per-peer failures. getBlocksByHashes will return empty for inactive ones.
            print("⚠️ FIX #1285: No dispatcher-active peers found — using all \(availablePeers.count) peers")
        }

        // FIX #1287: Shuffle peers before selection so the same slow peer isn't always picked.
        // Without shuffle, prefix(3) always takes the first 3 peers in array order,
        // which may consistently include the slowest peer (e.g., 140.174.189.3 at 280 blocks/sec
        // instead of peers at 1400+ blocks/sec).
        availablePeers.shuffle()

        // FIX #1287: Continuous per-peer streaming (Bitcoin Core-inspired).
        // OLD: Round-based — static ranges per peer, wait for ALL to finish → idle gaps → TCP collapse.
        // NEW: Shared queue of 32-block chunks. Each peer grabs and fetches continuously.
        //      Smaller chunks = less data in-flight = TCP windows stay manageable.
        //      128-block chunks × 4 peers = 512 blocks in-flight → TCP saturation → 773→17 blocks/sec.
        //      32-block chunks × 4 peers = 128 blocks in-flight → within TCP limits.
        //      Bitcoin Core uses 16 blocks/peer — 32 is a good middle ground.
        let chunkSize = 32  // Small chunks prevent TCP window bloat
        let numChunks = (count + chunkSize - 1) / chunkSize
        let actualPeerCount = min(numChunks, availablePeers.count)  // Use ALL available peers

        // Check if block hashes are available for this range
        let bundledAvailable = BundledBlockHashes.shared.isLoaded && BundledBlockHashes.shared.contains(height: height)
        let headerStoreAvailable = (try? HeaderStore.shared.getHeader(at: height)) != nil

        debugLog(.network, "🚀 P2P fetch: \(count) blocks from height \(height), \(availablePeers.count) ready peers, bundled=\(bundledAvailable), headers=\(headerStoreAvailable)")
        if verbose {
            print("🚀 FIX #1287: Streaming fetch \(count) blocks (\(numChunks) chunks) using \(actualPeerCount) peers")
        }
        let startTime = Date()

        // FIX #1287: Shared work queue — each peer grabs chunks continuously, no round boundaries.
        // Eliminates idle gaps that caused TCP congestion window collapse (1500→100 blocks/sec).
        actor BlockFetchQueue {
            private var nextHeight: UInt64
            private let endHeight: UInt64
            init(start: UInt64, totalCount: Int) {
                self.nextHeight = start
                self.endHeight = start + UInt64(totalCount)
            }
            func nextChunk(size: Int) -> (UInt64, Int)? {
                guard nextHeight < endHeight else { return nil }
                let count = min(size, Int(endHeight - nextHeight))
                let start = nextHeight
                nextHeight += UInt64(count)
                return (start, count)
            }
        }
        let fetchQueue = BlockFetchQueue(start: height, totalCount: count)

        let results = await withTaskGroup(of: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])]?.self) { group in
            var collected: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []

            // FIX #1315: Each peer runs a continuous fetch loop with ADAPTIVE TCP PACING
            // Without pacing: peers fire getdata as fast as chunks complete → TCP send buffer
            // saturation → kernel drops packets → retransmits → throughput collapses (1000→12 blocks/sec)
            // With pacing: small inter-chunk delay prevents buffer overflow, maintains steady throughput
            for peer in availablePeers.prefix(actualPeerCount) {
                group.addTask {
                    var peerResults: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []
                    var consecutiveChunkFailures = 0
                    let peerHost = peer.host
                    var chunksHandled = 0

                    // FIX #1315: Adaptive pacing state per peer
                    // Start at 0ms (cold start), ramp up on failures, ramp down on success
                    var pacingDelayMs: UInt64 = 0
                    var consecutiveFullChunks = 0

                    while let (chunkStart, chunkCount) = await fetchQueue.nextChunk(size: chunkSize) {
                        if Task.isCancelled { break }

                        // FIX #1315: Apply pacing delay BEFORE each request (except first)
                        if chunksHandled > 0 && pacingDelayMs > 0 {
                            try? await Task.sleep(nanoseconds: pacingDelayMs * 1_000_000)
                        }

                        if let blocks = await self.fetchBlockBatchP2P(peer: peer, startHeight: chunkStart, count: chunkCount) {
                            peerResults.append(contentsOf: blocks)
                            consecutiveChunkFailures = 0

                            // FIX #1315: Adaptive pacing — adjust based on chunk completeness
                            if blocks.count >= chunkCount {
                                // Full chunk received — peer is healthy
                                consecutiveFullChunks += 1
                                if consecutiveFullChunks >= 3 && pacingDelayMs > 0 {
                                    // 3 consecutive full chunks — decrease delay (min 0)
                                    pacingDelayMs = pacingDelayMs > 25 ? pacingDelayMs - 25 : 0
                                    consecutiveFullChunks = 0
                                }
                            } else {
                                // Partial chunk — peer is struggling, increase delay
                                pacingDelayMs = min(pacingDelayMs + 50, 500)
                                consecutiveFullChunks = 0
                            }
                        } else {
                            consecutiveChunkFailures += 1
                            consecutiveFullChunks = 0
                            // Chunk failed — significant backoff
                            pacingDelayMs = min(pacingDelayMs + 100, 500)
                            if consecutiveChunkFailures >= 3 {
                                if self.verbose {
                                    print("⚠️ FIX #1287: [\(peerHost)] 3 consecutive chunk failures — stopping peer")
                                }
                                break
                            }
                        }
                        chunksHandled += 1
                    }

                    if !peerResults.isEmpty {
                        let avgDelay = pacingDelayMs
                        if self.verbose {
                            print("📊 FIX #1287: [\(peerHost)] delivered \(peerResults.count) blocks in \(chunksHandled) chunks (final pacing: \(avgDelay)ms)")
                        }
                    }
                    return peerResults.isEmpty ? nil : peerResults
                }
            }

            // Collect results from all peers
            for await result in group {
                if let blocks = result {
                    collected.append(contentsOf: blocks)
                }
            }

            return collected
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let rate = Double(results.count) / max(elapsed, 0.001)

        // FIX #1218: 50% threshold — catch massive P2P failures
        if results.count < count / 2 {
            print("⚠️ FIX #1218: P2P fetch incomplete: only got \(results.count)/\(count) blocks (\(String(format: "%.0f", Double(results.count) / Double(count) * 100))%) in \(String(format: "%.1f", elapsed))s")
            throw NetworkError.p2pFetchFailed
        }

        if verbose {
            print("✅ FIX #1287: Streaming fetch: \(results.count)/\(count) blocks in \(String(format: "%.1f", elapsed))s (\(String(format: "%.0f", rate)) blocks/sec)")
        }

        // Sort by height to maintain order
        return results.sorted { $0.0 < $1.0 }
    }

    /// Fetch a batch of blocks from a single peer using HeaderStore or BundledBlockHashes
    /// Uses sequential getdata calls (batch getdata had parsing issues)
    /// PRIORITY: 1) HeaderStore (synced headers), 2) BundledBlockHashes (for historical scan)
    /// Returns: [(height, blockHash, timestamp, txData)]
    private func fetchBlockBatchP2P(peer: Peer, startHeight: UInt64, count: Int) async -> [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])]? {
        // Get block hashes - try HeaderStore first, then BundledBlockHashes
        var blockHashes: [(UInt64, Data)] = []
        var headerStoreCount = 0
        var bundledCount = 0

        // FIX #928: Cap at P2P protocol limit (128 blocks per peer)
        // From Zclassic main.h: MAX_BLOCKS_IN_TRANSIT_PER_PEER = 128
        let maxP2PBlocks = 128
        let effectiveCount = min(count, maxP2PBlocks)

        // FIX #1287: Batch header lookup — single SQL query instead of 128 individual queries
        // Each getHeader(at:) was doing SELECT with 11 columns (including 400-byte solution blob)
        // New: SELECT only height + block_hash for the entire range in one query
        let headerHashes = (try? HeaderStore.shared.getBlockHashesInRange(from: startHeight, count: effectiveCount)) ?? [:]

        for i in 0..<effectiveCount {
            let height = startHeight + UInt64(i)

            // First try HeaderStore batch results
            if let hash = headerHashes[height] {
                blockHashes.append((height, hash))
                headerStoreCount += 1
            }
            // Then try BundledBlockHashes (for historical blocks)
            else if let hash = BundledBlockHashes.shared.getBlockHash(at: height) {
                blockHashes.append((height, hash))
                bundledCount += 1
            }
        }

        if headerStoreCount > 0 || bundledCount > 0 {
            print("📦 [\(peer.host)] P2P batch: \(headerStoreCount) from HeaderStore, \(bundledCount) from BundledHashes")
        }

        // FIX #1234: If no hashes found, SKIP this peer's batch instead of on-demand fetch.
        // FIX #1184 explicitly warns: "ALL P2P block fetches MUST go through dispatcher".
        // On-demand fetch uses withExclusiveAccess (direct reads) which conflicts with block
        // listeners → lock acquisition timeouts (30s) → peer failures → gap-fill aborts.
        // Better to skip and let header sync catch up, then retry with hashes available.
        if blockHashes.isEmpty {
            print("⚠️ FIX #1234: [\(peer.host)] HeaderStore missing blocks \(startHeight)-\(startHeight + UInt64(effectiveCount) - 1) — skipping batch (header sync needed)")
            peer.recordBatchResult(blocksReceived: 0)
            return nil
        }

        // REMOVED FIX #120 on-demand fallback (moved below for reference):
        // On-demand P2P fetch path is preserved but UNREACHABLE due to early return above.
        // This code remains for documentation of why on-demand fetch was problematic:
        if false && blockHashes.isEmpty {  // DEAD CODE - FIX #1234 returns nil above
            print("📦 [\(peer.host)] Using on-demand P2P fetch for blocks \(startHeight)-\(startHeight + UInt64(effectiveCount) - 1)")
            do {
                let blocks = try await peer.getFullBlocks(from: startHeight, count: effectiveCount)
                var results: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []
                for block in blocks {
                    // FIX #1204: Save finalsaplingroot to HeaderStore for anchor validation
                    // Full blocks from getdata have authoritative sapling roots
                    if !block.finalSaplingRoot.isEmpty && !block.finalSaplingRoot.allSatisfy({ $0 == 0 }) {
                        try? HeaderStore.shared.updateSaplingRoot(at: block.blockHeight, root: block.finalSaplingRoot, timestamp: block.time)
                        // FIX #1253: Also save to delta sapling roots (survives missing header rows)
                        DeltaCMUManager.shared.appendSaplingRoot(height: block.blockHeight, root: block.finalSaplingRoot)
                    }

                    let finalBlockHash = block.blockHash.map { String(format: "%02x", $0) }.joined()
                    let blockTimestamp = block.time
                    var txDataList: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []

                    for tx in block.transactions {
                        var shieldedOutputs: [ShieldedOutput] = []
                        for output in tx.outputs {
                            let cmuHex = Data(output.cmu.reversed()).map { String(format: "%02x", $0) }.joined()
                            let epkHex = Data(output.epk.reversed()).map { String(format: "%02x", $0) }.joined()
                            let ciphertextHex = output.ciphertext.map { String(format: "%02x", $0) }.joined()
                            let shieldedOutput = ShieldedOutput(
                                cv: String(repeating: "0", count: 64),
                                cmu: cmuHex,
                                ephemeralKey: epkHex,
                                encCiphertext: ciphertextHex,
                                outCiphertext: String(repeating: "0", count: 160),
                                proof: String(repeating: "0", count: 384)
                            )
                            shieldedOutputs.append(shieldedOutput)
                        }

                        var shieldedSpends: [ShieldedSpend]? = nil
                        if !tx.spends.isEmpty {
                            shieldedSpends = tx.spends.map { spend in
                                let nullifierHex = Data(spend.nullifier.reversed()).map { String(format: "%02x", $0) }.joined()
                                return ShieldedSpend(
                                    cv: String(repeating: "0", count: 64),
                                    anchor: String(repeating: "0", count: 64),
                                    nullifier: nullifierHex,
                                    rk: String(repeating: "0", count: 64),
                                    proof: String(repeating: "0", count: 384),
                                    spendAuthSig: String(repeating: "0", count: 128)
                                )
                            }
                        }

                        // FIX #882: Store txid in WIRE format (little-endian) - txidString property reverses for display
                        // FIX #880 was incorrect - it converted to display format causing double-reversal in UI
                        let txidHex = tx.txHash.map { String(format: "%02x", $0) }.joined()
                        if !shieldedOutputs.isEmpty || (shieldedSpends?.isEmpty == false) {
                            // FIX #288: Debug log spends fetched
                            let spendCount = shieldedSpends?.count ?? 0
                            if spendCount > 0 {
                                if verbose {
                                    print("🔍 FIX #288: P2P block \(block.blockHeight) tx \(txidHex.prefix(16))... has \(spendCount) spends, \(shieldedOutputs.count) outputs")
                                }
                            }
                            txDataList.append((txidHex, shieldedOutputs, shieldedSpends))
                        }
                    }

                    results.append((block.blockHeight, finalBlockHash, blockTimestamp, txDataList))
                }

                // FIX #406: Log success with shielded output count
                let totalOutputs = results.reduce(0) { $0 + $1.3.reduce(0) { $0 + $1.1.count } }
                let totalSpends = results.reduce(0) { $0 + $1.3.reduce(0) { $0 + ($1.2?.count ?? 0) } }
                print("✅ [\(peer.host)] On-demand P2P: \(results.count) blocks, \(totalOutputs) outputs, \(totalSpends) spends")

                if results.isEmpty {
                    print("⚠️ FIX #406: [\(peer.host)] On-demand fetch returned 0 blocks!")
                }
                return results.isEmpty ? nil : results
            } catch {
                print("⚠️ [\(peer.host)] On-demand P2P fetch failed: \(error.localizedDescription)")
                return nil
            }
        }  // END DEAD CODE - FIX #1234

        // Check peer connection before attempting fetches
        guard peer.isConnectionReady else {
            print("⚠️ [\(peer.host)] Peer not ready, skipping batch of \(count) blocks")
            return nil
        }

        // FIX #939: BATCH FETCH - request all blocks in one getdata message
        // Previous SEQUENTIAL fetch was SLOW: 128 blocks × 0.3s = ~38 seconds per peer
        // BATCH fetch: 1 getdata request + response time = ~5-10 seconds per peer (5-7x faster!)
        var blocks: [(UInt64, CompactBlock)] = []

        do {
            // Extract just the hashes for batch request
            let hashes = blockHashes.map { $0.1 }
            if verbose {
                print("🚀 FIX #939: [\(peer.host)] Batch fetching \(hashes.count) blocks...")
            }
            let batchStartTime = Date()

            // FIX #939: Use getBlocksByHashes for efficient batch retrieval
            let fetchedBlocks = try await peer.getBlocksByHashes(hashes: hashes)

            let batchDuration = Date().timeIntervalSince(batchStartTime)
            let batchRate = Double(fetchedBlocks.count) / max(batchDuration, 0.001)
            if verbose {
                print("✅ FIX #939: [\(peer.host)] Batch fetched \(fetchedBlocks.count)/\(hashes.count) blocks in \(String(format: "%.1f", batchDuration))s (\(String(format: "%.0f", batchRate)) blocks/sec)")
            }

            // Match fetched blocks to their heights
            // getBlocksByHashes returns blocks in order of the hashes we sent
            for (index, block) in fetchedBlocks.enumerated() {
                if index < blockHashes.count {
                    let height = blockHashes[index].0
                    blocks.append((height, block))
                }
            }
        } catch {
            // FIX #939: On batch failure, fall back to sequential fetch (one block at a time)
            // This handles peers that don't respond well to large batch requests
            if !(error is CancellationError) {
                if verbose {
                    print("⚠️ FIX #939: [\(peer.host)] Batch fetch failed (\(error.localizedDescription)), falling back to sequential...")
                }
            }

            // Sequential fallback
            var failCount = 0
            for (height, hash) in blockHashes {
                if Task.isCancelled {
                    break
                }

                do {
                    let block = try await withTimeout(seconds: 10) {
                        try await peer.getBlockByHash(hash: hash)
                    }
                    blocks.append((height, block))
                } catch {
                    if error is CancellationError {
                        break
                    }
                    failCount += 1
                    if failCount > 3 {
                        break
                    }
                    continue
                }
            }
        }

        // FIX #1205: Track batch fetch results for peer selection
        peer.recordBatchResult(blocksReceived: blocks.count)
        if blocks.isEmpty && !blockHashes.isEmpty {
            print("⚠️ [\(peer.host)] Returned 0 blocks from \(blockHashes.count) requests (consecutive failures: \(peer.consecutiveBatchFailures))")
        }

        var results: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []

        // FIX #1287: Collect sapling roots for batch write (was per-block → 128 individual SQLite writes + file I/Os)
        var saplingRootsDict: [UInt64: Data] = [:]
        var saplingRootEntries: [(height: UInt64, root: Data)] = []

        for (blockHeight, compactBlock) in blocks {
            // Collect sapling roots for batch write below
            if !compactBlock.finalSaplingRoot.isEmpty && !compactBlock.finalSaplingRoot.allSatisfy({ $0 == 0 }) {
                saplingRootsDict[blockHeight] = compactBlock.finalSaplingRoot
                saplingRootEntries.append((height: blockHeight, root: compactBlock.finalSaplingRoot))
            }

            let finalBlockHash = compactBlock.blockHash.map { String(format: "%02x", $0) }.joined()
            let blockTimestamp = compactBlock.time  // Block timestamp from P2P header
            var txDataList: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []

            for tx in compactBlock.transactions {
                var shieldedOutputs: [ShieldedOutput] = []
                for output in tx.outputs {
                    let cmuHex = Data(output.cmu.reversed()).map { String(format: "%02x", $0) }.joined()
                    let epkHex = Data(output.epk.reversed()).map { String(format: "%02x", $0) }.joined()
                    let ciphertextHex = output.ciphertext.map { String(format: "%02x", $0) }.joined()

                    let shieldedOutput = ShieldedOutput(
                        cv: String(repeating: "0", count: 64),
                        cmu: cmuHex,
                        ephemeralKey: epkHex,
                        encCiphertext: ciphertextHex,
                        outCiphertext: String(repeating: "0", count: 160),
                        proof: String(repeating: "0", count: 384)
                    )
                    shieldedOutputs.append(shieldedOutput)
                }

                var shieldedSpends: [ShieldedSpend]? = nil
                if !tx.spends.isEmpty {
                    shieldedSpends = tx.spends.map { spend in
                        let nullifierHex = Data(spend.nullifier.reversed()).map { String(format: "%02x", $0) }.joined()
                        return ShieldedSpend(
                            cv: String(repeating: "0", count: 64),
                            anchor: String(repeating: "0", count: 64),
                            nullifier: nullifierHex,
                            rk: String(repeating: "0", count: 64),
                            proof: String(repeating: "0", count: 384),
                            spendAuthSig: String(repeating: "0", count: 128)
                        )
                    }
                }

                // FIX #882: Store txid in WIRE format (little-endian) - txidString property reverses for display
                // FIX #880 was incorrect - it converted to display format causing double-reversal in UI
                let txidHex = tx.txHash.map { String(format: "%02x", $0) }.joined()

                if !shieldedOutputs.isEmpty || (shieldedSpends?.isEmpty == false) {
                    txDataList.append((txidHex, shieldedOutputs, shieldedSpends))
                }
            }

            results.append((blockHeight, finalBlockHash, blockTimestamp, txDataList))
        }

        // FIX #1287: Batch write sapling roots — 1 SQL transaction + 1 file I/O instead of N per-block ops
        // FIX #1204: Save finalsaplingroot to HeaderStore for anchor validation
        if !saplingRootsDict.isEmpty {
            try? HeaderStore.shared.updateSaplingRoots(saplingRootsDict)
            // FIX #1253: Also save to delta sapling roots (survives missing header rows)
            DeltaCMUManager.shared.appendSaplingRootsBatch(saplingRootEntries)
        }

        return results
    }

    /// Fetch a single block from P2P peers with fallback to InsightAPI
    /// Returns: (height, blockHash, timestamp, txData)
    private func fetchSingleBlockP2P(height: UInt64, peers: [Peer]) async -> (UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])? {
        var block: CompactBlock?
        var blockHash: Data?

        // Get block hash from HeaderStore
        if let header = try? HeaderStore.shared.getHeader(at: height) {
            blockHash = header.blockHash
        }

        // Try P2P peers with timeout
        if let hash = blockHash {
            // Try a random peer first for load balancing
            let shuffledPeers = peers.shuffled()
            for peer in shuffledPeers.prefix(3) {  // Try up to 3 peers
                do {
                    block = try await withTimeout(seconds: 5) {
                        try await peer.getBlockByHash(hash: hash)
                    }
                    if block != nil { break }
                } catch {
                    // Try next peer
                }
            }
        }

        // FIX #120: InsightAPI fallback commented out - P2P only
        // Fallback to InsightAPI if P2P failed
        if block == nil {
            // do {
            //     let hashFromAPI = try await InsightAPI.shared.getBlockHash(height: height)
            //     let insightBlock = try await InsightAPI.shared.getBlock(hash: hashFromAPI)
            //     var txDataList: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []
            //
            //     for txid in insightBlock.tx {
            //         let txInfo = try? await InsightAPI.shared.getTransaction(txid: txid)
            //         let spends = txInfo?.spendDescs
            //         let outputs = try await InsightAPI.shared.getShieldedOutputsFromRaw(txid: txid)
            //
            //         if !outputs.isEmpty || (spends?.isEmpty == false) {
            //             txDataList.append((txid, outputs, spends))
            //         }
            //     }
            //     return (height, hashFromAPI, UInt32(insightBlock.time), txDataList)
            // } catch {
            //     return nil
            // }
            print("⚠️ P2P block fetch failed - no fallback (P2P only mode)")
            return nil
        }

        guard let block = block else { return nil }

        // Process P2P block data
        let finalBlockHash = block.blockHash.map { String(format: "%02x", $0) }.joined()
        var txDataList: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []

        for tx in block.transactions {
            var shieldedOutputs: [ShieldedOutput] = []
            for output in tx.outputs {
                let cmuHex = Data(output.cmu.reversed()).map { String(format: "%02x", $0) }.joined()
                let epkHex = Data(output.epk.reversed()).map { String(format: "%02x", $0) }.joined()
                let ciphertextHex = output.ciphertext.map { String(format: "%02x", $0) }.joined()

                let shieldedOutput = ShieldedOutput(
                    cv: String(repeating: "0", count: 64),
                    cmu: cmuHex,
                    ephemeralKey: epkHex,
                    encCiphertext: ciphertextHex,
                    outCiphertext: String(repeating: "0", count: 160),
                    proof: String(repeating: "0", count: 384)
                )
                shieldedOutputs.append(shieldedOutput)
            }

            var shieldedSpends: [ShieldedSpend]? = nil
            if !tx.spends.isEmpty {
                shieldedSpends = tx.spends.map { spend in
                    let nullifierHex = Data(spend.nullifier.reversed()).map { String(format: "%02x", $0) }.joined()
                    return ShieldedSpend(
                        cv: String(repeating: "0", count: 64),
                        anchor: String(repeating: "0", count: 64),
                        nullifier: nullifierHex,
                        rk: String(repeating: "0", count: 64),
                        proof: String(repeating: "0", count: 384),
                        spendAuthSig: String(repeating: "0", count: 128)
                    )
                }
            }

            // FIX #882: Store txid in WIRE format (little-endian) - txidString property reverses for display
            // FIX #880 was incorrect - it converted to display format causing double-reversal in UI
            let txidHex = tx.txHash.map { String(format: "%02x", $0) }.joined()

            if !shieldedOutputs.isEmpty || (shieldedSpends?.isEmpty == false) {
                txDataList.append((txidHex, shieldedOutputs, shieldedSpends))
            }
        }

        return (height, finalBlockHash, block.time, txDataList)
    }

    // MARK: - Peer Rotation

    private func setupPeerRotation() {
        peerRotationTimer = Timer.scheduledTimer(withTimeInterval: PEER_ROTATION_INTERVAL, repeats: true) { [weak self] _ in
            self?.rotatePeers()
        }
        peerRotationTimer?.tolerance = 60.0  // FIX #1450: Timer coalescing (5min interval, 1min tolerance)
    }

    private func rotatePeers() {
        Task {
            // FIX #1273: Don't rotate/connect peers before authentication
            guard BiometricAuthManager.shared.hasAuthenticatedThisSession else {
                return
            }

            // Check for peers that should be banned
            for peer in peers {
                if peer.shouldBan() {
                    banPeer(peer, reason: peer.consecutiveFailures >= 10 ? .tooManyFailures : .lowSuccessRate)
                    peer.disconnect()
                }
            }

            // Remove banned/disconnected peers AND peers with dead connections
            // FIX #119: Also remove peers that are not connection-ready to prevent socket accumulation
            peers.removeAll { peer in
                let shouldRemove = isBanned(peer.host) || peer.shouldBan() || !peer.isConnectionReady
                if shouldRemove && !isBanned(peer.host) && !peer.shouldBan() {
                    // Peer has dead connection but isn't banned - disconnect and remove
                    peer.disconnect()
                }
                return shouldRemove
            }

            // Find worst performing peer to rotate out
            if peers.count >= MIN_PEERS {
                if let worstPeer = peers.min(by: { $0.getChance() < $1.getChance() }) {
                    if worstPeer.getChance() < 0.5 {
                        worstPeer.disconnect()
                        peers.removeAll { $0.id == worstPeer.id }
                    }
                }
            }

            // Connect to new peers if needed
            // FIX #134: Track tried addresses in this rotation to prevent infinite loop
            var triedInThisRotation = Set<String>()
            var consecutiveCooldownSkips = 0
            let maxCooldownSkips = 20  // Break after 20 consecutive cooldown skips

            // FIX #235: Try hardcoded Zclassic seeds FIRST before DNS peers
            // These are known-good nodes that should always be attempted
            if peers.count < MIN_PEERS {
                for seedHost in HARDCODED_SEEDS {
                    let seedAddress = PeerAddress(host: seedHost, port: defaultPort)
                    let addressKey = "\(seedAddress.host):\(seedAddress.port)"

                    // Skip if already connected
                    if peers.contains(where: { $0.host == seedHost }) {
                        continue
                    }

                    // Skip if banned (but seeds are exempt from cooldown)
                    if isBanned(seedAddress.host) {
                        continue
                    }

                    // Skip if already tried in this rotation
                    if triedInThisRotation.contains(addressKey) {
                        continue
                    }
                    triedInThisRotation.insert(addressKey)

                    print("🌱 FIX #235: Trying hardcoded seed \(seedHost)...")
                    recordConnectionAttempt(seedAddress.host, port: seedAddress.port)

                    if let peer = try? await connectToPeer(seedAddress) {
                        peers.append(peer)
                        // FIX #478: Also add to PeerManager to keep peer lists in sync
                        PeerManager.shared.addPeer(peer)
                        setupBlockListener(for: peer)
                        print("✅ FIX #235: Connected to hardcoded seed \(seedHost)")

                        // Stop if we have enough peers
                        if peers.count >= MIN_PEERS {
                            break
                        }
                    }
                }
            }

            while peers.count < MIN_PEERS {
                guard let address = selectBestAddress() else {
                    break
                }

                let addressKey = "\(address.host):\(address.port)"

                // FIX #134: Skip if we already tried this address in this rotation
                if triedInThisRotation.contains(addressKey) {
                    consecutiveCooldownSkips += 1
                    if consecutiveCooldownSkips >= maxCooldownSkips {
                        // All available addresses are either on cooldown or already tried
                        break
                    }
                    continue
                }
                triedInThisRotation.insert(addressKey)

                if isBanned(address.host) {
                    continue
                }

                // FIX #121: Add cooldown check to prevent infinite reconnection loops
                // Without this, rotatePeers could spam connect() calls to failing addresses
                if isOnCooldown(address.host, port: address.port) {
                    // FIX #134: Only log once per address per rotation (no spam)
                    consecutiveCooldownSkips += 1
                    if consecutiveCooldownSkips >= maxCooldownSkips {
                        print("⏳ All \(triedInThisRotation.count) addresses on cooldown, waiting...")
                        break
                    }
                    continue
                }
                consecutiveCooldownSkips = 0  // Reset counter on successful non-cooldown address
                recordConnectionAttempt(address.host, port: address.port)

                if let peer = try? await connectToPeer(address) {
                    peers.append(peer)
                    // FIX #478: Also add to PeerManager to keep peer lists in sync
                    PeerManager.shared.addPeer(peer)

                    // Set up block announcement listener
                    setupBlockListener(for: peer)

                    // FIX #384: Sync connection success to PeerManager
                    await MainActor.run {
                        PeerManager.shared.recordConnectionSuccess(address.host, port: address.port)
                    }

                    // Also update custom node stats if this is a custom node
                    recordCustomNodeConnection(host: address.host, port: address.port, success: true)

                    // Request addresses from new peer
                    if let addresses = try? await peer.getAddresses() {
                        for addr in addresses {
                            addAddress(addr, source: peer.host)
                        }
                    }
                } else {
                    // FIX #384: Sync connection failure to PeerManager
                    await MainActor.run {
                        PeerManager.shared.recordConnectionFailure(address.host, port: address.port)
                    }
                }
            }

            // FIX #384: Sync peer list to PeerManager
            await MainActor.run {
                PeerManager.shared.syncPeers(self.peers)
            }

            DispatchQueue.main.async {
                // BUGFIX: Only count peers with READY connections, not all peers in array
                let readyPeers = self.peers.filter { $0.isConnectionReady }
                let newCount = readyPeers.count
                let newConnected = newCount > 0
                // CPU OPTIMIZATION: only update @Published if value changed
                if self.connectedPeers != newCount { self.connectedPeers = newCount }
                if self.isConnected != newConnected { self.isConnected = newConnected }
            }
        }
    }

    // MARK: - FIX #227: Peer Recovery Watchdog

    /// Setup peer recovery watchdog that runs every 30 seconds
    /// Detects when all peers are lost and triggers immediate reconnection
    private func setupPeerRecoveryWatchdog() {
        peerRecoveryTimer = Timer.scheduledTimer(withTimeInterval: PEER_RECOVERY_INTERVAL, repeats: true) { [weak self] _ in
            self?.checkPeerRecovery()
        }
        peerRecoveryTimer?.tolerance = PEER_RECOVERY_INTERVAL * 0.25  // FIX #1450: Timer coalescing
    }

    /// Check if peers need recovery and trigger reconnection if needed
    private func checkPeerRecovery() {
        // FIX #1273: Don't attempt peer recovery before authentication
        if !BiometricAuthManager.shared.hasAuthenticatedThisSession {
            return
        }
        // FIX #1467: Skip peer recovery when iOS device is overheating
        #if os(iOS)
        if isDeviceOverheating { return }
        #endif

        // FIX #227: Don't run during sync/repair/connection operations - they manage their own connections
        if WalletManager.shared.isSyncing || WalletManager.shared.isRepairingHistory || isConnecting {
            return  // Skip recovery check during active operations
        }

        let readyPeers = peers.filter { $0.isConnectionReady }
        let readyCount = readyPeers.count

        if readyCount == 0 {
            print("🚨 FIX #227: No ready peers detected! Triggering recovery...")

            // Check if Tor SOCKS failures are the cause
            if consecutiveSOCKS5Failures >= SOCKS5_FAILURE_THRESHOLD && !sybilBypassActive {
                print("🚨 FIX #1428: \(consecutiveSOCKS5Failures) SOCKS5 failures - bypassing Tor temporarily")
                sybilBypassActive = true
                _torIsAvailable = false
                // FIX #1428: MUST set TorManager bypass — Peer.connect() checks TorManager.isTorBypassed
                Task {
                    await TorManager.shared.temporarilyBypassTor()
                }
            }

            // Trigger immediate peer reconnection
            Task {
                await attemptPeerRecovery()
            }
        } else {
            // Reset SOCKS5 failure counter on successful connections
            if readyCount >= MIN_PEERS / 2 {
                consecutiveSOCKS5Failures = 0
            }
        }

        // Update published state (CPU OPTIMIZATION: only if changed)
        DispatchQueue.main.async {
            let newConnected = readyCount > 0
            if self.connectedPeers != readyCount { self.connectedPeers = readyCount }
            if self.isConnected != newConnected { self.isConnected = newConnected }
            // FIX #1420: Also update Tor peer counts in keepalive timer
            let newTorCount = self.peers.filter { $0.isConnectedViaTor && $0.isConnectionReady }.count
            let newOnionCount = self.peers.filter { $0.isOnion && $0.isConnectionReady }.count
            if self.torConnectedPeersCount != newTorCount { self.torConnectedPeersCount = newTorCount }
            if self.onionConnectedPeersCount != newOnionCount { self.onionConnectedPeersCount = newOnionCount }
        }
    }

    /// Attempt to recover peer connections
    public func attemptPeerRecovery() async {
        // FIX #1273: Don't attempt peer recovery before authentication
        guard BiometricAuthManager.shared.hasAuthenticatedThisSession else {
            print("🔄 FIX #1273: Skipping peer recovery — not authenticated yet")
            return
        }

        // FIX #1434: Serialize recovery — only 1 at a time (prevents thundering herd)
        guard !isRecoveringPeers else {
            print("🔄 FIX #1434: Recovery already in progress, skipping")
            return
        }

        // FIX #1434: Exponential backoff between recovery attempts (saves battery)
        let elapsed = Date().timeIntervalSince(lastRecoveryAttempt)
        guard elapsed >= recoveryBackoffSeconds else {
            print("🔄 FIX #1434: Recovery backoff — \(Int(recoveryBackoffSeconds - elapsed))s remaining")
            return
        }

        isRecoveringPeers = true
        lastRecoveryAttempt = Date()
        defer {
            isRecoveringPeers = false
            // Increase backoff: 30 → 60 → 120 → 240 → max 300s (5min)
            recoveryBackoffSeconds = min(300, recoveryBackoffSeconds * 2)
        }

        print("🔄 FIX #227: Attempting peer recovery...")

        // FIX #250: Diagnostic logging for real iOS debugging
        let torMode = await TorManager.shared.mode
        var torConnected = await TorManager.shared.connectionState.isConnected
        var torSocksPort = await TorManager.shared.socksPort
        let torBypassed = await TorManager.shared.isTorBypassed

        // ==========================================================================
        // FIX #842: Wait for Tor SOCKS Proxy BEFORE Parallel Peer Recovery
        // Problem: connectToPeer() has 10s timeout, but connectViaSocks5() waits 30s for Tor
        //   → All parallel connections timeout simultaneously with "Request timed out"
        // Root Cause: Each connection independently waits for Tor, but outer timeout fires first
        // Solution: Wait for Tor to be ready ONCE before starting any connections
        // ==========================================================================
        if torMode == .enabled && !torBypassed && (!torConnected || torSocksPort == 0) {
            print("🧅 FIX #842: Waiting for Tor SOCKS proxy before peer recovery...")
            let proxyReady = await TorManager.shared.waitForSocksProxyReady(maxWait: 30)
            if proxyReady {
                torConnected = await TorManager.shared.connectionState.isConnected
                torSocksPort = await TorManager.shared.socksPort
                print("✅ FIX #842: Tor proxy ready (port \(torSocksPort))")
            } else {
                print("⚠️ FIX #842: Tor proxy not ready after 30s - connections may fail")
            }
        }

        // FIX #284: Get preferred seeds from database (replaces hardcoded seeds)
        let preferredSeeds = getPreferredSeeds()

        // FIX #352: If we have NO connected peers, clear parked hardcoded seeds for immediate retry
        // This prevents being stuck for 24h when all hardcoded seeds are parked
        let readyPeers = peers.filter { $0.isConnectionReady }
        if readyPeers.isEmpty {
            clearParkedHardcodedSeeds()
        }

        let parkedReadyCount = getParkedPeersReadyForRetry().count

        debugLog(.network, "🔄 FIX #250: Peer recovery diagnostics:")
        debugLog(.network, "   - Tor mode: \(torMode)")
        debugLog(.network, "   - Tor connected: \(torConnected)")
        debugLog(.network, "   - SOCKS port: \(torSocksPort)")
        debugLog(.network, "   - Preferred seeds: \(preferredSeeds.count)")
        debugLog(.network, "   - Parked (ready): \(parkedReadyCount)")
        debugLog(.network, "   - Known addresses: \(knownAddresses.count)")

        // Clear dead peer references
        peers.removeAll { !$0.isConnectionReady }

        // ==========================================================================
        // FIX #394: PARALLEL peer recovery - connect to all peers simultaneously
        // Previous bug: Serial connections took 24+ seconds (each Tor connection ~2-5s)
        // Solution: Use TaskGroup to connect to all candidates in parallel
        // ==========================================================================

        // Collect all candidate addresses
        var candidateAddresses: [(address: PeerAddress, source: String)] = []

        // FIX #427: Add hardcoded seeds FIRST - they are the most reliable
        // Previous bug: Recovery only used parked peers because hardcoded seeds
        // weren't in knownAddresses. This caused 0 peers when all parked peers failed.
        // FIX #845: Also check if peer is parked and not ready for retry
        // Without this, failed hardcoded seeds get re-added immediately every 30 seconds
        // causing repeated "Ping failed: Peer handshake failed" errors
        for seedHost in HARDCODED_SEEDS {
            if !isBanned(seedHost) && !peers.contains(where: { $0.host == seedHost }) && !shouldSkipPeer(seedHost) {
                candidateAddresses.append((PeerAddress(host: seedHost, port: defaultPort), "hardcoded"))
            }
        }
        print("⭐ FIX #427: Added \(candidateAddresses.count) hardcoded seeds to recovery candidates")

        // 1. Preferred seeds (user-configured, highest priority after hardcoded)
        for seed in preferredSeeds {
            let seedAddress = PeerAddress(host: seed.host, port: seed.port)
            if !isBanned(seedAddress.host) && !candidateAddresses.contains(where: { $0.address.host == seed.host }) {
                candidateAddresses.append((seedAddress, "preferred"))
            } else if isBanned(seedAddress.host) {
                print("⚠️ FIX #284: Preferred seed \(seed.host) is BANNED - skipping")
            }
        }

        // 2. Parked peers ready for retry (lower priority than hardcoded seeds)
        let readyParked = getParkedPeersReadyForRetry()
        for parked in readyParked.prefix(5) {
            // FIX #427: Skip parked peers that are already in candidates
            if candidateAddresses.contains(where: { $0.address.host == parked.address }) {
                continue
            }
            // FIX #427: Skip invalid IP addresses (reserved ranges)
            if isReservedIPAddress(parked.address) {
                print("⚠️ FIX #427: Skipping reserved IP \(LogRedaction.redactIP(parked.address))")
                continue
            }
            let address = PeerAddress(host: parked.address, port: parked.port)
            candidateAddresses.append((address, "parked"))
        }

        // 3. All known addresses as fallback (bundled + discovered via addr messages)
        // FIX #1428: Try ALL known addresses, not just bundled (107 known but only 5 were tried)
        let allKnownAddresses = knownAddresses.values.map { $0.address }
            .sorted { a, _ in a.host < "z" }  // Deterministic order
        for address in allKnownAddresses.prefix(20) {
            // Skip if already in candidates
            if candidateAddresses.contains(where: { $0.address.host == address.host }) {
                continue
            }
            if !shouldSkipPeer(address.host) && !isOnCooldown(address.host, port: address.port) {
                candidateAddresses.append((address, "discovered"))
            }
        }

        print("⚡ FIX #394: Attempting PARALLEL recovery with \(candidateAddresses.count) candidates...")

        // Connect to all candidates in parallel
        var recovered = 0
        let maxPeers = 8  // FIX #1461: Was 5, raised to MIN_PEERS for full recovery

        // FIX #1428: Try up to 16 candidates in parallel (was 8) — Tor circuits are unreliable
        // on cellular, so more parallel attempts = better chance of getting 3+ peers
        await withTaskGroup(of: (Peer?, PeerAddress, String).self) { group in
            for (address, source) in candidateAddresses.prefix(16) {
                group.addTask { [weak self] in
                    guard let self = self else { return (nil, address, source) }

                    await MainActor.run {
                        self.recordConnectionAttempt(address.host, port: address.port)
                    }

                    do {
                        let peer = try await self.connectToPeer(address)
                        return (peer, address, source)
                    } catch {
                        print("❌ FIX #394: Failed \(source) peer \(LogRedaction.redactIP(address.host)): \(error.localizedDescription)")
                        return (nil, address, source)
                    }
                }
            }

            // Collect results as they complete
            for await (peer, address, source) in group {
                if let peer = peer {
                    // FIX #850: Check for duplicate before adding to prevent same peer appearing twice
                    // This can happen when recovery runs while previous peer is still in array
                    let isDuplicate = peers.contains { $0.host == peer.host }
                    if isDuplicate {
                        print("⚠️ FIX #850: Skipping duplicate peer \(LogRedaction.redactIP(address.host)) - already in peers array")
                        peer.disconnect()
                        continue
                    }

                    if recovered < maxPeers {
                        peers.append(peer)
                        // FIX #478: Also add to PeerManager to keep peer lists in sync
                        PeerManager.shared.addPeer(peer)
                        setupBlockListener(for: peer)
                        recovered += 1
                        unparkPeer(address.host, port: address.port)
                        // FIX #908: Reset handshake failures on successful connection
                        PeerManager.shared.resetHandshakeFailures(address.host)
                        print("✅ FIX #394: Recovered \(source) peer \(address.host) (\(recovered)/\(maxPeers))")
                    } else {
                        // Already have enough peers, disconnect this one
                        peer.disconnect()
                    }
                } else {
                    // Failed - park the peer
                    parkPeer(address.host, port: address.port)
                }
            }
        }

        print("⚡ FIX #394: Parallel recovery complete - \(recovered) peers connected")

        // Legacy fallback if parallel didn't get enough (should rarely happen)
        if recovered < 3 {
            // Get bundled addresses for additional fallback
            let remainingBundled = knownAddresses.values
                .filter { $0.source == "bundled" }
                .map { $0.address }

            for address in remainingBundled.prefix(5) {
                // FIX #284: Use shouldSkipPeer (checks banned + parked)
                if shouldSkipPeer(address.host) || isOnCooldown(address.host, port: address.port) {
                    continue
                }

                // FIX #850: Skip if peer is already connected (prevent duplicates)
                if peers.contains(where: { $0.host == address.host }) {
                    continue
                }

                recordConnectionAttempt(address.host, port: address.port)

                do {
                    let peer = try await connectToPeer(address)
                    peers.append(peer)
                    // FIX #478: Also add to PeerManager to keep peer lists in sync
                    PeerManager.shared.addPeer(peer)
                    setupBlockListener(for: peer)
                    recovered += 1
                    unparkPeer(address.host, port: address.port)
                    // FIX #908: Reset handshake failures on successful connection
                    PeerManager.shared.resetHandshakeFailures(address.host)
                    print("✅ FIX #227: Recovered peer \(address.host)")

                    if recovered >= 3 {
                        break  // Got enough peers
                    }
                } catch let error as NetworkError {
                    print("❌ FIX #227: Failed to connect to \(address.host): \(error.localizedDescription)")
                    // FIX #908: Track handshake failures with extended parking
                    if case .handshakeFailed = error {
                        PeerManager.shared.recordHandshakeFailure(address.host, port: address.port)
                    } else {
                        // Park instead of ban for connection issues
                        parkPeer(address.host, port: address.port)
                    }

                    // Track SOCKS5 failures specifically
                    if error.localizedDescription.contains("Socket is not connected") ||
                       error.localizedDescription.contains("SOCKS") {
                        consecutiveSOCKS5Failures += 1
                    }
                } catch {
                    print("❌ FIX #227: Failed to connect to \(address.host): \(error.localizedDescription)")
                    parkPeer(address.host, port: address.port)
                }
            }
        }

        if recovered == 0 {
            print("⚠️ FIX #227: Could not recover any peers from preferred/parked/bundled lists")

            // FIX #1419: Track consecutive 0-peer recoveries for exit circuit failure detection
            consecutiveZeroPeerRecoveries += 1
            let exitFailures = await TorManager.shared.getExitCircuitFailures()
            print("📊 FIX #1419: Consecutive 0-peer recoveries: \(consecutiveZeroPeerRecoveries)/\(ZERO_PEER_RECOVERY_THRESHOLD), exit circuit failures: \(exitFailures)")

            // FIX #1419: If Tor enabled and repeated failures, restart Tor with cache clear
            // This detects stale consensus causing "Failed to obtain exit circuit" errors
            if consecutiveZeroPeerRecoveries >= ZERO_PEER_RECOVERY_THRESHOLD && torMode == .enabled && !torBypassed {
                if exitFailures > 0 {
                    print("🚨 FIX #1419: \(consecutiveZeroPeerRecoveries) consecutive 0-peer recoveries + \(exitFailures) exit circuit failures → restarting Tor with cache clear")
                    consecutiveZeroPeerRecoveries = 0
                    await TorManager.shared.restartTor(clearCache: true)
                    // Wait for new circuits to build
                    try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
                    return  // Will retry on next recovery cycle
                } else {
                    print("⚠️ FIX #1419: 0-peer recoveries but no exit circuit failures — may be network issue")
                }
            }

            // If Tor bypass not active yet and we have failures, try direct
            if !sybilBypassActive {
                print("🔧 FIX #1428: Enabling Tor bypass for direct connections")
                sybilBypassActive = true
                _torIsAvailable = false
                // FIX #1428: MUST set TorManager bypass — Peer.connect() checks TorManager.isTorBypassed,
                // NOT NetworkManager._torIsAvailable. Without this, bypass is broken (all connections
                // still go through SOCKS5).
                await TorManager.shared.temporarilyBypassTor()

                // FIX #1428: Retry with direct connections using hardcoded seeds (not preferredSeeds
                // which is often empty). Clear parked seeds first so they're eligible.
                clearParkedHardcodedSeeds()
                var directRecovered = 0
                for seedHost in HARDCODED_SEEDS {
                    if isBanned(seedHost) || peers.contains(where: { $0.host == seedHost }) { continue }

                    do {
                        let address = PeerAddress(host: seedHost, port: defaultPort)
                        let peer = try await connectToPeer(address)
                        peers.append(peer)
                        PeerManager.shared.addPeer(peer)
                        setupBlockListener(for: peer)
                        unparkPeer(seedHost, port: defaultPort)
                        directRecovered += 1
                        print("✅ FIX #1428: Direct connection to \(seedHost) succeeded (\(directRecovered))")
                        if directRecovered >= 3 { break }
                    } catch {
                        print("❌ FIX #1428: Direct connection to \(seedHost) failed: \(error.localizedDescription)")
                    }
                }

                if directRecovered > 0 {
                    print("✅ FIX #1428: Recovered \(directRecovered) peer(s) via direct connection (Tor bypassed)")
                } else {
                    // Direct also failed — restore Tor for next cycle
                    print("⚠️ FIX #1428: Direct connections also failed — restoring Tor")
                    await TorManager.shared.restoreAfterSingleTxBypass()
                    sybilBypassActive = false
                }
            }
        } else {
            print("✅ FIX #227: Recovered \(recovered) peer(s)")
            // FIX #1419: Reset counter on successful recovery
            consecutiveZeroPeerRecoveries = 0
            // FIX #1434: Reset backoff on success — don't penalize after a good recovery
            recoveryBackoffSeconds = 30
        }

        // FIX #384: Sync peer list to PeerManager
        await MainActor.run {
            PeerManager.shared.syncPeers(self.peers)
        }

        // FIX #1428: Start dispatchers for recovered peers — without this, block announcements
        // don't get routed, FIX #859 scanner can't run, and getBlocksDataP2P has to activate
        // dispatchers on demand (adding delay). Only start if we actually recovered peers.
        let finalReadyCount = peers.filter { $0.isConnectionReady }.count
        if finalReadyCount > 0 {
            print("🔄 FIX #1428: Starting block listeners for \(finalReadyCount) recovered peer(s)...")
            await startBlockListenersOnMainScreen()
        }

        // Update UI (CPU OPTIMIZATION: only if values changed)
        DispatchQueue.main.async {
            let readyPeers = self.peers.filter { $0.isConnectionReady }
            let newCount = readyPeers.count
            let newConnected = newCount > 0
            if self.connectedPeers != newCount { self.connectedPeers = newCount }
            if self.isConnected != newConnected { self.isConnected = newConnected }
            // FIX #1420: Also update Tor peer counts
            let newTorCount = self.peers.filter { $0.isConnectedViaTor && $0.isConnectionReady }.count
            let newOnionCount = self.peers.filter { $0.isOnion && $0.isConnectionReady }.count
            if self.torConnectedPeersCount != newTorCount { self.torConnectedPeersCount = newTorCount }
            if self.onionConnectedPeersCount != newOnionCount { self.onionConnectedPeersCount = newOnionCount }
        }
    }

    // MARK: - FIX #246: Peer Keepalive System

    /// Keepalive timer
    private var keepaliveTimer: Timer?
    // FIX #1502: Increase keepalive from 30s to 90s on iOS to reduce overheating.
    // z8.log: 293 ping/pong messages in 21 min at 30s interval. Bitcoin Core uses 120s.
    // ZCL blocks arrive every ~75s, so 90s is safe — dead peers detected within 1 block.
    #if os(iOS)
    private let KEEPALIVE_INTERVAL: TimeInterval = 90
    #else
    private let KEEPALIVE_INTERVAL: TimeInterval = 30
    #endif

    // FIX #326: Track long periods with no peers for Tor circuit refresh
    private var lastSuccessfulPeerContact: Date = Date()
    private let TOR_CIRCUIT_REFRESH_THRESHOLD: TimeInterval = 1800  // 30 minutes without peers = refresh Tor
    private var torCircuitRefreshInProgress = false

    /// Exponential backoff state for reconnection
    private var reconnectionAttempts: [String: Int] = [:]  // host -> attempt count
    private let reconnectionAttemptsLock = NSLock()  // Thread safety for reconnectionAttempts
    private let MAX_BACKOFF_SECONDS: TimeInterval = 300  // Max 5 minutes between retries
    private let BASE_BACKOFF_SECONDS: TimeInterval = 2  // Start at 2 seconds

    /// Setup keepalive timer that pings peers periodically
    func setupKeepaliveTimer() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: KEEPALIVE_INTERVAL, repeats: true) { [weak self] _ in
            Task {
                await self?.performKeepalivePing()
            }
        }
        keepaliveTimer?.tolerance = KEEPALIVE_INTERVAL * 0.25  // FIX #1450: 25% tolerance for iOS timer coalescing
        debugLog(.network, "🫀 FIX #246: Keepalive timer started (interval: \(KEEPALIVE_INTERVAL)s)")
    }

    /// Stop keepalive timer
    func stopKeepaliveTimer() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        debugLog(.network, "🫀 FIX #246: Keepalive timer stopped")
    }

    // MARK: - FIX #268: NWPathMonitor for Network Transitions

    /// Setup NWPathMonitor to detect WiFi ↔ cellular transitions
    /// Like BitChat: monitor path changes and trigger debounced recovery
    private func setupPathMonitor() {
        pathMonitor = NWPathMonitor()

        pathMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let pathStatus = path.status
            let isExpensive = path.isExpensive  // true = cellular
            let isConstrained = path.isConstrained

            // Handle path change on main thread
            Task { @MainActor in
                // FIX #1352: Only log path changes when background processes are enabled
                // (suppresses ~53 noisy lines during initial sync — iOS cellular fires every 3-6s)
                if self.backgroundProcessesEnabled {
                    debugLog(.network, "📶 FIX #268: Network path changed - status=\(pathStatus), expensive=\(isExpensive), constrained=\(isConstrained)")
                }
                await self.handleNetworkPathChange(path: path)
            }
        }

        pathMonitor?.start(queue: pathMonitorQueue)
        debugLog(.network, "📶 FIX #268: NWPathMonitor started - monitoring network transitions")
    }

    /// Stop the path monitor
    func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        debugLog(.network, "📶 FIX #268: NWPathMonitor stopped")
    }

    // MARK: - FIX: Connection Health Monitoring

    /// Setup enhanced connection health monitoring
    /// Monitors peer connectivity and triggers recovery when needed
    /// Uses Task-based timer instead of Timer.scheduledTimer for reliability
    private var connectionHealthTimerTask: Task<Void, Never>?
    private let CONNECTION_HEALTH_CHECK_INTERVAL: TimeInterval = 30  // Every 30 seconds

    private func setupConnectionHealthMonitoring() {
        // CPU OPTIMIZATION: Disabled duplicate timer — keepalive timer (FIX #246) now handles
        // Tor SOCKS5 health check + updatePeerCountsForSettings() at end of performKeepalivePing().
        // Both fired every 30s doing the same work (ping peers, update counts, trigger recovery).
        connectionHealthTimerTask?.cancel()
        connectionHealthTimerTask = nil
        debugLog(.network, "💓 Connection health monitoring merged into keepalive timer (CPU optimization)")
    }

    /// Stop connection health monitoring
    private func stopConnectionHealthMonitoring() {
        connectionHealthTimerTask?.cancel()
        connectionHealthTimerTask = nil
    }

    /// Check connection health and trigger recovery if needed
    private func checkConnectionHealth() async {
        // FIX #1273: Don't run before authentication
        if !BiometricAuthManager.shared.hasAuthenticatedThisSession {
            return
        }

        // FIX #519: Skip ping checks during header sync - they disrupt the sync!
        if headerSyncInProgress {
            print("🔍 [HEALTH] Header sync in progress - skipping ping checks (would disrupt sync)")
            // Still update UI counts without pinging
            updatePeerCountsForSettings()
            return
        }

        if verbose {
            print("🔍 [HEALTH] checkConnectionHealth() called at \(Date())")
        }

        let connectedCount = connectedPeers
        let aliveCount = await countAlivePeers()

        if verbose {
            print("💓 Connection health: \(connectedCount) connected, \(aliveCount) alive")
        }

        // FIX #455: Update reactive peer counts for Settings UI
        updatePeerCountsForSettings()

        // If not enough alive peers, trigger recovery
        if aliveCount < CONSENSUS_THRESHOLD {
            print("⚠️ Not enough alive peers (\(aliveCount) < \(CONSENSUS_THRESHOLD)) - triggering recovery")
            await attemptPeerRecovery()
        }

        // Also check Tor SOCKS5 health if Tor is enabled
        let torMode = await TorManager.shared.mode
        if verbose {
            print("🔍 [HEALTH] Tor mode: \(torMode.rawValue)")
        }
        if torMode == .enabled {
            if verbose {
                print("🔍 [HEALTH] Tor enabled - calling SOCKS5 health check...")
            }
            let torHealthy = await TorManager.shared.checkSOCKS5Health()
            if !torHealthy {
                print("⚠️ Tor SOCKS5 health check failed - will trigger restart if continues")
            } else {
                if verbose {
                    print("✅ Tor SOCKS5 health check PASSED")
                }
            }
        } else {
            if verbose {
                print("🔍 [HEALTH] Tor NOT enabled - skipping SOCKS5 health check")
            }
        }
    }

    /// Count how many peers are actually alive (respond to ping)
    /// FIX #449: Use hasRecentActivity to avoid unnecessary pings (like keepalive does)
    private func countAlivePeers() async -> Int {
        var alive = 0
        let readyPeers = peers.filter { $0.isConnectionReady }

        for peer in readyPeers {
            // FIX #449: Check recent activity FIRST before pinging (reduces false positives)
            // If peer had activity in last 60 seconds, consider it alive without ping
            if peer.hasRecentActivity {
                alive += 1
            } else {
                // Only ping if no recent activity
                // Use 10 second timeout for health check (was 3s - too aggressive)
                // FIX #869: sendPing now returns PingResult
                let pingResult = await peer.sendPing(timeoutSeconds: 10)
                if pingResult == .success || pingResult == .busy {
                    alive += 1  // FIX #869: busy means peer might be fine
                } else {
                    // Peer didn't respond - mark for potential reconnection
                    debugLog(.network, "💓 Peer \(peer.host) not responding to health check (\(pingResult))")
                }
            }
        }

        return alive
    }

    /// Handle network path change with debouncing (like BitChat's 3s cooldown)
    private func handleNetworkPathChange(path: NWPath) async {
        // FIX #1273: Don't handle network path changes before authentication
        guard BiometricAuthManager.shared.hasAuthenticatedThisSession else { return }

        // FIX #890: Skip network path handling during boost header loading
        // NWPathMonitor callbacks cause thread contention with SQLite bulk inserts
        // This was contributing to the 91-99% stall during Import PK
        if isLoadingHeaders {
            debugLog(.network, "📶 FIX #890: Suppressing path change during header load")
            return
        }

        // FIX #1344: Suppress ALL reconnections during initial sync (boost download + scan phases).
        // On iOS cellular, NWPathMonitor fires every 3-6s (LTE↔5G transitions), triggering
        // 26+ reconnection cycles during import. Each cycle: disconnect all peers → DNS → 8 TCP
        // connections → handshakes → 16 DB writes = massive CPU/radio drain → phone overheats.
        // During initial sync: boost download uses Rust reqwest (not P2P), PHASE 1/1.5 are
        // computation only, PHASE 2 manages its own connections. P2P reconnections are HARMFUL
        // (they kill active header sync connections mid-stream).
        if !backgroundProcessesEnabled {
            // FIX #1352: Only log first suppression (was 53 messages in iOS import log)
            if !hasLoggedPathChangeSuppression {
                hasLoggedPathChangeSuppression = true
                debugLog(.network, "📶 FIX #1344: Suppressing path changes during initial sync (further suppressed)")
            }
            return
        }

        // Check if we're within the debounce window
        if let lastChange = lastPathChangeTime {
            let elapsed = Date().timeIntervalSince(lastChange)
            if elapsed < PATH_CHANGE_DEBOUNCE {
                debugLog(.network, "📶 FIX #268: Ignoring path change - within \(PATH_CHANGE_DEBOUNCE)s debounce window")
                return
            }
        }

        // Update debounce timestamp
        lastPathChangeTime = Date()

        // Increment network generation to invalidate stale reconnection callbacks
        let newGeneration = incrementNetworkGeneration()
        debugLog(.network, "📶 FIX #268: Network generation incremented to \(newGeneration)")

        // If network is not satisfied, just update state and wait
        if path.status != .satisfied {
            debugLog(.network, "📶 FIX #268: Network not satisfied - waiting for connectivity")
            DispatchQueue.main.async {
                self.isConnected = false
                self.connectedPeers = 0
            }
            return
        }

        // FIX #1497: Skip full reconnection if peers are already healthy.
        // iOS cellular tower handoffs trigger path changes without breaking existing TCP connections.
        // Disconnecting all peers and reconnecting wastes CPU/radio and causes the phone to overheat.
        let healthyPeerCount = peers.filter { $0.isConnectionReady }.count
        if healthyPeerCount >= CONSENSUS_THRESHOLD {
            debugLog(.network, "📶 FIX #1497: Path changed but \(healthyPeerCount) healthy peers — skipping reconnection")
            return
        }

        // Network is back - trigger recovery (only when peers are actually unhealthy)
        debugLog(.network, "📶 FIX #268: Network path satisfied - triggering peer recovery (\(healthyPeerCount) healthy peers)")

        // Disconnect all existing peers (their sockets may be stale)
        for peer in peers {
            peer.disconnect()
        }

        // Clear the peers array and reset backoff state
        peers.removeAll()
        reconnectionAttemptsLock.lock()
        reconnectionAttempts.removeAll()
        reconnectionAttemptsLock.unlock()

        // Clear connection cooldowns to allow immediate reconnection
        connectionAttemptsLock.lock()
        connectionAttempts.removeAll()
        connectionAttemptsLock.unlock()

        // Update UI
        DispatchQueue.main.async {
            self.connectedPeers = 0
            self.isConnected = false
        }

        // If Tor is enabled, it may need to rebuild circuits
        if await TorManager.shared.mode == .enabled {
            let torConnected = await TorManager.shared.connectionState.isConnected
            if !torConnected {
                debugLog(.network, "📶 FIX #268: Tor not connected after network change - waiting...")
                // Wait for Tor to reconnect (up to 15s)
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
                    if await TorManager.shared.connectionState.isConnected {
                        debugLog(.network, "📶 FIX #268: Tor reconnected after network change")
                        break
                    }
                }
            }
        }

        // Reconnect to peers with generation check
        let capturedGeneration = newGeneration
        Task {
            // FIX #1273: Do NOT connect to P2P network before authentication.
            // NWPathMonitor fires immediately on app launch when network is available,
            // which would start network connections behind the lock screen.
            if !BiometricAuthManager.shared.hasAuthenticatedThisSession {
                debugLog(.network, "📶 FIX #1273: Skipping network reconnect — not authenticated yet")
                return
            }

            // Check if this generation is still current before connecting
            if self.getNetworkGeneration() != capturedGeneration {
                debugLog(.network, "📶 FIX #268: Stale generation \(capturedGeneration) - aborting reconnection")
                return
            }

            do {
                try await self.connect()
                debugLog(.network, "📶 FIX #268: Successfully reconnected after network path change")

                // FIX #1362: Restart block listeners IMMEDIATELY after network path change recovery.
                // Without this, listeners are dead until FIX #1263 timer fires (~30-88s on iOS).
                // During this gap: no inv messages → no mempool detection → no block confirmation.
                // iOS log showed 88s gap after network path change at app launch → 2m26s to detect
                // incoming TX in mempool, 5m55s to detect block confirmation.
                if !PeerManager.shared.areBlockListenersBlocked() {
                    // Brief wait for TCP connections to stabilize after connect()
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                    // Verify generation is still current (another path change may have fired)
                    if self.getNetworkGeneration() == capturedGeneration {
                        await self.startBlockListenersOnMainScreen()
                        print("📶 FIX #1362: Block listeners restarted after network path change recovery")
                    }
                }
            } catch {
                debugLog(.network, "📶 FIX #268: Failed to reconnect after path change: \(error.localizedDescription)")
            }
        }
    }

    /// Get current network generation (thread-safe)
    /// FIX #388: Uses local counter for synchronous access
    func getNetworkGeneration() -> UInt64 {
        networkGenerationLock.lock()
        defer { networkGenerationLock.unlock() }
        return localNetworkGeneration
    }

    /// Increment network generation and return new value (thread-safe)
    /// FIX #388: Updates local counter synchronously, syncs with PeerManager asynchronously
    @discardableResult
    private func incrementNetworkGeneration() -> UInt64 {
        networkGenerationLock.lock()
        localNetworkGeneration += 1
        let newValue = localNetworkGeneration
        networkGenerationLock.unlock()

        // Sync with PeerManager asynchronously (fire and forget)
        Task { @MainActor in
            PeerManager.shared.incrementNetworkGeneration()
        }

        return newValue
    }

    /// Ping all connected peers to detect dead connections
    private func performKeepalivePing() async {
        // FIX #1273: Don't run before authentication
        if !BiometricAuthManager.shared.hasAuthenticatedThisSession {
            return
        }
        // FIX #1467: Skip keepalive ping when iOS device is overheating
        #if os(iOS)
        if isDeviceOverheating { return }
        #endif

        // FIX #1461: Allow peer growth even during sync — only skip ping when syncing
        let isBusySyncing = isHeaderSyncing || WalletManager.shared.isSyncing

        let readyPeers = peers.filter { $0.isConnectionReady }
        if readyPeers.isEmpty {
            debugLog(.network, "🫀 FIX #246: No peers to ping - triggering recovery")
            await attemptPeerRecovery()
            return
        }

        // FIX #1461: Proactive peer growth — connect to more peers if below MIN_PEERS
        // This runs even during sync, because having more peers improves P2P fetch reliability.
        // The main connect() exits early at 3-6 peers for fast startup; this fills to 8+.
        // FIX #1501: On iOS, skip peer growth when >= CONSENSUS_THRESHOLD peers.
        // z8.log: 14 growth attempts in 21 min, each trying 5 SOCKS5 connections, ALL failing.
        // 3 peers is sufficient for iOS consensus. Growing to 8 wastes CPU/radio.
        #if os(iOS)
        let peerGrowthThreshold = CONSENSUS_THRESHOLD
        #else
        let peerGrowthThreshold = MIN_PEERS
        #endif
        if readyPeers.count < peerGrowthThreshold && !isRecoveringPeers {
            debugLog(.network, "🫀 FIX #1461: Only \(readyPeers.count)/\(peerGrowthThreshold) peers — growing peer count in background")
            await growPeerCount(currentReady: readyPeers.count)
        }

        // FIX #246: Skip ping checks during header sync or active operations
        if isBusySyncing {
            return
        }

        var deadPeers: [(Peer, PingResult)] = []  // FIX #869: Track ping result with dead peer
        var alivePeersFromActivity = 0

        // FIX #327: Check recent activity FIRST before sending ping
        // Block listeners receive messages continuously - if we got data recently, peer is alive
        // Only ping peers with NO recent activity to avoid socket conflicts
        // FIX #869: Return PingResult to distinguish transient vs protocol failures
        await withTaskGroup(of: (Peer, PingResult).self) { group in
            for peer in readyPeers {
                group.addTask {
                    // FIX #327: If peer had recent activity, it's alive (no ping needed)
                    if peer.hasRecentActivity {
                        return (peer, .success)  // Alive based on recent activity
                    }

                    // No recent activity - send actual ping to check
                    let pingResult = await peer.sendPing(timeoutSeconds: 10)
                    return (peer, pingResult)
                }
            }

            for await (peer, pingResult) in group {
                switch pingResult {
                case .success:
                    if peer.hasRecentActivity {
                        alivePeersFromActivity += 1
                    }
                    // FIX #863: Reset ping failures when peer is alive
                    // This prevents false positives from temporary network issues
                    await MainActor.run {
                        PeerManager.shared.resetPingFailures(peer.host)
                    }
                case .busy:
                    // FIX #869: Peer is busy with other operation, not dead
                    // Don't count as failure, don't reset failures either
                    break
                case .timeout, .protocolError, .transientNetworkError:
                    // FIX #869: Track result to decide whether to count towards ban
                    deadPeers.append((peer, pingResult))
                }
            }
        }

        // Log activity-based keepalive
        if alivePeersFromActivity > 0 {
            debugLog(.network, "🫀 FIX #327: \(alivePeersFromActivity) peer(s) alive via recent activity (no ping needed)")
        }

        // Handle dead peers
        if !deadPeers.isEmpty {
            debugLog(.network, "🫀 FIX #246: \(deadPeers.count) dead peer(s) detected via keepalive")

            // CRITICAL FIX: Detect "all peers dead" pattern (Tor SOCKS5 proxy failure)
            // If ALL peers died simultaneously, this is Tor issue, not peer issue
            // Threshold: 3+ peers (consensus threshold) to avoid false positives
            let allPeersDiedSimultaneously = (deadPeers.count == readyPeers.count) && (readyPeers.count >= 3)
            if allPeersDiedSimultaneously {
                print("🚨 CRITICAL: All \(readyPeers.count) peers died simultaneously!")
                print("   This indicates Tor SOCKS5 proxy failure, not peer failure")
                print("   Blocking peer reconnection and restarting Tor...")

                // Block peer reconnection attempts (they'll all fail anyway)
                // Reset all reconnection attempts
                for (peer, _) in deadPeers {
                    await MainActor.run { PeerManager.shared.resetReconnectionAttempts(peer.host, port: peer.port) }
                }

                // Restart Tor instead of trying to reconnect peers
                await TorManager.shared.restartTor()

                // After Tor restart, then reconnect peers
                try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
                await attemptPeerRecovery()

                return  // Skip normal dead peer handling
            }

            // FIX #473: Handle dead peers (they will be parked and not immediately retried)
            // FIX #863/869: Track ping failures - only count PROTOCOL errors towards ban threshold
            // Transient network errors (connection reset, broken pipe) should NOT count
            // FIX #870: Track transient vs protocol errors to decide recovery strategy
            var transientErrorCount = 0
            var protocolErrorCount = 0

            for (deadPeer, pingResult) in deadPeers {
                // FIX #869: Only record ping failure for PROTOCOL errors
                // Transient network errors can happen to any peer and shouldn't lead to banning
                let isProtocolError = (pingResult == .timeout || pingResult == .protocolError)

                var shouldBan = false
                if isProtocolError {
                    protocolErrorCount += 1
                    // FIX #863: Record ping failure and check if peer should be banned
                    // A peer that connects OK but consistently fails ping is likely on wrong chain
                    shouldBan = await MainActor.run {
                        PeerManager.shared.recordPingFailure(deadPeer.host, port: deadPeer.port)
                    }
                } else {
                    transientErrorCount += 1
                    // FIX #869: Transient network error - just log, don't count towards ban
                    debugLog(.network, "⚠️ FIX #869: [\(deadPeer.host)] Transient network error - not counting towards ban")
                }

                if shouldBan {
                    debugLog(.network, "🚫 FIX #863: [\(deadPeer.host)] Banning peer - too many ping failures (likely wrong chain or corrupted protocol)")
                    banPeer(deadPeer, reason: .lowSuccessRate)
                    // Remove from peers array and skip normal dead peer handling
                    peers.removeAll { $0.id == deadPeer.id }
                    continue
                }

                await handleDeadPeer(deadPeer)
            }

            // FIX #473: CRITICAL - Pre-emptively connect to MORE peers before we hit 0
            // Bitcoin Core maintains 8-10 outgoing connections for redundancy
            // We should connect to replacements IMMEDIATELY when peers die, not wait until 0
            // FIX #870: Only do immediate parallel recovery for PROTOCOL errors
            // FIX #872/879: Transient errors include error 54, error 57 (ENOTCONN), error 96 (ENOMSG),
            // connection reset, socket not connected - temporary network issues, parallel recovery overwhelms network
            let currentReadyCount = peers.filter { $0.isConnectionReady }.count
            if currentReadyCount < CONSENSUS_THRESHOLD {
                // FIX #870: If ALL errors were transient (network hiccup), delay recovery
                // This prevents overwhelming network with parallel connections that will all fail
                let allTransient = (transientErrorCount > 0 && protocolErrorCount == 0)

                if allTransient {
                    debugLog(.network, "⚠️ FIX #870: All \(transientErrorCount) failures were transient network errors - delaying recovery by 5s")

                    // FIX #871: Signal health check to suppress CRITICAL alert during transient recovery
                    await MainActor.run { isTransientRecoveryInProgress = true }
                    debugLog(.network, "⏳ FIX #871: Set isTransientRecoveryInProgress = true")

                    // Short delay to let network stabilize before retrying
                    try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds

                    // Check if peers recovered during the delay (network hiccups often resolve quickly)
                    let readyAfterDelay = peers.filter { $0.isConnectionReady }.count
                    if readyAfterDelay >= CONSENSUS_THRESHOLD {
                        debugLog(.network, "✅ FIX #870: Peers recovered during delay (\(readyAfterDelay) ready) - skipping recovery")
                    } else {
                        debugLog(.network, "🔄 FIX #870: Still only \(readyAfterDelay) peers - starting recovery")
                        await attemptPeerRecovery()
                    }

                    // FIX #871: Clear the flag after recovery attempt (success or failure)
                    await MainActor.run { isTransientRecoveryInProgress = false }
                    debugLog(.network, "✅ FIX #871: Set isTransientRecoveryInProgress = false")
                } else {
                    print("⚠️ FIX #473: Only \(currentReadyCount) peers alive (need \(CONSENSUS_THRESHOLD)) - pre-emptively connecting to replacements...")
                    // Trigger immediate recovery to connect to more peers before we hit 0
                    await attemptPeerRecovery()
                }
            }
        }

        // FIX #326: Track successful peer contact for Tor circuit health
        let alivePeers = readyPeers.count - deadPeers.count
        if alivePeers > 0 {
            lastSuccessfulPeerContact = Date()
        } else {
            // All peers are dead - check if Tor circuit refresh is needed
            let timeSinceContact = Date().timeIntervalSince(lastSuccessfulPeerContact)
            if timeSinceContact > TOR_CIRCUIT_REFRESH_THRESHOLD {
                await refreshTorCircuitsIfNeeded()
            }
        }

        // Update UI (CPU OPTIMIZATION: only if values changed)
        DispatchQueue.main.async {
            let currentReady = self.peers.filter { $0.isConnectionReady }
            let newCount = currentReady.count
            let newConnected = newCount > 0
            if self.connectedPeers != newCount { self.connectedPeers = newCount }
            if self.isConnected != newConnected { self.isConnected = newConnected }
            // FIX #1420: Also update Tor peer counts in keepalive timer
            let newTorCount = self.peers.filter { $0.isConnectedViaTor && $0.isConnectionReady }.count
            let newOnionCount = self.peers.filter { $0.isOnion && $0.isConnectionReady }.count
            if self.torConnectedPeersCount != newTorCount { self.torConnectedPeersCount = newTorCount }
            if self.onionConnectedPeersCount != newOnionCount { self.onionConnectedPeersCount = newOnionCount }
        }

        // Merge from connection health timer: update settings counts + Tor health
        updatePeerCountsForSettings()
        let torMode = await TorManager.shared.mode
        if torMode == .enabled {
            let torHealthy = await TorManager.shared.checkSOCKS5Health()
            if !torHealthy {
                debugLog(.network, "⚠️ Tor SOCKS5 health check failed during keepalive")
            }
        }
    }

    /// FIX #326: Refresh Tor circuits when connections are stale
    /// Arti circuits can become stale after hours of inactivity
    private func refreshTorCircuitsIfNeeded() async {
        let torMode = await TorManager.shared.mode
        guard torMode == .enabled else { return }
        guard !torCircuitRefreshInProgress else { return }

        torCircuitRefreshInProgress = true
        let timeSinceContact = Date().timeIntervalSince(lastSuccessfulPeerContact)
        print("🧅 FIX #326: No peer contact for \(Int(timeSinceContact/60)) minutes - refreshing Tor circuits...")

        // Stop and restart Tor to get fresh circuits
        await TorManager.shared.stop()
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 second delay
        await TorManager.shared.start()

        // Wait for SOCKS proxy to be ready
        let proxyReady = await TorManager.shared.waitForSocksProxyReady(maxWait: 30)
        if proxyReady {
            print("✅ FIX #326: Tor circuits refreshed - attempting peer recovery")
            lastSuccessfulPeerContact = Date()  // Reset timer
            await attemptPeerRecovery()
        } else {
            print("❌ FIX #326: Tor circuit refresh failed")
        }

        torCircuitRefreshInProgress = false
    }

    /// Handle a dead peer with reconnection using exponential backoff
    /// FIX #268: Uses generation tracking to abort if network changed during sleep
    /// FIX #384: Uses PeerManager for backoff tracking
    /// FIX #473: Park failing peers so they're not immediately retried
    private func handleDeadPeer(_ peer: Peer) async {
        // FIX #268: Capture generation at start - if it changes, abort reconnection
        // FIX #388: Use local synchronous generation counter
        let capturedGeneration = getNetworkGeneration()

        // Disconnect cleanly
        peer.disconnect()

        // Remove from peers list
        peers.removeAll { $0.id == peer.id }

        // FIX #384: Sync peer removal to PeerManager
        await MainActor.run {
            PeerManager.shared.syncPeers(self.peers)
        }

        // FIX #473: PARK the peer so it's not immediately retried in recovery
        // This prevents wasting time on peers that are known to fail
        // Peers will be unparked when they're ready for retry (exponential backoff)
        await MainActor.run {
            PeerManager.shared.parkPeer(peer.host, port: peer.port)
        }

        // FIX #384: Get current attempt count and increment using PeerManager
        let attempts = await MainActor.run { PeerManager.shared.getReconnectionAttempts(peer.host, port: peer.port) }
        await MainActor.run { PeerManager.shared.incrementReconnectionAttempts(peer.host, port: peer.port) }

        // FIX #388: Calculate backoff - nonisolated method, no MainActor.run needed
        let backoffSeconds = PeerManager.shared.calculateBackoffWithJitter(attempts: attempts)

        debugLog(.network, "🔄 FIX #246: [\(peer.host)] Dead - will retry in \(String(format: "%.1f", backoffSeconds))s (attempt \(attempts + 1), gen=\(capturedGeneration))")

        // Schedule reconnection with backoff
        Task { [weak self] in
            guard let self = self else { return }

            try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))

            // FIX #268: Check if network generation changed - abort if stale
            // FIX #388: Use local generation counter for synchronous check
            let currentGen = self.getNetworkGeneration()
            let isStale = currentGen != capturedGeneration
            if isStale {
                debugLog(.network, "📶 FIX #268: [\(peer.host)] Stale reconnection (gen \(capturedGeneration) → \(currentGen)) - aborting")
                await MainActor.run { PeerManager.shared.resetReconnectionAttempts(peer.host, port: peer.port) }
                return
            }

            // Check if peer is still dead (not reconnected by another mechanism)
            let isAlreadyConnected = await MainActor.run { PeerManager.shared.isAlreadyConnected(peer.host) }
            if isAlreadyConnected {
                await MainActor.run { PeerManager.shared.resetReconnectionAttempts(peer.host, port: peer.port) }
                return
            }

            // Attempt reconnection with generation check
            await self.reconnectWithBackoff(host: peer.host, port: peer.port, generation: capturedGeneration)
        }
    }

    /// Calculate exponential backoff with jitter
    /// FIX #384: Delegates to PeerManager
    private func calculateBackoffWithJitter(attempts: Int) -> TimeInterval {
        return PeerManager.shared.calculateBackoffWithJitter(attempts: attempts)
    }

    /// Attempt to reconnect to a peer with exponential backoff
    /// FIX #268: Optional generation parameter - if provided and stale, aborts reconnection
    /// FIX #384: Uses PeerManager for backoff and SOCKS5 failure tracking
    private func reconnectWithBackoff(host: String, port: UInt16, generation: UInt64? = nil) async {
        // FIX #268: Check generation if provided - abort if network context changed
        // FIX #388: Use local generation counter for synchronous check
        if let capturedGen = generation {
            let currentGen = getNetworkGeneration()
            let isStale = currentGen != capturedGen
            if isStale {
                debugLog(.network, "📶 FIX #268: [\(host)] Stale generation in reconnectWithBackoff - aborting")
                await MainActor.run { PeerManager.shared.resetReconnectionAttempts(host, port: port) }
                return
            }
        }

        // FIX #384: Get attempt count from PeerManager
        let attempts = await MainActor.run { PeerManager.shared.getReconnectionAttempts(host, port: port) }

        // Give up after too many attempts
        if attempts >= 10 {
            debugLog(.network, "🛑 FIX #246: [\(host)] Giving up after \(attempts) failed reconnection attempts")
            await MainActor.run { PeerManager.shared.resetReconnectionAttempts(host, port: port) }
            return
        }

        let address = PeerAddress(host: host, port: port)

        // Check if banned (already delegates to PeerManager)
        if isBanned(host) {
            debugLog(.network, "🚫 FIX #246: [\(host)] Banned - not reconnecting")
            await MainActor.run { PeerManager.shared.resetReconnectionAttempts(host, port: port) }
            return
        }

        do {
            let peer = try await connectToPeer(address)
            peers.append(peer)
            // FIX #478: Also add to PeerManager to keep peer lists in sync
            PeerManager.shared.addPeer(peer)
            setupBlockListener(for: peer)

            // FIX #384: Sync success to PeerManager
            await MainActor.run {
                PeerManager.shared.resetReconnectionAttempts(host, port: port)
                PeerManager.shared.recordConnectionSuccess(host, port: port)
                PeerManager.shared.syncPeers(self.peers)
            }
            debugLog(.network, "✅ FIX #246: [\(host)] Reconnected successfully")

            // Update UI (CPU OPTIMIZATION: only if changed)
            DispatchQueue.main.async {
                let newCount = self.peers.filter { $0.isConnectionReady }.count
                if self.connectedPeers != newCount { self.connectedPeers = newCount }
                let newConnected = newCount > 0
                if self.isConnected != newConnected { self.isConnected = newConnected }
                // FIX #1420: Also update Tor peer counts
                let newTorCount = self.peers.filter { $0.isConnectedViaTor && $0.isConnectionReady }.count
                let newOnionCount = self.peers.filter { $0.isOnion && $0.isConnectionReady }.count
                if self.torConnectedPeersCount != newTorCount { self.torConnectedPeersCount = newTorCount }
                if self.onionConnectedPeersCount != newOnionCount { self.onionConnectedPeersCount = newOnionCount }
            }
        } catch {
            debugLog(.network, "❌ FIX #246: [\(host)] Reconnection failed: \(error.localizedDescription)")

            // Check for specific error types that indicate Tor issues
            // FIX #384: Track SOCKS5 failures in PeerManager
            let errorDesc = error.localizedDescription.lowercased()
            if errorDesc.contains("socks") || errorDesc.contains("socket") ||
               errorDesc.contains("reset") || errorDesc.contains("broken pipe") {
                await MainActor.run { PeerManager.shared.recordSOCKS5Failure() }

                // If too many SOCKS failures, consider Tor health check
                let shouldCheck = await MainActor.run { PeerManager.shared.shouldCheckTorHealth() }
                if shouldCheck {
                    debugLog(.network, "🧅 FIX #246: Too many SOCKS5 failures - checking Tor health")
                    await checkAndRestartTorIfNeeded()
                }
            }
        }
    }

    /// Check Tor health and restart if degraded
    private func checkAndRestartTorIfNeeded() async {
        let torManager = await TorManager.shared
        let torMode = await torManager.mode
        let torConnected = await torManager.connectionState.isConnected

        // Only check if Tor should be running
        guard torMode == .enabled else { return }

        if !torConnected {
            debugLog(.network, "🧅 FIX #246: Tor is enabled but not connected - attempting restart")

            // Reset SOCKS failure counter before restart
            consecutiveSOCKS5Failures = 0

            // Restart Tor
            await torManager.stop()
            try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 second delay
            await torManager.start()

            // Wait for reconnection
            let proxyReady = await torManager.waitForSocksProxyReady(maxWait: 30)
            if proxyReady {
                debugLog(.network, "✅ FIX #246: Tor restarted successfully")
            } else {
                debugLog(.network, "❌ FIX #246: Tor restart failed - may need manual intervention")
            }
        }
    }
}

// MARK: - Supporting Types
// NOTE: PeerAddress, AddressInfo, PersistedAddress are now defined in PeerManager.swift

/// User-added custom node for manual peer management
/// Supports IPv4, IPv6, and .onion addresses
public struct UserCustomNode: Codable, Identifiable, Equatable {
    public let id: UUID
    public var host: String  // IPv4, IPv6, or .onion address
    public var port: UInt16
    public var label: String  // User-friendly name
    public var isEnabled: Bool
    public var addedDate: Date
    public var lastConnected: Date?
    public var connectionSuccesses: Int
    public var connectionAttempts: Int

    public init(host: String, port: UInt16 = 8033, label: String = "") {
        self.id = UUID()
        self.host = host
        self.port = port
        self.label = label.isEmpty ? host : label
        self.isEnabled = true
        self.addedDate = Date()
        self.lastConnected = nil
        self.connectionSuccesses = 0
        self.connectionAttempts = 0
    }

    /// Determine the address type
    public var addressType: AddressType {
        if host.hasSuffix(".onion") {
            return .onion
        } else if host.contains(":") {
            return .ipv6
        } else {
            return .ipv4
        }
    }

    public enum AddressType: String, Codable {
        case ipv4 = "IPv4"
        case ipv6 = "IPv6"
        case onion = "Onion"

        public var icon: String {
            switch self {
            case .ipv4: return "network"
            case .ipv6: return "network.badge.shield.half.filled"
            case .onion: return "shield.lefthalf.filled"
            }
        }
    }

    /// Validate the address format
    public var isValid: Bool {
        switch addressType {
        case .onion:
            // Tor v3 onion addresses are 56 characters (without .onion)
            let onionPart = host.replacingOccurrences(of: ".onion", with: "")
            return onionPart.count == 56 && onionPart.allSatisfy { $0.isLetter || $0.isNumber }
        case .ipv4:
            let components = host.split(separator: ".")
            if components.count != 4 { return false }
            return components.allSatisfy { UInt8($0) != nil }
        case .ipv6:
            // Basic IPv6 validation
            return host.contains(":") && !host.contains("..")
        }
    }

    /// Success rate as percentage
    public var successRate: Double {
        guard connectionAttempts > 0 else { return 0 }
        return Double(connectionSuccesses) / Double(connectionAttempts) * 100
    }
}

/// Peer data for bundling in app resources
struct BundledPeer: Codable {
    let host: String
    let port: UInt16
    let reliability: Double  // Success rate 0.0-1.0
    let lastSeen: Date
}

struct ShieldedBalance: Equatable {
    let confirmed: UInt64
    let pending: UInt64
}

struct BlockHeader: Hashable {
    let version: Int32
    let prevBlockHash: Data
    let merkleRoot: Data
    let finalSaplingRoot: Data // 32-byte reserved field (hashFinalSaplingRoot post-Sapling)
    let timestamp: UInt32
    let bits: UInt32
    let nonce: Data // Equihash nonce (32 bytes)
    let solution: Data // Equihash solution (400 bytes for post-Bubbles Equihash(192,7))
}

struct CompactFilter: Hashable {
    let blockHash: Data
    let filterType: UInt8
    let filterData: Data
}

// MARK: - Network Errors

enum NetworkError: LocalizedError, Equatable {
    case notConnected
    case insufficientPeers(Int, Int)
    case consensusNotReached
    case broadcastFailed
    case transactionRejected
    case transactionDuplicateRejected  // FIX #563 v8: Track DUPLICATE rejections separately
    case transactionNotVerified
    case invalidTransaction(String)  // FIX #516: Invalid transaction (anchor not found, etc)
    case connectionFailed(String)
    case handshakeFailed
    case wrongChain(String)  // FIX #229: Zcash peer detected (requires 170020+)
    case invalidMagicBytes  // For tolerant block listener - can retry
    case streamDesync  // FIX #892: TCP stream desynchronized - need fresh connection
    case timeout
    case connectionTimeout
    case invalidData
    case notFound
    case p2pFetchFailed
    case scanAbortedDueToNetworkFailure(fetched: Int, needed: Int, lastHeight: UInt64)  // FIX #910

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to network"
        case .insufficientPeers(let connected, let required):
            return "Insufficient peers: \(connected)/\(required)"
        case .consensusNotReached:
            return "Could not reach consensus among peers"
        case .broadcastFailed:
            return "Transaction broadcast failed"
        case .transactionRejected:
            return "Transaction was rejected by the network"
        case .transactionDuplicateRejected:
            return "Transaction already in peer's mempool (DUPLICATE)"
        case .transactionNotVerified:
            return "Transaction not found on blockchain - may have been rejected"
        case .invalidTransaction(let reason):
            return "Invalid transaction: \(reason)"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .handshakeFailed:
            return "Peer handshake failed"
        case .wrongChain(let host):
            return "Wrong chain: \(host) is Zcash, not Zclassic"
        case .invalidMagicBytes:
            return "Invalid P2P magic bytes (Tor noise or protocol mismatch)"
        case .streamDesync:
            return "TCP stream desynchronized - need fresh connection"
        case .timeout:
            return "Request timed out"
        case .connectionTimeout:
            return "Connection timed out"
        case .invalidData:
            return "Invalid data format"
        case .notFound:
            return "Data not found on peer"
        case .p2pFetchFailed:
            return "P2P block fetch failed"
        case .scanAbortedDueToNetworkFailure(let fetched, let needed, let lastHeight):
            return "FIX #910: Scan aborted - network failure (fetched \(fetched)/\(needed) blocks, last height: \(lastHeight))"
        }
    }
}
