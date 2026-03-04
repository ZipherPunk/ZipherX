//
//  ChatManager.swift
//  ZipherX
//
//  Created by ZipherX Team on 2025-12-09.
//  Cypherpunk P2P Chat Manager - Encrypted messaging over Tor
//
//  "Cypherpunks write code. We know that software can't be destroyed."
//  - A Cypherpunk's Manifesto
//

import Foundation
import Network
import CryptoKit

// MARK: - Chat Connection State

/// State of a chat connection to a peer
enum ChatConnectionState: Equatable {
    case disconnected
    case connecting
    case handshaking
    case connected
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - Chat Peer

/// A connected chat peer with encryption state
actor ChatPeer {
    let onionAddress: String
    let connection: NWConnection

    private(set) var state: ChatConnectionState = .disconnected
    private(set) var sharedKey: SymmetricKey?
    private(set) var theirPublicKey: Curve25519.KeyAgreement.PublicKey?
    private(set) var lastActivity: Date = Date()
    private(set) var nickname: String?

    private let ourPrivateKey: Curve25519.KeyAgreement.PrivateKey
    private let ourPublicKey: Curve25519.KeyAgreement.PublicKey

    init(onionAddress: String, connection: NWConnection) {
        self.onionAddress = onionAddress
        self.connection = connection

        // Generate ephemeral key pair for this session
        let keyPair = ChatEncryption.generateKeyPair()
        self.ourPrivateKey = keyPair.privateKey
        self.ourPublicKey = keyPair.publicKey
    }

    func setState(_ newState: ChatConnectionState) {
        state = newState
        lastActivity = Date()
    }

    func setSharedKey(_ key: SymmetricKey) {
        sharedKey = key
        lastActivity = Date()
    }

    func setTheirPublicKey(_ key: Curve25519.KeyAgreement.PublicKey) throws {
        theirPublicKey = key
        // Derive shared secret
        let shared = try ChatEncryption.deriveSharedSecret(
            ourPrivateKey: ourPrivateKey,
            theirPublicKey: key
        )
        sharedKey = shared
        lastActivity = Date()
    }

    func setNickname(_ name: String?) {
        nickname = name
        lastActivity = Date()
    }

    func updateActivity() {
        lastActivity = Date()
    }

    func getOurPublicKeyData() -> Data {
        ourPrivateKey.publicKey.rawRepresentation
    }
}

// MARK: - Chat Manager

/// Main manager for Cypherpunk P2P Chat
/// Handles connections, encryption, and message routing
@MainActor
final class ChatManager: ObservableObject {

    // MARK: - Singleton

    static let shared = ChatManager()

    // MARK: - Published Properties

    /// All contacts
    @Published private(set) var contacts: [ChatContact] = []

    /// Active conversations
    @Published private(set) var conversations: [String: ChatConversation] = [:]

    /// Currently selected conversation
    @Published var selectedConversation: String?

    /// Unread message count (total)
    @Published private(set) var totalUnreadCount: Int = 0

    /// Is chat service available (requires Tor + Hidden Service)
    @Published private(set) var isAvailable: Bool = false

    /// FIX #1532: True while connecting to contacts after startup (warmup phase)
    @Published private(set) var isWarmingUp: Bool = false

    /// Our .onion address for chat
    @Published private(set) var ourOnionAddress: String?

    /// Our nickname
    /// VUL-STOR-003: Now stored in encrypted SQLCipher database instead of plaintext UserDefaults
    @Published var ourNickname: String {
        didSet {
            WalletDatabase.shared.saveChatSetting(key: "chatNickname", value: ourNickname)
            // FIX #1508: Resend nickname to all connected contacts when it changes
            if ourNickname != oldValue && !ourNickname.isEmpty {
                Task { await resendProfileToConnectedContacts(nicknameOnly: true) }
            }
        }
    }

    /// FIX #1436: Our profile image (stored as file, not UserDefaults)
    @Published var profileImage: Data? = nil

    /// FIX #1436: Whether to share profile image with contacts
    /// VUL-STOR-003: Now stored in encrypted SQLCipher database instead of plaintext UserDefaults
    var isProfileImageShared: Bool {
        get {
            WalletDatabase.shared.getChatSetting(key: "chatShareProfileImage") == "true"
        }
        set {
            let oldValue = WalletDatabase.shared.getChatSetting(key: "chatShareProfileImage") == "true"
            WalletDatabase.shared.saveChatSetting(key: "chatShareProfileImage", value: newValue ? "true" : "false")
            // FIX #1508: When toggle is enabled, immediately send profile to all connected contacts
            if newValue && !oldValue {
                Task { await resendProfileToConnectedContacts(nicknameOnly: false) }
            }
        }
    }

    // MARK: - Private Properties

    /// Connected peers (actor-isolated)
    private var peers: [String: ChatPeer] = [:]

    /// NWListener for incoming chat connections
    private var listener: NWListener?

    /// Background task for connection maintenance
    private var maintenanceTask: Task<Void, Never>?

    /// Database for message persistence
    private let database: ChatDatabase

    /// Queue for network operations
    private let networkQueue = DispatchQueue(label: "chat.network", qos: .userInitiated)

    // MARK: - FIX #249: Message Queue for Offline Recipients

    /// Queued messages waiting to be sent when recipient comes online
    /// Key: onionAddress, Value: array of queued messages
    private var messageQueue: [String: [ChatMessage]] = [:]

    /// UserDefaults key for persisting encrypted message queue
    private let messageQueueKey = "chat_message_queue_encrypted"

    /// Keychain key for queue encryption key
    private let queueEncryptionKeyKeychainKey = "com.zipherx.chat-queue-key"

    /// Task for periodic queue retry
    private var queueRetryTask: Task<Void, Never>?

    /// Retry interval for queued messages (30 seconds)
    private let queueRetryInterval: TimeInterval = 30

    /// FIX #249 v2: Maximum age for queued messages (180 days)
    private let maxQueuedMessageAge: TimeInterval = 180 * 24 * 60 * 60  // 180 days in seconds

    /// Cached encryption key for queue (loaded from Keychain)
    private var queueEncryptionKey: SymmetricKey?

    // MARK: - FIX #329: Exponential Backoff for Hidden Service Retries

    /// Tracks connection failure count per contact for exponential backoff
    /// Key: onionAddress, Value: consecutive failure count
    private var connectionFailureCount: [String: Int] = [:]

    /// FIX #1458: Increased max backoff from 30s to 5 minutes.
    /// Offline .onion contacts generate ~30 TCP connections per attempt (SOCKS5 + Tor circuit).
    /// With 30s max backoff + 30s maintenance loop = constant retries = hundreds of "Connection reset by peer".
    private let maxBackoffSeconds: Double = 300.0

    /// FIX #1473: Base backoff delay increased from 2s to 35s.
    /// With 30s maintenance loop, first backoff (35s) must exceed loop interval
    /// or shouldSkipConnection() never blocks retries (30s > 4s/8s/16s = always retry).
    private let baseBackoffSeconds: Double = 35.0

    /// FIX #1458: Track last attempt time to prevent overlapping connection attempts
    private var lastConnectionAttempt: [String: Date] = [:]
    /// FIX #1476: Prevent concurrent connection attempts to the same contact.
    /// Multiple callers (maintenance loop, checkAllContactsOnline, flushMessageQueue, UI)
    /// can race past the "already connected" check before any connection is established.
    private var connectionsInFlight: Set<String> = []

    /// Calculate backoff delay using exponential formula: min(base * 2^failures, max)
    private func calculateBackoff(for onionAddress: String) -> Double {
        let failures = connectionFailureCount[onionAddress] ?? 0
        let delay = baseBackoffSeconds * pow(2.0, Double(failures))
        return min(delay, maxBackoffSeconds)
    }

    /// FIX #1458: Check if we should skip this connection attempt (still within backoff window)
    private func shouldSkipConnection(for onionAddress: String) -> Bool {
        guard let lastAttempt = lastConnectionAttempt[onionAddress] else { return false }
        let backoff = calculateBackoff(for: onionAddress)
        let elapsed = Date().timeIntervalSince(lastAttempt)
        return elapsed < backoff
    }

    /// Record a connection failure for backoff calculation
    private func recordConnectionFailure(for onionAddress: String) {
        let current = connectionFailureCount[onionAddress] ?? 0
        connectionFailureCount[onionAddress] = min(current + 1, 8) // FIX #1458: Cap at 8 (5 min max)
        lastConnectionAttempt[onionAddress] = Date()
    }

    /// Reset failure count on successful connection
    private func resetConnectionFailure(for onionAddress: String) {
        connectionFailureCount.removeValue(forKey: onionAddress)
        lastConnectionAttempt.removeValue(forKey: onionAddress)
    }

    // MARK: - Initialization

    private init() {
        // VUL-STOR-003: Migrate from UserDefaults to SQLCipher if needed
        if let legacyNickname = UserDefaults.standard.string(forKey: "chatNickname"),
           !legacyNickname.isEmpty,
           WalletDatabase.shared.getChatSetting(key: "chatNickname") == nil {
            WalletDatabase.shared.saveChatSetting(key: "chatNickname", value: legacyNickname)
            UserDefaults.standard.removeObject(forKey: "chatNickname")
            print("💬 VUL-STOR-003: Migrated chatNickname from UserDefaults to SQLCipher")
        }

        // VUL-STOR-003: Migrate profile sharing flag
        if UserDefaults.standard.object(forKey: "chatShareProfileImage") != nil {
            let legacyValue = UserDefaults.standard.bool(forKey: "chatShareProfileImage")
            if WalletDatabase.shared.getChatSetting(key: "chatShareProfileImage") == nil {
                WalletDatabase.shared.saveChatSetting(key: "chatShareProfileImage", value: legacyValue ? "true" : "false")
                UserDefaults.standard.removeObject(forKey: "chatShareProfileImage")
                print("💬 VUL-STOR-003: Migrated chatShareProfileImage from UserDefaults to SQLCipher")
            }
        }

        // FIX #1482: Migrate contacts and messages from old UserDefaults+ChaChaPoly to SQLCipher
        // Old ChatDatabase stored contacts in "chat_contacts_encrypted" and messages in
        // "chat_messages_encrypted_<onionAddress>" — both encrypted with ChaChaPoly using
        // key from Keychain ("com.zipherx.chat-database-key").
        ChatManager.migrateLegacyChatData()

        // Load nickname from SQLCipher (may be empty if DB not open yet — FIX #1526 reloads)
        self.ourNickname = WalletDatabase.shared.getChatSetting(key: "chatNickname") ?? ""
        self.database = ChatDatabase()

        // FIX #1525: Load profile image SYNCHRONOUSLY before any connections.
        // Previously called inside async loadPersistentData() → profileImage was nil when
        // connect(to:) checked it → avatar never sent on initial connection.
        loadProfileImage()

        // Load contacts and conversations from database
        // NOTE: If DB is not open yet (before biometric auth), this loads empty data.
        // FIX #1526 observer below reloads once DB is ready.
        if WalletDatabase.shared.isOpen {
            Task {
                await loadPersistentData()
                await loadMessageQueue()
            }
        }

        // FIX #1526: ChatManager.init() runs before WalletDatabase.open() (SwiftUI creates
        // @StateObject before biometric auth completes). All DB reads return empty → 0 contacts,
        // empty nickname. Observe DB open notification to reload with real data.
        NotificationCenter.default.addObserver(forName: .walletDatabaseOpened, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Reload nickname from DB (was empty at init time)
                let savedNickname = WalletDatabase.shared.getChatSetting(key: "chatNickname") ?? ""
                if !savedNickname.isEmpty && self.ourNickname.isEmpty {
                    self.ourNickname = savedNickname
                    print("💬 FIX #1526: Reloaded nickname '\(savedNickname)' after DB open")
                }
                // Reload contacts, conversations, messages
                await self.loadPersistentData()
                await self.loadMessageQueue()
                print("💬 FIX #1526: Reloaded \(self.contacts.count) contacts after DB open")
            }
        }

        // FIX #1487: When .onion circuits become ready, reset backoff and retry all contacts.
        // Without this: first connect fails (circuits not ready) → 35s+ backoff → stuck offline.
        // FIX #1564: Also auto-start the chat service if not yet started. Previously, chat only
        // started when the user opened the Chat tab (ChatView.onAppear). If the user stays on
        // the wallet screen, the NWListener on port 8034 never starts → macOS can't connect →
        // messages never arrive. Now the service starts automatically when Tor is ready.
        NotificationCenter.default.addObserver(forName: .onionCircuitsReady, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // FIX #1564: Auto-start chat service when circuits are ready (regardless of UI state)
                if !self.isAvailable {
                    do {
                        try await self.start()
                        print("💬 FIX #1564: Chat auto-started on circuits ready (no ChatView needed)")
                    } catch {
                        print("💬 FIX #1564: Chat auto-start failed: \(error)")
                        return
                    }
                }
                print("💬 FIX #1487: .onion circuits ready — resetting backoff and retrying all contacts")
                self.connectionFailureCount.removeAll()
                self.lastConnectionAttempt.removeAll()
                await self.checkAllContactsOnline()
            }
        }

        print("💬 ChatManager initialized")
    }

    // MARK: - FIX #1482: Legacy Data Migration

    /// Migrate contacts and messages from old UserDefaults+ChaChaPoly to SQLCipher.
    /// The old ChatDatabase (pre-VUL-STOR-003) stored:
    ///   - Contacts: "chat_contacts_encrypted" in UserDefaults
    ///   - Messages: "chat_messages_encrypted_<onionAddress>" in UserDefaults
    ///   - Encryption key: "com.zipherx.chat-database-key" in Keychain
    private static func migrateLegacyChatData() {
        let legacyContactsKey = "chat_contacts_encrypted"
        let legacyMessagesPrefix = "chat_messages_encrypted_"
        let legacyKeychainKey = "com.zipherx.chat-database-key"

        // Check if there's old data to migrate
        guard let encryptedContacts = UserDefaults.standard.data(forKey: legacyContactsKey) else {
            return  // No legacy data — nothing to migrate
        }

        // Only migrate if SQLCipher has no contacts yet (avoid duplicate migration)
        let existingContacts = WalletDatabase.shared.loadChatContacts()
        if !existingContacts.isEmpty {
            // Already have contacts in SQLCipher — just clean up old data
            UserDefaults.standard.removeObject(forKey: legacyContactsKey)
            print("💬 FIX #1482: Cleaned up legacy contacts (already in SQLCipher)")
            return
        }

        // Load the old ChaChaPoly encryption key from Keychain
        guard let encryptionKey = loadLegacyChatDatabaseKey(keychainKey: legacyKeychainKey) else {
            print("💬 FIX #1482: Cannot migrate — old encryption key not found in Keychain")
            return
        }

        // Decrypt contacts
        guard let decryptedData = decryptLegacyData(encryptedContacts, using: encryptionKey),
              let contacts = try? JSONDecoder().decode([ChatContact].self, from: decryptedData) else {
            print("💬 FIX #1482: Cannot migrate — failed to decrypt/decode legacy contacts")
            return
        }

        // Save contacts to SQLCipher
        var migratedContacts = 0
        var migratedMessages = 0
        for contact in contacts {
            WalletDatabase.shared.saveChatContact(
                onionAddress: contact.onionAddress,
                nickname: contact.nickname.isEmpty ? nil : contact.nickname,
                isBlocked: contact.isBlocked,
                unreadCount: contact.unreadCount,
                lastMessageTime: nil
            )
            migratedContacts += 1

            // Migrate messages for this contact
            let messagesKey = legacyMessagesPrefix + contact.onionAddress
            if let encryptedMessages = UserDefaults.standard.data(forKey: messagesKey),
               let decryptedMessages = decryptLegacyData(encryptedMessages, using: encryptionKey),
               let messages = try? JSONDecoder().decode([ChatMessage].self, from: decryptedMessages) {
                for message in messages {
                    let isSent = message.status == .sent || message.status == .delivered || message.status == .read
                    let isDelivered = message.status == .delivered || message.status == .read
                    let isRead = message.status == .read

                    WalletDatabase.shared.saveChatMessage(
                        id: message.id,
                        conversationAddress: contact.onionAddress,
                        fromOnion: message.fromOnion,
                        toOnion: message.toOnion,
                        content: message.content,
                        messageType: message.type.rawValue,
                        isSent: isSent,
                        isDelivered: isDelivered,
                        isRead: isRead,
                        timestamp: Int64(message.timestamp.timeIntervalSince1970),
                        replyToId: message.replyTo
                    )
                    migratedMessages += 1
                }
                UserDefaults.standard.removeObject(forKey: messagesKey)
            }
        }

        // Clean up old contacts data
        UserDefaults.standard.removeObject(forKey: legacyContactsKey)
        print("💬 FIX #1482: Migrated \(migratedContacts) contacts and \(migratedMessages) messages from UserDefaults to SQLCipher")
    }

    /// Load the old ChatDatabase encryption key from Keychain
    private static func loadLegacyChatDatabaseKey(keychainKey: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: keychainKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        return nil
    }

    /// Decrypt data using ChaChaPoly (matches old ChatDatabase format)
    private static func decryptLegacyData(_ data: Data, using key: SymmetricKey) -> Data? {
        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: data)
            return try ChaChaPoly.open(sealedBox, using: key)
        } catch {
            print("💬 FIX #1482: Legacy decryption error: \(error)")
            return nil
        }
    }

    // MARK: - Public API

    /// Start the chat service (requires Hidden Service to be running)
    func start() async throws {
        // FIX #1561: Race condition — Hidden Service (Arti/Rust) starts accepting TCP connections
        // on port 8034 as soon as state == .running. If start() waits for the state check first,
        // there is a window where Tor forwards an iOS connection to 127.0.0.1:8034 but no
        // NWListener is bound yet → "Connection refused" → iOS drops the call/message.
        // Fix: bind the NWListener BEFORE checking hidden service state so the port is ready
        // the moment the first connection arrives, regardless of timing.
        if listener == nil {
            try startListener()
        }

        guard await HiddenServiceManager.shared.state == .running else {
            throw ChatError.hiddenServiceNotRunning
        }

        guard let onion = await HiddenServiceManager.shared.onionAddress else {
            throw ChatError.hiddenServiceNotRunning
        }

        ourOnionAddress = onion

        // Start maintenance loop
        startMaintenanceLoop()

        isAvailable = true
        print("💬 Chat service started at \(onion):\(CYPHERPUNK_CHAT_PORT)")
    }

    /// Stop the chat service
    func stop() async {
        maintenanceTask?.cancel()
        maintenanceTask = nil

        listener?.cancel()
        listener = nil

        // Disconnect all peers
        for (_, peer) in peers {
            await peer.connection.cancel()
        }
        peers.removeAll()

        isAvailable = false
        ourOnionAddress = nil

        print("💬 Chat service stopped")
    }

    /// Add a new contact by .onion address
    func addContact(onionAddress: String, nickname: String) throws {
        // Validate onion address format
        guard isValidOnionAddress(onionAddress) else {
            throw ChatError.invalidMessage("Invalid .onion address format")
        }

        // FIX #192: Prevent adding own address as contact
        if onionAddress == ourOnionAddress {
            throw ChatError.invalidMessage("Cannot add yourself as a contact")
        }

        // Check if already exists
        guard !contacts.contains(where: { $0.onionAddress == onionAddress }) else {
            throw ChatError.invalidMessage("Contact already exists")
        }

        let contact = ChatContact(onionAddress: onionAddress, nickname: nickname)
        contacts.append(contact)

        // Create empty conversation
        conversations[onionAddress] = ChatConversation(contact: contact)

        // Persist
        database.saveContact(contact)

        print("💬 Added contact: \(nickname) (\(onionAddress.prefix(16))...)")
    }

    /// Remove a contact
    func removeContact(_ contact: ChatContact) {
        contacts.removeAll { $0.onionAddress == contact.onionAddress }
        conversations.removeValue(forKey: contact.onionAddress)

        // Disconnect if connected
        if let peer = peers[contact.onionAddress] {
            Task {
                await peer.connection.cancel()
            }
            peers.removeValue(forKey: contact.onionAddress)
        }

        database.deleteContact(contact)
        print("💬 Removed contact: \(contact.displayName)")
    }

    /// Toggle favorite status for a contact
    func toggleFavorite(_ contact: ChatContact) {
        if let index = contacts.firstIndex(where: { $0.onionAddress == contact.onionAddress }) {
            contacts[index].isFavorite.toggle()
            database.saveContact(contacts[index])
            print("💬 \(contacts[index].isFavorite ? "Starred" : "Unstarred") contact: \(contact.displayName)")
        }
    }

    /// FIX #1433: Block a contact — no incoming messages will be shown
    /// FIX #1529: Also disconnect immediately so they see us go offline
    func blockContact(_ contact: ChatContact) {
        guard let index = contacts.firstIndex(where: { $0.onionAddress == contact.onionAddress }) else { return }
        var updated = contacts[index]
        updated.isBlocked = true
        contacts[index] = updated
        database.saveContact(updated)

        // FIX #1529: Disconnect blocked contact immediately — they should see us as offline
        if let peer = peers[contact.onionAddress] {
            peer.connection.cancel()
            peers.removeValue(forKey: contact.onionAddress)
            print("💬 FIX #1529: Disconnected blocked contact: \(contact.displayName)")
        }
        updateContactOnlineStatus(contact.onionAddress, isOnline: false)
        print("💬 FIX #1433: Blocked contact: \(contact.displayName)")
    }

    /// FIX #1433: Unblock a contact — incoming messages will be shown again
    func unblockContact(_ contact: ChatContact) {
        guard let index = contacts.firstIndex(where: { $0.onionAddress == contact.onionAddress }) else { return }
        var updated = contacts[index]
        updated.isBlocked = false
        contacts[index] = updated
        database.saveContact(updated)
        print("💬 FIX #1433: Unblocked contact: \(contact.displayName)")
    }

    /// Connect to a contact via Tor SOCKS5 proxy
    /// .onion addresses require proper SOCKS5 tunneling through Tor
    func connect(to contact: ChatContact) async throws {
        guard isAvailable else {
            throw ChatError.hiddenServiceNotRunning
        }

        // Check if already connected
        if let peer = peers[contact.onionAddress], await peer.state.isConnected {
            return
        }

        // FIX #1476: Prevent concurrent connection attempts to same contact.
        // Without this: 6 callers race past "already connected" check → 6 parallel TCP handshakes → resource waste.
        guard !connectionsInFlight.contains(contact.onionAddress) else {
            print("💬 FIX #1476: Connection to \(contact.displayName) already in flight — skipping duplicate")
            return
        }
        connectionsInFlight.insert(contact.onionAddress)
        defer { connectionsInFlight.remove(contact.onionAddress) }

        // ==========================================================================
        // FIX #330 + FIX #1487: Circuit health check before operations
        // Verify Tor .onion circuits are established before attempting .onion connection
        // FIX #1487: Wait for FULL warmup (no 15s cutoff). Observed 46s warmup in production.
        // Premature connection → "Onion Service not found" → backoff → stuck offline.
        // ==========================================================================
        let torManager = await TorManager.shared
        let isCircuitReady = await torManager.isOnionCircuitsReady
        let warmupRemaining = await torManager.onionCircuitWarmupRemaining

        if !isCircuitReady {
            if warmupRemaining > 0 {
                // FIX #1487: Wait for full remaining warmup + 2s safety margin.
                // Old code refused to wait if > 15s → premature connection → instant failure.
                print("💬 FIX #1487: Waiting \(String(format: "%.0f", warmupRemaining + 2))s for .onion circuit warmup...")
                try await Task.sleep(nanoseconds: UInt64((warmupRemaining + 2) * 1_000_000_000))
            } else {
                // Tor not connected at all
                print("💬 FIX #330: Tor circuit not available")
                throw ChatError.hiddenServiceNotRunning
            }
        }
        print("💬 FIX #330: Tor circuit health check passed")

        // FIX #329 + FIX #1458: Apply exponential backoff before retry
        let backoff = calculateBackoff(for: contact.onionAddress)
        if backoff > baseBackoffSeconds {
            print("💬 FIX #329: Waiting \(String(format: "%.1f", backoff))s before retry (backoff)...")
            try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        }

        // FIX #1458: Mark attempt time to prevent overlapping connections
        lastConnectionAttempt[contact.onionAddress] = Date()

        print("💬 Connecting to \(contact.displayName) via Tor...")

        // Get Tor SOCKS port
        let socksPort = await TorManager.shared.socksPort
        let torConnected = await TorManager.shared.connectionState.isConnected

        guard torConnected && socksPort > 0 else {
            print("💬 Error: Tor not connected or SOCKS port unavailable")
            throw ChatError.hiddenServiceNotRunning
        }

        // Step 1: Connect to SOCKS5 proxy first (not directly to .onion)
        let proxyEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(TorManager.shared.proxyHost),
            port: NWEndpoint.Port(integerLiteral: socksPort)
        )

        let params = NWParameters.tcp
        let connection = NWConnection(to: proxyEndpoint, using: params)

        // Wait for connection to SOCKS proxy
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var hasResumed = false

            connection.stateUpdateHandler = { state in
                guard !hasResumed else { return }

                switch state {
                case .ready:
                    hasResumed = true
                    continuation.resume()
                case .failed(let error):
                    hasResumed = true
                    continuation.resume(throwing: ChatError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    hasResumed = true
                    continuation.resume(throwing: ChatError.connectionFailed("Connection cancelled"))
                default:
                    break
                }
            }

            connection.start(queue: networkQueue)

            // FIX #328: Increased timeout from 15s to 45s for .onion rendezvous circuits
            // Tor hidden services require rendezvous point establishment which takes 30-60 seconds
            Task {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                if !hasResumed {
                    hasResumed = true
                    connection.cancel()
                    continuation.resume(throwing: ChatError.connectionFailed("Connection timed out. Tor may still be establishing circuits."))
                }
            }
        }

        // Step 2: Perform SOCKS5 handshake to tunnel to .onion address
        try await performSocks5Handshake(connection: connection, targetHost: contact.onionAddress, targetPort: CYPHERPUNK_CHAT_PORT)

        print("💬 SOCKS5 tunnel established to \(contact.onionAddress.prefix(16))...")

        // Now the connection is tunneled to the .onion address
        let peer = ChatPeer(onionAddress: contact.onionAddress, connection: connection)
        await peer.setState(.handshaking)
        peers[contact.onionAddress] = peer

        // Perform key exchange
        do {
            try await performKeyExchange(with: peer)
        } catch {
            // Key exchange failed - clean up and mark as offline
            print("💬 Key exchange failed with \(contact.displayName): \(error)")
            await peer.setState(.failed(error.localizedDescription))
            connection.cancel()
            peers.removeValue(forKey: contact.onionAddress)
            updateContactOnlineStatus(contact.onionAddress, isOnline: false)
            // FIX #329: Record failure for exponential backoff
            recordConnectionFailure(for: contact.onionAddress)
            throw error
        }

        // Mark as fully connected after successful key exchange
        await peer.setState(.connected)

        // FIX #329: Reset backoff on successful connection
        resetConnectionFailure(for: contact.onionAddress)

        // FIX #1508: Send our nickname on every connection (not just initial)
        if !ourNickname.isEmpty {
            do {
                try await sendNickname(to: contact)
                print("💬 FIX #1508: Sent nickname '\(ourNickname)' to \(contact.displayName)")
            } catch {
                print("💬 FIX #1508: Failed to send nickname to \(contact.displayName): \(error)")
            }
        }

        // FIX #1441/#1508: Send our profile picture if sharing is enabled
        if isProfileImageShared, let imageData = profileImage {
            do {
                try await sendAvatar(imageData, to: contact)
            } catch {
                print("💬 FIX #1508: Failed to send avatar to \(contact.displayName): \(error)")
            }
        }

        updateContactOnlineStatus(contact.onionAddress, isOnline: true)

        // FIX #1541: Monitor NWConnection state for IMMEDIATE offline detection.
        // Without this, disconnect is only caught by: (1) receiveMessages failing 3x,
        // (2) 120s stale timeout, or (3) 30s ping failure — all too slow.
        let onion = contact.onionAddress
        peer.connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.peers.removeValue(forKey: onion)
                    self.updateContactOnlineStatus(onion, isOnline: false)
                    print("💬 FIX #1541: NWConnection state → \(state) — marked \(onion.prefix(16))... offline immediately")
                }
            default:
                break
            }
        }

        print("💬 Connected to \(contact.displayName)")
    }

    /// Perform SOCKS5 handshake to connect through proxy to target host
    /// RFC 1928: https://datatracker.ietf.org/doc/html/rfc1928
    private func performSocks5Handshake(connection: NWConnection, targetHost: String, targetPort: UInt16) async throws {
        // Step 1: Send greeting - offer no-auth (0x00) and username/password (0x02)
        let greeting = Data([0x05, 0x02, 0x00, 0x02])
        try await sendRawData(connection: connection, data: greeting)

        // Step 2: Receive auth method selection
        let authResponse = try await receiveRawData(connection: connection, length: 2)

        guard authResponse.count == 2, authResponse[0] == 0x05 else {
            throw ChatError.connectionFailed("Invalid SOCKS5 response")
        }

        // Handle authentication
        switch authResponse[1] {
        case 0x00:
            print("💬 SOCKS5: No authentication required")
        case 0x02:
            // Username/password auth (for Arti circuit isolation)
            print("💬 SOCKS5: Using username/password auth")
            let authRequest = Data([0x01, 0x00, 0x00]) // Version 1, empty username, empty password
            try await sendRawData(connection: connection, data: authRequest)
            let authResult = try await receiveRawData(connection: connection, length: 2)
            guard authResult.count == 2, authResult[1] == 0x00 else {
                throw ChatError.connectionFailed("SOCKS5 authentication failed")
            }
        case 0xFF:
            throw ChatError.connectionFailed("SOCKS5 proxy: no acceptable auth methods")
        default:
            throw ChatError.connectionFailed("SOCKS5 unsupported auth method: \(authResponse[1])")
        }

        // Step 3: Send connection request
        // VER(1) + CMD(1) + RSV(1) + ATYP(1) + DST.ADDR(var) + DST.PORT(2)
        var request = Data()
        request.append(0x05) // SOCKS5
        request.append(0x01) // CONNECT
        request.append(0x00) // Reserved
        request.append(0x03) // Domain name (ATYP = 0x03)

        // Domain name with length prefix
        let hostData = targetHost.data(using: .utf8)!
        request.append(UInt8(hostData.count))
        request.append(hostData)

        // Port (big-endian)
        request.append(UInt8((targetPort >> 8) & 0xFF))
        request.append(UInt8(targetPort & 0xFF))

        try await sendRawData(connection: connection, data: request)

        // FIX #1368: Step 4: Receive connection response — ATYP-aware variable-length parsing
        // VER(1) + REP(1) + RSV(1) + ATYP(1) + BND.ADDR(var) + BND.PORT(2)
        // BUG: Was hardcoded to 10 bytes (IPv4 only). Tor returns ATYP=0x03 (domain) or 0x04 (IPv6)
        // for .onion addresses — leftover bytes in TCP buffer caused stream desync → "Invalid magic bytes"
        let header = try await receiveRawData(connection: connection, length: 4)

        guard header.count == 4, header[0] == 0x05 else {
            throw ChatError.connectionFailed("Invalid SOCKS5 connect response")
        }

        // Check reply code — user-friendly messages
        let replyCode = header[1]
        switch replyCode {
        case 0x00:
            break // Success — continue parsing
        case 0x01:
            throw ChatError.connectionFailed("Unable to reach contact. Please try again later.")
        case 0x02:
            throw ChatError.connectionFailed("Connection blocked by network. Please try again later.")
        case 0x03:
            throw ChatError.connectionFailed("Contact unreachable. They may be offline.")
        case 0x04:
            throw ChatError.connectionFailed("Contact unreachable. They may be offline.")
        case 0x05:
            throw ChatError.connectionFailed("Contact is offline or not accepting connections.")
        case 0x06:
            throw ChatError.connectionFailed("Connection timed out. Contact may be offline.")
        case 0x07:
            throw ChatError.connectionFailed("Connection method not supported.")
        case 0x08:
            throw ChatError.connectionFailed("Unable to resolve contact address.")
        default:
            throw ChatError.connectionFailed("Connection failed (code \(replyCode)). Please try again.")
        }

        // FIX #1368: Parse ATYP to determine remaining bytes — drain them all from TCP buffer
        let atyp = header[3]
        var remainingBytes = 0

        switch atyp {
        case 0x01:  // IPv4: 4 addr + 2 port
            remainingBytes = 6
        case 0x03:  // Domain: 1 length + N domain + 2 port
            let lenData = try await receiveRawData(connection: connection, length: 1)
            remainingBytes = Int(lenData[0]) + 2
        case 0x04:  // IPv6: 16 addr + 2 port
            remainingBytes = 18
        default:
            throw ChatError.connectionFailed("SOCKS5: Unknown address type \(atyp)")
        }

        // Drain remaining bind address + port bytes
        _ = try await receiveRawData(connection: connection, length: remainingBytes)
        print("💬 SOCKS5: Connection succeeded to \(targetHost.prefix(16))... (ATYP=\(atyp))")
    }

    /// Send raw data to connection
    private func sendRawData(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: ChatError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Receive raw data from connection
    private func receiveRawData(connection: NWConnection, length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: ChatError.connectionFailed(error.localizedDescription))
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ChatError.connectionFailed("No data received"))
                }
            }
        }
    }

    /// Disconnect from a contact
    func disconnect(from contact: ChatContact) async {
        guard let peer = peers[contact.onionAddress] else { return }

        // Send goodbye message
        do {
            let goodbye = ChatMessage(
                type: .goodbye,
                fromOnion: ourOnionAddress ?? "",
                toOnion: contact.onionAddress,
                content: ""
            )
            try await sendMessage(goodbye, to: contact)
        } catch {
            // Ignore send errors on disconnect
        }

        await peer.connection.cancel()
        peers.removeValue(forKey: contact.onionAddress)
        updateContactOnlineStatus(contact.onionAddress, isOnline: false)
    }

    /// Send a text message to a contact
    func sendTextMessage(_ text: String, to contact: ChatContact, replyTo: String? = nil) async throws {
        guard !text.isEmpty else { return }

        var message = ChatMessage(
            type: .text,
            fromOnion: ourOnionAddress ?? "",
            toOnion: contact.onionAddress,
            content: text,
            nickname: ourNickname.isEmpty ? nil : ourNickname,
            replyTo: replyTo,
            status: .sending  // Start as sending
        )

        // FIX #1432: If queue has pending messages for this contact, add to queue
        // This preserves chronological order: queued M1, M2 must send before new M3
        if let queued = messageQueue[contact.onionAddress], !queued.isEmpty {
            print("💬 FIX #1432: Queue has \(queued.count) pending — adding new message to queue for ordering")
            message.markQueued()
            addMessageToConversation(message)
            database.saveMessage(message, ourOnionAddress: ourOnionAddress)
            queueMessage(message, for: contact.onionAddress)
            return
        }

        // Add to conversation immediately (shows as "sending")
        addMessageToConversation(message)

        do {
            try await sendMessage(message, to: contact)

            // Update status to sent
            message.markSent()
            updateMessageInConversation(message)

            // Persist with sent status
            database.saveMessage(message, ourOnionAddress: ourOnionAddress)
        } catch {
            // FIX #249: Queue message if recipient is offline instead of marking failed
            if isOfflineError(error) {
                print("💬 FIX #249: Recipient offline, queueing message for \(contact.displayName)")
                message.markQueued()
                updateMessageInConversation(message)
                database.saveMessage(message, ourOnionAddress: ourOnionAddress)
                queueMessage(message, for: contact.onionAddress)
                // Don't throw - message is queued, will be sent when online
            } else {
                // Other errors (encryption, protocol) - mark as failed
                message.markFailed()
                updateMessageInConversation(message)
                database.saveMessage(message, ourOnionAddress: ourOnionAddress)
                throw error
            }
        }
    }

    /// FIX #249: Check if error indicates recipient is offline
    private func isOfflineError(_ error: Error) -> Bool {
        if case ChatError.notConnected = error { return true }
        if case ChatError.connectionFailed(_) = error { return true }
        if case ChatError.hiddenServiceNotRunning = error { return false }  // Our issue, not theirs
        if case ChatError.torNotConnected = error { return false }  // Our issue, not theirs
        // Check for NWError connection failures
        let errorDescription = error.localizedDescription.lowercased()
        return errorDescription.contains("connection") ||
               errorDescription.contains("timeout") ||
               errorDescription.contains("unreachable") ||
               errorDescription.contains("refused")
    }

    /// Send a payment request
    func sendPaymentRequest(
        to contact: ChatContact,
        amount: UInt64,
        address: String,
        memo: String?
    ) async throws {
        var message = ChatMessage(
            type: .paymentRequest,
            fromOnion: ourOnionAddress ?? "",
            toOnion: contact.onionAddress,
            content: memo ?? "Payment request",
            nickname: ourNickname.isEmpty ? nil : ourNickname,
            paymentAddress: address,
            paymentAmount: amount,
            status: .sending
        )

        // FIX #1432: Gate behind queue for ordering
        if let queued = messageQueue[contact.onionAddress], !queued.isEmpty {
            print("💬 FIX #1432: Queue has \(queued.count) pending — adding payment request to queue for ordering")
            message.markQueued()
            addMessageToConversation(message)
            database.saveMessage(message, ourOnionAddress: ourOnionAddress)
            queueMessage(message, for: contact.onionAddress)
            return
        }

        // FIX #1427: Add to conversation immediately (shows as "sending")
        // Same pattern as sendTextMessage (FIX #249)
        addMessageToConversation(message)

        do {
            try await sendMessage(message, to: contact)

            // Update status to sent
            message.markSent()
            updateMessageInConversation(message)
            database.saveMessage(message, ourOnionAddress: ourOnionAddress)
        } catch {
            // FIX #1427: Queue if recipient offline (same as FIX #249 for text messages)
            if isOfflineError(error) {
                print("💬 FIX #1427: Recipient offline, queueing payment request for \(contact.displayName)")
                message.markQueued()
                updateMessageInConversation(message)
                database.saveMessage(message, ourOnionAddress: ourOnionAddress)
                queueMessage(message, for: contact.onionAddress)
                // Don't throw - message is queued, will be sent when online
            } else {
                message.markFailed()
                updateMessageInConversation(message)
                database.saveMessage(message, ourOnionAddress: ourOnionAddress)
                throw error
            }
        }
    }

    /// Send payment confirmation back to the requester after completing a payment
    /// - Parameters:
    ///   - contact: The contact who requested payment
    ///   - amount: Amount paid in zatoshis
    ///   - txId: Transaction ID of the payment
    ///   - requestId: ID of the original payment request message (for reference)
    func sendPaymentConfirmation(
        to contact: ChatContact,
        amount: UInt64,
        txId: String,
        requestId: String
    ) async throws {
        var message = ChatMessage(
            type: .paymentSent,
            fromOnion: ourOnionAddress ?? "",
            toOnion: contact.onionAddress,
            content: "Payment sent: \(txId)",
            nickname: ourNickname.isEmpty ? nil : ourNickname,
            paymentAmount: amount,
            replyTo: requestId,  // Link to the original payment request
            status: .sending
        )

        // FIX #1432: Gate behind queue for ordering
        if let queued = messageQueue[contact.onionAddress], !queued.isEmpty {
            print("💬 FIX #1432: Queue has \(queued.count) pending — adding payment confirmation to queue for ordering")
            message.markQueued()
            addMessageToConversation(message)
            database.saveMessage(message, ourOnionAddress: ourOnionAddress)
            queueMessage(message, for: contact.onionAddress)
            return
        }

        // FIX #1427: Add to conversation immediately, queue if offline
        addMessageToConversation(message)

        do {
            try await sendMessage(message, to: contact)
            message.markSent()
            updateMessageInConversation(message)
            database.saveMessage(message, ourOnionAddress: ourOnionAddress)
            print("💸 Payment confirmation sent to \(contact.displayName) - txId: \(txId.prefix(16))...")
        } catch {
            if isOfflineError(error) {
                print("💬 FIX #1427: Recipient offline, queueing payment confirmation for \(contact.displayName)")
                message.markQueued()
                updateMessageInConversation(message)
                database.saveMessage(message, ourOnionAddress: ourOnionAddress)
                queueMessage(message, for: contact.onionAddress)
            } else {
                message.markFailed()
                updateMessageInConversation(message)
                database.saveMessage(message, ourOnionAddress: ourOnionAddress)
                throw error
            }
        }
    }

    /// Send a payment rejection back to the requester
    func sendPaymentRejection(
        to contact: ChatContact,
        requestId: String,
        reason: String?
    ) async throws {
        var message = ChatMessage(
            type: .paymentRejected,
            fromOnion: ourOnionAddress ?? "",
            toOnion: contact.onionAddress,
            content: reason ?? "Payment request declined",
            nickname: ourNickname.isEmpty ? nil : ourNickname,
            replyTo: requestId,
            status: .sending
        )

        // FIX #1432: Gate behind queue for ordering
        if let queued = messageQueue[contact.onionAddress], !queued.isEmpty {
            message.markQueued()
            addMessageToConversation(message)
            database.saveMessage(message, ourOnionAddress: ourOnionAddress)
            queueMessage(message, for: contact.onionAddress)
            return
        }

        addMessageToConversation(message)

        do {
            try await sendMessage(message, to: contact)
            message.markSent()
            updateMessageInConversation(message)
            database.saveMessage(message, ourOnionAddress: ourOnionAddress)
        } catch {
            if isOfflineError(error) {
                message.markQueued()
                updateMessageInConversation(message)
                database.saveMessage(message, ourOnionAddress: ourOnionAddress)
                queueMessage(message, for: contact.onionAddress)
            } else {
                message.markFailed()
                updateMessageInConversation(message)
                database.saveMessage(message, ourOnionAddress: ourOnionAddress)
                throw error
            }
        }
    }

    /// Send typing indicator
    func sendTypingIndicator(to contact: ChatContact) async throws {
        let message = ChatMessage(
            type: .typing,
            fromOnion: ourOnionAddress ?? "",
            toOnion: contact.onionAddress,
            content: ""
        )

        try await sendMessage(message, to: contact)
    }

    /// Mark messages as read
    func markAsRead(contact: ChatContact) {
        guard var conversation = conversations[contact.onionAddress] else { return }

        // Update unread count
        if let index = contacts.firstIndex(where: { $0.onionAddress == contact.onionAddress }) {
            var updatedContact = contacts[index]
            updatedContact.unreadCount = 0
            contacts[index] = updatedContact
            // FIX #1431: Authoritative recompute instead of fragile subtract (prevents drift)
            totalUnreadCount = contacts.reduce(0) { $0 + $1.unreadCount }
            conversation = ChatConversation(contact: updatedContact)
            conversation.messages = conversations[contact.onionAddress]?.messages ?? []
            conversations[contact.onionAddress] = conversation

            // FIX #265: Persist unread count reset to disk
            // Previous bug: unreadCount was reset in memory but not saved
            // After app restart, old unread count was loaded from disk
            database.saveContact(updatedContact)
        }

        // Send read receipts for unread messages
        Task {
            for message in conversation.messages where message.fromOnion == contact.onionAddress {
                let receipt = ChatMessage(
                    type: .read,
                    fromOnion: ourOnionAddress ?? "",
                    toOnion: contact.onionAddress,
                    content: message.id
                )
                try? await sendMessage(receipt, to: contact)
            }
        }
    }

    // MARK: - Private Methods

    private func startListener() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: CYPHERPUNK_CHAT_PORT))

        // FIX M-002: Limit concurrent connections to prevent DoS via Tor
        listener?.newConnectionLimit = 50

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                await self?.handleIncomingConnection(connection)
            }
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("💬 Chat listener ready on port \(CYPHERPUNK_CHAT_PORT)")
            case .failed(let error):
                print("💬 Chat listener failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: networkQueue)
    }

    private func handleIncomingConnection(_ connection: NWConnection) async {
        print("💬 Incoming chat connection...")

        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                Task { @MainActor in
                    await self?.receiveInitialHandshake(from: connection)
                }
            }
        }

        connection.start(queue: networkQueue)
    }

    private func receiveInitialHandshake(from connection: NWConnection) async {
        // Receive their public key and onion address
        // FIX #1577: Cap at 94 bytes (32 pubkey + 62 max v3 onion) — old 1024 limit caused
        // TCP stream desync: NWConnection delivered handshake + message bytes in one read,
        // consuming the next message's header → permanent stream misalignment → lost messages
        connection.receive(minimumIncompleteLength: 32, maximumLength: 94) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                connection.cancel()
                return
            }

            Task { @MainActor in
                await self.processIncomingHandshake(data: data, connection: connection)
            }
        }
    }

    private func processIncomingHandshake(data: Data, connection: NWConnection) async {
        // Parse handshake: [32 bytes pubkey][onion address string]
        guard data.count > 32 else {
            connection.cancel()
            return
        }

        let pubKeyData = data.prefix(32)
        guard let theirPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubKeyData) else {
            connection.cancel()
            return
        }

        let onionData = data.dropFirst(32)
        guard let onionAddress = String(data: onionData, encoding: .utf8) else {
            connection.cancel()
            return
        }

        print("💬 Handshake from: \(onionAddress.prefix(16))...")

        // FIX #1529: Reject connection from blocked contacts — don't reveal online status
        // Without this: blocked contact connects → handshake succeeds → they know we're online.
        // With this: connection cancelled immediately → they see "offline" (same as not running).
        if let existingContact = contacts.first(where: { $0.onionAddress == onionAddress }), existingContact.isBlocked {
            print("💬 FIX #1529: Rejected incoming connection from blocked contact: \(onionAddress.prefix(16))...")
            connection.cancel()
            return
        }

        // FIX M-003: Reject duplicate onion address if existing session is active
        // Prevents session hijacking where attacker claims same onion as existing peer
        if let existingPeer = peers[onionAddress], await existingPeer.state == .connected {
            print("💬 FIX M-003: Rejected duplicate connection from \(onionAddress.prefix(16))... — active session exists")
            connection.cancel()
            return
        }

        // FIX M-001: Verify public key matches stored contact identity (Trust On First Use)
        // FIX #1580: The .onion address IS the identity proof (requires ed25519 private key to host).
        // The X25519 session key can legitimately change (app reinstall, update, device migration).
        // On mismatch: warn + accept the new key instead of permanently rejecting.
        if let existingContact = contacts.first(where: { $0.onionAddress == onionAddress }) {
            if let storedKey = existingContact.publicKeyData {
                if Data(pubKeyData) != storedKey {
                    // FIX #1580: Accept new key — .onion address proves identity, session key can rotate
                    print("⚠️ FIX #1580: Key rotation detected for \(onionAddress.prefix(16))... — accepting new key (onion identity verified)")
                    var updatedContact = existingContact
                    updatedContact.publicKeyData = Data(pubKeyData)
                    if let idx = contacts.firstIndex(where: { $0.onionAddress == onionAddress }) {
                        contacts[idx] = updatedContact
                    }
                    database.saveContact(updatedContact)
                }
                // Key matches — identity confirmed, no action needed.
            } else {
                // First handshake for this contact — capture and store the key (TOFU).
                var updatedContact = existingContact
                updatedContact.publicKeyData = Data(pubKeyData)
                if let idx = contacts.firstIndex(where: { $0.onionAddress == onionAddress }) {
                    contacts[idx] = updatedContact
                }
                database.saveContact(updatedContact)
                print("💬 FIX M-001: Captured public key for \(onionAddress.prefix(16))... (Trust On First Use, incoming)")
            }
        }
        // Note: if the contact does not exist yet (brand-new peer), the auto-add block below
        // creates the contact with publicKeyData set, establishing the binding on first contact.

        // Create or update peer
        let peer = ChatPeer(onionAddress: onionAddress, connection: connection)
        try? await peer.setTheirPublicKey(theirPublicKey)
        await peer.setState(.connected)
        peers[onionAddress] = peer

        // FIX #1541: Monitor incoming connection for IMMEDIATE offline detection
        let incomingOnion = onionAddress
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.peers.removeValue(forKey: incomingOnion)
                    self.updateContactOnlineStatus(incomingOnion, isOnline: false)
                    print("💬 FIX #1541: Incoming connection state → \(state) — marked \(incomingOnion.prefix(16))... offline immediately")
                }
            default:
                break
            }
        }

        // Send our public key back
        var response = Data()
        response.append(await peer.getOurPublicKeyData())
        if let ourOnion = ourOnionAddress {
            response.append(Data(ourOnion.utf8))
        }

        connection.send(content: response, completion: .contentProcessed { _ in })

        // FIX #192: Auto-add as contact if not exists AND not our own address
        // Without this check, our own .onion address would appear in contacts list!
        if !contacts.contains(where: { $0.onionAddress == onionAddress }) &&
           onionAddress != ourOnionAddress {
            // FIX M-001: Capture public key immediately on auto-add (TOFU on first ever connection)
            var contact = ChatContact(onionAddress: onionAddress, nickname: "")
            contact.publicKeyData = Data(pubKeyData)
            contacts.append(contact)
            conversations[onionAddress] = ChatConversation(contact: contact)
            database.saveContact(contact)
            print("💬 Auto-added contact: \(onionAddress.prefix(16))... (FIX M-001: key captured at creation)")
        }

        updateContactOnlineStatus(onionAddress, isOnline: true)

        // Start receiving messages
        receiveMessages(from: peer)

        // FIX #1530: Send our profile (nickname + avatar) on INCOMING connections too
        // Without this: only outgoing connect() sends profile → other side never gets our picture.
        // The outgoing side sends in connect() (line ~705), but incoming side never did.
        if let contact = contacts.first(where: { $0.onionAddress == onionAddress }) {
            if !ourNickname.isEmpty {
                do {
                    try await sendNickname(to: contact)
                    print("💬 FIX #1530: Sent nickname '\(ourNickname)' on incoming connection to \(contact.displayName)")
                } catch {
                    print("💬 FIX #1530: Failed to send nickname on incoming connection: \(error)")
                }
            }

            if isProfileImageShared, let imageData = profileImage {
                do {
                    try await sendAvatar(imageData, to: contact)
                    print("💬 FIX #1530: Sent avatar on incoming connection to \(contact.displayName)")
                } catch {
                    print("💬 FIX #1530: Failed to send avatar on incoming connection: \(error)")
                }
            }
        }
    }

    private func handleConnectionState(_ state: NWConnection.State, for onionAddress: String) async {
        guard let peer = peers[onionAddress] else { return }

        switch state {
        case .ready:
            await peer.setState(.handshaking)
        case .failed(let error):
            await peer.setState(.failed(error.localizedDescription))
            updateContactOnlineStatus(onionAddress, isOnline: false)
        case .cancelled:
            await peer.setState(.disconnected)
            updateContactOnlineStatus(onionAddress, isOnline: false)
        default:
            break
        }
    }

    private func performKeyExchange(with peer: ChatPeer) async throws {
        // Send our public key and onion address
        var handshake = Data()
        handshake.append(await peer.getOurPublicKeyData())
        if let ourOnion = ourOnionAddress {
            handshake.append(Data(ourOnion.utf8))
        }

        await peer.connection.send(content: handshake, completion: .contentProcessed { _ in })

        // Receive their public key AND onion address
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            peer.connection.receive(minimumIncompleteLength: 32, maximumLength: 1024) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ChatError.notConnected)
                }
            }
        }

        guard response.count >= 32 else {
            throw ChatError.encryptionFailed("Invalid handshake response")
        }

        let pubKeyData = response.prefix(32)
        let theirPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubKeyData)
        try await peer.setTheirPublicKey(theirPublicKey)

        // FIX M-001: Verify public key matches stored contact identity (Trust On First Use, outgoing)
        // FIX #1580: The .onion address IS the identity proof (requires ed25519 private key to host).
        // The X25519 session key can legitimately change (app reinstall, update, device migration).
        // On mismatch: warn + accept the new key instead of permanently rejecting.
        let peerOnion = await peer.onionAddress
        if let existingContact = contacts.first(where: { $0.onionAddress == peerOnion }) {
            if let storedKey = existingContact.publicKeyData {
                if Data(pubKeyData) != storedKey {
                    // FIX #1580: Accept new key — .onion address proves identity, session key can rotate
                    print("⚠️ FIX #1580: Key rotation detected for \(peerOnion.prefix(16))... — accepting new key (onion identity verified, outgoing)")
                    var updatedContact = existingContact
                    updatedContact.publicKeyData = Data(pubKeyData)
                    if let idx = contacts.firstIndex(where: { $0.onionAddress == peerOnion }) {
                        contacts[idx] = updatedContact
                    }
                    database.saveContact(updatedContact)
                }
                // Key matches — identity confirmed.
            } else {
                // First outgoing handshake — capture and store the key (TOFU).
                var updatedContact = existingContact
                updatedContact.publicKeyData = Data(pubKeyData)
                if let idx = contacts.firstIndex(where: { $0.onionAddress == peerOnion }) {
                    contacts[idx] = updatedContact
                }
                database.saveContact(updatedContact)
                print("💬 FIX M-001: Captured public key for \(peerOnion.prefix(16))... (Trust On First Use, outgoing)")
            }
        }

        // FIX #238: Verify the returned onion address matches what we expected
        // This prevents connecting to wrong hidden service (e.g., iOS→Sim going to macOS)
        // FIX #332: Improved error handling with specific error type
        let expectedOnion = await peer.onionAddress
        if response.count > 32 {
            let onionData = response.dropFirst(32)
            if let returnedOnion = String(data: onionData, encoding: .utf8) {
                if returnedOnion != expectedOnion {
                    print("🚨 FIX #238: ONION MISMATCH! Expected: \(expectedOnion.prefix(16))... Got: \(returnedOnion.prefix(16))...")
                    print("🚨 FIX #332: Wrong hidden service detected - providing detailed error")
                    // Cancel connection - we're connected to the wrong peer!
                    await peer.connection.cancel()
                    // FIX #332: Use specific error type with full addresses for debugging
                    throw ChatError.wrongHiddenService(expected: expectedOnion, got: returnedOnion)
                } else {
                    print("✅ FIX #238: Onion address verified: \(returnedOnion.prefix(16))...")
                }
            }
        }

        await peer.setState(.connected)

        // Start receiving messages
        receiveMessages(from: peer)
    }

    private func receiveMessages(from peer: ChatPeer) {
        Task {
            let onionAddress = await peer.onionAddress
            var consecutiveErrors = 0
            let maxRetries = 3

            while await peer.state.isConnected {
                do {
                    let data = try await receiveData(from: peer)
                    try await processReceivedData(data, from: peer)
                    consecutiveErrors = 0  // Reset on success
                } catch {
                    consecutiveErrors += 1
                    print("💬 FIX #397: Receive error \(consecutiveErrors)/\(maxRetries) from \(onionAddress.prefix(16))...: \(error)")

                    // FIX #397: Auto-reconnect on transient errors instead of immediately marking offline
                    // Only mark offline after multiple consecutive failures
                    if consecutiveErrors >= maxRetries {
                        print("💬 FIX #397: Max retries reached, attempting reconnection...")
                        await peer.setState(.disconnected)

                        // Try to reconnect instead of just marking offline
                        if let contact = await MainActor.run(body: { self.contacts.first { $0.onionAddress == onionAddress } }) {
                            print("💬 FIX #397: Auto-reconnecting to \(onionAddress.prefix(16))...")
                            do {
                                try await self.connect(to: contact)
                                print("💬 FIX #397: Auto-reconnect successful!")
                                return  // Exit this loop, new receiveMessages started by connectToContact
                            } catch {
                                print("💬 FIX #397: Auto-reconnect failed: \(error)")
                                // Only now mark as offline after reconnect fails
                                await MainActor.run {
                                    self.updateContactOnlineStatus(onionAddress, isOnline: false)
                                    print("💬 Marked \(onionAddress.prefix(16))... as offline after reconnect failure")
                                }
                            }
                        }
                        break
                    }

                    // Brief delay before retry to avoid tight loop
                    try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
                }
            }
        }
    }

    private func receiveData(from peer: ChatPeer) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            // First read the header (5 bytes: 4 length + 1 version)
            peer.connection.receive(minimumIncompleteLength: ChatProtocol.HEADER_SIZE, maximumLength: ChatProtocol.HEADER_SIZE) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let headerData = data, headerData.count == ChatProtocol.HEADER_SIZE else {
                    continuation.resume(throwing: ChatError.invalidMessage("Incomplete header"))
                    return
                }

                // Parse length
                let length = headerData.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }

                guard length <= ChatProtocol.MAX_MESSAGE_SIZE else {
                    continuation.resume(throwing: ChatError.invalidMessage("Message too large"))
                    return
                }

                // Read payload
                peer.connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { payloadData, _, _, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let payload = payloadData {
                        var fullData = headerData
                        fullData.append(payload)
                        continuation.resume(returning: fullData)
                    } else {
                        continuation.resume(throwing: ChatError.invalidMessage("No payload"))
                    }
                }
            }
        }
    }

    private func processReceivedData(_ data: Data, from peer: ChatPeer) async throws {
        // Decode wire protocol
        let encryptedPayload = try ChatProtocol.decode(data)

        // Decrypt
        guard let sharedKey = await peer.sharedKey else {
            throw ChatError.encryptionFailed("No shared key")
        }

        let message = try ChatEncryption.decryptMessage(encryptedPayload, using: sharedKey)

        await peer.updateActivity()

        // Process by type
        await MainActor.run {
            handleReceivedMessage(message, from: peer)
        }
    }

    private func handleReceivedMessage(_ message: ChatMessage, from peer: ChatPeer) {
        // FIX #1433: Silently drop messages from blocked contacts
        if let sender = contacts.first(where: { $0.onionAddress == message.fromOnion }), sender.isBlocked {
            print("💬 FIX #1433: Dropped message from blocked contact: \(message.fromOnion.prefix(16))...")
            return
        }

        switch message.type {
        case .text, .paymentRequest, .paymentSent, .paymentReceived, .paymentRejected:
            addMessageToConversation(message)
            database.saveMessage(message, ourOnionAddress: ourOnionAddress)

            // FIX #1568: Play in-app sound for ALL incoming messages
            NotificationManager.shared.playChatMessageSound()

            // FIX #1386: Bridge chat payment confirmations to balance view + system notifications
            // When we receive paymentSent (someone paid our request) or paymentReceived,
            // trigger a balance view refresh and send a payment notification
            if message.type == .paymentSent || message.type == .paymentReceived {
                let amount = message.paymentAmount ?? 0
                let senderName = message.nickname ?? contacts.first(where: { $0.onionAddress == message.fromOnion })?.displayName ?? String(message.fromOnion.prefix(8)) + "..."

                // Post notification to refresh balance view and transaction history
                NotificationCenter.default.post(name: Notification.Name("transactionHistoryUpdated"), object: nil)
                print("📜 FIX #1386: Posted transactionHistoryUpdated after chat payment confirmation from \(senderName)")

                // Send system notification for incoming payment
                if amount > 0 {
                    let txid = message.content.replacingOccurrences(of: "Payment sent: ", with: "")
                    NotificationManager.shared.notifyReceived(amount: amount, txid: txid)
                    print("🔔 FIX #1386: System notification sent for chat payment of \(LogRedaction.redactAmount(UInt64(amount))) from \(senderName)")
                }
            }

            // Update unread count
            if selectedConversation != message.fromOnion {
                incrementUnreadCount(for: message.fromOnion)

                // FIX #223: Send push notification when not viewing this conversation
                let senderName = message.nickname ?? contacts.first(where: { $0.onionAddress == message.fromOnion })?.displayName ?? String(message.fromOnion.prefix(8)) + "..."
                // AUDIT FIX: Never pass plaintext content to notifications — E2E encryption
                // is undermined if decrypted text appears on lock screen or Notification Center.
                NotificationManager.shared.notifyChatMessage(
                    from: senderName,
                    type: message.type.rawValue,
                    preview: nil
                )
            }

            // FIX #1562: Send delivery confirmation directly via the existing peer connection.
            // Previous code looked up message.fromOnion in contacts before sending the ACK.
            // If the sender is not yet in the contacts list (or the lookup races with auto-add),
            // the ACK was silently dropped → no delivered checkmarks on sender's device.
            // Fix: send the ACK directly on peer.connection using the shared key already
            // established during handshake. No contact lookup required — the peer IS connected.
            let ackPeer = peer
            Task {
                let delivery = ChatMessage(
                    type: .delivered,
                    fromOnion: ourOnionAddress ?? "",
                    toOnion: message.fromOnion,
                    content: message.id
                )
                guard let sharedKey = await ackPeer.sharedKey else { return }
                do {
                    let encryptedPayload = try ChatEncryption.encryptMessage(delivery, using: sharedKey)
                    let wireData = ChatProtocol.encode(encryptedPayload: encryptedPayload)
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        ackPeer.connection.send(content: wireData, completion: .contentProcessed { error in
                            if let error = error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume()
                            }
                        })
                    }
                    print("💬 FIX #1562: Delivery ACK sent for message \(message.id.prefix(8))...")
                } catch {
                    print("💬 FIX #1562: Failed to send delivery ACK: \(error)")
                }
            }

        case .typing:
            // Notify UI of typing indicator
            NotificationCenter.default.post(
                name: .chatTypingIndicator,
                object: nil,
                userInfo: ["onion": message.fromOnion]
            )

        case .delivered:
            // Mark our message as delivered
            markMessageDelivered(id: message.content)

        case .read:
            // Mark our message as read
            markMessageRead(id: message.content)

        case .ping:
            // FIX #1586: Receiving a ping is proof the sender is alive — mark online
            updateContactOnlineStatus(message.fromOnion, isOnline: true)
            // Respond with pong
            Task {
                if let contact = contacts.first(where: { $0.onionAddress == message.fromOnion }) {
                    let pong = ChatMessage(
                        type: .pong,
                        fromOnion: ourOnionAddress ?? "",
                        toOnion: message.fromOnion,
                        content: ""
                    )
                    try? await sendMessage(pong, to: contact)
                }
            }

        case .pong:
            // FIX #1586: Receiving a pong is proof of life — mark online + update last seen
            updateContactOnlineStatus(message.fromOnion, isOnline: true)
            updateContactLastSeen(message.fromOnion)

        case .nickname:
            // Update contact nickname if they shared it
            Task {
                await peer.setNickname(message.content)
            }
            updateContactNickname(message.fromOnion, nickname: message.content)

        case .avatar:
            // FIX #1441: Received contact's profile picture (base64 JPEG in content)
            if let avatarData = Data(base64Encoded: message.content), !avatarData.isEmpty {
                saveContactAvatar(avatarData, for: message.fromOnion)
                print("💬 FIX #1441: Received avatar from \(message.fromOnion.prefix(8))... (\(avatarData.count) bytes)")
            }

        case .goodbye:
            // Peer is disconnecting
            updateContactOnlineStatus(message.fromOnion, isOnline: false)

        case .file:
            // FIX #1535: Incoming file transfer metadata
            handleFileMessage(message)

            // FIX #1568: Play in-app sound for incoming file
            NotificationManager.shared.playChatMessageSound()

            // Update unread count
            if selectedConversation != message.fromOnion {
                incrementUnreadCount(for: message.fromOnion)
                let senderName = message.nickname ?? contacts.first(where: { $0.onionAddress == message.fromOnion })?.displayName ?? String(message.fromOnion.prefix(8)) + "..."
                NotificationManager.shared.notifyChatMessage(from: senderName, type: "file", preview: "Sent a file")
            }

        case .fileChunk:
            // FIX #1535: Incoming file chunk — buffer, do NOT save to DB
            handleFileChunk(message)

        // FIX #1540: Voice call signaling — NOT saved to DB, routed to VoiceCallManager
        #if ENABLE_VOICE_CALLS
        case .callOffer:
            if let data = message.content.data(using: .utf8),
               let offer = try? JSONDecoder().decode(CallOffer.self, from: data) {
                Task { @MainActor in
                    VoiceCallManager.shared.handleCallOffer(offer, from: message.fromOnion)
                }
            }

        case .callAnswer:
            if let data = message.content.data(using: .utf8),
               let answer = try? JSONDecoder().decode(CallAnswer.self, from: data) {
                Task { @MainActor in
                    await VoiceCallManager.shared.handleCallAnswer(answer)
                }
            }

        case .callReject:
            if let data = message.content.data(using: .utf8),
               let control = try? JSONDecoder().decode(CallControl.self, from: data) {
                Task { @MainActor in
                    await VoiceCallManager.shared.handleCallReject(control)
                }
            }

        case .callEnd:
            if let data = message.content.data(using: .utf8),
               let control = try? JSONDecoder().decode(CallControl.self, from: data) {
                Task { @MainActor in
                    await VoiceCallManager.shared.handleCallEnd(control)
                }
            }

        case .callAudio:
            // Audio frames — highest priority, don't block
            if let data = message.content.data(using: .utf8),
               let frame = try? JSONDecoder().decode(CallAudioFrame.self, from: data) {
                Task { @MainActor in
                    VoiceCallManager.shared.handleAudioFrame(frame)
                }
            }
        #else
        case .callOffer, .callAnswer, .callReject, .callEnd, .callAudio:
            break  // Voice calls disabled
        #endif
        }
    }

    private func sendMessage(_ message: ChatMessage, to contact: ChatContact) async throws {
        // Check if connected, if not, try to connect
        var needsReconnect = true
        if let peer = peers[contact.onionAddress] {
            let peerState = await peer.state
            needsReconnect = !peerState.isConnected

            // Also check if connection is stale (no activity for 2+ minutes)
            let lastActivity = await peer.lastActivity
            if Date().timeIntervalSince(lastActivity) > 120 {
                print("💬 Connection to \(contact.displayName) is stale, reconnecting...")
                await peer.connection.cancel()
                peers.removeValue(forKey: contact.onionAddress)
                needsReconnect = true
            }
        }

        if needsReconnect {
            try await connect(to: contact)
        }

        guard let peer = peers[contact.onionAddress] else {
            throw ChatError.notConnected
        }

        guard let sharedKey = await peer.sharedKey else {
            throw ChatError.encryptionFailed("No shared key")
        }

        // Encrypt message
        let encryptedPayload = try ChatEncryption.encryptMessage(message, using: sharedKey)

        // Encode for wire
        let wireData = ChatProtocol.encode(encryptedPayload: encryptedPayload)

        // Send
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                peer.connection.send(content: wireData, completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }

            // Message sent successfully - ensure contact is marked online
            await peer.updateActivity()
            updateContactOnlineStatus(contact.onionAddress, isOnline: true)

        } catch {
            // Send failed - mark as offline and clean up connection
            print("💬 Send failed to \(contact.displayName): \(error)")
            await peer.setState(.disconnected)
            await peer.connection.cancel()
            peers.removeValue(forKey: contact.onionAddress)
            updateContactOnlineStatus(contact.onionAddress, isOnline: false)
            throw error
        }
    }

    private func sendNickname(to contact: ChatContact) async throws {
        let message = ChatMessage(
            type: .nickname,
            fromOnion: ourOnionAddress ?? "",
            toOnion: contact.onionAddress,
            content: ourNickname
        )
        try await sendMessage(message, to: contact)
    }

    /// FIX #1441: Send our profile picture to a contact (base64 JPEG)
    private func sendAvatar(_ imageData: Data, to contact: ChatContact) async throws {
        let base64 = imageData.base64EncodedString()
        let message = ChatMessage(
            type: .avatar,
            fromOnion: ourOnionAddress ?? "",
            toOnion: contact.onionAddress,
            content: base64
        )
        try await sendMessage(message, to: contact)
        print("💬 FIX #1441: Sent avatar to \(contact.displayName) (\(imageData.count) bytes)")
    }

    /// FIX #1508: Resend profile (nickname and/or avatar) to all currently connected contacts.
    /// Called when: (1) nickname changes, (2) profile sharing toggle is enabled,
    /// (3) profile image is updated while sharing is enabled.
    private func resendProfileToConnectedContacts(nicknameOnly: Bool) async {
        let connectedContacts = contacts.filter { contact in
            peers[contact.onionAddress] != nil
        }
        guard !connectedContacts.isEmpty else { return }

        print("💬 FIX #1508: Resending profile to \(connectedContacts.count) connected contacts (nicknameOnly=\(nicknameOnly))...")

        for contact in connectedContacts {
            // Send nickname if set
            if !ourNickname.isEmpty {
                do {
                    try await sendNickname(to: contact)
                } catch {
                    print("💬 FIX #1508: Failed to resend nickname to \(contact.displayName): \(error)")
                }
            }

            // Send avatar if sharing is enabled and not nickname-only
            if !nicknameOnly, isProfileImageShared, let imageData = profileImage {
                do {
                    try await sendAvatar(imageData, to: contact)
                } catch {
                    print("💬 FIX #1508: Failed to resend avatar to \(contact.displayName): \(error)")
                }
            }
        }
    }

    /// FIX #1441: Save received contact avatar to disk
    func saveContactAvatar(_ data: Data, for onionAddress: String) {
        let url = contactAvatarURL(for: onionAddress)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
        // Notify UI to refresh
        objectWillChange.send()
    }

    /// FIX #1441: Load contact avatar from disk
    func loadContactAvatar(for onionAddress: String) -> Data? {
        let url = contactAvatarURL(for: onionAddress)
        return try? Data(contentsOf: url)
    }

    /// FIX #1441: File URL for a contact's avatar
    private func contactAvatarURL(for onionAddress: String) -> URL {
        // Use first 16 chars of onion address as filename (safe, unique)
        let safeName = String(onionAddress.prefix(16)).replacingOccurrences(of: ".", with: "_")
        return chatFilesDirectory.appendingPathComponent("avatars/\(safeName).jpg")
    }

    // MARK: - FIX #1540: Voice Call Signal Sending

    /// Send a call signaling message (offer, answer, reject, end, audio) to a peer.
    /// Call signals are ephemeral — NOT saved to chat history DB.
    func sendCallSignal(type: ChatMessageType, content: String, to onionAddress: String) async {
        guard let contact = contacts.first(where: { $0.onionAddress == onionAddress }) else {
            print("📞 FIX #1540: Cannot send call signal — contact not found for \(onionAddress.prefix(16))...")
            return
        }

        let message = ChatMessage(
            type: type,
            fromOnion: ourOnionAddress ?? "",
            toOnion: onionAddress,
            content: content,
            status: .sending
        )

        do {
            try await sendMessage(message, to: contact)
        } catch {
            print("📞 FIX #1540: Failed to send call signal (\(type.rawValue)): \(error)")
            // FIX #1552: Only trigger endCall for call_offer and call_answer failures.
            // NEVER trigger endCall for call_end or call_reject failures — that creates
            // infinite recursion: endCall → sendCallSignal(call_end) → fails → endCall → ...
            // Also skip for call_audio (just drop the frame silently).
            #if ENABLE_VOICE_CALLS
            if type == .callOffer || type == .callAnswer {
                Task { @MainActor in
                    await VoiceCallManager.shared.endCall(reason: "network_error")
                }
            }
            #endif
        }
    }

    // MARK: - FIX #1535: File Transfer

    /// State for an active file transfer (sending or receiving)
    struct FileTransferState {
        let fileId: String
        let fileName: String
        let fileSize: UInt64
        let totalChunks: Int
        var receivedChunks: Int = 0
        var localPath: URL?
        var isSending: Bool
        var progress: Double { totalChunks > 0 ? Double(receivedChunks) / Double(totalChunks) : 0 }
    }

    /// Active file transfers (both sending and receiving)
    @Published var activeFileTransfers: [String: FileTransferState] = [:]

    /// Incoming file chunk buffers (fileId → [chunkIndex: rawData])
    private var incomingFileBuffers: [String: [Int: Data]] = [:]

    /// Maximum concurrent file transfers
    private let maxConcurrentTransfers = 3

    /// Timeout for incomplete transfers (60 seconds)
    private let fileTransferTimeout: TimeInterval = 60

    /// Send a file to a contact
    func sendFile(url: URL, to contact: ChatContact) async throws {
        // Read file data
        let fileData = try Data(contentsOf: url)
        let fileName = url.lastPathComponent
        let fileSize = UInt64(fileData.count)

        // Validate size
        guard fileSize <= CHAT_MAX_FILE_SIZE else {
            throw ChatError.invalidMessage("File too large (\(fileSize / 1024 / 1024) MB). Maximum is 2 MB.")
        }

        // Check concurrent transfer limit
        let activeCount = activeFileTransfers.values.filter { $0.isSending }.count
        guard activeCount < maxConcurrentTransfers else {
            throw ChatError.invalidMessage("Too many active file transfers. Please wait.")
        }

        // Detect MIME type
        let mimeType = Self.mimeType(for: url)

        // Calculate chunks
        let totalChunks = (fileData.count + CHAT_FILE_CHUNK_SIZE - 1) / CHAT_FILE_CHUNK_SIZE
        let fileId = UUID().uuidString

        print("📎 FIX #1535: Sending file '\(fileName)' (\(fileSize) bytes, \(totalChunks) chunks) to \(contact.displayName)")

        // Create metadata
        let metadata = FileMetadata(
            fileId: fileId,
            fileName: fileName,
            fileSize: fileSize,
            mimeType: mimeType,
            totalChunks: totalChunks
        )

        // Encode metadata as JSON for content field
        let metadataJSON = String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? ""

        // Create file message (visible in chat)
        var fileMessage = ChatMessage(
            type: .file,
            fromOnion: ourOnionAddress ?? "",
            toOnion: contact.onionAddress,
            content: metadataJSON,
            nickname: ourNickname.isEmpty ? nil : ourNickname,
            status: .sending,
            fileName: fileName,
            fileSize: fileSize,
            fileId: fileId
        )

        // Add to conversation and track transfer
        addMessageToConversation(fileMessage)
        database.saveMessage(fileMessage, ourOnionAddress: ourOnionAddress)
        await MainActor.run {
            activeFileTransfers[fileId] = FileTransferState(
                fileId: fileId, fileName: fileName, fileSize: fileSize,
                totalChunks: totalChunks, isSending: true
            )
        }

        // Send metadata message first
        try await sendMessage(fileMessage, to: contact)

        // Send chunks
        for chunkIndex in 0..<totalChunks {
            let start = chunkIndex * CHAT_FILE_CHUNK_SIZE
            let end = min(start + CHAT_FILE_CHUNK_SIZE, fileData.count)
            let chunkData = fileData[start..<end]
            let base64Chunk = chunkData.base64EncodedString()

            let chunkPayload = FileChunkData(
                fileId: fileId,
                index: chunkIndex,
                data: base64Chunk
            )
            let chunkJSON = String(data: try JSONEncoder().encode(chunkPayload), encoding: .utf8) ?? ""

            let chunkMessage = ChatMessage(
                type: .fileChunk,
                fromOnion: ourOnionAddress ?? "",
                toOnion: contact.onionAddress,
                content: chunkJSON,
                fileId: fileId
            )

            try await sendMessage(chunkMessage, to: contact)

            // Update progress
            await MainActor.run {
                activeFileTransfers[fileId]?.receivedChunks = chunkIndex + 1
            }
        }

        // All chunks sent
        fileMessage.markSent()
        updateMessageInConversation(fileMessage)
        database.saveMessage(fileMessage, ourOnionAddress: ourOnionAddress)

        await MainActor.run {
            activeFileTransfers.removeValue(forKey: fileId)
        }

        print("📎 FIX #1535: File '\(fileName)' sent successfully (\(totalChunks) chunks)")
    }

    /// Handle incoming .file metadata message
    private func handleFileMessage(_ message: ChatMessage) {
        // Parse metadata from content
        guard let jsonData = message.content.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(FileMetadata.self, from: jsonData) else {
            print("📎 FIX #1535: Failed to parse file metadata")
            return
        }

        // Check file size limit
        guard metadata.fileSize <= CHAT_MAX_FILE_SIZE else {
            print("📎 FIX #1535: Rejected file '\(metadata.fileName)' — too large (\(metadata.fileSize) bytes)")
            return
        }

        // Check disk space
        let availableSpace = BundledShieldedOutputs.getAvailableDiskSpace()
        guard availableSpace > Int64(metadata.fileSize) + ZipherXConstants.criticalDiskSpaceBytes else {
            print("📎 FIX #1535: Rejected file '\(metadata.fileName)' — insufficient disk space")
            return
        }

        // Check concurrent transfers
        let receiving = activeFileTransfers.values.filter { !$0.isSending }.count
        guard receiving < maxConcurrentTransfers else {
            print("📎 FIX #1535: Rejected file — too many concurrent transfers")
            return
        }

        print("📎 FIX #1535: Receiving file '\(metadata.fileName)' (\(metadata.fileSize) bytes, \(metadata.totalChunks) chunks)")

        // Initialize buffer
        incomingFileBuffers[metadata.fileId] = [:]

        // Track transfer
        DispatchQueue.main.async {
            self.activeFileTransfers[metadata.fileId] = FileTransferState(
                fileId: metadata.fileId, fileName: metadata.fileName,
                fileSize: metadata.fileSize, totalChunks: metadata.totalChunks,
                isSending: false
            )
        }

        // Save as visible message in conversation
        addMessageToConversation(message)
        database.saveMessage(message, ourOnionAddress: ourOnionAddress)

        // Start timeout timer
        let fileId = metadata.fileId
        Task {
            try? await Task.sleep(nanoseconds: UInt64(fileTransferTimeout * 1_000_000_000))
            if incomingFileBuffers[fileId] != nil {
                print("📎 FIX #1535: File transfer timeout for '\(metadata.fileName)'")
                incomingFileBuffers.removeValue(forKey: fileId)
                await MainActor.run {
                    activeFileTransfers.removeValue(forKey: fileId)
                }
            }
        }
    }

    /// Handle incoming .fileChunk data message
    private func handleFileChunk(_ message: ChatMessage) {
        guard let jsonData = message.content.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(FileChunkData.self, from: jsonData) else {
            print("📎 FIX #1535: Failed to parse file chunk")
            return
        }

        guard var buffer = incomingFileBuffers[chunk.fileId] else {
            print("📎 FIX #1535: Received chunk for unknown file \(chunk.fileId.prefix(8))")
            return
        }

        // Decode base64 data
        guard let rawData = Data(base64Encoded: chunk.data) else {
            print("📎 FIX #1535: Failed to decode base64 chunk data")
            return
        }

        // Store chunk (idempotent — overwrite if duplicate)
        buffer[chunk.index] = rawData
        incomingFileBuffers[chunk.fileId] = buffer

        // Update progress
        let receivedCount = buffer.count
        DispatchQueue.main.async {
            self.activeFileTransfers[chunk.fileId]?.receivedChunks = receivedCount
        }

        // Check if all chunks received
        if let transfer = activeFileTransfers[chunk.fileId], receivedCount >= transfer.totalChunks {
            assembleFile(fileId: chunk.fileId)
        }
    }

    /// Assemble received chunks into a complete file and save to disk
    private func assembleFile(fileId: String) {
        guard let transfer = activeFileTransfers[fileId],
              let chunks = incomingFileBuffers[fileId] else { return }

        // Assemble in order
        var assembledData = Data()
        for i in 0..<transfer.totalChunks {
            guard let chunk = chunks[i] else {
                print("📎 FIX #1535: Missing chunk \(i) for file '\(transfer.fileName)'")
                return
            }
            assembledData.append(chunk)
        }

        // Verify size
        guard UInt64(assembledData.count) == transfer.fileSize else {
            print("📎 FIX #1535: Size mismatch: expected \(transfer.fileSize), got \(assembledData.count)")
            return
        }

        // FIX H-001: Sanitize fileName to prevent path traversal attacks
        // Strip directory components and ".." sequences — only keep the final filename
        let safeName = URL(fileURLWithPath: transfer.fileName).lastPathComponent
            .replacingOccurrences(of: "..", with: "_")
        let fileURL = chatFilesDirectory
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent("\(fileId)_\(safeName)")

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try assembledData.write(to: fileURL)
            print("📎 FIX #1535: File '\(transfer.fileName)' saved to \(fileURL.lastPathComponent)")
        } catch {
            print("📎 FIX #1535: Failed to save file: \(error)")
            return
        }

        // Clean up buffer
        incomingFileBuffers.removeValue(forKey: fileId)

        // Update transfer state with local path
        DispatchQueue.main.async {
            self.activeFileTransfers[fileId]?.localPath = fileURL
            self.activeFileTransfers[fileId]?.receivedChunks = transfer.totalChunks

            // Post notification for UI update
            NotificationCenter.default.post(name: Notification.Name("fileTransferCompleted"), object: nil, userInfo: ["fileId": fileId, "localPath": fileURL])
        }
    }

    /// Get saved file URL for a file message
    func getSavedFileURL(for fileId: String, fileName: String) -> URL? {
        // FIX H-001: Sanitize fileName to prevent path traversal
        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
            .replacingOccurrences(of: "..", with: "_")
        let fileURL = chatFilesDirectory
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent("\(fileId)_\(safeName)")
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// MIME type detection from file extension
    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "zip": return "application/zip"
        case "mp3": return "audio/mpeg"
        case "mp4": return "video/mp4"
        case "doc", "docx": return "application/msword"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Helper Methods

    private func addMessageToConversation(_ message: ChatMessage) {
        let onion = message.fromOnion == ourOnionAddress ? message.toOnion : message.fromOnion

        // FIX #1578: Create conversation on demand if missing — old code silently dropped
        // messages when conversations[onion] was nil (race with loadPersistentData / FIX #1526)
        if conversations[onion] == nil {
            if let contact = contacts.first(where: { $0.onionAddress == onion }) {
                conversations[onion] = ChatConversation(contact: contact)
                print("💬 FIX #1578: Created missing conversation for \(onion.prefix(16))... on message receive")
            } else {
                print("💬 FIX #1578: Dropping message from unknown contact \(onion.prefix(16))...")
                return
            }
        }

        if var conversation = conversations[onion] {
            conversation.messages.append(message)
            conversations[onion] = conversation
        }
    }

    private func incrementUnreadCount(for onionAddress: String) {
        if let index = contacts.firstIndex(where: { $0.onionAddress == onionAddress }) {
            var contact = contacts[index]
            contact.unreadCount += 1
            contacts[index] = contact
            totalUnreadCount += 1
        }
    }

    /// Update an existing message in conversation (for status changes)
    private func updateMessageInConversation(_ message: ChatMessage) {
        let onion = message.fromOnion == ourOnionAddress ? message.toOnion : message.fromOnion

        if var conversation = conversations[onion],
           let index = conversation.messages.firstIndex(where: { $0.id == message.id }) {
            conversation.messages[index] = message
            conversations[onion] = conversation
        }
    }

    private func updateContactOnlineStatus(_ onionAddress: String, isOnline: Bool) {
        if let index = contacts.firstIndex(where: { $0.onionAddress == onionAddress }) {
            var contact = contacts[index]
            let wasOffline = !contact.isOnline
            contact.isOnline = isOnline
            if isOnline {
                contact.lastSeen = Date()
            }
            contacts[index] = contact
            database.saveContact(contact)

            // FIX #249: Flush queued messages when contact comes online
            if isOnline && wasOffline {
                Task {
                    await flushQueue(for: contact)
                }
            }
        }
    }

    private func updateContactLastSeen(_ onionAddress: String) {
        if let index = contacts.firstIndex(where: { $0.onionAddress == onionAddress }) {
            var contact = contacts[index]
            contact.lastSeen = Date()
            contacts[index] = contact
        }
    }

    // FIX #1508: Always update contact nickname when remote sends one.
    // Previous code only updated if contact.nickname.isEmpty — meaning if a contact
    // changed their nickname, the update was silently discarded.
    private func updateContactNickname(_ onionAddress: String, nickname: String) {
        if let index = contacts.firstIndex(where: { $0.onionAddress == onionAddress }) {
            var contact = contacts[index]
            if contact.nickname != nickname {
                contact.nickname = nickname
                contacts[index] = contact
                database.saveContact(contact)
                print("💬 FIX #1508: Updated contact nickname to '\(nickname)' for \(onionAddress.prefix(8))...")
            }
        }
    }

    private func markMessageDelivered(id: String) {
        // Find and update the message in conversations
        var found = false
        for (onion, var conversation) in conversations {
            if let index = conversation.messages.firstIndex(where: { $0.id == id }) {
                var message = conversation.messages[index]
                message.markDelivered()
                conversation.messages[index] = message
                conversations[onion] = conversation

                // Update in database
                database.saveMessage(message, ourOnionAddress: ourOnionAddress)
                found = true
                break
            }
        }

        // FIX #1562: Only post notification when a message was actually updated.
        // Previously posted unconditionally — if the id matched nothing, the notification
        // fired but conversations was unchanged → UI re-rendered with stale .sent status.
        // Also explicitly send objectWillChange to guarantee SwiftUI redraws on macOS
        // where @Published dict mutations can be coalesced before the view re-evaluates.
        if found {
            objectWillChange.send()
            NotificationCenter.default.post(
                name: .chatMessageDelivered,
                object: nil,
                userInfo: ["messageId": id]
            )
            print("💬 FIX #1562: Marked message \(id.prefix(8))... as delivered")
        } else {
            print("💬 FIX #1562: Delivery ACK for unknown message id \(id.prefix(8))... (ignored)")
        }
    }

    private func markMessageRead(id: String) {
        // Find and update the message in conversations
        var found = false
        for (onion, var conversation) in conversations {
            if let index = conversation.messages.firstIndex(where: { $0.id == id }) {
                var message = conversation.messages[index]
                message.markRead()
                conversation.messages[index] = message
                conversations[onion] = conversation

                // Update in database
                database.saveMessage(message, ourOnionAddress: ourOnionAddress)
                found = true
                break
            }
        }

        // FIX #1562: Only post notification when a message was actually updated (mirrors markMessageDelivered fix).
        if found {
            objectWillChange.send()
            NotificationCenter.default.post(
                name: .chatMessageRead,
                object: nil,
                userInfo: ["messageId": id]
            )
        }
    }

    private func isValidOnionAddress(_ address: String) -> Bool {
        // v3 onion addresses are 56 characters + ".onion"
        let pattern = "^[a-z2-7]{56}\\.onion$"
        return address.range(of: pattern, options: .regularExpression) != nil
    }

    /// FIX #1440: Public method to trigger immediate online check for all contacts
    /// Called when chat view first appears so dots are green right away (not after 30s)
    /// FIX #1532: Sets isWarmingUp during the check so UI can show warmup status
    func checkAllContactsOnline() async {
        let contactsToCheck = contacts.filter { !$0.isBlocked }
        guard !contactsToCheck.isEmpty else { return }

        isWarmingUp = true
        defer { isWarmingUp = false }

        for contact in contactsToCheck {
            let isConnected: Bool
            if let peer = peers[contact.onionAddress] {
                isConnected = await peer.state.isConnected
            } else {
                isConnected = false
            }
            if !isConnected {
                // FIX #1458: Skip if we recently failed (don't spam on view appear)
                if shouldSkipConnection(for: contact.onionAddress) {
                    continue
                }
                do {
                    try await connect(to: contact)
                    print("💬 FIX #1440: Initial connect to \(contact.displayName) succeeded — online")
                } catch {
                    // FIX #1473: Record failure here too — was missing, so UI-triggered checks
                    // never accumulated backoff, causing retry storms on view appear
                    recordConnectionFailure(for: contact.onionAddress)
                    if contact.isOnline {
                        updateContactOnlineStatus(contact.onionAddress, isOnline: false)
                    }
                }
            } else if !contact.isOnline {
                // FIX #1586: Peer is connected but contact.isOnline is stale (false).
                // This happens when loadPersistentData() resets all isOnline=false AFTER
                // connections were already established. Reconcile now.
                updateContactOnlineStatus(contact.onionAddress, isOnline: true)
                print("💬 FIX #1586: Reconciled stale offline status for \(contact.displayName) — peer is connected")
            }
        }
    }

    private func startMaintenanceLoop() {
        maintenanceTask = Task {
            // FIX #1440: Run proactive online check immediately (don't wait 30s)
            await checkAllContactsOnline()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000) // FIX #1541: 15s for faster online detection (was 30s)

                // Ping connected peers
                for (onion, peer) in peers {
                    if await peer.state.isConnected {
                        if let contact = contacts.first(where: { $0.onionAddress == onion }) {
                            let ping = ChatMessage(
                                type: .ping,
                                fromOnion: ourOnionAddress ?? "",
                                toOnion: onion,
                                content: ""
                            )
                            try? await sendMessage(ping, to: contact)
                        }
                    }
                }

                // FIX #1541: Reduced stale threshold from 120s to 45s for faster offline detection.
                // With NWConnection state monitoring, this is a backup — but 120s was far too long.
                let staleThreshold = Date().addingTimeInterval(-45)
                for (onion, peer) in peers {
                    if await peer.lastActivity < staleThreshold {
                        await peer.connection.cancel()
                        peers.removeValue(forKey: onion)
                        updateContactOnlineStatus(onion, isOnline: false)
                    }
                }

                // FIX #1435 + FIX #1458: Proactive online check with backoff gate
                // Only attempt connection if backoff window has elapsed
                for contact in contacts where !contact.isBlocked {
                    let isConnected: Bool
                    if let peer = peers[contact.onionAddress] {
                        isConnected = await peer.state.isConnected
                    } else {
                        isConnected = false
                    }
                    if !isConnected {
                        // FIX #1458: Skip if still within backoff window
                        if shouldSkipConnection(for: contact.onionAddress) {
                            continue
                        }
                        do {
                            try await connect(to: contact)
                            print("💬 FIX #1435: Proactive connect to \(contact.displayName) succeeded — now online")
                        } catch {
                            // FIX #1468: Record ALL connection failures for backoff, not just key exchange
                            // Without this, SOCKS5 failures ("Onion Service not found") never trigger backoff
                            // → retry storm every 30 seconds with no delay
                            recordConnectionFailure(for: contact.onionAddress)
                            if contact.isOnline {
                                updateContactOnlineStatus(contact.onionAddress, isOnline: false)
                            }
                        }
                    }
                }

                // FIX #249: Retry queued messages periodically
                await retryQueuedMessages()
            }
        }
    }

    private func loadPersistentData() async {
        contacts = database.loadContacts()
        // FIX #1511: Log contact count on startup for debugging contact loss
        print("💬 FIX #1511: Loaded \(contacts.count) contacts from database")
        for contact in contacts {
            print("💬 FIX #1511:   - \(contact.onionAddress.prefix(16))... nickname='\(contact.nickname)' unread=\(contact.unreadCount)")
        }

        // FIX #1369: Reset all contacts to offline on startup — no connections exist yet.
        // isOnline was persisted to disk from the previous session but is stale.
        // FIX #1586: Don't reset if a live peer connection already exists (race with
        // walletDatabaseOpened notification — connections can be established before this runs)
        for i in contacts.indices {
            if contacts[i].isOnline {
                let hasPeer = peers[contacts[i].onionAddress] != nil
                if !hasPeer {
                    contacts[i].isOnline = false
                    database.saveContact(contacts[i])
                }
            }
        }

        for contact in contacts {
            var conversation = ChatConversation(contact: contact)
            conversation.messages = database.loadMessages(for: contact.onionAddress)
            conversations[contact.onionAddress] = conversation
        }

        totalUnreadCount = contacts.reduce(0) { $0 + $1.unreadCount }
        // FIX #1525: loadProfileImage() now called synchronously in init() — no longer needed here
    }

    // MARK: - FIX #1436: Profile Image

    /// Directory for chat files (profile image, etc.)
    private var chatFilesDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZipherX/Chat")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var profileImageURL: URL {
        chatFilesDirectory.appendingPathComponent("profile_image.jpg")
    }

    /// Save profile image to disk (nil to remove)
    func saveProfileImage(_ imageData: Data?) {
        profileImage = imageData
        if let data = imageData {
            try? data.write(to: profileImageURL)
            print("💬 FIX #1436: Profile image saved (\(data.count) bytes)")
            // FIX #1508: Resend to connected contacts when image changes while sharing is enabled
            if isProfileImageShared {
                Task { await resendProfileToConnectedContacts(nicknameOnly: false) }
            }
        } else {
            try? FileManager.default.removeItem(at: profileImageURL)
            print("💬 FIX #1436: Profile image removed")
        }
    }

    /// Load profile image from disk
    private func loadProfileImage() {
        if FileManager.default.fileExists(atPath: profileImageURL.path) {
            profileImage = try? Data(contentsOf: profileImageURL)
            print("💬 FIX #1436: Profile image loaded (\(profileImage?.count ?? 0) bytes)")
        }
    }

    // MARK: - FIX #249: Message Queue Methods

    /// Add a message to the queue for a specific contact
    private func queueMessage(_ message: ChatMessage, for onionAddress: String) {
        if messageQueue[onionAddress] == nil {
            messageQueue[onionAddress] = []
        }
        messageQueue[onionAddress]?.append(message)
        saveMessageQueue()
        print("💬 FIX #249: Message queued for \(onionAddress.prefix(16))... (queue size: \(messageQueue[onionAddress]?.count ?? 0))")
    }

    /// FIX #249 v2 + VUL-STOR-003: Load message queue from SQLCipher (encrypted + expiry filter)
    /// Previously used UserDefaults with ChaChaPoly - now uses SQLCipher with domain-separated encryption
    private func loadMessageQueue() async {
        // VUL-STOR-003: Migrate from legacy UserDefaults storage if needed
        if let legacyEncryptedData = UserDefaults.standard.data(forKey: messageQueueKey),
           WalletDatabase.shared.getChatMessageQueue() == nil,
           let key = getOrCreateQueueEncryptionKey(),
           let decryptedData = decryptQueueData(legacyEncryptedData, using: key) {
            // Migrate to SQLCipher
            WalletDatabase.shared.saveChatMessageQueue(data: decryptedData)
            UserDefaults.standard.removeObject(forKey: messageQueueKey)
            print("💬 VUL-STOR-003: Migrated message queue from UserDefaults to SQLCipher")
        }

        // Load from SQLCipher
        guard let queueData = WalletDatabase.shared.getChatMessageQueue() else {
            print("💬 FIX #249: No message queue found")
            return
        }

        // Decode
        guard let queue = try? JSONDecoder().decode([String: [ChatMessage]].self, from: queueData) else {
            print("💬 FIX #249: Failed to decode message queue")
            return
        }

        // Filter out expired messages (older than 180 days)
        let now = Date()
        var filteredQueue: [String: [ChatMessage]] = [:]
        var expiredCount = 0

        for (onionAddress, messages) in queue {
            let validMessages = messages.filter { message in
                let age = now.timeIntervalSince(message.timestamp)
                if age > maxQueuedMessageAge {
                    expiredCount += 1
                    return false
                }
                return true
            }
            if !validMessages.isEmpty {
                filteredQueue[onionAddress] = validMessages
            }
        }

        messageQueue = filteredQueue

        if expiredCount > 0 {
            print("💬 FIX #249 v2: Removed \(expiredCount) expired message(s) (>180 days)")
            saveMessageQueue()  // Persist the filtered queue
        }

        let totalQueued = filteredQueue.values.reduce(0) { $0 + $1.count }
        print("💬 FIX #249: Loaded message queue (\(totalQueued) messages for \(filteredQueue.keys.count) contacts)")
    }

    /// FIX #249 v2 + VUL-STOR-003: Save message queue to SQLCipher database
    /// Previously used UserDefaults with ChaChaPoly - now uses SQLCipher with domain-separated encryption
    private func saveMessageQueue() {
        // Encode to JSON
        guard let jsonData = try? JSONEncoder().encode(messageQueue) else {
            print("💬 FIX #249: Failed to encode message queue")
            return
        }

        // Save to SQLCipher (automatically encrypted with .chat domain key)
        WalletDatabase.shared.saveChatMessageQueue(data: jsonData)
    }

    // MARK: - FIX #249 v2: Queue Encryption Helpers

    /// Get or create the queue encryption key from Keychain
    private func getOrCreateQueueEncryptionKey() -> SymmetricKey? {
        // Return cached key if available
        if let cached = queueEncryptionKey {
            return cached
        }

        // Try to load from Keychain
        if let keyData = loadQueueKeyFromKeychain() {
            let key = SymmetricKey(data: keyData)
            queueEncryptionKey = key
            return key
        }

        // Generate new 256-bit key
        let newKey = SymmetricKey(size: .bits256)

        // Save to Keychain
        let keyData = newKey.withUnsafeBytes { Data($0) }
        if saveQueueKeyToKeychain(keyData) {
            queueEncryptionKey = newKey
            print("💬 FIX #249 v2: Generated new queue encryption key")
            return newKey
        }

        print("💬 FIX #249 v2: Failed to save queue encryption key to Keychain")
        return nil
    }

    /// Encrypt queue data using ChaChaPoly
    private func encryptQueueData(_ data: Data, using key: SymmetricKey) -> Data? {
        do {
            let sealedBox = try ChaChaPoly.seal(data, using: key)
            return sealedBox.combined
        } catch {
            print("💬 FIX #249 v2: Encryption error: \(error)")
            return nil
        }
    }

    /// Decrypt queue data using ChaChaPoly
    private func decryptQueueData(_ data: Data, using key: SymmetricKey) -> Data? {
        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: data)
            return try ChaChaPoly.open(sealedBox, using: key)
        } catch {
            print("💬 FIX #249 v2: Decryption error: \(error)")
            return nil
        }
    }

    /// Save queue encryption key to Keychain
    private func saveQueueKeyToKeychain(_ keyData: Data) -> Bool {
        // Delete existing if any
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: queueEncryptionKeyKeychainKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new key
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: queueEncryptionKeyKeychainKey,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Load queue encryption key from Keychain
    private func loadQueueKeyFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: queueEncryptionKeyKeychainKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return data
        }
        return nil
    }

    /// Flush all queued messages for a contact who just came online
    private func flushQueue(for contact: ChatContact) async {
        guard let queued = messageQueue[contact.onionAddress], !queued.isEmpty else {
            return
        }

        print("💬 FIX #249: Flushing \(queued.count) queued message(s) for \(contact.displayName)")

        var successCount = 0
        var failCount = 0
        var remainingMessages: [ChatMessage] = []

        for var message in queued {
            do {
                // Try to send the message
                try await sendMessage(message, to: contact)

                // Success - update status to sent
                message.markSent()
                updateMessageInConversation(message)
                database.saveMessage(message, ourOnionAddress: ourOnionAddress)
                successCount += 1
                print("💬 FIX #249: Queued message sent successfully")
            } catch {
                // Still offline or other error - keep in queue
                failCount += 1
                remainingMessages.append(message)
                print("💬 FIX #249: Failed to send queued message: \(error.localizedDescription)")
            }
        }

        // Update queue with any remaining messages
        if remainingMessages.isEmpty {
            messageQueue.removeValue(forKey: contact.onionAddress)
        } else {
            messageQueue[contact.onionAddress] = remainingMessages
        }
        saveMessageQueue()

        print("💬 FIX #249: Queue flush complete - sent: \(successCount), remaining: \(failCount)")
    }

    /// Retry sending queued messages for all contacts (called periodically)
    private func retryQueuedMessages() async {
        guard !messageQueue.isEmpty else { return }

        // FIX #1478: Apply backoff gate to queue retries.
        // Without this, retryQueuedMessages() bypasses shouldSkipConnection() entirely.
        // Result: every 30s maintenance loop builds a full Tor circuit → iOS overheating.
        var contactsToRetry: [ChatContact] = []
        for onionAddress in messageQueue.keys {
            guard let contact = contacts.first(where: { $0.onionAddress == onionAddress }) else {
                continue
            }
            // Check if we're within backoff window — skip if so
            if shouldSkipConnection(for: onionAddress) {
                continue
            }
            // Check if already connected — only flush if connected (no new circuit)
            let isConnected: Bool
            if let peer = peers[contact.onionAddress] {
                isConnected = await peer.state.isConnected
            } else {
                isConnected = false
            }
            if isConnected {
                contactsToRetry.append(contact)
            }
        }

        guard !contactsToRetry.isEmpty else { return }
        print("💬 FIX #249: Retrying queued messages for \(contactsToRetry.count) connected contact(s)")

        for contact in contactsToRetry {
            await flushQueue(for: contact)
        }
    }

    /// Get the number of queued messages for a contact (for UI)
    func getQueuedMessageCount(for onionAddress: String) -> Int {
        return messageQueue[onionAddress]?.count ?? 0
    }

    /// Get total number of queued messages across all contacts
    var totalQueuedMessages: Int {
        return messageQueue.values.reduce(0) { $0 + $1.count }
    }

    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ChatError.notConnected
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Chat Database

/// FIX #249 v2: Encrypted database for chat persistence
/// All data is encrypted at rest using ChaChaPoly with a Keychain-stored key
/// VUL-STOR-003: Chat storage now uses SQLCipher (WalletDatabase) instead of UserDefaults
/// Data is encrypted at rest by SQLCipher — no separate ChaChaPoly layer needed
class ChatDatabase {

    // MARK: - Contacts (SQLCipher)

    // FIX #1531: Pass isBlocked to persist blocked status across restarts
    // FIX M-001: Pass publicKeyData to persist identity binding
    func saveContact(_ contact: ChatContact) {
        WalletDatabase.shared.saveChatContact(
            onionAddress: contact.onionAddress,
            nickname: contact.nickname.isEmpty ? nil : contact.nickname,
            isBlocked: contact.isBlocked,
            unreadCount: contact.unreadCount,
            lastMessageTime: nil,
            publicKey: contact.publicKeyData
        )
        // FIX #1486: Checkpoint WAL immediately after contact save.
        // On iOS, app can be force-killed before applicationDidEnterBackground fires.
        // Without this: contact written to WAL → app killed → WAL not checkpointed → contact lost.
        WalletDatabase.shared.checkpoint()
    }

    func loadContacts() -> [ChatContact] {
        let rows = WalletDatabase.shared.loadChatContacts()
        return rows.map { row in
            var contact = ChatContact(onionAddress: row.onionAddress, nickname: row.nickname ?? "")
            contact.unreadCount = row.unreadCount
            contact.isBlocked = row.isBlocked
            // FIX M-001: Restore persisted public key for identity verification
            contact.publicKeyData = row.publicKey
            return contact
        }
    }

    func deleteContact(_ contact: ChatContact) {
        WalletDatabase.shared.deleteChatContact(onionAddress: contact.onionAddress)
        WalletDatabase.shared.deleteChatMessages(for: contact.onionAddress)
    }

    // MARK: - Messages (SQLCipher)

    func saveMessage(_ message: ChatMessage, ourOnionAddress: String? = nil) {
        // FIX #264: Store by conversation partner's address
        let onion: String
        if let ourAddress = ourOnionAddress {
            onion = message.fromOnion == ourAddress ? message.toOnion : message.fromOnion
        } else {
            onion = message.fromOnion.isEmpty ? message.toOnion : message.fromOnion
        }

        let isSent = message.status == .sent || message.status == .delivered || message.status == .read
        let isDelivered = message.status == .delivered || message.status == .read
        let isRead = message.status == .read

        WalletDatabase.shared.saveChatMessage(
            id: message.id,
            conversationAddress: onion,
            fromOnion: message.fromOnion,
            toOnion: message.toOnion,
            content: message.content,
            messageType: message.type.rawValue,
            isSent: isSent,
            isDelivered: isDelivered,
            isRead: isRead,
            timestamp: Int64(message.timestamp.timeIntervalSince1970),
            replyToId: message.replyTo,
            paymentAmount: message.paymentAmount,
            paymentAddress: message.paymentAddress
        )

        // FIX #1499: Update contact's last_message_time so contacts sort correctly after restart.
        // COALESCE in the SQL ensures only non-NULL values overwrite, so passing nil for
        // nickname/unreadCount won't wipe existing values... but we need a separate UPDATE here
        // to avoid changing nickname/unreadCount. Use direct SQL for surgical update.
        WalletDatabase.shared.updateChatContactLastMessageTime(
            onionAddress: onion,
            lastMessageTime: Int64(message.timestamp.timeIntervalSince1970)
        )
    }

    // FIX #1498: Use restore initializer with stored id + timestamp from database.
    // Previous code used the short init which generated new UUID + Date() on every load,
    // causing duplicate IDs, wrong timestamps, and messages appearing empty after restart.
    func loadMessages(for onionAddress: String) -> [ChatMessage] {
        let rows = WalletDatabase.shared.loadChatMessages(for: onionAddress)
        return rows.compactMap { row in
            guard let type = ChatMessageType(rawValue: row.messageType) else { return nil }
            // Reconstruct status from booleans
            let status: MessageStatus
            if row.isRead { status = .read }
            else if row.isDelivered { status = .delivered }
            else if row.isSent { status = .sent }
            else { status = .sending }

            return ChatMessage(
                id: row.id,
                type: type,
                fromOnion: row.fromOnion,
                toOnion: row.toOnion,
                timestamp: Date(timeIntervalSince1970: TimeInterval(row.timestamp)),
                content: row.content,
                replyTo: row.replyToId,
                status: status,
                paymentAddress: row.paymentAddress,
                paymentAmount: row.paymentAmount
            )
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let chatTypingIndicator = Notification.Name("chatTypingIndicator")
    static let chatMessageDelivered = Notification.Name("chatMessageDelivered")
    static let chatMessageRead = Notification.Name("chatMessageRead")
    /// FIX #1487: Posted by NetworkManager when .onion circuits become ready
    static let onionCircuitsReady = Notification.Name("onionCircuitsReady")
    /// FIX #1504: Posted from chat/sheets when user interacts — resets inactivity timer.
    /// Sheets are separate view hierarchies, so ContentView gesture recognizers don't fire.
    static let userActivityInSheet = Notification.Name("userActivityInSheet")
    /// FIX #1526: Posted by WalletDatabase.open() after tables are created and DB is ready.
    static let walletDatabaseOpened = Notification.Name("walletDatabaseOpened")
}
