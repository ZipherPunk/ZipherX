import SwiftUI

/// Wallet Setup View - Create or restore wallet
/// Uses current theme from ThemeManager
struct WalletSetupView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var themeManager: ThemeManager

    @State private var showCreateWallet = false
    @State private var showImportKey = false
    @State private var showImportWarning = false
    @State private var showRestoreMnemonic = false  // Restore from seed phrase
    @State private var mnemonic: [String] = []
    @State private var showMnemonicBackup = false
    @State private var privateKeyInput = ""
    @State private var mnemonicInputWords: [String] = Array(repeating: "", count: 24)  // For restore
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isProcessing = false
    @State private var currentBlockHeight: UInt64 = 0
    @State private var showMnemonicWords = false  // Hidden by default for cypherpunk security
    @State private var showPrivateKeyInput = false  // Hidden by default
    @State private var showMnemonicInput = false  // Hidden by default for restore

    /* DISABLED: Scan options no longer needed - full scan is fast (2-5 min) with parallel decryption
    // Scan options for imported wallets
    @State private var showScanOptions = false
    @State private var scanOptionSelected: ScanOption = .fullScan
    @State private var customScanDate: Date = Date()
    @State private var pendingImportAction: (() -> Void)? = nil  // Action to execute after scan option selected

    enum ScanOption {
        case fullScan
        case fromDate
    }
    */

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

                    Button(action: { showRestoreMnemonic = true }) {
                        HStack {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                            Text("RESTORE FROM SEED")
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

                    Button(action: { showImportWarning = true }) {
                        HStack {
                            Image(systemName: "key.fill")
                            Text("IMPORT PRIVATE KEY")
                        }
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(theme.surfaceColor.opacity(0.5))
                        .cornerRadius(theme.cornerRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.cornerRadius)
                                .stroke(theme.borderColor.opacity(0.5), lineWidth: 1)
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
                .frame(minWidth: 550, idealWidth: 600, minHeight: 850, idealHeight: 950)
                #else
                .presentationDetents([.large])
                #endif
        }
        .sheet(isPresented: $showImportKey) {
            importKeyView
                .environmentObject(themeManager)
                #if os(macOS)
                .frame(minWidth: 500, idealWidth: 550, minHeight: 450, idealHeight: 500)
                #endif
        }
        .sheet(isPresented: $showRestoreMnemonic) {
            restoreMnemonicView
                .environmentObject(themeManager)
                #if os(macOS)
                .frame(minWidth: 550, idealWidth: 600, minHeight: 650, idealHeight: 750)
                #endif
        }
        /* DISABLED: Scan options no longer needed - full scan is fast (2-5 min) with parallel decryption
        .sheet(isPresented: $showScanOptions) {
            scanOptionsView
                .environmentObject(themeManager)
                #if os(macOS)
                .frame(minWidth: 500, idealWidth: 550, minHeight: 550, idealHeight: 600)
                #endif
        }
        */
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

                // Security notice when hidden
                if !showMnemonicWords {
                    VStack(spacing: 16) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 40))
                            .foregroundColor(theme.primaryColor)

                        Text("SEED PHRASE HIDDEN")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.textPrimary)

                        Text("For your security, your seed phrase is hidden by default.\nMake sure no one is watching your screen.")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        // Reveal button
                        Button(action: { showMnemonicWords = true }) {
                            HStack {
                                Image(systemName: "eye.fill")
                                Text("REVEAL SEED PHRASE")
                            }
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.warningColor)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(theme.warningColor.opacity(0.15))
                            .cornerRadius(theme.cornerRadius)
                            .overlay(
                                RoundedRectangle(cornerRadius: theme.cornerRadius)
                                    .stroke(theme.warningColor.opacity(0.5), lineWidth: 1)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
                    .background(theme.surfaceColor)
                    .cornerRadius(theme.cornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .stroke(theme.borderColor, lineWidth: 1)
                    )
                    .padding(.horizontal, 24)
                }

                // Mnemonic words grid (only shown when revealed)
                if showMnemonicWords {
                    // Warning banner
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundColor(theme.warningColor)
                            .font(.system(size: 12))
                        Text("SENSITIVE DATA - ENSURE PRIVACY")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.warningColor)
                        Spacer()
                        Button(action: { showMnemonicWords = false }) {
                            Image(systemName: "eye.slash")
                                .foregroundColor(theme.textSecondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(8)
                    .background(theme.warningColor.opacity(0.15))
                    .cornerRadius(theme.cornerRadius)
                    .padding(.horizontal, 16)

                    // 24 words in a 4-column grid (6 rows) - all visible without scrolling
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 6),
                        GridItem(.flexible(), spacing: 6),
                        GridItem(.flexible(), spacing: 6),
                        GridItem(.flexible(), spacing: 6)
                    ], spacing: 6) {
                        ForEach(Array(mnemonic.enumerated()), id: \.offset) { index, word in
                            HStack(spacing: 2) {
                                Text("\(index + 1).")
                                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                                    .foregroundColor(theme.textSecondary)
                                    .frame(width: 18, alignment: .trailing)

                                Text(word)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(theme.primaryColor)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.surfaceColor)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(theme.borderColor, lineWidth: 1)
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }

                Spacer()

                // Confirm button
                Button(action: {
                    showMnemonicWords = false  // Reset for next time
                    showMnemonicBackup = false
                    // Confirm backup and complete wallet creation
                    walletManager.confirmMnemonicBackup()
                }) {
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
                            title: "FULL BLOCKCHAIN SCAN",
                            icon: "clock.arrow.circlepath",
                            content: "ZipherX will scan the entire blockchain to find your transactions. This takes approximately 2-5 minutes."
                        )

                        warningSection(
                            title: "KEY SECURITY",
                            icon: "key.fill",
                            content: "Never import keys from untrusted sources. Anyone with your key can spend your funds."
                        )

                        // Parallel scanning info
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(theme.primaryColor)
                                Text("PARALLEL SCANNING")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(theme.textPrimary)
                            }

                            Text("ZipherX uses parallel note decryption and pre-built commitment trees for fast imports.")
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

    /* DISABLED: Scan options no longer needed - full scan is fast (2-5 min) with parallel decryption
    // MARK: - Scan Options View

    private var scanOptionsView: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 56))
                        .foregroundColor(theme.primaryColor)

                    Text("SCAN OPTIONS")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.textPrimary)

                    Text("Choose how far back to scan for your notes")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)
                .padding(.horizontal)

                ScrollView {
                    VStack(spacing: 16) {
                        // Option 1: Full Scan
                        scanOptionButton(
                            title: "FULL HISTORICAL SCAN",
                            subtitle: "From Sapling activation (Nov 2016)",
                            duration: WalletManager.estimatedScanDuration(from: 476_969),
                            icon: "clock.fill",
                            isSelected: scanOptionSelected == .fullScan,
                            action: { scanOptionSelected = .fullScan }
                        )

                        // Option 2: From Date
                        VStack(spacing: 12) {
                            scanOptionButton(
                                title: "SCAN FROM DATE",
                                subtitle: "Faster if you know when you first received ZCL",
                                duration: scanOptionSelected == .fromDate
                                    ? WalletManager.estimatedScanDuration(from: WalletManager.blockHeightForDate(customScanDate))
                                    : nil,
                                icon: "calendar",
                                isSelected: scanOptionSelected == .fromDate,
                                action: { scanOptionSelected = .fromDate }
                            )

                            // Date picker (only shown when fromDate is selected)
                            if scanOptionSelected == .fromDate {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Select the earliest date you may have received ZCL:")
                                        .font(theme.captionFont)
                                        .foregroundColor(theme.textSecondary)

                                    // Compact date picker - tap to open calendar, auto-closes on selection
                                    HStack {
                                        DatePicker(
                                            "Start Date",
                                            selection: $customScanDate,
                                            in: WalletManager.saplingActivationDate...Date(),
                                            displayedComponents: .date
                                        )
                                        .datePickerStyle(.compact)
                                        .labelsHidden()
                                        .accentColor(theme.primaryColor)
                                        .colorScheme(.dark)  // Force dark mode for better contrast

                                        Spacer()
                                    }
                                    .padding(12)
                                    .background(Color.black.opacity(0.4))
                                    .cornerRadius(8)

                                    // Show estimated block height with brighter colors
                                    let estimatedHeight = WalletManager.blockHeightForDate(customScanDate)
                                    HStack {
                                        Text("≈ Block")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(theme.textPrimary)
                                        Text("\(estimatedHeight.formatted())")
                                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                                            .foregroundColor(theme.primaryColor)

                                        Spacer()

                                        // Show estimated duration for this date
                                        Text(WalletManager.estimatedScanDuration(from: estimatedHeight))
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundColor(theme.primaryColor.opacity(0.8))
                                    }
                                }
                                .padding()
                                .background(theme.surfaceColor)
                                .cornerRadius(theme.cornerRadius)
                                .overlay(
                                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                                        .stroke(theme.primaryColor.opacity(0.3), lineWidth: 1)
                                )
                            }
                        }

                        // Info box
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(theme.primaryColor)
                                Text("NOTE")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(theme.textPrimary)
                            }

                            Text("If you scan from a date AFTER your first transaction, those early notes won't be found. When in doubt, use Full Scan.")
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)
                        }
                        .padding()
                        .background(theme.primaryColor.opacity(0.1))
                        .cornerRadius(theme.cornerRadius)
                    }
                    .padding()
                }

                // Action buttons
                VStack(spacing: 12) {
                    Button(action: {
                        // Set the scan start height based on selection
                        if scanOptionSelected == .fullScan {
                            walletManager.importScanStartHeight = nil  // Full scan
                        } else {
                            walletManager.importScanStartHeight = WalletManager.blockHeightForDate(customScanDate)
                        }

                        showScanOptions = false

                        // Execute the pending import action
                        if let action = pendingImportAction {
                            action()
                            pendingImportAction = nil
                        }
                    }) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("START SCAN")
                        }
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.backgroundColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(theme.primaryColor)
                        .cornerRadius(theme.cornerRadius)
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: {
                        showScanOptions = false
                        pendingImportAction = nil
                    }) {
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

    private func scanOptionButton(title: String, subtitle: String, duration: String?, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Radio button
                Circle()
                    .stroke(isSelected ? theme.primaryColor : theme.borderColor, lineWidth: 2)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle()
                            .fill(isSelected ? theme.primaryColor : Color.clear)
                            .frame(width: 14, height: 14)
                    )

                // Icon
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? theme.primaryColor : theme.textSecondary)
                    .frame(width: 32)

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? theme.textPrimary : theme.textSecondary)

                    Text(subtitle)
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let duration = duration {
                        Text("Est. time: \(duration)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.primaryColor)
                    }
                }

                Spacer()
            }
            .padding()
            .background(isSelected ? theme.primaryColor.opacity(0.1) : theme.surfaceColor)
            .cornerRadius(theme.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(isSelected ? theme.primaryColor : theme.borderColor, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    */

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

                // Private key input (hidden by default)
                ZStack {
                    if showPrivateKeyInput {
                        // Visible input
                        VStack(spacing: 8) {
                            // Warning banner when visible
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .foregroundColor(theme.warningColor)
                                Text("KEY VISIBLE - ENSURE PRIVACY")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(theme.warningColor)
                                Spacer()
                                Button(action: { showPrivateKeyInput = false }) {
                                    Image(systemName: "eye.slash")
                                        .foregroundColor(theme.textSecondary)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(10)
                            .background(theme.warningColor.opacity(0.15))
                            .cornerRadius(theme.cornerRadius)

                            TextEditor(text: $privateKeyInput)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(theme.textPrimary)
                                .frame(height: 100)
                                .padding(12)
                                .background(theme.surfaceColor)
                                .cornerRadius(theme.cornerRadius)
                                .overlay(
                                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                                        .stroke(theme.borderColor, lineWidth: 1)
                                )
                        }
                    } else {
                        // Hidden input with masked display
                        VStack(spacing: 12) {
                            // Masked display
                            HStack {
                                if privateKeyInput.isEmpty {
                                    Text("Paste your private key here...")
                                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                                        .foregroundColor(theme.textSecondary.opacity(0.5))
                                } else {
                                    Text(maskedKeyDisplay)
                                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                                        .foregroundColor(theme.primaryColor)
                                }
                                Spacer()
                            }
                            .frame(height: 80)
                            .padding(12)
                            .background(theme.surfaceColor)
                            .cornerRadius(theme.cornerRadius)
                            .overlay(
                                RoundedRectangle(cornerRadius: theme.cornerRadius)
                                    .stroke(theme.borderColor, lineWidth: 1)
                            )
                            .onTapGesture {
                                // Paste from clipboard when tapped
                                #if os(macOS)
                                if let clipboardString = NSPasteboard.general.string(forType: .string) {
                                    privateKeyInput = clipboardString
                                }
                                #else
                                if let clipboardString = UIPasteboard.general.string {
                                    privateKeyInput = clipboardString
                                }
                                #endif
                            }

                            // Action buttons
                            HStack(spacing: 12) {
                                Button(action: {
                                    #if os(macOS)
                                    if let clipboardString = NSPasteboard.general.string(forType: .string) {
                                        privateKeyInput = clipboardString
                                    }
                                    #else
                                    if let clipboardString = UIPasteboard.general.string {
                                        privateKeyInput = clipboardString
                                    }
                                    #endif
                                }) {
                                    HStack {
                                        Image(systemName: "doc.on.clipboard")
                                        Text("PASTE")
                                    }
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(theme.primaryColor)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(theme.surfaceColor)
                                    .cornerRadius(theme.cornerRadius)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                                            .stroke(theme.borderColor, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())

                                if !privateKeyInput.isEmpty {
                                    Button(action: { showPrivateKeyInput = true }) {
                                        HStack {
                                            Image(systemName: "eye")
                                            Text("REVEAL")
                                        }
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(theme.warningColor)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(theme.warningColor.opacity(0.15))
                                        .cornerRadius(theme.cornerRadius)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: theme.cornerRadius)
                                                .stroke(theme.warningColor.opacity(0.5), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(PlainButtonStyle())

                                    Button(action: { privateKeyInput = "" }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(theme.textSecondary)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }
                    }
                }
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
                    } else if charCount > 0 {
                        Text("\(charCount) characters (hidden)")
                            .foregroundColor(theme.textSecondary)
                    } else {
                        Text("Tap to paste from clipboard")
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
                        showPrivateKeyInput = false
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

    // Helper to show masked key
    private var maskedKeyDisplay: String {
        let clean = privateKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count <= 8 {
            return String(repeating: "•", count: clean.count)
        }
        let prefix = String(clean.prefix(4))
        let suffix = String(clean.suffix(4))
        let middle = String(repeating: "•", count: min(clean.count - 8, 30))
        return "\(prefix)\(middle)\(suffix)"
    }

    // Helper computed properties to reduce type-check complexity
    private var mnemonicFilledWordsCount: Int {
        mnemonicInputWords.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    private var isMnemonicComplete: Bool {
        mnemonicFilledWordsCount == 24
    }

    // MARK: - Restore Mnemonic Sub-Views (broken up to help compiler)

    private var mnemonicHeaderView: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(theme.primaryColor)

            Text("RESTORE FROM SEED")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(theme.textPrimary)

            Text("Enter your 24-word seed phrase to restore your wallet.")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.top, 24)
    }

    private var mnemonicHiddenNoticeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 40))
                .foregroundColor(theme.primaryColor)

            Text("SEED PHRASE HIDDEN")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(theme.textPrimary)

            Text("For your security, seed phrase input is hidden by default.\nMake sure no one is watching your screen.")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(action: { showMnemonicInput = true }) {
                HStack {
                    Image(systemName: "eye.fill")
                    Text("ENTER SEED PHRASE")
                }
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(theme.warningColor)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(theme.warningColor.opacity(0.15))
                .cornerRadius(theme.cornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(theme.warningColor.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .background(theme.surfaceColor)
        .cornerRadius(theme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }

    private var mnemonicWarningBannerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundColor(theme.warningColor)
            Text("SENSITIVE DATA - ENSURE PRIVACY")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(theme.warningColor)
            Spacer()
            Button(action: { showMnemonicInput = false }) {
                Image(systemName: "eye.slash")
                    .foregroundColor(theme.textSecondary)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(10)
        .background(theme.warningColor.opacity(0.15))
        .cornerRadius(theme.cornerRadius)
        .padding(.horizontal, 24)
    }

    private var mnemonicWordCountView: some View {
        HStack {
            Text("\(mnemonicFilledWordsCount)/24 words entered")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(isMnemonicComplete ? theme.successColor : theme.textSecondary)

            Spacer()

            Button(action: { pasteAllWords() }) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.clipboard")
                    Text("PASTE ALL")
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(theme.primaryColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.surfaceColor)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(theme.borderColor, lineWidth: 1)
                )
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: { mnemonicInputWords = Array(repeating: "", count: 24) }) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle")
                    Text("CLEAR")
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.surfaceColor)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(theme.borderColor, lineWidth: 1)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 24)
    }

    private func mnemonicWordCell(index: Int) -> some View {
        HStack(spacing: 4) {
            Text("\(index + 1).")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(theme.textSecondary)
                .frame(width: 24, alignment: .trailing)

            TextField("", text: $mnemonicInputWords[index])
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(theme.primaryColor)
                .textFieldStyle(PlainTextFieldStyle())
                #if os(iOS)
                .autocapitalization(.none)
                #endif
                .disableAutocorrection(true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(mnemonicInputWords[index].isEmpty ? theme.borderColor : theme.primaryColor.opacity(0.5), lineWidth: 1)
        )
    }

    private var mnemonicGridView: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                ForEach(0..<24, id: \.self) { index in
                    mnemonicWordCell(index: index)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private var mnemonicButtonsView: some View {
        VStack(spacing: 12) {
            Button(action: { restoreFromMnemonic() }) {
                HStack {
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(theme.backgroundColor)
                    }
                    Text(isProcessing ? "RESTORING..." : "RESTORE WALLET")
                }
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(theme.backgroundColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(isMnemonicComplete && !isProcessing ? theme.primaryColor : theme.textSecondary)
                .cornerRadius(theme.cornerRadius)
            }
            .disabled(!isMnemonicComplete || isProcessing)
            .buttonStyle(PlainButtonStyle())

            Button(action: {
                showRestoreMnemonic = false
                showMnemonicInput = false
                mnemonicInputWords = Array(repeating: "", count: 24)
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

    // MARK: - Restore Mnemonic View (using sub-views)

    private var restoreMnemonicView: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()

            VStack(spacing: 16) {
                mnemonicHeaderView

                if !showMnemonicInput {
                    mnemonicHiddenNoticeView
                }

                if showMnemonicInput {
                    mnemonicWarningBannerView
                    mnemonicWordCountView
                    mnemonicGridView
                }

                Spacer()

                mnemonicButtonsView
            }
        }
    }

    /// Paste all words from clipboard (space-separated)
    private func pasteAllWords() {
        #if os(macOS)
        guard let clipboardString = NSPasteboard.general.string(forType: .string) else { return }
        #else
        guard let clipboardString = UIPasteboard.general.string else { return }
        #endif

        let words = clipboardString
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        // Fill in words up to 24
        for (index, word) in words.prefix(24).enumerated() {
            mnemonicInputWords[index] = word
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
        print("📝 CREATE WALLET: Starting wallet creation...")

        Task {
            do {
                let words = try walletManager.createNewWallet()
                print("📝 CREATE WALLET: Generated \(words.count) words")
                print("📝 CREATE WALLET: First word: \(words.first ?? "NONE")")

                await MainActor.run {
                    mnemonic = words
                    print("📝 CREATE WALLET: Set mnemonic with \(mnemonic.count) words")
                    isProcessing = false
                    showMnemonicBackup = true
                    print("📝 CREATE WALLET: Showing backup sheet")
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
        // Close import sheet and start full scan immediately (fast with parallel decryption)
        let keyToImport = privateKeyInput
        showImportKey = false

        // Set full scan mode (nil = scan from Sapling activation)
        walletManager.importScanStartHeight = nil

        isProcessing = true

        Task {
            do {
                try self.walletManager.importSpendingKey(keyToImport)

                await MainActor.run {
                    self.privateKeyInput = ""
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                    self.isProcessing = false
                }
            }
        }
    }

    private func restoreFromMnemonic() {
        // Clean up words (trim whitespace, lowercase)
        let cleanedWords = mnemonicInputWords.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        // Close restore sheet and start full scan immediately (fast with parallel decryption)
        showRestoreMnemonic = false
        showMnemonicInput = false

        // Set full scan mode (nil = scan from Sapling activation)
        walletManager.importScanStartHeight = nil

        isProcessing = true

        Task {
            do {
                try self.walletManager.restoreWallet(from: cleanedWords)

                await MainActor.run {
                    self.mnemonicInputWords = Array(repeating: "", count: 24)
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                    self.isProcessing = false
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
