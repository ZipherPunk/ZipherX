import SwiftUI

/// Wallet Setup View - Create or restore wallet
/// Classic Macintosh System 7 design
struct WalletSetupView: View {
    @EnvironmentObject var walletManager: WalletManager

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

    var body: some View {
        VStack(spacing: 0) {
            System7MenuBar()

            System7Window(title: "Welcome to ZipherX") {
                VStack(spacing: 24) {
                    // Logo/Title
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 48))
                            .foregroundColor(System7Theme.black)

                        Text("ZipherX")
                            .font(System7Theme.titleFont(size: 18))
                            .foregroundColor(System7Theme.black)

                        Text("Secure Zclassic Wallet")
                            .font(System7Theme.bodyFont(size: 11))
                            .foregroundColor(System7Theme.darkGray)
                    }
                    .padding(.top, 20)

                    // Features list
                    featuresList

                    Spacer()

                    // Block height display
                    if currentBlockHeight > 0 {
                        Text("Block Height: \(currentBlockHeight)")
                            .font(System7Theme.bodyFont(size: 9))
                            .foregroundColor(System7Theme.darkGray)
                    }

                    // Action buttons
                    VStack(spacing: 12) {
                        System7Button(title: "Create New Wallet") {
                            createNewWallet()
                        }
                        .disabled(isProcessing)

                        System7Button(title: "Import Private Key") {
                            showImportWarning = true
                        }
                        .disabled(isProcessing)
                    }
                    .padding(.bottom, 20)
                }
                .padding()
            }
            .padding()
        }
        .sheet(isPresented: $showMnemonicBackup) {
            mnemonicBackupView
                #if os(macOS)
                .frame(minWidth: 450, idealWidth: 500, minHeight: 500, idealHeight: 550)
                #endif
        }
        .sheet(isPresented: $showImportWarning) {
            importWarningView
                #if os(macOS)
                .frame(minWidth: 500, idealWidth: 550, minHeight: 600, idealHeight: 700)
                #endif
        }
        .sheet(isPresented: $showImportKey) {
            importKeyView
                #if os(macOS)
                .frame(minWidth: 450, idealWidth: 500, minHeight: 400, idealHeight: 450)
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
        VStack(alignment: .leading, spacing: 8) {
            featureRow(icon: "lock.shield", text: "Fully Shielded (z-addresses only)")
            featureRow(icon: "network", text: "Decentralized (8+ peer consensus)")
            featureRow(icon: "cpu", text: "Secure Enclave protection")
            featureRow(icon: "checkmark.seal", text: "Local proof verification")
        }
        .padding(12)
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 16)
            Text(text)
                .font(System7Theme.bodyFont(size: 10))
        }
        .foregroundColor(System7Theme.black)
    }

    // MARK: - Mnemonic Backup View

    private var mnemonicBackupView: some View {
        NavigationView {
            VStack(spacing: 16) {
                // Warning
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)

                    Text("Write Down Your Seed Phrase!")
                        .font(System7Theme.titleFont(size: 14))

                    Text("This is your ONLY way to recover your wallet. Store it securely offline. Never share it with anyone.")
                        .font(System7Theme.bodyFont(size: 10))
                        .foregroundColor(System7Theme.darkGray)
                        .multilineTextAlignment(.center)
                }
                .padding()

                // Mnemonic words
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(Array(mnemonic.enumerated()), id: \.offset) { index, word in
                            HStack(spacing: 4) {
                                Text("\(index + 1).")
                                    .font(System7Theme.bodyFont(size: 9))
                                    .foregroundColor(System7Theme.darkGray)
                                    .frame(width: 20, alignment: .trailing)

                                Text(word)
                                    .font(System7Theme.bodyFont(size: 10))
                                    .foregroundColor(System7Theme.black)
                            }
                            .padding(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(System7Theme.white)
                            .overlay(
                                Rectangle()
                                    .stroke(System7Theme.black, lineWidth: 1)
                            )
                        }
                    }
                    .padding()
                }

                // Confirm button
                System7Button(title: "I've Saved My Seed Phrase") {
                    showMnemonicBackup = false
                }
                .padding()
            }
            .background(System7Theme.lightGray)
            #if os(iOS)
            .navigationBarHidden(true)
            #endif
        }
    }

    // MARK: - Import Warning View (Cypherpunk Privacy Notice)

    private var importWarningView: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header with skull icon
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)

                    Text("PRIVACY WARNING")
                        .font(System7Theme.titleFont(size: 16))
                        .foregroundColor(System7Theme.black)
                }
                .padding(.top, 24)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Cypherpunk manifesto quote
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\"Privacy is necessary for an open society in the electronic age.\"")
                                .font(System7Theme.bodyFont(size: 11))
                                .italic()
                                .foregroundColor(System7Theme.darkGray)

                            Text("— A Cypherpunk's Manifesto, 1993")
                                .font(System7Theme.bodyFont(size: 9))
                                .foregroundColor(System7Theme.darkGray)
                        }
                        .padding()
                        .background(Color.black.opacity(0.05))
                        .overlay(
                            Rectangle()
                                .stroke(System7Theme.darkGray, lineWidth: 1)
                        )

                        // Privacy implications
                        warningSection(
                            title: "Address Reuse Degrades Privacy",
                            icon: "eye.slash",
                            content: "Importing a key that has been used elsewhere may reduce your privacy. Each transaction from a reused address can be linked together by blockchain observers."
                        )

                        // Historical scan warning
                        warningSection(
                            title: "Historical Scan Required",
                            icon: "clock.arrow.circlepath",
                            content: "To find all your previous transactions, the wallet needs to scan the blockchain history. A quick scan of recent blocks (~10,000) takes about 2-5 minutes. Older transactions may require a full historical scan (30-60 minutes)."
                        )

                        // Key security
                        warningSection(
                            title: "Key Security",
                            icon: "key.fill",
                            content: "Never import a key from an untrusted source. If anyone else has seen your private key, they can spend your funds. Your key is your sole proof of ownership."
                        )

                        // Fast start info
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(.blue)
                                Text("Fast Start Mode")
                                    .font(System7Theme.titleFont(size: 11))
                            }

                            Text("By default, ZipherX scans only recent blocks for fast wallet setup. If your notes are older than ~17 days, use Settings → Quick Scan or Full Rescan to find them.")
                                .font(System7Theme.bodyFont(size: 10))
                                .foregroundColor(System7Theme.darkGray)
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .overlay(
                            Rectangle()
                                .stroke(Color.blue.opacity(0.5), lineWidth: 1)
                        )
                    }
                    .padding()
                }

                // Action buttons
                VStack(spacing: 12) {
                    System7Button(title: "I Understand, Continue") {
                        showImportWarning = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showImportKey = true
                        }
                    }

                    Button("Cancel") {
                        showImportWarning = false
                    }
                    .font(System7Theme.bodyFont(size: 11))
                    .foregroundColor(System7Theme.darkGray)
                }
                .padding()
                .background(System7Theme.lightGray)
            }
            .background(System7Theme.lightGray)
            #if os(iOS)
            .navigationBarHidden(true)
            #endif
        }
    }

    private func warningSection(title: String, icon: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.orange)
                Text(title)
                    .font(System7Theme.titleFont(size: 11))
            }

            Text(content)
                .font(System7Theme.bodyFont(size: 10))
                .foregroundColor(System7Theme.darkGray)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .overlay(
            Rectangle()
                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Import Key View

    private var importKeyView: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text("Import Private Key")
                    .font(System7Theme.titleFont(size: 14))
                    .padding(.top)

                Text("Enter your Bech32 private key (secret-extended-key-main1...) or 338-character hex key.")
                    .font(System7Theme.bodyFont(size: 10))
                    .foregroundColor(System7Theme.darkGray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // Private key input
                TextEditor(text: $privateKeyInput)
                    .font(System7Theme.bodyFont(size: 10))
                    .frame(height: 80)
                    .padding(8)
                    .background(System7Theme.white)
                    .overlay(
                        Rectangle()
                            .stroke(System7Theme.black, lineWidth: 1)
                    )
                    .padding(.horizontal)

                // Character count - support both 338-char hex and Bech32 format
                let cleanInput = privateKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let charCount = cleanInput.count
                let isBech32 = cleanInput.hasPrefix("secret-extended-key-main")
                // 169 bytes = 338 hex chars, or Bech32 format (typically ~280 chars)
                let isValidLength = charCount == 338 || (isBech32 && charCount > 100)
                Text(isBech32 ? "Bech32 format detected ✓" : (charCount == 338 ? "Hex format detected ✓" : "\(charCount)/338 characters"))
                    .font(System7Theme.bodyFont(size: 9))
                    .foregroundColor(isValidLength ? .green : System7Theme.darkGray)

                Spacer()

                // Buttons
                HStack(spacing: 12) {
                    System7Button(title: "Cancel") {
                        showImportKey = false
                        privateKeyInput = ""
                    }

                    System7Button(title: "Import") {
                        importPrivateKey()
                    }
                    .disabled(!isValidLength || isProcessing)
                }
                .padding()
            }
            .background(System7Theme.lightGray)
            #if os(iOS)
            .navigationBarHidden(true)
            #endif
        }
    }

    // MARK: - Actions

    private func fetchBlockHeight() {
        Task {
            do {
                let status = try await InsightAPI.shared.getStatus()
                DispatchQueue.main.async {
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

                DispatchQueue.main.async {
                    mnemonic = words
                    isProcessing = false
                    showMnemonicBackup = true
                }
            } catch {
                DispatchQueue.main.async {
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

                DispatchQueue.main.async {
                    showImportKey = false
                    privateKeyInput = ""
                    isProcessing = false
                }
            } catch {
                DispatchQueue.main.async {
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
}
