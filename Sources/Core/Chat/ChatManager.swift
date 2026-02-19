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

    /// Our .onion address for chat
    @Published private(set) var ourOnionAddress: String?

    /// Our nickname
    @Published var ourNickname: String {
        didSet {
            UserDefaults.standard.set(ourNickname, forKey: "chatNickname")
        }
    }

    /// FIX #1436: Our profile image (stored as file, not UserDefaults)
    @Published var profileImage: Data? = nil

    /// FIX #1436: Whether to share profile image with contacts
    var isProfileImageShared: Bool {
        get { UserDefaults.standard.bool(forKey: "chatShareProfileImage") }
        set { UserDefaults.standard.set(newValue, forKey: "chatShareProfileImage") }
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

    /// Base backoff delay (2 seconds)
    private let baseBackoffSeconds: Double = 2.0

    /// FIX #1458: Track last attempt time to prevent overlapping connection attempts
    private var lastConnectionAttempt: [String: Date] = [:]

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
        self.ourNickname = UserDefaults.standard.string(forKey: "chatNickname") ?? ""
        self.database = ChatDatabase()

        // Load contacts and conversations from database
        Task {
            await loadPersistentData()
            // FIX #249: Load queued messages
            await loadMessageQueue()
        }

        print("💬 ChatManager initialized")
    }

    // MARK: - Public API

    /// Start the chat service (requires Hidden Service to be running)
    func start() async throws {
        guard await HiddenServiceManager.shared.state == .running else {
            throw ChatError.hiddenServiceNotRunning
        }

        guard let onion = await HiddenServiceManager.shared.onionAddress else {
            throw ChatError.hiddenServiceNotRunning
        }

        ourOnionAddress = onion

        // Start listening for incoming chat connections
        try startListener()

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
    func blockContact(_ contact: ChatContact) {
        guard let index = contacts.firstIndex(where: { $0.onionAddress == contact.onionAddress }) else { return }
        var updated = contacts[index]
        updated.isBlocked = true
        contacts[index] = updated
        database.saveContact(updated)
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

        // ==========================================================================
        // FIX #330: Circuit health check before operations
        // Verify Tor circuit is established before attempting .onion connection
        // This prevents wasted connection attempts during circuit warmup
        // ==========================================================================
        let torManager = await TorManager.shared
        let isCircuitReady = await torManager.isOnionCircuitsReady
        let warmupRemaining = await torManager.onionCircuitWarmupRemaining

        if !isCircuitReady {
            // Option 1: Wait for warmup if it's short (< 15 seconds)
            if warmupRemaining > 0 && warmupRemaining <= 15 {
                print("💬 FIX #330: Waiting \(String(format: "%.0f", warmupRemaining))s for Tor circuit warmup...")
                try await Task.sleep(nanoseconds: UInt64(warmupRemaining * 1_000_000_000) + 1_000_000_000) // +1s safety
            } else if warmupRemaining > 15 {
                // Option 2: If warmup is long, throw informative error
                print("💬 FIX #330: Tor circuit not ready - \(String(format: "%.0f", warmupRemaining))s remaining")
                throw ChatError.connectionFailed("Tor circuit warming up (\(Int(warmupRemaining))s remaining). Please wait and try again.")
            } else {
                // Option 3: Tor not connected at all
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
            host: NWEndpoint.Host("127.0.0.1"),
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

        // Send our nickname
        if !ourNickname.isEmpty {
            try? await sendNickname(to: contact)
        }

        // FIX #1441: Send our profile picture if sharing is enabled
        if isProfileImageShared, let imageData = profileImage {
            try? await sendAvatar(imageData, to: contact)
        }

        updateContactOnlineStatus(contact.onionAddress, isOnline: true)
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, _, error in
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

        // Create or update peer
        let peer = ChatPeer(onionAddress: onionAddress, connection: connection)
        try? await peer.setTheirPublicKey(theirPublicKey)
        await peer.setState(.connected)
        peers[onionAddress] = peer

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
            let contact = ChatContact(onionAddress: onionAddress, nickname: "")
            contacts.append(contact)
            conversations[onionAddress] = ChatConversation(contact: contact)
            database.saveContact(contact)
            print("💬 Auto-added contact: \(onionAddress.prefix(16))...")
        }

        updateContactOnlineStatus(onionAddress, isOnline: true)

        // Start receiving messages
        receiveMessages(from: peer)
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
        case .text, .paymentRequest, .paymentSent, .paymentReceived:
            addMessageToConversation(message)
            database.saveMessage(message, ourOnionAddress: ourOnionAddress)

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
                let preview = message.type == .text ? message.content : nil
                NotificationManager.shared.notifyChatMessage(
                    from: senderName,
                    type: message.type.rawValue,
                    preview: preview
                )
            }

            // Send delivery confirmation
            Task {
                let delivery = ChatMessage(
                    type: .delivered,
                    fromOnion: ourOnionAddress ?? "",
                    toOnion: message.fromOnion,
                    content: message.id
                )
                if let contact = contacts.first(where: { $0.onionAddress == message.fromOnion }) {
                    try? await sendMessage(delivery, to: contact)
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
            // Update last seen
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

    // MARK: - Helper Methods

    private func addMessageToConversation(_ message: ChatMessage) {
        let onion = message.fromOnion == ourOnionAddress ? message.toOnion : message.fromOnion

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

    private func updateContactNickname(_ onionAddress: String, nickname: String) {
        if let index = contacts.firstIndex(where: { $0.onionAddress == onionAddress }) {
            var contact = contacts[index]
            if contact.nickname.isEmpty {
                contact.nickname = nickname
                contacts[index] = contact
                database.saveContact(contact)
            }
        }
    }

    private func markMessageDelivered(id: String) {
        // Find and update the message in conversations
        for (onion, var conversation) in conversations {
            if let index = conversation.messages.firstIndex(where: { $0.id == id }) {
                var message = conversation.messages[index]
                message.markDelivered()
                conversation.messages[index] = message
                conversations[onion] = conversation

                // Update in database
                database.saveMessage(message, ourOnionAddress: ourOnionAddress)
                break
            }
        }

        // Notify UI of delivery confirmation
        NotificationCenter.default.post(
            name: .chatMessageDelivered,
            object: nil,
            userInfo: ["messageId": id]
        )
    }

    private func markMessageRead(id: String) {
        // Find and update the message in conversations
        for (onion, var conversation) in conversations {
            if let index = conversation.messages.firstIndex(where: { $0.id == id }) {
                var message = conversation.messages[index]
                message.markRead()
                conversation.messages[index] = message
                conversations[onion] = conversation

                // Update in database
                database.saveMessage(message, ourOnionAddress: ourOnionAddress)
                break
            }
        }

        // Notify UI of read receipt
        NotificationCenter.default.post(
            name: .chatMessageRead,
            object: nil,
            userInfo: ["messageId": id]
        )
    }

    private func isValidOnionAddress(_ address: String) -> Bool {
        // v3 onion addresses are 56 characters + ".onion"
        let pattern = "^[a-z2-7]{56}\\.onion$"
        return address.range(of: pattern, options: .regularExpression) != nil
    }

    /// FIX #1440: Public method to trigger immediate online check for all contacts
    /// Called when chat view first appears so dots are green right away (not after 30s)
    func checkAllContactsOnline() async {
        for contact in contacts where !contact.isBlocked {
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
                    if contact.isOnline {
                        updateContactOnlineStatus(contact.onionAddress, isOnline: false)
                    }
                }
            }
        }
    }

    private func startMaintenanceLoop() {
        maintenanceTask = Task {
            // FIX #1440: Run proactive online check immediately (don't wait 30s)
            await checkAllContactsOnline()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds

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

                // Check for stale connections (no activity for 2 minutes)
                let staleThreshold = Date().addingTimeInterval(-120)
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
                            // Silently fail — contact is genuinely offline
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

        // FIX #1369: Reset all contacts to offline on startup — no connections exist yet.
        // isOnline was persisted to disk from the previous session but is stale.
        for i in contacts.indices {
            if contacts[i].isOnline {
                contacts[i].isOnline = false
                database.saveContact(contacts[i])
            }
        }

        for contact in contacts {
            var conversation = ChatConversation(contact: contact)
            conversation.messages = database.loadMessages(for: contact.onionAddress)
            conversations[contact.onionAddress] = conversation
        }

        totalUnreadCount = contacts.reduce(0) { $0 + $1.unreadCount }

        // FIX #1436: Load profile image from disk
        loadProfileImage()
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

    /// FIX #249 v2: Load message queue from UserDefaults (encrypted + expiry filter)
    private func loadMessageQueue() async {
        // Ensure we have encryption key
        guard let key = getOrCreateQueueEncryptionKey() else {
            print("💬 FIX #249: Failed to get queue encryption key")
            return
        }

        // Load encrypted data
        guard let encryptedData = UserDefaults.standard.data(forKey: messageQueueKey) else {
            print("💬 FIX #249: No message queue found")
            return
        }

        // Decrypt
        guard let decryptedData = decryptQueueData(encryptedData, using: key) else {
            print("💬 FIX #249: Failed to decrypt message queue - may be corrupted or old format")
            // Clear corrupted queue
            UserDefaults.standard.removeObject(forKey: messageQueueKey)
            return
        }

        // Decode
        guard let queue = try? JSONDecoder().decode([String: [ChatMessage]].self, from: decryptedData) else {
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

    /// FIX #249 v2: Save message queue to UserDefaults (encrypted with ChaChaPoly)
    private func saveMessageQueue() {
        // Ensure we have encryption key
        guard let key = getOrCreateQueueEncryptionKey() else {
            print("💬 FIX #249: Failed to get queue encryption key - cannot save queue")
            return
        }

        // Encode to JSON
        guard let jsonData = try? JSONEncoder().encode(messageQueue) else {
            print("💬 FIX #249: Failed to encode message queue")
            return
        }

        // Encrypt with ChaChaPoly
        guard let encryptedData = encryptQueueData(jsonData, using: key) else {
            print("💬 FIX #249: Failed to encrypt message queue")
            return
        }

        UserDefaults.standard.set(encryptedData, forKey: messageQueueKey)
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

        print("💬 FIX #249: Retrying queued messages for \(messageQueue.keys.count) contact(s)")

        for onionAddress in messageQueue.keys {
            // Find the contact
            guard let contact = contacts.first(where: { $0.onionAddress == onionAddress }) else {
                continue
            }

            // Try to flush queue for this contact
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

    func saveContact(_ contact: ChatContact) {
        WalletDatabase.shared.saveChatContact(
            onionAddress: contact.onionAddress,
            nickname: contact.nickname.isEmpty ? nil : contact.nickname,
            unreadCount: contact.unreadCount,
            lastMessageTime: nil
        )
    }

    func loadContacts() -> [ChatContact] {
        let rows = WalletDatabase.shared.loadChatContacts()
        return rows.map { row in
            var contact = ChatContact(onionAddress: row.onionAddress, nickname: row.nickname ?? "")
            contact.unreadCount = row.unreadCount
            contact.isBlocked = row.isBlocked
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
            replyToId: message.replyTo
        )
    }

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
                type: type,
                fromOnion: row.fromOnion,
                toOnion: row.toOnion,
                content: row.content,
                replyTo: row.replyToId,
                status: status
            )
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let chatTypingIndicator = Notification.Name("chatTypingIndicator")
    static let chatMessageDelivered = Notification.Name("chatMessageDelivered")
    static let chatMessageRead = Notification.Name("chatMessageRead")
}
