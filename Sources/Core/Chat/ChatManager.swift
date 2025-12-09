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

    // MARK: - Initialization

    private init() {
        self.ourNickname = UserDefaults.standard.string(forKey: "chatNickname") ?? ""
        self.database = ChatDatabase()

        // Load contacts and conversations from database
        Task {
            await loadPersistentData()
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

    /// Connect to a contact
    func connect(to contact: ChatContact) async throws {
        guard isAvailable else {
            throw ChatError.hiddenServiceNotRunning
        }

        // Check if already connected
        if let peer = peers[contact.onionAddress], await peer.state.isConnected {
            return
        }

        print("💬 Connecting to \(contact.displayName)...")

        // Create connection through Tor SOCKS5 proxy
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(contact.onionAddress),
            port: NWEndpoint.Port(integerLiteral: CYPHERPUNK_CHAT_PORT)
        )

        // Use Tor SOCKS5 proxy
        let proxyConfig = NWProtocolTLS.Options()
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30

        let params = NWParameters(tls: nil, tcp: tcpOptions)

        // Configure SOCKS5 proxy for Tor
        if let proxyEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9050) as NWEndpoint? {
            // Note: NWConnection SOCKS5 support requires custom implementation
            // For now, we'll use the direct connection through arti's SOCKS proxy
        }

        let connection = NWConnection(to: endpoint, using: params)
        let peer = ChatPeer(onionAddress: contact.onionAddress, connection: connection)

        await peer.setState(.connecting)
        peers[contact.onionAddress] = peer

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                await self?.handleConnectionState(state, for: contact.onionAddress)
            }
        }

        connection.start(queue: networkQueue)

        // Wait for connection with timeout
        try await withTimeout(seconds: 30) {
            while await peer.state == .connecting {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        guard await peer.state.isConnected else {
            if case .failed(let reason) = await peer.state {
                throw ChatError.notConnected
            }
            throw ChatError.notConnected
        }

        // Perform key exchange
        try await performKeyExchange(with: peer)

        // Send our nickname
        if !ourNickname.isEmpty {
            try await sendNickname(to: contact)
        }

        updateContactOnlineStatus(contact.onionAddress, isOnline: true)
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

        // Add to conversation immediately (shows as "sending")
        addMessageToConversation(message)

        do {
            try await sendMessage(message, to: contact)

            // Update status to sent
            message.markSent()
            updateMessageInConversation(message)

            // Persist with sent status
            database.saveMessage(message)
        } catch {
            // Update status to failed
            message.markFailed()
            updateMessageInConversation(message)
            database.saveMessage(message)
            throw error
        }
    }

    /// Send a payment request
    func sendPaymentRequest(
        to contact: ChatContact,
        amount: UInt64,
        address: String,
        memo: String?
    ) async throws {
        let message = ChatMessage(
            type: .paymentRequest,
            fromOnion: ourOnionAddress ?? "",
            toOnion: contact.onionAddress,
            content: memo ?? "Payment request",
            nickname: ourNickname.isEmpty ? nil : ourNickname,
            paymentAddress: address,
            paymentAmount: amount
        )

        try await sendMessage(message, to: contact)
        addMessageToConversation(message)
        database.saveMessage(message)
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
            totalUnreadCount -= updatedContact.unreadCount
            updatedContact.unreadCount = 0
            contacts[index] = updatedContact
            conversation = ChatConversation(contact: updatedContact)
            conversation.messages = conversations[contact.onionAddress]?.messages ?? []
            conversations[contact.onionAddress] = conversation
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

        // Auto-add as contact if not exists
        if !contacts.contains(where: { $0.onionAddress == onionAddress }) {
            let contact = ChatContact(onionAddress: onionAddress, nickname: "")
            contacts.append(contact)
            conversations[onionAddress] = ChatConversation(contact: contact)
            database.saveContact(contact)
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

        // Receive their public key
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
        await peer.setState(.connected)

        // Start receiving messages
        receiveMessages(from: peer)
    }

    private func receiveMessages(from peer: ChatPeer) {
        Task {
            while await peer.state.isConnected {
                do {
                    let data = try await receiveData(from: peer)
                    try await processReceivedData(data, from: peer)
                } catch {
                    print("💬 Receive error: \(error)")
                    break
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
                let length = headerData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

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
        switch message.type {
        case .text, .paymentRequest, .paymentSent:
            addMessageToConversation(message)
            database.saveMessage(message)

            // Update unread count
            if selectedConversation != message.fromOnion {
                incrementUnreadCount(for: message.fromOnion)
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

        case .goodbye:
            // Peer is disconnecting
            updateContactOnlineStatus(message.fromOnion, isOnline: false)
        }
    }

    private func sendMessage(_ message: ChatMessage, to contact: ChatContact) async throws {
        // Check if connected, if not, try to connect
        var isConnected = false
        if let peer = peers[contact.onionAddress] {
            isConnected = await peer.state.isConnected
        }
        if !isConnected {
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.connection.send(content: wireData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
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
            contact.isOnline = isOnline
            if isOnline {
                contact.lastSeen = Date()
            }
            contacts[index] = contact
            database.saveContact(contact)
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
                database.saveMessage(message)
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
                database.saveMessage(message)
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

    private func startMaintenanceLoop() {
        maintenanceTask = Task {
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
            }
        }
    }

    private func loadPersistentData() async {
        contacts = database.loadContacts()

        for contact in contacts {
            var conversation = ChatConversation(contact: contact)
            conversation.messages = database.loadMessages(for: contact.onionAddress)
            conversations[contact.onionAddress] = conversation
        }

        totalUnreadCount = contacts.reduce(0) { $0 + $1.unreadCount }
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

/// Simple database for chat persistence
class ChatDatabase {
    private let contactsKey = "chat_contacts"
    private let messagesPrefix = "chat_messages_"

    func saveContact(_ contact: ChatContact) {
        var contacts = loadContacts()
        if let index = contacts.firstIndex(where: { $0.onionAddress == contact.onionAddress }) {
            contacts[index] = contact
        } else {
            contacts.append(contact)
        }

        if let data = try? JSONEncoder().encode(contacts) {
            UserDefaults.standard.set(data, forKey: contactsKey)
        }
    }

    func loadContacts() -> [ChatContact] {
        guard let data = UserDefaults.standard.data(forKey: contactsKey),
              let contacts = try? JSONDecoder().decode([ChatContact].self, from: data) else {
            return []
        }
        return contacts
    }

    func deleteContact(_ contact: ChatContact) {
        var contacts = loadContacts()
        contacts.removeAll { $0.onionAddress == contact.onionAddress }

        if let data = try? JSONEncoder().encode(contacts) {
            UserDefaults.standard.set(data, forKey: contactsKey)
        }

        // Delete messages
        UserDefaults.standard.removeObject(forKey: messagesPrefix + contact.onionAddress)
    }

    func saveMessage(_ message: ChatMessage) {
        let onion = message.fromOnion.contains(".onion") ? message.fromOnion : message.toOnion
        var messages = loadMessages(for: onion)
        messages.append(message)

        // Keep only last 1000 messages per conversation
        if messages.count > 1000 {
            messages = Array(messages.suffix(1000))
        }

        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: messagesPrefix + onion)
        }
    }

    func loadMessages(for onionAddress: String) -> [ChatMessage] {
        guard let data = UserDefaults.standard.data(forKey: messagesPrefix + onionAddress),
              let messages = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return []
        }
        return messages
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let chatTypingIndicator = Notification.Name("chatTypingIndicator")
    static let chatMessageDelivered = Notification.Name("chatMessageDelivered")
    static let chatMessageRead = Notification.Name("chatMessageRead")
}
