import SwiftUI

/// Wallet Setup View - Create or restore wallet
/// Uses current theme from ThemeManager
struct WalletSetupView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var themeManager: ThemeManager

    @State private var showCreateWallet = false
    @State private var showImportKey = false
    @State private var showImportWarning = false
    @State private var mnemonic: [String] = []
    @State private var showMnemonicBackup = false
    @State private var privateKeyInput = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isProcessing = false
    @State private var currentBlockHeight: UInt64 = 0

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        ZStack {
            // Background
            theme.backgroundColor
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Logo/Title
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 64))
                        .foregroundColor(theme.primaryColor)
                        .shadow(color: theme.primaryColor.opacity(0.5), radius: 10)

                    Text("ZipherX")
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.textPrimary)

                    Text("Secure Zclassic Wallet")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textSecondary)
                }

                // Features list
                featuresList

                // Block height display
                if currentBlockHeight > 0 {
                    HStack(spacing: 4) {
                        Text("BLOCK:")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                        Text("\(currentBlockHeight)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.primaryColor)
                    }
                }

                Spacer()

                // Action buttons
                VStack(spacing: 16) {
                    Button(action: { createNewWallet() }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("CREATE NEW WALLET")
                        }
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.backgroundColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(theme.primaryColor)
                        .cornerRadius(theme.cornerRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.cornerRadius)
                                .stroke(theme.primaryColor.opacity(0.5), lineWidth: 1)
                        )
                    }
                    .disabled(isProcessing)
                    .buttonStyle(PlainButtonStyle())

                    Button(action: { showImportWarning = true }) {
                        HStack {
                            Image(systemName: "key.fill")
                            Text("IMPORT PRIVATE KEY")
                        }
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.primaryColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(theme.surfaceColor)
                        .cornerRadius(theme.cornerRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.cornerRadius)
                                .stroke(theme.borderColor, lineWidth: 1)
                        )
                    }
                    .disabled(isProcessing)
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showMnemonicBackup) {
            mnemonicBackupView
                .environmentObject(themeManager)
                #if os(macOS)
                .frame(minWidth: 500, idealWidth: 550, minHeight: 550, idealHeight: 600)
                #endif
        }
        .sheet(isPresented: $showImportWarning) {
            importWarningView
                .environmentObject(themeManager)
                #if os(macOS)
                .frame(minWidth: 550, idealWidth: 600, minHeight: 650, idealHeight: 750)
                #endif
        }
        .sheet(isPresented: $showImportKey) {
            importKeyView
                .environmentObject(themeManager)
                #if os(macOS)
                .frame(minWidth: 500, idealWidth: 550, minHeight: 450, idealHeight: 500)
                #endif
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            fetchBlockHeight()
        }
    }

    private var featuresList: some View {
        VStack(alignment: .leading, spacing: 12) {
            featureRow(icon: "lock.shield", text: "Fully Shielded (z-addresses only)")
            featureRow(icon: "network", text: "Decentralized (8+ peer consensus)")
            featureRow(icon: "cpu", text: "Secure Enclave protection")
            featureRow(icon: "checkmark.seal", text: "Local proof verification")
        }
        .padding(16)
        .background(theme.surfaceColor.opacity(0.8))
        .cornerRadius(theme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: 1)
        )
        .padding(.horizontal, 32)
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(theme.primaryColor)
                .frame(width: 20)
            Text(text)
                .font(theme.bodyFont)
                .foregroundColor(theme.textPrimary)
        }
    }

    // MARK: - Mnemonic Backup View

    private var mnemonicBackupView: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()

            VStack(spacing: 20) {
                // Warning header
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(theme.warningColor)

                    Text("BACKUP YOUR SEED PHRASE")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.textPrimary)

                    Text("Write these words down. This is your ONLY way to recover your wallet.")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 24)

                // Mnemonic words grid
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(Array(mnemonic.enumerated()), id: \.offset) { index, word in
                            HStack(spacing: 4) {
                                Text("\(index + 1).")
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundColor(theme.textSecondary)
                                    .frame(width: 24, alignment: .trailing)

                                Text(word)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(theme.primaryColor)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.surfaceColor)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(theme.borderColor, lineWidth: 1)
                            )
                        }
                    }
                    .padding()
                }

                // Confirm button
                Button(action: { showMnemonicBackup = false }) {
                    Text("I'VE SAVED MY SEED PHRASE")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.backgroundColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(theme.primaryColor)
                        .cornerRadius(theme.cornerRadius)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Import Warning View (Cypherpunk Privacy Notice)

    private var importWarningView: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 56))
                        .foregroundColor(theme.warningColor)

                    Text("PRIVACY WARNING")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.textPrimary)
                }
                .padding(.top, 32)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Cypherpunk manifesto quote
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\"Privacy is necessary for an open society in the electronic age.\"")
                                .font(.system(size: 13, weight: .regular, design: .monospaced))
                                .italic()
                                .foregroundColor(theme.primaryColor)

                            Text("— A Cypherpunk's Manifesto, 1993")
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.surfaceColor)
                        .cornerRadius(theme.cornerRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.cornerRadius)
                                .stroke(theme.primaryColor.opacity(0.3), lineWidth: 1)
                        )

                        // Warning sections
                        warningSection(
                            title: "ADDRESS REUSE",
                            icon: "link.badge.plus",
                            content: "Importing a key used elsewhere may reduce privacy. Transactions can be linked by observers."
                        )

                        warningSection(
                            title: "HISTORICAL SCAN",
                            icon: "clock.arrow.circlepath",
                            content: "Finding old transactions requires scanning blockchain history. Quick scan: 2-5 min. Full scan: 30-60 min."
                        )

                        warningSection(
                            title: "KEY SECURITY",
                            icon: "key.fill",
                            content: "Never import keys from untrusted sources. Anyone with your key can spend your funds."
                        )

                        // Fast start info
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(theme.primaryColor)
                                Text("FAST START")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(theme.textPrimary)
                            }

                            Text("ZipherX scans recent blocks by default. Use Settings → Quick Scan for older notes.")
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)
                        }
                        .padding()
                        .background(theme.primaryColor.opacity(0.1))
                        .cornerRadius(theme.cornerRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.cornerRadius)
                                .stroke(theme.primaryColor.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .padding()
                }

                // Action buttons
                VStack(spacing: 12) {
                    Button(action: {
                        showImportWarning = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showImportKey = true
                        }
                    }) {
                        Text("I UNDERSTAND, CONTINUE")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.backgroundColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(theme.primaryColor)
                            .cornerRadius(theme.cornerRadius)
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: { showImportWarning = false }) {
                        Text("Cancel")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(24)
                .background(theme.surfaceColor)
            }
        }
    }

    private func warningSection(title: String, icon: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(theme.warningColor)
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
            }

            Text(content)
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warningColor.opacity(0.1))
        .cornerRadius(theme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.warningColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Import Key View

    private var importKeyView: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()

            VStack(spacing: 20) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 48))
                        .foregroundColor(theme.primaryColor)

                    Text("IMPORT PRIVATE KEY")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.textPrimary)

                    Text("Enter your Bech32 key (secret-extended-key-main1...) or 338-char hex key.")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 24)

                // Private key input
                TextEditor(text: $privateKeyInput)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(height: 100)
                    .padding(12)
                    .background(theme.surfaceColor)
                    .cornerRadius(theme.cornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .stroke(theme.borderColor, lineWidth: 1)
                    )
                    .padding(.horizontal, 24)

                // Character count / validation
                let cleanInput = privateKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let charCount = cleanInput.count
                let isBech32 = cleanInput.hasPrefix("secret-extended-key-main")
                let isValidLength = charCount == 338 || (isBech32 && charCount > 100)

                HStack {
                    if isBech32 {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(theme.successColor)
                        Text("Bech32 format detected")
                            .foregroundColor(theme.successColor)
                    } else if charCount == 338 {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(theme.successColor)
                        Text("Hex format detected")
                            .foregroundColor(theme.successColor)
                    } else {
                        Text("\(charCount)/338 characters")
                            .foregroundColor(theme.textSecondary)
                    }
                }
                .font(.system(size: 11, weight: .regular, design: .monospaced))

                Spacer()

                // Buttons
                VStack(spacing: 12) {
                    Button(action: { importPrivateKey() }) {
                        HStack {
                            if isProcessing {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(theme.backgroundColor)
                            }
                            Text(isProcessing ? "IMPORTING..." : "IMPORT KEY")
                        }
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.backgroundColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(isValidLength && !isProcessing ? theme.primaryColor : theme.textSecondary)
                        .cornerRadius(theme.cornerRadius)
                    }
                    .disabled(!isValidLength || isProcessing)
                    .buttonStyle(PlainButtonStyle())

                    Button(action: {
                        showImportKey = false
                        privateKeyInput = ""
                    }) {
                        Text("Cancel")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Actions

    private func fetchBlockHeight() {
        Task {
            do {
                let status = try await InsightAPI.shared.getStatus()
                await MainActor.run {
                    currentBlockHeight = status.height
                }
            } catch {
                print("Failed to fetch block height: \(error)")
            }
        }
    }

    private func createNewWallet() {
        isProcessing = true

        Task {
            do {
                let words = try walletManager.createNewWallet()

                await MainActor.run {
                    mnemonic = words
                    isProcessing = false
                    showMnemonicBackup = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isProcessing = false
                }
            }
        }
    }

    private func importPrivateKey() {
        isProcessing = true

        Task {
            do {
                try walletManager.importSpendingKey(privateKeyInput)

                await MainActor.run {
                    showImportKey = false
                    privateKeyInput = ""
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isProcessing = false
                }
            }
        }
    }
}

#Preview {
    WalletSetupView()
        .environmentObject(WalletManager.shared)
        .environmentObject(ThemeManager.shared)
}
