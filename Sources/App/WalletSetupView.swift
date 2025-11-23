import SwiftUI

/// Wallet Setup View - Create or restore wallet
/// Classic Macintosh System 7 design
struct WalletSetupView: View {
    @EnvironmentObject var walletManager: WalletManager

    @State private var showCreateWallet = false
    @State private var showImportKey = false
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
                            showImportKey = true
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
        }
        .sheet(isPresented: $showImportKey) {
            importKeyView
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
            .navigationBarHidden(true)
        }
    }

    // MARK: - Import Key View

    private var importKeyView: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text("Import Private Key")
                    .font(System7Theme.titleFont(size: 14))
                    .padding(.top)

                Text("Enter your 64-character hex private key.")
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

                // Character count - support both 64-char hex and Bech32 format
                let cleanInput = privateKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let charCount = cleanInput.count
                let isBech32 = cleanInput.hasPrefix("secret-extended-key-main")
                let isValidLength = charCount == 64 || (isBech32 && charCount > 100)
                Text(isBech32 ? "Bech32 format detected" : "\(charCount)/64 characters")
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
            .navigationBarHidden(true)
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
