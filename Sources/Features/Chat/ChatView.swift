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

    var body: some View {
        NavigationSplitView {
            // Contact list sidebar
            contactListView
        } detail: {
            // Conversation view
            if let contact = selectedContact {
                ConversationView(contact: contact)
            } else {
                emptyStateView
            }
        }
        .sheet(isPresented: $showAddContact) {
            AddContactSheet()
        }
        .sheet(isPresented: $showSettings) {
            ChatSettingsSheet()
        }
    }

    // MARK: - Contact List

    private var contactListView: some View {
        VStack(spacing: 0) {
            // Header
            chatHeader

            // Status bar
            statusBar

            // Contact list
            if chatManager.contacts.isEmpty {
                noContactsView
            } else {
                List(selection: $selectedContact) {
                    ForEach(chatManager.contacts) { contact in
                        ContactRow(contact: contact)
                            .tag(contact)
                    }
                    .onDelete(perform: deleteContacts)
                }
                .listStyle(.plain)
            }
        }
        .background(themeManager.theme.backgroundColor)
        .navigationTitle("CYPHERPUNK CHAT")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showAddContact = true }) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(Color(hex: "39FF14"))
                }
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(themeManager.theme.textColor.opacity(0.7))
                }
            }
        }
    }

    private var chatHeader: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(Color(hex: "39FF14"))
                Text("ENCRYPTED P2P")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "39FF14"))
            }

            if let onion = chatManager.ourOnionAddress {
                Text(onion.prefix(16) + "...")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(themeManager.theme.textColor.opacity(0.5))
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.3))
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(chatManager.isAvailable ? Color(hex: "39FF14") : Color.red)
                .frame(width: 8, height: 8)

            Text(chatManager.isAvailable ? "ONLINE" : "OFFLINE")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(chatManager.isAvailable ? Color(hex: "39FF14") : Color.red)

            Spacer()

            if chatManager.totalUnreadCount > 0 {
                Text("\(chatManager.totalUnreadCount) UNREAD")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(themeManager.theme.backgroundColor.opacity(0.8))
    }

    private var noContactsView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundColor(themeManager.theme.textColor.opacity(0.3))

            Text("No Contacts Yet")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(themeManager.theme.textColor.opacity(0.6))

            Text("Add a contact by their .onion address\nto start a secure conversation")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(themeManager.theme.textColor.opacity(0.4))
                .multilineTextAlignment(.center)

            Button(action: { showAddContact = true }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("ADD CONTACT")
                }
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(hex: "39FF14"))
                .cornerRadius(8)
            }

            Spacer()

            // Cypherpunk quote
            Text("\"" + randomCypherpunkQuote() + "\"")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(hex: "39FF14").opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 64))
                .foregroundColor(Color(hex: "39FF14").opacity(0.3))

            Text("Select a Contact")
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundColor(themeManager.theme.textColor.opacity(0.6))

            Text("Choose a contact from the list\nto start chatting")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(themeManager.theme.textColor.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.theme.backgroundColor)
    }

    private func deleteContacts(at offsets: IndexSet) {
        for index in offsets {
            chatManager.removeContact(chatManager.contacts[index])
        }
    }
}

// MARK: - Contact Row

struct ContactRow: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let contact: ChatContact

    var body: some View {
        HStack(spacing: 12) {
            // Avatar with online indicator
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color(hex: "39FF14").opacity(0.2))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(contact.displayName.prefix(1).uppercased())
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(hex: "39FF14"))
                    )

                if contact.isOnline {
                    Circle()
                        .fill(Color(hex: "39FF14"))
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(themeManager.theme.backgroundColor, lineWidth: 2)
                        )
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(contact.displayName)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(themeManager.theme.textColor)

                    if contact.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.yellow)
                    }
                }

                Text(contact.onionAddress.prefix(20) + "...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(themeManager.theme.textColor.opacity(0.5))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if contact.unreadCount > 0 {
                    Text("\(contact.unreadCount)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(minWidth: 20)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: "39FF14"))
                        .cornerRadius(10)
                }

                if let lastSeen = contact.lastSeen {
                    Text(lastSeenText(lastSeen))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(themeManager.theme.textColor.opacity(0.4))
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func lastSeenText(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h ago"
        } else {
            return "\(Int(interval / 86400))d ago"
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

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if let conversation = chatManager.conversations[contact.onionAddress] {
                            ForEach(conversation.messages) { message in
                                MessageBubble(message: message, isFromMe: message.fromOnion == chatManager.ourOnionAddress)
                                    .id(message.id)
                            }
                        }

                        if isTyping {
                            TypingIndicator()
                        }
                    }
                    .padding()
                }
                .onChange(of: chatManager.conversations[contact.onionAddress]?.messages.count) { _, _ in
                    if let lastMessage = chatManager.conversations[contact.onionAddress]?.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input bar
            inputBar
        }
        .background(themeManager.theme.backgroundColor)
        .navigationTitle(contact.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    Button(action: { showPaymentRequest = true }) {
                        Image(systemName: "dollarsign.circle")
                            .foregroundColor(Color(hex: "39FF14"))
                    }

                    Circle()
                        .fill(contact.isOnline ? Color(hex: "39FF14") : Color.gray)
                        .frame(width: 8, height: 8)
                }
            }
        }
        .onAppear {
            chatManager.markAsRead(contact: contact)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatTypingIndicator)) { notification in
            if let onion = notification.userInfo?["onion"] as? String, onion == contact.onionAddress {
                isTyping = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    isTyping = false
                }
            }
        }
        .sheet(isPresented: $showPaymentRequest) {
            PaymentRequestSheet(contact: contact)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            // Message input
            TextField("Message...", text: $messageText)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .padding(10)
                .background(themeManager.theme.backgroundColor.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(hex: "39FF14").opacity(0.3), lineWidth: 1)
                )
                .cornerRadius(8)
                .focused($isInputFocused)
                .onChange(of: messageText) { _, _ in
                    // Send typing indicator (debounced)
                    Task {
                        try? await chatManager.sendTypingIndicator(to: contact)
                    }
                }
                .onSubmit {
                    sendMessage()
                }

            // Send button
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(messageText.isEmpty ? Color.gray : Color(hex: "39FF14"))
            }
            .disabled(messageText.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.3))
    }

    private func sendMessage() {
        guard !messageText.isEmpty else { return }

        let text = messageText
        messageText = ""

        Task {
            do {
                try await chatManager.sendTextMessage(text, to: contact)
            } catch {
                print("💬 Failed to send message: \(error)")
            }
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let message: ChatMessage
    let isFromMe: Bool

    var body: some View {
        HStack {
            if isFromMe { Spacer(minLength: 50) }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
                // Sender nickname
                if !isFromMe, let nickname = message.nickname {
                    Text(nickname)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "39FF14"))
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

                // Timestamp + Status (for sent messages)
                HStack(spacing: 4) {
                    Text(formatTime(message.timestamp))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(themeManager.theme.textColor.opacity(0.4))

                    // Message status indicator (only for outgoing messages)
                    if isFromMe {
                        MessageStatusIndicator(status: message.status)
                    }
                }
            }

            if !isFromMe { Spacer(minLength: 50) }
        }
    }

    private var textBubble: some View {
        Text(message.content)
            .font(.system(size: 14, design: .monospaced))
            .foregroundColor(isFromMe ? .black : themeManager.theme.textColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isFromMe
                    ? Color(hex: "39FF14")
                    : themeManager.theme.backgroundColor.opacity(0.8)
            )
            .cornerRadius(16, corners: isFromMe ? [.topLeft, .topRight, .bottomLeft] : [.topLeft, .topRight, .bottomRight])
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(hex: "39FF14").opacity(isFromMe ? 0 : 0.3), lineWidth: 1)
            )
    }

    private var paymentRequestBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundColor(Color(hex: "39FF14"))
                Text("PAYMENT REQUEST")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "39FF14"))
            }

            if let amount = message.formattedAmount {
                Text(amount)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(themeManager.theme.textColor)
            }

            if !message.content.isEmpty {
                Text(message.content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(themeManager.theme.textColor.opacity(0.7))
            }

            if !isFromMe {
                Button(action: { /* TODO: Navigate to send */ }) {
                    Text("PAY NOW")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color(hex: "39FF14"))
                        .cornerRadius(6)
                }
            }
        }
        .padding(12)
        .background(themeManager.theme.backgroundColor.opacity(0.8))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "39FF14").opacity(0.5), lineWidth: 1)
        )
    }

    private var paymentSentBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color(hex: "39FF14"))
                Text("PAYMENT SENT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "39FF14"))
            }

            if let amount = message.formattedAmount {
                Text(amount)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(themeManager.theme.textColor)
            }
        }
        .padding(10)
        .background(Color(hex: "39FF14").opacity(0.1))
        .cornerRadius(8)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Message Status Indicator

/// Cypherpunk-style message status indicator (like Signal/WhatsApp checkmarks)
struct MessageStatusIndicator: View {
    let status: MessageStatus

    var body: some View {
        HStack(spacing: 2) {
            switch status {
            case .sending:
                // Animated sending indicator
                SendingAnimation()

            case .sent:
                // Single shield - sent through Tor
                Image(systemName: "shield.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color.gray)

            case .delivered:
                // Double shield - decrypted by peer
                HStack(spacing: -3) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "39FF14").opacity(0.7))
                    Image(systemName: "shield.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "39FF14").opacity(0.7))
                }

            case .read:
                // Double shield with eye - message was read
                HStack(spacing: -3) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "39FF14"))
                    Image(systemName: "shield.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "39FF14"))
                }
                Image(systemName: "eye.fill")
                    .font(.system(size: 8))
                    .foregroundColor(Color(hex: "39FF14"))

            case .failed:
                // Error indicator
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }
        }
        .accessibilityLabel(status.description)
    }
}

/// Animated indicator for "sending" state
struct SendingAnimation: View {
    @State private var isAnimating = false

    var body: some View {
        Image(systemName: "shield")
            .font(.system(size: 10))
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
    @State private var animationOffset: CGFloat = 0

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color(hex: "39FF14").opacity(0.6))
                        .frame(width: 8, height: 8)
                        .offset(y: animationOffset)
                        .animation(
                            Animation.easeInOut(duration: 0.5)
                                .repeatForever()
                                .delay(Double(index) * 0.15),
                            value: animationOffset
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.3))
            .cornerRadius(16)

            Spacer()
        }
        .onAppear {
            animationOffset = -5
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 48))
                        .foregroundColor(Color(hex: "39FF14"))

                    Text("Add Contact")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(themeManager.theme.textColor)

                    Text("Enter their .onion address to connect")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(themeManager.theme.textColor.opacity(0.6))
                }
                .padding(.top, 20)

                // Form
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ONION ADDRESS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(hex: "39FF14"))

                        TextField("xxxxxxxx...xxxxx.onion", text: $onionAddress)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .padding(12)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(hex: "39FF14").opacity(0.3), lineWidth: 1)
                            )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("NICKNAME (OPTIONAL)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(hex: "39FF14"))

                        TextField("Enter a nickname", text: $nickname)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .monospaced))
                            .padding(12)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(hex: "39FF14").opacity(0.3), lineWidth: 1)
                            )
                    }
                }
                .padding(.horizontal, 20)

                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.red)
                        .padding(.horizontal, 20)
                }

                Spacer()

                // Add button
                Button(action: addContact) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("ADD CONTACT")
                    }
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(hex: "39FF14"))
                    .cornerRadius(8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .disabled(onionAddress.isEmpty)
            }
            .background(themeManager.theme.backgroundColor)
            .navigationTitle("Add Contact")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func addContact() {
        do {
            try chatManager.addContact(onionAddress: onionAddress, nickname: nickname)
            dismiss()
        } catch let error as ChatError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Chat Settings Sheet

struct ChatSettingsSheet: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var chatManager = ChatManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("YOUR IDENTITY") {
                    HStack {
                        Text("Nickname")
                        Spacer()
                        TextField("Enter nickname", text: $chatManager.ourNickname)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 14, design: .monospaced))
                    }

                    if let onion = chatManager.ourOnionAddress {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your .onion Address")
                                .font(.system(size: 12, weight: .medium))
                            Text(onion)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(hex: "39FF14"))
                        }
                    }
                }

                Section("STATUS") {
                    HStack {
                        Text("Chat Service")
                        Spacer()
                        Text(chatManager.isAvailable ? "Online" : "Offline")
                            .foregroundColor(chatManager.isAvailable ? Color(hex: "39FF14") : .red)
                    }

                    HStack {
                        Text("Active Contacts")
                        Spacer()
                        Text("\(chatManager.contacts.count)")
                    }
                }

                Section {
                    Text("\"" + randomCypherpunkQuote() + "\"")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(hex: "39FF14").opacity(0.8))
                        .italic()
                }
            }
            .navigationTitle("Chat Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(Color(hex: "39FF14"))

                Text("Request Payment")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))

                VStack(spacing: 16) {
                    TextField("Amount (ZCL)", text: $amount)
                        .textFieldStyle(.plain)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .keyboardType(.decimalPad)
                        .padding()
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(8)

                    TextField("Memo (optional)", text: $memo)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .padding()
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(8)
                }
                .padding(.horizontal, 20)

                Spacer()

                Button(action: sendRequest) {
                    if isSending {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                    } else {
                        Text("SEND REQUEST")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                    }
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(hex: "39FF14"))
                .cornerRadius(8)
                .padding(.horizontal, 20)
                .disabled(amount.isEmpty || isSending)
            }
            .padding(.vertical, 20)
            .background(themeManager.theme.backgroundColor)
            .navigationTitle("Payment Request")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
                // Get our z-address for payment
                let zAddress = await WalletManager.shared.zAddress ?? ""
                try await chatManager.sendPaymentRequest(to: contact, amount: zatoshis, address: zAddress, memo: memo)
                dismiss()
            } catch {
                print("💬 Failed to send payment request: \(error)")
            }
            isSending = false
        }
    }
}

// MARK: - Corner Radius Extension

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
