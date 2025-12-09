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
    @StateObject private var chatManager = ChatManager.shared

    @State private var showAddContact = false
    @State private var showSettings = false
    @State private var selectedContact: ChatContact?
    @State private var noContactsQuote: String = ""  // Store quote to prevent loop

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        #if os(iOS)
        NavigationView {
            contactListView

            if let contact = selectedContact {
                ConversationView(contact: contact)
            } else {
                emptyStateView
            }
        }
        .navigationViewStyle(.columns)
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

    private var cypherpunkHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Animated lock icon
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 18))
                    .foregroundColor(theme.accentColor)
                    .shadow(color: theme.accentColor.opacity(0.5), radius: 4)

                Text("CYPHERPUNK CHAT")
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
        HStack(spacing: 12) {
            // Online status with pulse animation
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(chatManager.isAvailable ? theme.accentColor : Color.red)
                        .frame(width: 10, height: 10)

                    if chatManager.isAvailable {
                        Circle()
                            .stroke(theme.accentColor, lineWidth: 2)
                            .frame(width: 16, height: 16)
                            .opacity(0.5)
                            .scaleEffect(1.2)
                    }
                }

                Text(chatManager.isAvailable ? "ONLINE" : "OFFLINE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(chatManager.isAvailable ? theme.accentColor : Color.red)
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

            // Contact count
            Text("\(chatManager.contacts.count) contacts")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.textPrimary.opacity(0.4))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.15))
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
    @StateObject private var chatManager = ChatManager.shared

    let contact: ChatContact

    @State private var messageText = ""
    @State private var isTyping = false
    @State private var showPaymentRequest = false
    @FocusState private var isInputFocused: Bool

    private var theme: AppTheme { themeManager.currentTheme }

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

                                MessageBubble(message: message, isFromMe: message.fromOnion == chatManager.ourOnionAddress)
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
                        .foregroundColor(theme.textPrimary)

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
        HStack(spacing: 12) {
            // Attachment button (placeholder)
            Button(action: { /* TODO: attachments */ }) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(theme.textPrimary.opacity(0.4))
            }
            .buttonStyle(.plain)

            // Message input
            HStack {
                TextField("Type a message...", text: $messageText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .monospaced))
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
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(messageText.isEmpty ? Color.gray.opacity(0.5) : theme.accentColor)
                    .shadow(color: messageText.isEmpty ? .clear : theme.accentColor.opacity(0.4), radius: 4)
            }
            .buttonStyle(.plain)
            .disabled(messageText.isEmpty)
            .scaleEffect(messageText.isEmpty ? 1.0 : 1.05)
            .animation(.spring(response: 0.3), value: messageText.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.25), Color.black.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func sendMessage() {
        guard !messageText.isEmpty else { return }

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
                    paymentSentBubble
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
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(theme.accentColor)
                Text("PAYMENT REQUEST")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accentColor)
            }

            if let amount = message.formattedAmount {
                Text(amount)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
            }

            if !message.content.isEmpty {
                Text(message.content)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.textPrimary.opacity(0.7))
            }

            if !isFromMe {
                Button(action: { /* TODO: Navigate to send */ }) {
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
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.25))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.accentColor.opacity(0.4), lineWidth: 1)
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
        }
        .padding(12)
        .background(theme.accentColor.opacity(0.15))
        .cornerRadius(10)
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
                        Text("ONION ADDRESS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.accentColor)

                        TextField("xxxxxxxx...xxxxx.onion", text: $onionAddress)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .monospaced))
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

                        TextField("Enter a friendly name", text: $nickname)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .monospaced))
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(theme.accentColor)
                }
                #if os(macOS)
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(theme.accentColor)
                }
                #endif
            }
        }
        #if os(macOS)
        // Ensure entire sheet has consistent background on macOS
        .background(theme.backgroundColor.ignoresSafeArea())
        #endif
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

                    // Identity Section
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeader("YOUR IDENTITY")

                        VStack(spacing: 12) {
                            HStack {
                                Text("Nickname")
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(theme.textPrimary.opacity(0.7))
                                Spacer()
                                TextField("Enter nickname", text: $chatManager.ourNickname)
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.trailing)
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundColor(theme.accentColor)
                            }
                            .padding(14)
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(10)

                            if let onion = chatManager.ourOnionAddress {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Your .onion Address")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundColor(theme.textPrimary.opacity(0.5))
                                    Text(onion)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(theme.accentColor)
                                        .lineLimit(2)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.black.opacity(0.2))
                                .cornerRadius(10)
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
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundColor(theme.accentColor)
                }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(theme.accentColor)
                }
            }
        }
        #if os(macOS)
        // Ensure entire sheet has consistent background on macOS
        .background(theme.backgroundColor.ignoresSafeArea())
        #endif
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
                    TextField("0.00", text: $amount)
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

                    TextField("Add a memo (optional)", text: $memo)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(14)
                        .background(Color.black.opacity(0.25))
                        .cornerRadius(10)
                }
                .padding(.horizontal, 24)

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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(theme.accentColor)
                }
            }
        }
    }

    private func sendRequest() {
        guard let amountDouble = Double(amount) else { return }
        let zatoshis = UInt64(amountDouble * 100_000_000)

        isSending = true

        Task {
            do {
                let zAddress = await WalletManager.shared.zAddress ?? ""
                try await chatManager.sendPaymentRequest(to: contact, amount: zatoshis, address: zAddress, memo: memo)
                dismiss()
            } catch {
                print("Failed to send payment request: \(error)")
            }
            isSending = false
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
