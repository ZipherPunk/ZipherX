//
//  CypherpunkChat.swift
//  ZipherX
//
//  Created by ZipherX Team on 2025-12-09.
//  Cypherpunk P2P Chat - Encrypted messaging over Tor hidden services
//
//  "We the Cypherpunks are dedicated to building anonymous systems.
//   We are defending our privacy with cryptography."
//  - A Cypherpunk's Manifesto, Eric Hughes, 1993
//

import Foundation
import CryptoKit

// MARK: - Chat Constants

/// Chat uses a separate port from P2P blockchain sync
/// Port 8033 = P2P blockchain
/// Port 8034 = Cypherpunk Chat
let CYPHERPUNK_CHAT_PORT: UInt16 = 8034

// MARK: - Message Types

/// Types of messages in the Cypherpunk Chat protocol
enum ChatMessageType: String, Codable {
    case text = "text"              // Regular text message
    case paymentRequest = "pay_req" // ZCL payment request
    case paymentSent = "pay_sent"   // Notification that payment was sent
    case typing = "typing"          // User is typing indicator
    case delivered = "delivered"    // Message delivery confirmation
    case read = "read"              // Message read receipt
    case ping = "ping"              // Presence check
    case pong = "pong"              // Presence response
    case nickname = "nickname"      // Nickname announcement
    case goodbye = "goodbye"        // User going offline
}

// MARK: - Message Status

/// Delivery and read status for messages (Signal/WhatsApp style, cypherpunk themed)
enum MessageStatus: String, Codable {
    case sending = "sending"        // ⏳ Message being encrypted and sent
    case sent = "sent"              // ⚡ Message sent to peer's hidden service
    case delivered = "delivered"    // 🔐 Peer received and decrypted
    case read = "read"              // 👁 Peer opened the message
    case failed = "failed"          // ❌ Failed to send

    /// Cypherpunk-style status indicator
    var indicator: String {
        switch self {
        case .sending:   return "⏳"  // Encrypting...
        case .sent:      return "⚡"  // Sent through Tor
        case .delivered: return "🔐"  // Decrypted by peer
        case .read:      return "👁"   // Eyes on message
        case .failed:    return "❌"  // Failed
        }
    }

    /// Alternative: ZipherX shield icon style (for UI)
    var shieldIndicator: String {
        switch self {
        case .sending:   return "◌"   // Empty circle
        case .sent:      return "◐"   // Half filled
        case .delivered: return "●"   // Filled circle
        case .read:      return "◉"   // Double circle (like double check)
        case .failed:    return "⊘"   // Prohibited
        }
    }

    /// Description for accessibility
    var description: String {
        switch self {
        case .sending:   return "Encrypting and sending..."
        case .sent:      return "Sent via Tor"
        case .delivered: return "Delivered and decrypted"
        case .read:      return "Seen by recipient"
        case .failed:    return "Failed to send"
        }
    }
}

// MARK: - Chat Message

/// A message in the Cypherpunk Chat protocol
/// All messages are end-to-end encrypted before transmission
struct ChatMessage: Codable, Identifiable {
    let id: String                      // UUID for this message
    let type: ChatMessageType           // Message type
    let fromOnion: String               // Sender's .onion address
    let toOnion: String                 // Recipient's .onion address
    let timestamp: Date                 // When message was created
    let content: String                 // Message content (encrypted in transit)
    let nickname: String?               // Sender's nickname (optional)
    let paymentAddress: String?         // Z-address for payment requests
    let paymentAmount: UInt64?          // Amount in zatoshis for payment requests
    let ttl: TimeInterval?              // Time-to-live (self-destruct timer)
    let replyTo: String?                // ID of message being replied to
    var status: MessageStatus           // Delivery/read status (mutable for updates)
    var deliveredAt: Date?              // When message was delivered
    var readAt: Date?                   // When message was read

    init(
        type: ChatMessageType,
        fromOnion: String,
        toOnion: String,
        content: String,
        nickname: String? = nil,
        paymentAddress: String? = nil,
        paymentAmount: UInt64? = nil,
        ttl: TimeInterval? = nil,
        replyTo: String? = nil,
        status: MessageStatus = .sending
    ) {
        self.id = UUID().uuidString
        self.type = type
        self.fromOnion = fromOnion
        self.toOnion = toOnion
        self.timestamp = Date()
        self.content = content
        self.nickname = nickname
        self.paymentAddress = paymentAddress
        self.paymentAmount = paymentAmount
        self.ttl = ttl
        self.replyTo = replyTo
        self.status = status
        self.deliveredAt = nil
        self.readAt = nil
    }

    /// Check if message has expired (TTL)
    var isExpired: Bool {
        guard let ttl = ttl else { return false }
        return Date().timeIntervalSince(timestamp) > ttl
    }

    /// Format amount for display
    var formattedAmount: String? {
        guard let amount = paymentAmount else { return nil }
        let zcl = Double(amount) / 100_000_000.0
        return String(format: "%.8f ZCL", zcl)
    }

    /// Update status to delivered
    mutating func markDelivered() {
        status = .delivered
        deliveredAt = Date()
    }

    /// Update status to read
    mutating func markRead() {
        status = .read
        readAt = Date()
    }

    /// Update status to sent
    mutating func markSent() {
        status = .sent
    }

    /// Update status to failed
    mutating func markFailed() {
        status = .failed
    }
}

// MARK: - Contact

/// A contact in the Cypherpunk Chat
struct ChatContact: Codable, Identifiable, Hashable {
    let id: String                  // UUID
    let onionAddress: String        // Their .onion address (primary identifier)
    var nickname: String            // User-assigned nickname
    var lastSeen: Date?             // Last time they were online
    var isOnline: Bool              // Current online status
    var unreadCount: Int            // Number of unread messages
    var isFavorite: Bool            // Starred contact
    var addedAt: Date               // When contact was added
    var notes: String?              // User notes about contact

    init(onionAddress: String, nickname: String) {
        self.id = UUID().uuidString
        self.onionAddress = onionAddress
        self.nickname = nickname
        self.lastSeen = nil
        self.isOnline = false
        self.unreadCount = 0
        self.isFavorite = false
        self.addedAt = Date()
        self.notes = nil
    }

    /// Display name (nickname or truncated onion address)
    var displayName: String {
        if !nickname.isEmpty {
            return nickname
        }
        // Show first 8 chars of onion address
        let prefix = String(onionAddress.prefix(8))
        return "\(prefix)..."
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(onionAddress)
    }

    static func == (lhs: ChatContact, rhs: ChatContact) -> Bool {
        lhs.onionAddress == rhs.onionAddress
    }
}

// MARK: - Conversation

/// A conversation thread with a contact
struct ChatConversation: Identifiable {
    let id: String
    let contact: ChatContact
    var messages: [ChatMessage]
    var lastMessage: ChatMessage? { messages.last }
    var lastActivity: Date { lastMessage?.timestamp ?? contact.addedAt }

    init(contact: ChatContact) {
        self.id = contact.onionAddress
        self.contact = contact
        self.messages = []
    }
}

// MARK: - Encryption

/// End-to-end encryption for chat messages using ChaChaPoly
/// Each contact pair generates a shared secret via X25519 key exchange
class ChatEncryption {

    /// Generate a new X25519 key pair for chat encryption
    static func generateKeyPair() -> (privateKey: Curve25519.KeyAgreement.PrivateKey, publicKey: Curve25519.KeyAgreement.PublicKey) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return (privateKey, privateKey.publicKey)
    }

    /// Derive shared secret from our private key and their public key
    static func deriveSharedSecret(
        ourPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        theirPublicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> SymmetricKey {
        let sharedSecret = try ourPrivateKey.sharedSecretFromKeyAgreement(with: theirPublicKey)

        // Derive symmetric key using HKDF
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("ZipherX-CypherpunkChat-v1".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )

        return symmetricKey
    }

    /// Encrypt a message using ChaChaPoly
    static func encrypt(message: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try ChaChaPoly.seal(message, using: key)
        return sealedBox.combined
    }

    /// Decrypt a message using ChaChaPoly
    static func decrypt(ciphertext: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try ChaChaPoly.SealedBox(combined: ciphertext)
        return try ChaChaPoly.open(sealedBox, using: key)
    }

    /// Encrypt a ChatMessage for transmission
    static func encryptMessage(_ message: ChatMessage, using key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        let messageData = try encoder.encode(message)
        return try encrypt(message: messageData, using: key)
    }

    /// Decrypt a ChatMessage from received data
    static func decryptMessage(_ ciphertext: Data, using key: SymmetricKey) throws -> ChatMessage {
        let messageData = try decrypt(ciphertext: ciphertext, using: key)
        let decoder = JSONDecoder()
        return try decoder.decode(ChatMessage.self, from: messageData)
    }
}

// MARK: - Protocol Constants

/// Wire protocol for Cypherpunk Chat
/// Message format: [4 bytes: length][1 byte: version][N bytes: encrypted payload]
struct ChatProtocol {
    static let VERSION: UInt8 = 1
    static let MAX_MESSAGE_SIZE: UInt32 = 65536  // 64KB max message
    static let HEADER_SIZE: Int = 5              // 4 bytes length + 1 byte version

    /// Encode a message for wire transmission
    static func encode(encryptedPayload: Data) -> Data {
        var data = Data()

        // 4 bytes: payload length (big-endian)
        var length = UInt32(encryptedPayload.count).bigEndian
        data.append(Data(bytes: &length, count: 4))

        // 1 byte: protocol version
        data.append(VERSION)

        // N bytes: encrypted payload
        data.append(encryptedPayload)

        return data
    }

    /// Decode wire data and extract encrypted payload
    static func decode(_ data: Data) throws -> Data {
        guard data.count >= HEADER_SIZE else {
            throw ChatError.invalidMessage("Message too short")
        }

        // Read length
        let lengthBytes = data.prefix(4)
        let length = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        guard length <= MAX_MESSAGE_SIZE else {
            throw ChatError.invalidMessage("Message too large")
        }

        // Check version
        let version = data[4]
        guard version == VERSION else {
            throw ChatError.invalidMessage("Unknown protocol version: \(version)")
        }

        // Extract payload
        let payloadStart = HEADER_SIZE
        let payloadEnd = payloadStart + Int(length)

        guard data.count >= payloadEnd else {
            throw ChatError.invalidMessage("Incomplete message")
        }

        return data.subdata(in: payloadStart..<payloadEnd)
    }
}

// MARK: - Errors

enum ChatError: Error, LocalizedError {
    case notConnected
    case invalidMessage(String)
    case encryptionFailed(String)
    case contactNotFound
    case hiddenServiceNotRunning
    case torNotConnected
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to peer"
        case .invalidMessage(let reason):
            return "Invalid message: \(reason)"
        case .encryptionFailed(let reason):
            return "Encryption failed: \(reason)"
        case .contactNotFound:
            return "Contact not found"
        case .hiddenServiceNotRunning:
            return "Hidden service not running. Enable it in Settings."
        case .torNotConnected:
            return "Tor not connected"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        }
    }
}

// MARK: - Cypherpunk Quotes for Chat

/// Random cypherpunk quotes to display in chat UI
let cypherpunkChatQuotes = [
    "Privacy is necessary for an open society in the electronic age.",
    "We the Cypherpunks are dedicated to building anonymous systems.",
    "Privacy is the power to selectively reveal oneself to the world.",
    "Cypherpunks write code. We know that software can't be destroyed.",
    "We must defend our own privacy if we expect to have any.",
    "Privacy in an open society requires anonymous transaction systems.",
    "We are defending our privacy with cryptography.",
    "Cypherpunks deplore regulations on cryptography.",
    "We know that someone has to write software to defend privacy.",
    "The Cypherpunks are actively engaged in making the networks safer for privacy.",
    "Cryptography is the ultimate form of non-violent direct action.",
    "Information wants to be free. Information also wants to be expensive.",
    "A cypherpunk is someone who uses cryptography to protect their privacy.",
    "We don't much care if you don't approve of the software we write.",
    "Code speaks. Talk is cheap.",
]

/// Get a random cypherpunk quote
func randomCypherpunkQuote() -> String {
    cypherpunkChatQuotes.randomElement() ?? cypherpunkChatQuotes[0]
}
