//
//  ChatView.swift
//  ZipherX
//
//  Created by ZipherX Team on 2025-12-09.
//  Cypherpunk P2P Chat UI - Encrypted messaging over Tor
//
//  "Privacy is necessary for an open society in the electronic age."
//  - A Cypherpunk's Manifesto
//

import SwiftUI

// MARK: - Main Chat View

/// Main chat view with contact list and conversation
struct ChatView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var networkManager: NetworkManager
    @StateObject private var chatManager = ChatManager.shared
    @StateObject private var torManager = TorManager.shared

    @State private var showAddContact = false
    @State private var showSettings = false
    @State private var selectedContact: ChatContact?
    @State private var noContactsQuote: String = ""  // Store quote to prevent loop

    // FIX #252: Callback to navigate to main app settings (for enabling Tor)
    var onShowAppSettings: (() -> Void)?

    private var theme: AppTheme { themeManager.currentTheme }

    // FIX #243: Minimum peers required for stable chat
    private let minimumPeersForChat = 4

    /// Check if we have enough peers for stable chat
    private var hasEnoughPeers: Bool {
        networkManager.connectedPeers >= minimumPeersForChat
    }

    /// FIX #244: Check if Tor is enabled (required for chat)
    private var isTorEnabled: Bool {
        torManager.mode == .enabled
    }

    var body: some View {
        // FIX #244: Show cypherpunk warning if Tor is disabled
        if !isTorEnabled {
            torRequiredView
        } else {
            #if os(iOS)
            NavigationView {
                iOSContactListView
            }
            .navigationViewStyle(.stack)
            .sheet(isPresented: $showAddContact) {
                AddContactSheet()
            }
            .sheet(isPresented: $showSettings) {
                ChatSettingsSheet()
            }
            .onAppear {
                autoStartChatIfNeeded()
            }
            #else
            NavigationView {
                contactListView
                    .frame(minWidth: 280, maxWidth: 320)

                if let contact = selectedContact {
                    ConversationView(contact: contact)
                } else {
                    emptyStateView
                }
            }
            .sheet(isPresented: $showAddContact) {
                AddContactSheet()
                    .frame(minWidth: 420, idealWidth: 450, minHeight: 520, idealHeight: 560)
            }
            .sheet(isPresented: $showSettings) {
                ChatSettingsSheet()
                    .frame(minWidth: 450, idealWidth: 500, minHeight: 550, idealHeight: 600)
            }
            .onAppear {
                autoStartChatIfNeeded()
            }
            #endif
        }
    }

    // MARK: - FIX #244: Tor Required View

    /// Cypherpunk-style warning when Tor is disabled
    private var torRequiredView: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 18))
                        .foregroundColor(theme.accentColor.opacity(0.5))
                    Text("ENCRYPTED CHAT")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 16)

                Divider()
                    .background(theme.accentColor.opacity(0.3))
            }

            Spacer()

            // Cypherpunk warning
            VStack(spacing: 24) {
                // Onion icon with lock
                ZStack {
                    Circle()
                        .stroke(Color.orange.opacity(0.3), lineWidth: 2)
                        .frame(width: 120, height: 120)

                    Circle()
                        .stroke(Color.orange.opacity(0.15), lineWidth: 1)
                        .frame(width: 150, height: 150)

                    Image(systemName: "network.slash")
                        .font(.system(size: 50))
                        .foregroundColor(Color.orange.opacity(0.6))
                }

                VStack(spacing: 16) {
                    Text("🧅 TOR REQUIRED")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)

                    VStack(spacing: 12) {
                        Text("Chat uses .onion addresses for\nend-to-end encrypted messaging.")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(theme.textPrimary.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)

                        Text("Without Tor, your identity and\nmessages cannot be protected.")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(Color.orange.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                    }
                }

                // Cypherpunk quote
                VStack(spacing: 8) {
                    Text("\"Privacy is necessary for an")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.accentColor.opacity(0.6))
                    Text("open society in the electronic age.\"")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.accentColor.opacity(0.6))
                    Text("— A Cypherpunk's Manifesto")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.textPrimary.opacity(0.4))
                        .padding(.top, 4)
                }
                .padding(.top, 8)

                // Enable Tor button
                // FIX #252: Navigate to main app settings (not chat settings)
                Button(action: {
                    onShowAppSettings?()
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "network")
                            .font(.system(size: 14))
                        Text("ENABLE TOR IN SETTINGS")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.orange)
                            .shadow(color: Color.orange.opacity(0.4), radius: 8)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .background(
            LinearGradient(
                colors: [theme.backgroundColor, theme.backgroundColor.opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        // FIX #252: Removed sheet - now uses onShowAppSettings callback to navigate to main app settings
    }

    // MARK: - Auto-start Chat

    /// Automatically start chat service when Hidden Service is running
    private func autoStartChatIfNeeded() {
        Task {
            // Check if Hidden Service is running
            let hsState = await HiddenServiceManager.shared.state
            guard hsState == .running else {
                print("💬 Chat: Hidden Service not running (state: \(hsState)), chat cannot start")
                return
            }

            // Only auto-start if not already available
            guard !chatManager.isAvailable else {
                print("💬 Chat: Already available")
                return
            }

            do {
                try await chatManager.start()
                print("💬 Chat: Auto-started successfully")
            } catch {
                print("💬 Chat: Auto-start failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Contact List

    private var contactListView: some View {
        VStack(spacing: 0) {
            // Cypherpunk Header
            cypherpunkHeader

            // Status bar
            statusBar

            Divider()
                .background(theme.accentColor.opacity(0.3))

            // Contact list
            if chatManager.contacts.isEmpty {
                noContactsView
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(chatManager.contacts) { contact in
                            ContactRow(contact: contact, isSelected: selectedContact?.id == contact.id)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedContact = contact
                                    }
                                }
                                .contextMenu {
                                    Button(action: { toggleFavorite(contact) }) {
                                        Label(contact.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                              systemImage: contact.isFavorite ? "star.slash" : "star")
                                    }
                                    Button(role: .destructive, action: { deleteContact(contact) }) {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(
            LinearGradient(
                colors: [theme.backgroundColor, theme.backgroundColor.opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showAddContact = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
                        .foregroundColor(theme.textPrimary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - iOS Contact List (with NavigationLink for proper push navigation)

    #if os(iOS)
    private var iOSContactListView: some View {
        VStack(spacing: 0) {
            // Cypherpunk Header
            cypherpunkHeader

            // Status bar
            statusBar

            Divider()
                .background(theme.accentColor.opacity(0.3))

            // Contact list with NavigationLinks
            if chatManager.contacts.isEmpty {
                noContactsView
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(chatManager.contacts) { contact in
                            NavigationLink(destination: ConversationView(contact: contact)) {
                                ContactRow(contact: contact, isSelected: false)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(action: { toggleFavorite(contact) }) {
                                    Label(contact.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                          systemImage: contact.isFavorite ? "star.slash" : "star")
                                }
                                Button(role: .destructive, action: { deleteContact(contact) }) {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(
            LinearGradient(
                colors: [theme.backgroundColor, theme.backgroundColor.opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showAddContact = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
                        .foregroundColor(theme.textPrimary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
    }
    #endif

    private var cypherpunkHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Animated lock icon
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 18))
                    .foregroundColor(theme.accentColor)
                    .shadow(color: theme.accentColor.opacity(0.5), radius: 4)

                Text("ZIPHERPUNK CHAT")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundColor(theme.accentColor)
                    .shadow(color: theme.accentColor.opacity(0.3), radius: 2)
            }

            if let onion = chatManager.ourOnionAddress {
                HStack(spacing: 4) {
                    Image(systemName: "network")
                        .font(.system(size: 8))
                        .foregroundColor(theme.accentColor.opacity(0.6))
                    Text(onion.prefix(20) + "...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.textPrimary.opacity(0.5))
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.4), Color.black.opacity(0.2)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            // FIX #243: Warning when not enough peers for stable chat
            if !hasEnoughPeers {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("Unstable: Need \(minimumPeersForChat) peers, have \(networkManager.connectedPeers)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.orange)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.15))
            }

            HStack(spacing: 12) {
                // Online status with pulse animation
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(chatStatusColor)
                            .frame(width: 10, height: 10)

                        if chatManager.isAvailable && hasEnoughPeers {
                            Circle()
                                .stroke(theme.accentColor, lineWidth: 2)
                                .frame(width: 16, height: 16)
                                .opacity(0.5)
                                .scaleEffect(1.2)
                        }
                    }

                    Text(chatStatusText)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(chatStatusColor)
                }

                Spacer()

                // Unread badge
                if chatManager.totalUnreadCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 10))
                        Text("\(chatManager.totalUnreadCount)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.red)
                            .shadow(color: Color.red.opacity(0.4), radius: 4)
                    )
                }

                // Peer count
                Text("\(networkManager.connectedPeers) peers")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(hasEnoughPeers ? theme.textPrimary.opacity(0.4) : .orange)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.15))
        }
    }

    // FIX #243: Chat status color based on peers and availability
    private var chatStatusColor: Color {
        if !chatManager.isAvailable {
            return Color.red
        } else if !hasEnoughPeers {
            return Color.orange
        } else {
            return theme.accentColor
        }
    }

    // FIX #243: Chat status text based on peers and availability
    private var chatStatusText: String {
        if !chatManager.isAvailable {
            return "OFFLINE"
        } else if !hasEnoughPeers {
            return "UNSTABLE"
        } else {
            return "ONLINE"
        }
    }

    private var noContactsView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Animated icon
            ZStack {
                Circle()
                    .stroke(theme.accentColor.opacity(0.2), lineWidth: 2)
                    .frame(width: 100, height: 100)

                Circle()
                    .stroke(theme.accentColor.opacity(0.1), lineWidth: 1)
                    .frame(width: 120, height: 120)

                Image(systemName: "person.2.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(theme.accentColor.opacity(0.4))
            }

            VStack(spacing: 8) {
                Text("No Contacts Yet")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary.opacity(0.8))

                Text("Add a contact by their .onion address\nto start a secure conversation")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.textPrimary.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Button(action: { showAddContact = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                    Text("ADD CONTACT")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [theme.accentColor, theme.accentColor.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(10)
                .shadow(color: theme.accentColor.opacity(0.4), radius: 8, y: 4)
            }
            .buttonStyle(.plain)

            Spacer()

            // Cypherpunk quote (stored to prevent loop)
            VStack(spacing: 8) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 16))
                    .foregroundColor(theme.accentColor.opacity(0.4))

                Text(noContactsQuote.isEmpty ? "Privacy is necessary for an open society." : noContactsQuote)
                    .font(.system(size: 11, weight: .light, design: .monospaced))
                    .foregroundColor(theme.accentColor.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
            .onAppear {
                if noContactsQuote.isEmpty {
                    noContactsQuote = randomCypherpunkQuote()
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                // Background circles
                Circle()
                    .stroke(theme.accentColor.opacity(0.1), lineWidth: 1)
                    .frame(width: 180, height: 180)

                Circle()
                    .stroke(theme.accentColor.opacity(0.15), lineWidth: 1)
                    .frame(width: 140, height: 140)

                Circle()
                    .stroke(theme.accentColor.opacity(0.2), lineWidth: 1)
                    .frame(width: 100, height: 100)

                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 48))
                    .foregroundColor(theme.accentColor.opacity(0.4))
            }

            VStack(spacing: 8) {
                Text("Select a Contact")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary.opacity(0.7))

                Text("Choose a contact from the list\nto start an encrypted conversation")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(theme.textPrimary.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Spacer()

            // Security badge
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12))
                Text("End-to-End Encrypted via Tor")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundColor(theme.accentColor.opacity(0.5))
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.backgroundColor)
    }

    private func deleteContact(_ contact: ChatContact) {
        chatManager.removeContact(contact)
        if selectedContact?.id == contact.id {
            selectedContact = nil
        }
    }

    private func toggleFavorite(_ contact: ChatContact) {
        chatManager.toggleFavorite(contact)
    }
}

// MARK: - Contact Row

struct ContactRow: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let contact: ChatContact
    let isSelected: Bool

    private var theme: AppTheme { themeManager.currentTheme }

    // Generate consistent gradient colors based on contact name
    private var avatarGradient: [Color] {
        let hash = abs(contact.displayName.hashValue)
        let hue1 = Double(hash % 360) / 360.0
        let hue2 = Double((hash + 40) % 360) / 360.0
        return [
            Color(hue: hue1, saturation: 0.7, brightness: 0.8),
            Color(hue: hue2, saturation: 0.6, brightness: 0.6)
        ]
    }

    var body: some View {
        HStack(spacing: 14) {
            // Gradient Avatar with online indicator
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: avatarGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)
                    .overlay(
                        Text(contact.displayName.prefix(1).uppercased())
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.2), radius: 1)
                    )
                    .shadow(color: avatarGradient[0].opacity(0.3), radius: 4, y: 2)

                // Online indicator with pulse
                if contact.isOnline {
                    ZStack {
                        Circle()
                            .fill(theme.accentColor)
                            .frame(width: 14, height: 14)
                        Circle()
                            .stroke(theme.backgroundColor, lineWidth: 2)
                            .frame(width: 14, height: 14)
                    }
                    .offset(x: 2, y: 2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(contact.displayName)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.textPrimary)
                        .lineLimit(1)

                    if contact.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.yellow)
                    }
                }

                // Onion address preview
                HStack(spacing: 4) {
                    Image(systemName: "network")
                        .font(.system(size: 8))
                        .foregroundColor(theme.accentColor.opacity(0.5))
                    Text(contact.onionAddress.prefix(16) + "...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.textPrimary.opacity(0.4))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                // Unread badge
                if contact.unreadCount > 0 {
                    Text("\(contact.unreadCount)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(
                            Circle()
                                .fill(theme.accentColor)
                                .shadow(color: theme.accentColor.opacity(0.4), radius: 3)
                        )
                }

                // Last seen
                if let lastSeen = contact.lastSeen {
                    Text(lastSeenText(lastSeen))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.textPrimary.opacity(0.35))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? theme.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? theme.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private func lastSeenText(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h"
        } else {
            return "\(Int(interval / 86400))d"
        }
    }
}

// MARK: - Conversation View

struct ConversationView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var networkManager: NetworkManager
    @StateObject private var chatManager = ChatManager.shared

    let contact: ChatContact

    @State private var messageText = ""
    @State private var isTyping = false
    @State private var showPaymentRequest = false
    @State private var paymentRequestToPay: ChatMessage? = nil  // Payment request being paid
    @State private var showPayNowSheet = false
    @State private var copiedTxId: String? = nil  // FIX #405: Track copied txid for feedback
    @FocusState private var isInputFocused: Bool

    private var theme: AppTheme { themeManager.currentTheme }

    // FIX #243: Minimum peers required for stable chat
    private let minimumPeersForChat = 4
    private var hasEnoughPeers: Bool { networkManager.connectedPeers >= minimumPeersForChat }

    var body: some View {
        VStack(spacing: 0) {
            // Conversation header
            conversationHeader

            Divider()
                .background(theme.accentColor.opacity(0.2))

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if let conversation = chatManager.conversations[contact.onionAddress] {
                            ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                                // Date separator
                                if shouldShowDateSeparator(at: index, in: conversation.messages) {
                                    DateSeparator(date: message.timestamp)
                                }

                                // FIX #219: Check if this payment request has been paid
                                let isPaid = message.type == .paymentRequest && conversation.messages.contains {
                                    ($0.type == .paymentSent) && ($0.replyTo == message.id)
                                }

                                MessageBubble(
                                    message: message,
                                    isFromMe: message.fromOnion == chatManager.ourOnionAddress,
                                    isPaid: isPaid,
                                    onPayNow: { paymentMsg in
                                        paymentRequestToPay = paymentMsg
                                        showPayNowSheet = true
                                    }
                                )
                                    .id(message.id)
                                    .transition(.asymmetric(
                                        insertion: .scale(scale: 0.9).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                            }
                        }

                        if isTyping {
                            TypingIndicator()
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                }
                .onChange(of: chatManager.conversations[contact.onionAddress]?.messages.count) { _ in
                    if let lastMessage = chatManager.conversations[contact.onionAddress]?.messages.last {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            .background(
                // Subtle pattern background
                LinearGradient(
                    colors: [theme.backgroundColor, theme.backgroundColor.opacity(0.98)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Divider()
                .background(theme.accentColor.opacity(0.2))

            // Input bar
            inputBar
        }
        .background(theme.backgroundColor)
        .onAppear {
            chatManager.markAsRead(contact: contact)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatTypingIndicator)) { notification in
            if let onion = notification.userInfo?["onion"] as? String, onion == contact.onionAddress {
                withAnimation {
                    isTyping = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation {
                        isTyping = false
                    }
                }
            }
        }
        .sheet(isPresented: $showPaymentRequest) {
            PaymentRequestSheet(contact: contact)
        }
        // FIX #221: Explicitly pass environment objects to prevent blank screen delay
        // SwiftUI sheets don't always inherit environment objects properly
        .sheet(isPresented: $showPayNowSheet) {
            if let paymentRequest = paymentRequestToPay {
                PayNowSheet(
                    contact: contact,
                    paymentRequest: paymentRequest,
                    onPaymentComplete: { txId in
                        // Send payment confirmation back to requester
                        Task {
                            try? await chatManager.sendPaymentConfirmation(
                                to: contact,
                                amount: paymentRequest.paymentAmount ?? 0,
                                txId: txId,
                                requestId: paymentRequest.id
                            )
                        }
                        showPayNowSheet = false
                        paymentRequestToPay = nil
                    },
                    onCancel: {
                        showPayNowSheet = false
                        paymentRequestToPay = nil
                    }
                )
                .environmentObject(WalletManager.shared)
                .environmentObject(NetworkManager.shared)
                .environmentObject(themeManager)
            }
        }
    }

    private var conversationHeader: some View {
        HStack(spacing: 12) {
            // Back button (iOS)
            #if os(iOS)
            // Handled by NavigationView
            #endif

            // Contact info
            HStack(spacing: 10) {
                // Mini avatar
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hue: Double(abs(contact.displayName.hashValue) % 360) / 360.0, saturation: 0.7, brightness: 0.8),
                                Color(hue: Double((abs(contact.displayName.hashValue) + 40) % 360) / 360.0, saturation: 0.6, brightness: 0.6)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(contact.displayName.prefix(1).uppercased())
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(contact.isOnline ? theme.accentColor : Color.gray)
                            .frame(width: 6, height: 6)
                        Text(contact.isOnline ? "online" : "offline")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(contact.isOnline ? theme.accentColor : Color.gray)
                    }
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 16) {
                Button(action: { showPaymentRequest = true }) {
                    Image(systemName: "dollarsign.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)

                // Encryption indicator
                Image(systemName: "lock.fill")
                    .font(.system(size: 14))
                    .foregroundColor(theme.accentColor.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }

    private func shouldShowDateSeparator(at index: Int, in messages: [ChatMessage]) -> Bool {
        guard index > 0 else { return true }
        let calendar = Calendar.current
        let currentDate = messages[index].timestamp
        let previousDate = messages[index - 1].timestamp
        return !calendar.isDate(currentDate, inSameDayAs: previousDate)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            // FIX #410: Warning when chat is blocked by health check
            if networkManager.isFeatureBlocked(.chat) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text(networkManager.transactionBlockedReason ?? "Chat temporarily unavailable")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.red)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.1))
            }

            // FIX #243: Warning when not enough peers for stable chat
            if !hasEnoughPeers && !networkManager.isFeatureBlocked(.chat) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("Chat unstable: Need \(minimumPeersForChat) peers (\(networkManager.connectedPeers) connected)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.orange)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }

            HStack(spacing: 12) {
                // Attachment button (placeholder)
                Button(action: { /* TODO: attachments */ }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(theme.textPrimary.opacity(0.4))
                }
                .buttonStyle(.plain)

                // Message input
                // FIX #343: Add visible placeholder styling for iOS
                HStack {
                    TextField("", text: $messageText, prompt: Text("Type a message...")
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(.white)
                        .focused($isInputFocused)
                        .onChange(of: messageText) { _ in
                            Task {
                                try? await chatManager.sendTypingIndicator(to: contact)
                            }
                        }
                        .onSubmit {
                            sendMessage()
                        }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.black.opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(isInputFocused ? theme.accentColor.opacity(0.5) : theme.accentColor.opacity(0.2), lineWidth: 1)
                )

                // Send button
                // FIX #243: Disable send when not enough peers for stable connection
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundColor(canSendMessage ? theme.accentColor : Color.gray.opacity(0.5))
                        .shadow(color: canSendMessage ? theme.accentColor.opacity(0.4) : .clear, radius: 4)
                }
                .buttonStyle(.plain)
                .disabled(!canSendMessage)
                .scaleEffect(canSendMessage ? 1.05 : 1.0)
                .animation(.spring(response: 0.3), value: canSendMessage)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.25), Color.black.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // FIX #243: Can send message only if text is not empty AND enough peers connected
    // FIX #410: Also check if chat is blocked by health check
    private var canSendMessage: Bool {
        !messageText.isEmpty && hasEnoughPeers && !networkManager.isFeatureBlocked(.chat)
    }

    private func sendMessage() {
        guard canSendMessage else { return }

        let text = messageText
        messageText = ""

        Task {
            do {
                try await chatManager.sendTextMessage(text, to: contact)
            } catch {
                print("Failed to send message: \(error)")
            }
        }
    }
}

// MARK: - Date Separator

struct DateSeparator: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let date: Date

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        HStack {
            Rectangle()
                .fill(theme.accentColor.opacity(0.2))
                .frame(height: 1)

            Text(formatDate(date))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(theme.accentColor.opacity(0.6))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(theme.accentColor.opacity(0.1))
                )

            Rectangle()
                .fill(theme.accentColor.opacity(0.2))
                .frame(height: 1)
        }
        .padding(.vertical, 12)
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let message: ChatMessage
    let isFromMe: Bool
    var isPaid: Bool = false  // FIX #219: True if this payment request has been paid
    var onPayNow: ((ChatMessage) -> Void)? = nil  // Callback for PAY NOW button
    @State private var copiedTxId: String? = nil  // FIX #405: Track copied txid for feedback

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        HStack {
            if isFromMe { Spacer(minLength: 60) }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
                // Sender nickname
                if !isFromMe, let nickname = message.nickname {
                    Text(nickname)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                        .padding(.leading, 8)
                }

                // Message content
                switch message.type {
                case .text:
                    textBubble
                case .paymentRequest:
                    paymentRequestBubble
                case .paymentSent:
                    // FIX #219: When I receive a paymentSent from someone else,
                    // it means THEY paid MY request - show celebration!
                    if isFromMe {
                        paymentSentBubble  // I sent payment - show "PAYMENT SENT"
                    } else {
                        paymentReceivedBubble  // They paid me - show "PAYMENT RECEIVED" celebration
                    }
                case .paymentReceived:
                    // FIX #219: Explicit payment received type (for backwards compatibility)
                    paymentReceivedBubble
                default:
                    EmptyView()
                }

                // Timestamp + Status
                HStack(spacing: 6) {
                    Text(formatTime(message.timestamp))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.textPrimary.opacity(0.35))

                    if isFromMe {
                        MessageStatusIndicator(status: message.status)
                    }
                }
                .padding(.horizontal, 4)
            }

            if !isFromMe { Spacer(minLength: 60) }
        }
        .padding(.vertical, 2)
    }

    private var textBubble: some View {
        Text(message.content)
            .font(.system(size: 15, design: .monospaced))
            .foregroundColor(isFromMe ? .black : theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isFromMe
                    ? LinearGradient(
                        colors: [theme.accentColor, theme.accentColor.opacity(0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    : LinearGradient(
                        colors: [Color.black.opacity(0.3), Color.black.opacity(0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
            )
            #if os(iOS)
            .cornerRadius(18, corners: isFromMe ? [.topLeft, .topRight, .bottomLeft] : [.topLeft, .topRight, .bottomRight])
            #else
            .cornerRadius(18, corners: isFromMe ? [.topLeft, .topRight, .bottomLeft] as RectCorner : [.topLeft, .topRight, .bottomRight] as RectCorner)
            #endif
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(isFromMe ? Color.clear : theme.accentColor.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: isFromMe ? theme.accentColor.opacity(0.2) : Color.black.opacity(0.1), radius: 4, y: 2)
    }

    private var paymentRequestBubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: isPaid ? "checkmark.seal.fill" : "dollarsign.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(isPaid ? .green : theme.accentColor)
                Text(isPaid ? "PAYMENT REQUEST - PAID" : "PAYMENT REQUEST")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(isPaid ? .green : theme.accentColor)
            }

            if let amount = message.formattedAmount {
                Text(amount)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(isPaid ? .green.opacity(0.8) : theme.textPrimary)
                    .strikethrough(isPaid, color: .green.opacity(0.5))
            }

            if !message.content.isEmpty {
                Text(message.content)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.textPrimary.opacity(0.7))
            }

            // FIX #219: Show PAY NOW button only if not paid and not from me
            if !isFromMe && !isPaid {
                Button(action: { onPayNow?(message) }) {
                    HStack {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("PAY NOW")
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(theme.accentColor)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            } else if isPaid {
                // Show paid confirmation badge
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("PAID")
                }
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.green)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.15))
                .cornerRadius(8)
            }
        }
        .padding(14)
        .background(isPaid ? Color.green.opacity(0.1) : Color.black.opacity(0.25))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isPaid ? Color.green.opacity(0.5) : theme.accentColor.opacity(0.4), lineWidth: isPaid ? 2 : 1)
        )
    }

    private var paymentSentBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(theme.accentColor)
                Text("PAYMENT SENT")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accentColor)
            }

            if let amount = message.formattedAmount {
                Text(amount)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
            }

            // FIX #405: Show TXID with copy button
            if let txid = extractTxIdFromContent(message.content) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TXID:")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.textPrimary.opacity(0.5))
                    HStack(spacing: 6) {
                        Text("\(txid.prefix(16))...\(txid.suffix(8))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.accentColor)
                        Button(action: {
                            #if os(iOS)
                            UIPasteboard.general.string = txid
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(txid, forType: .string)
                            #endif
                            // Show brief feedback
                            withAnimation {
                                copiedTxId = txid
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation {
                                    if copiedTxId == txid { copiedTxId = nil }
                                }
                            }
                        }) {
                            Image(systemName: copiedTxId == txid ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundColor(copiedTxId == txid ? .green : theme.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(theme.accentColor.opacity(0.15))
        .cornerRadius(10)
    }

    // FIX #219: Celebration bubble when payment request is fulfilled
    private var paymentReceivedBubble: some View {
        VStack(alignment: .center, spacing: 8) {
            // Celebration header
            HStack {
                Text("🎉")
                    .font(.system(size: 24))
                Text("PAYMENT RECEIVED!")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)
                Text("🎉")
                    .font(.system(size: 24))
            }

            // Amount with glow effect
            if let amount = message.formattedAmount {
                Text(amount)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)
                    .shadow(color: .orange.opacity(0.6), radius: 8)
            }

            // TXID preview with copy button (FIX #405)
            if let txid = extractTxIdFromContent(message.content) {
                VStack(spacing: 4) {
                    Text("TXID:")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.textPrimary.opacity(0.5))
                    HStack(spacing: 6) {
                        Text("\(txid.prefix(16))...\(txid.suffix(8))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.accentColor)
                        Button(action: {
                            #if os(iOS)
                            UIPasteboard.general.string = txid
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(txid, forType: .string)
                            #endif
                            withAnimation {
                                copiedTxId = txid
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation {
                                    if copiedTxId == txid { copiedTxId = nil }
                                }
                            }
                        }) {
                            Image(systemName: copiedTxId == txid ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundColor(copiedTxId == txid ? .green : theme.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Cypherpunk quote
            Text("\"Privacy is a fundamental right.\"")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(theme.textPrimary.opacity(0.3))
                .italic()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color.orange.opacity(0.2), theme.accentColor.opacity(0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.orange.opacity(0.5), lineWidth: 2)
        )
        .cornerRadius(14)
    }

    // Helper to extract TXID from message content like "Payment sent: abc123..."
    private func extractTxIdFromContent(_ content: String) -> String? {
        // Look for 64-char hex string after "Payment sent:" or just any 64-char hex
        let patterns = [
            "Payment sent:\\s*([a-fA-F0-9]{64})",
            "([a-fA-F0-9]{64})"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: content, options: [], range: NSRange(content.startIndex..., in: content)),
               let range = Range(match.range(at: 1), in: content) {
                return String(content[range])
            }
        }
        return nil
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Message Status Indicator

struct MessageStatusIndicator: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let status: MessageStatus

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        HStack(spacing: 2) {
            switch status {
            case .sending:
                SendingAnimation()

            case .sent:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.gray)

            case .delivered:
                HStack(spacing: -4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(theme.accentColor.opacity(0.7))

            case .read:
                HStack(spacing: -4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(theme.accentColor)

            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.red)

            case .queued:
                // FIX #249: Show clock icon for queued messages (offline recipient)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
    }
}

struct SendingAnimation: View {
    @State private var isAnimating = false

    var body: some View {
        Image(systemName: "arrow.up.circle")
            .font(.system(size: 11))
            .foregroundColor(Color.gray.opacity(0.6))
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(
                Animation.linear(duration: 1.0)
                    .repeatForever(autoreverses: false),
                value: isAnimating
            )
            .onAppear {
                isAnimating = true
            }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var animationPhase: Int = 0

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(theme.accentColor.opacity(0.7))
                        .frame(width: 8, height: 8)
                        .scaleEffect(animationPhase == index ? 1.2 : 0.8)
                        .opacity(animationPhase == index ? 1.0 : 0.5)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.black.opacity(0.25))
            .cornerRadius(18)

            Spacer()
        }
        .onAppear {
            withAnimation(Animation.easeInOut(duration: 0.4).repeatForever()) {
                animationPhase = (animationPhase + 1) % 3
            }
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                animationPhase = (animationPhase + 1) % 3
            }
        }
    }
}

// MARK: - Add Contact Sheet

struct AddContactSheet: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var chatManager = ChatManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var onionAddress = ""
    @State private var nickname = ""
    @State private var errorMessage: String?
    @State private var isAdding = false
    // FIX #225: QR code scanner
    @State private var showQRScanner = false

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // macOS: Explicit close button (toolbar doesn't work in sheets)
                #if os(macOS)
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(theme.textPrimary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                #endif

                // Header icon
                ZStack {
                    Circle()
                        .stroke(theme.accentColor.opacity(0.3), lineWidth: 2)
                        .frame(width: 80, height: 80)

                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 36))
                        .foregroundColor(theme.accentColor)
                }
                .padding(.top, 20)

                VStack(spacing: 6) {
                    Text("Add Contact")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.textPrimary)

                    Text("Enter their .onion address to connect\nover the Tor network")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(theme.textPrimary.opacity(0.5))
                        .multilineTextAlignment(.center)
                }

                // Form
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("ONION ADDRESS")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(theme.accentColor)

                            Spacer()

                            // FIX #225: QR Scanner button (iOS only)
                            #if os(iOS)
                            Button(action: { showQRScanner = true }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "qrcode.viewfinder")
                                        .font(.system(size: 14))
                                    Text("SCAN")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                }
                                .foregroundColor(theme.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(theme.accentColor.opacity(0.15))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            #endif
                        }

                        // FIX #343: Add visible placeholder styling for iOS
                        TextField("", text: $onionAddress, prompt: Text("xxxxxxxx...xxxxx.onion")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5)))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.white)
                            #if os(iOS)
                            .autocapitalization(.none)
                            #endif
                            .disableAutocorrection(true)
                            .padding(14)
                            .background(Color.black.opacity(0.25))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(theme.accentColor.opacity(0.3), lineWidth: 1)
                            )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("NICKNAME (OPTIONAL)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.accentColor)

                        // FIX #343: Add visible placeholder styling for iOS
                        TextField("", text: $nickname, prompt: Text("Enter a friendly name")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5)))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(14)
                            .background(Color.black.opacity(0.25))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(theme.accentColor.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
                .padding(.horizontal, 24)

                if let error = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 24)
                }

                Spacer(minLength: 16)

                // Action buttons
                VStack(spacing: 12) {
                    // Add button
                    Button(action: addContact) {
                    HStack(spacing: 8) {
                        if isAdding {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 16))
                        }
                        Text("ADD CONTACT")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(12)
                    .shadow(color: theme.accentColor.opacity(0.3), radius: 8, y: 4)
                }
                    .buttonStyle(.plain)
                    .disabled(onionAddress.isEmpty || isAdding)
                    .opacity(onionAddress.isEmpty ? 0.6 : 1.0)

                    // Cancel button (explicit for macOS since toolbar doesn't work in sheets)
                    #if os(macOS)
                    Button(action: { dismiss() }) {
                        Text("CANCEL")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.textPrimary.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(theme.textPrimary.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    #endif
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.backgroundColor)
            .navigationTitle("Add Contact")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // FIX #270: Hide toolbar buttons on iOS - swipe to dismiss is sufficient
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(theme.accentColor)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(theme.accentColor)
                }
            }
            // Ensure entire sheet has consistent background on macOS
            .background(theme.backgroundColor.ignoresSafeArea())
            #endif
        }
        // FIX #225: QR Scanner sheet (iOS only)
        #if os(iOS)
        .sheet(isPresented: $showQRScanner) {
            ChatQRScannerSheet { scannedAddress in
                if let address = scannedAddress {
                    // FIX #251: Parse new QR format with nickname
                    if let qrData = ChatQRCodeData.parse(address) {
                        onionAddress = qrData.onionAddress

                        // FIX #251: Auto-fill nickname from QR code
                        if let scannedNickname = qrData.nickname, !scannedNickname.isEmpty {
                            // Check for duplicate nickname and add random suffix if needed
                            nickname = generateUniqueNickname(scannedNickname)
                        }
                    } else {
                        errorMessage = "Invalid QR code format"
                    }
                }
                showQRScanner = false
            }
            .environmentObject(themeManager)
        }
        #endif
    }

    /// FIX #251: Generate unique nickname by adding random 5-digit suffix if duplicate exists
    private func generateUniqueNickname(_ baseName: String) -> String {
        let existingNicknames = chatManager.contacts.map { $0.nickname.lowercased() }

        if !existingNicknames.contains(baseName.lowercased()) {
            return baseName
        }

        // Nickname exists - add random 5-digit suffix
        let suffix = String(format: "%05d", Int.random(in: 0...99999))
        let newNickname = "\(baseName)_\(suffix)"

        // Show warning to user
        errorMessage = "Contact '\(baseName)' already exists. Renamed to '\(newNickname)'"

        return newNickname
    }

    private func addContact() {
        isAdding = true
        errorMessage = nil

        do {
            try chatManager.addContact(onionAddress: onionAddress, nickname: nickname)
            dismiss()
        } catch let error as ChatError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        isAdding = false
    }
}

// MARK: - Chat Settings Sheet

struct ChatSettingsSheet: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var chatManager = ChatManager.shared
    @Environment(\.dismiss) private var dismiss

    // Store quote once to prevent "loop" effect from re-rendering
    @State private var quote: String = ""
    // FIX #224: Track if address was copied
    @State private var showCopiedFeedback = false

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // macOS: Explicit close button (toolbar doesn't work in sheets)
                    #if os(macOS)
                    HStack {
                        Spacer()
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(theme.textPrimary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    #endif

                    // Identity Section (FIX #224: QR code + copy button)
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeader("YOUR IDENTITY")

                        VStack(spacing: 12) {
                            HStack {
                                Text("Nickname")
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(theme.textPrimary.opacity(0.7))
                                Spacer()
                                // FIX #343: Add visible placeholder styling for iOS
                                TextField("", text: $chatManager.ourNickname, prompt: Text("Enter nickname")
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundColor(theme.accentColor.opacity(0.5)))
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.trailing)
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundColor(theme.accentColor)
                            }
                            .padding(14)
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(10)

                            // FIX #224: QR Code and .onion address with copy button
                            // FIX #251: Include nickname in QR code + add ZipherX logo
                            if let onion = chatManager.ourOnionAddress {
                                VStack(spacing: 16) {
                                    // QR Code
                                    VStack(spacing: 8) {
                                        Text("SHARE YOUR ADDRESS")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundColor(theme.accentColor)
                                            .tracking(2)

                                        // FIX #251: QR Code with nickname and ZipherX logo
                                        let qrData = ChatQRCodeData(
                                            onionAddress: onion,
                                            nickname: chatManager.ourNickname.isEmpty ? nil : chatManager.ourNickname
                                        )
                                        System7QRCode(data: qrData.qrString, showLogo: true)
                                            .frame(width: 180, height: 180)
                                            .background(Color.white)
                                            .cornerRadius(12)
                                            .shadow(color: theme.accentColor.opacity(0.3), radius: 8)

                                        Text("Scan to add as contact")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(theme.textPrimary.opacity(0.5))
                                    }

                                    // Onion address with copy button
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text("Your .onion Address")
                                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                .foregroundColor(theme.textPrimary.opacity(0.5))
                                            Spacer()

                                            // Copy button
                                            Button(action: {
                                                #if os(iOS)
                                                UIPasteboard.general.string = onion
                                                #else
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(onion, forType: .string)
                                                #endif
                                                withAnimation {
                                                    showCopiedFeedback = true
                                                }
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                                    withAnimation {
                                                        showCopiedFeedback = false
                                                    }
                                                }
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                                                        .font(.system(size: 12))
                                                    Text(showCopiedFeedback ? "Copied!" : "Copy")
                                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                                }
                                                .foregroundColor(showCopiedFeedback ? .green : theme.accentColor)
                                            }
                                            .buttonStyle(.plain)
                                        }

                                        Text(onion)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(theme.accentColor)
                                            .lineLimit(3)
                                            .textSelection(.enabled)
                                    }
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.black.opacity(0.2))
                                    .cornerRadius(10)
                                }
                                .padding(16)
                                .background(Color.black.opacity(0.15))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(theme.accentColor.opacity(0.2), lineWidth: 1)
                                )
                            }
                        }
                    }

                    // Status Section
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeader("STATUS")

                        VStack(spacing: 0) {
                            HStack {
                                Text("Chat Service")
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(theme.textPrimary.opacity(0.7))
                                Spacer()
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(chatManager.isAvailable ? theme.accentColor : Color.red)
                                        .frame(width: 8, height: 8)
                                    Text(chatManager.isAvailable ? "Online" : "Offline")
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .foregroundColor(chatManager.isAvailable ? theme.accentColor : Color.red)
                                }
                            }
                            .padding(14)

                            Divider()
                                .background(theme.accentColor.opacity(0.1))

                            HStack {
                                Text("Active Contacts")
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(theme.textPrimary.opacity(0.7))
                                Spacer()
                                Text("\(chatManager.contacts.count)")
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(theme.textPrimary)
                            }
                            .padding(14)
                        }
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(10)
                    }

                    // Quote (stored to prevent loop effect)
                    if !quote.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "quote.opening")
                                .font(.system(size: 20))
                                .foregroundColor(theme.accentColor.opacity(0.4))

                            Text(quote)
                                .font(.system(size: 12, weight: .light, design: .monospaced))
                                .foregroundColor(theme.accentColor.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                        }
                        .padding(.vertical, 16)
                    }

                    // Close button (explicit for macOS since toolbar doesn't work in sheets)
                    #if os(macOS)
                    Spacer(minLength: 16)

                    Button(action: { dismiss() }) {
                        Text("CLOSE")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.textPrimary.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(theme.textPrimary.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    #endif
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.backgroundColor)
            .navigationTitle("Chat Settings")
            .onAppear {
                // Set quote once on appear to prevent loop
                if quote.isEmpty {
                    quote = randomCypherpunkQuote()
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // FIX #270: Hide toolbar buttons on iOS - swipe to dismiss is sufficient
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundColor(theme.accentColor)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(theme.accentColor)
                }
            }
            // Ensure entire sheet has consistent background on macOS
            .background(theme.backgroundColor.ignoresSafeArea())
            #endif
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(theme.accentColor)
    }
}

// MARK: - Payment Request Sheet

struct PaymentRequestSheet: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var chatManager = ChatManager.shared
    @Environment(\.dismiss) private var dismiss

    let contact: ChatContact

    @State private var amount = ""
    @State private var memo = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var showSuccess = false

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Header
                ZStack {
                    Circle()
                        .stroke(theme.accentColor.opacity(0.3), lineWidth: 2)
                        .frame(width: 80, height: 80)

                    Image(systemName: "dollarsign.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(theme.accentColor)
                }

                Text("Request Payment")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)

                Text("from \(contact.displayName)")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(theme.textPrimary.opacity(0.5))

                VStack(spacing: 18) {
                    // FIX #343: Add visible placeholder styling for iOS
                    TextField("", text: $amount, prompt: Text("0.00")
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.accentColor.opacity(0.5)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .foregroundColor(theme.accentColor)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .padding(.vertical, 16)
                        .background(Color.black.opacity(0.25))
                        .cornerRadius(12)

                    Text("ZCL")
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.textPrimary.opacity(0.5))

                    // FIX #334: Add foregroundColor to make memo text visible on dark background
                    // FIX #343: Use prompt parameter with explicit styling for visible placeholder on iOS
                    TextField("", text: $memo, prompt: Text("Add a memo (optional)")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(theme.textSecondary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(theme.textPrimary)
                        .padding(14)
                        .background(Color.black.opacity(0.25))
                        .cornerRadius(10)
                        .tint(theme.accentColor)  // Cursor color
                }
                .padding(.horizontal, 24)

                // Error message
                if let error = errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                }

                // Success message
                if showSuccess {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(theme.accentColor)
                        Text("Payment request sent!")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.accentColor)
                    }
                    .padding(.horizontal, 24)
                    .transition(.scale.combined(with: .opacity))
                }

                Spacer()

                Button(action: sendRequest) {
                    HStack(spacing: 8) {
                        if isSending {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                        Text("SEND REQUEST")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(12)
                    .shadow(color: theme.accentColor.opacity(0.3), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(amount.isEmpty || isSending)
                .opacity(amount.isEmpty ? 0.6 : 1.0)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .padding(.top, 24)
            .background(theme.backgroundColor)
            // FIX #270: Hide toolbar buttons on iOS - swipe to dismiss is sufficient
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(theme.accentColor)
                }
            }
            #endif
        }
    }

    private func sendRequest() {
        // FIX #236: Handle both '.' and ',' decimal separators (locale-independent)
        let normalizedAmount = amount.replacingOccurrences(of: ",", with: ".")
        guard let amountDouble = Double(normalizedAmount) else { return }
        let zatoshis = UInt64(amountDouble * 100_000_000)

        isSending = true
        errorMessage = nil

        Task {
            do {
                let zAddress = await WalletManager.shared.zAddress ?? ""
                try await chatManager.sendPaymentRequest(to: contact, amount: zatoshis, address: zAddress, memo: memo)

                // Show success feedback
                await MainActor.run {
                    showSuccess = true
                }

                // Auto-dismiss after success
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    dismiss()
                }
            } catch let error as ChatError {
                await MainActor.run {
                    errorMessage = error.errorDescription ?? error.localizedDescription
                    isSending = false
                }
            } catch {
                await MainActor.run {
                    // Make timeout message more user-friendly
                    if error.localizedDescription.contains("timeout") {
                        errorMessage = "Connection timeout. \(contact.displayName) may be offline."
                    } else {
                        errorMessage = error.localizedDescription
                    }
                    isSending = false
                }
            }
        }
    }
}

// MARK: - Pay Now Sheet

/// Sheet displayed when user taps "PAY NOW" on a payment request
/// Wraps SendView with pre-filled address and amount
struct PayNowSheet: View {
    @EnvironmentObject private var themeManager: ThemeManager
    // FIX #221: Use StateObject with shared singleton for reliable access
    // Environment objects can fail to propagate through sheet presentation
    @StateObject private var walletManager = WalletManager.shared
    @StateObject private var networkManager = NetworkManager.shared
    @Environment(\.dismiss) private var dismiss

    let contact: ChatContact
    let paymentRequest: ChatMessage
    var onPaymentComplete: ((String) -> Void)?  // Called with txId when payment succeeds
    var onCancel: (() -> Void)?

    private var theme: AppTheme { themeManager.currentTheme }

    // Pre-calculated values from payment request
    private var recipientAddress: String {
        paymentRequest.paymentAddress ?? ""
    }

    private var amountZCL: String {
        guard let zatoshis = paymentRequest.paymentAmount else { return "" }
        let zcl = Double(zatoshis) / 100_000_000.0
        return String(format: "%.8f", zcl)
    }

    private var memo: String {
        paymentRequest.content.isEmpty ? "Payment for request" : paymentRequest.content
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header showing payment request details
                paymentRequestHeader

                Divider()
                    .background(theme.accentColor.opacity(0.2))

                // Embedded SendView with pre-filled data
                SendViewForPayment(
                    prefilledAddress: recipientAddress,
                    prefilledAmount: amountZCL,
                    prefilledMemo: memo,
                    onSuccess: { txId in
                        onPaymentComplete?(txId)
                    }
                )
            }
            .background(theme.backgroundColor)
            .navigationTitle("Pay \(contact.displayName)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // FIX #270: Hide toolbar buttons on iOS - swipe to dismiss is sufficient
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel?()
                        dismiss()
                    }
                    .foregroundColor(theme.accentColor)
                }
            }
            .frame(minWidth: 500, idealWidth: 600, minHeight: 600, idealHeight: 700)
            #endif
        }
    }

    private var paymentRequestHeader: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(theme.accentColor)
                Text("PAYMENT REQUEST FROM \(contact.displayName.uppercased())")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accentColor)
            }

            if let formattedAmount = paymentRequest.formattedAmount {
                Text(formattedAmount)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
            }

            if !paymentRequest.content.isEmpty {
                Text("\"\(paymentRequest.content)\"")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.textPrimary.opacity(0.6))
                    .italic()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.2))
    }
}

// MARK: - Simplified SendView for Payment

/// A simplified version of SendView used within PayNowSheet
/// Pre-fills address, amount, memo and provides success callback
struct SendViewForPayment: View {
    // FIX #221: Use StateObject with shared singletons for reliable access
    @StateObject private var walletManager = WalletManager.shared
    @StateObject private var networkManager = NetworkManager.shared
    @EnvironmentObject var themeManager: ThemeManager

    let prefilledAddress: String
    let prefilledAmount: String
    let prefilledMemo: String
    var onSuccess: ((String) -> Void)?

    private var theme: AppTheme { themeManager.currentTheme }

    @State private var isSending = false
    @State private var showSuccess = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var txId = ""

    // Progress tracking
    @State private var sendProgress: [SendProgressStep] = []
    @State private var currentStepIndex: Int = 0

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Address (read-only)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TO ADDRESS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.accentColor)

                        Text(prefilledAddress)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.textPrimary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.accentColor.opacity(0.3), lineWidth: 1)
                            )
                    }

                    // Amount (read-only)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AMOUNT")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.accentColor)

                        HStack {
                            Text(prefilledAmount)
                                .font(.system(size: 24, weight: .bold, design: .monospaced))
                                .foregroundColor(theme.textPrimary)
                            Text("ZCL")
                                .font(.system(size: 16, design: .monospaced))
                                .foregroundColor(theme.textPrimary.opacity(0.5))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.accentColor.opacity(0.3), lineWidth: 1)
                        )
                    }

                    // Memo (read-only)
                    if !prefilledMemo.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("MEMO")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(theme.accentColor)

                            Text(prefilledMemo)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(theme.textPrimary.opacity(0.7))
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.black.opacity(0.2))
                                .cornerRadius(8)
                        }
                    }

                    // Available balance
                    HStack {
                        Text("Available:")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.textPrimary.opacity(0.5))
                        Spacer()
                        Text(String(format: "%.8f ZCL", Double(walletManager.shieldedBalance) / 100_000_000.0))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.accentColor)
                    }

                    // Fee info
                    HStack {
                        Text("Network Fee:")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.textPrimary.opacity(0.5))
                        Spacer()
                        Text("0.0001 ZCL")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.textPrimary.opacity(0.7))
                    }

                    Spacer(minLength: 20)

                    // Confirm and Send button
                    Button(action: sendPayment) {
                        HStack(spacing: 8) {
                            if isSending {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "paperplane.fill")
                            }
                            Text(isSending ? "SENDING..." : "CONFIRM & SEND")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [theme.accentColor, theme.accentColor.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(12)
                        .shadow(color: theme.accentColor.opacity(0.3), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    // FIX #410: Also disable when send is blocked by health check
                    .disabled(isSending || !hasEnoughBalance || networkManager.isFeatureBlocked(.send))
                    .opacity(isSending || !hasEnoughBalance || networkManager.isFeatureBlocked(.send) ? 0.6 : 1.0)

                    // FIX #410: Show warning when send is blocked
                    if networkManager.isFeatureBlocked(.send) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                            Text(networkManager.transactionBlockedReason ?? "Send temporarily unavailable")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.red)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(20)
            }

            // Progress overlay
            if isSending && !showSuccess {
                sendProgressOverlay
            }

            // Success overlay
            if showSuccess {
                successOverlay
            }
        }
        .alert("Payment Failed", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    private var hasEnoughBalance: Bool {
        guard let amount = Double(prefilledAmount) else { return false }
        let amountZatoshis = UInt64(amount * 100_000_000)
        let fee: UInt64 = 10_000
        return walletManager.shieldedBalance >= amountZatoshis + fee
    }

    private var sendProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.8)

            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: theme.accentColor))
                    .scaleEffect(1.5)

                Text("Processing Payment...")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.textPrimary)

                if !sendProgress.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(sendProgress) { step in
                            HStack(spacing: 8) {
                                switch step.status {
                                case .completed:
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(theme.accentColor)
                                case .inProgress:
                                    ProgressView()
                                        .scaleEffect(0.6)
                                case .failed:
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                default:
                                    Image(systemName: "circle")
                                        .foregroundColor(theme.textPrimary.opacity(0.3))
                                }
                                Text(step.title)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(theme.textPrimary.opacity(0.7))
                            }
                        }
                    }
                }
            }
            .padding(30)
        }
    }

    private var successOverlay: some View {
        ZStack {
            Color.black

            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(theme.accentColor)
                    .shadow(color: theme.accentColor.opacity(0.8), radius: 20)

                Text("PAYMENT SENT!")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accentColor)

                Text("Transaction ID:")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.textPrimary.opacity(0.5))

                Text(txId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.accentColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button(action: {
                    onSuccess?(txId)
                }) {
                    Text("DONE")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 12)
                        .background(theme.accentColor)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
        }
    }

    private func sendPayment() {
        guard let amount = Double(prefilledAmount) else { return }
        let amountZatoshis = UInt64(amount * 100_000_000)

        isSending = true
        sendProgress = [
            SendProgressStep(id: "build", title: "Building transaction", status: .inProgress),
            SendProgressStep(id: "sign", title: "Signing with spending key", status: .pending),
            SendProgressStep(id: "broadcast", title: "Broadcasting to network", status: .pending),
            SendProgressStep(id: "verify", title: "Verifying in mempool", status: .pending)
        ]

        Task {
            do {
                let result = try await walletManager.sendShieldedWithProgress(
                    to: prefilledAddress,
                    amount: amountZatoshis,
                    memo: prefilledMemo
                ) { phase, detail, progress in
                    Task { @MainActor in
                        updateProgress(phase: phase, detail: detail ?? "", progress: progress ?? 0.0)
                    }
                }

                await MainActor.run {
                    txId = result
                    showSuccess = true
                    isSending = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isSending = false
                }
            }
        }
    }

    private func updateProgress(phase: String, detail: String, progress: Double) {
        switch phase {
        case "build":
            sendProgress[0].status = progress >= 1.0 ? .completed : .inProgress
            sendProgress[0].detail = detail
        case "sign":
            sendProgress[0].status = .completed
            sendProgress[1].status = progress >= 1.0 ? .completed : .inProgress
            sendProgress[1].detail = detail
        case "broadcast", "peers":
            sendProgress[0].status = .completed
            sendProgress[1].status = .completed
            sendProgress[2].status = progress >= 1.0 ? .completed : .inProgress
            sendProgress[2].detail = detail
        case "verify":
            sendProgress[0].status = .completed
            sendProgress[1].status = .completed
            sendProgress[2].status = .completed
            sendProgress[3].status = progress >= 1.0 ? .completed : .inProgress
            sendProgress[3].detail = detail
        default:
            break
        }
    }
}

// MARK: - Corner Radius Extension (Cross-Platform)

#if os(iOS)
import UIKit

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Chat QR Scanner Sheet (FIX #225)

/// QR code scanner sheet for adding contacts
struct ChatQRScannerSheet: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    let onScan: (String?) -> Void

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        NavigationView {
            ZStack {
                // Camera view
                QRScannerView { scannedCode in
                    onScan(scannedCode)
                }
                .edgesIgnoringSafeArea(.all)

                // Overlay UI
                VStack {
                    // Top instruction
                    VStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 40))
                            .foregroundColor(theme.accentColor)
                        Text("Scan .onion QR Code")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("Point camera at contact's QR code")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(16)
                    .padding(.top, 60)

                    Spacer()

                    // Viewfinder frame
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(theme.accentColor, lineWidth: 3)
                        .frame(width: 260, height: 260)
                        .shadow(color: theme.accentColor.opacity(0.5), radius: 10)

                    Spacer()

                    // Bottom hint
                    Text("\"Privacy is the power to selectively reveal oneself.\"")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                        .italic()
                        .padding(.bottom, 40)
                }
            }
            .background(Color.black)
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onScan(nil)
                    }
                    .foregroundColor(theme.accentColor)
                }
            }
        }
    }
}
#else
import AppKit

struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCornerMac(radius: radius, corners: corners))
    }
}

struct RoundedCornerMac: Shape {
    var radius: CGFloat = .infinity
    var corners: RectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let tl = corners.contains(.topLeft) ? radius : 0
        let tr = corners.contains(.topRight) ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                       radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                       radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                       radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                       radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        path.closeSubpath()

        return path
    }
}
#endif
