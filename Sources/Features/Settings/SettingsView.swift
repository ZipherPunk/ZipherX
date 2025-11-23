import SwiftUI
import LocalAuthentication

/// Settings View - Export keys, PIN code, Face ID setup
/// Classic Macintosh System 7 design
struct SettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var showExportAlert = false
    @State private var exportedKey = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var useFaceID = false
    @State private var usePINCode = false
    @State private var showPINSetup = false
    @State private var pinCode = ""
    @State private var confirmPIN = ""
    @State private var biometricAvailable = false

    var body: some View {
        VStack(spacing: 16) {
            // Security section
            securitySection

            // Export section
            exportSection

            Spacer()
        }
        .padding()
        .onAppear {
            checkBiometricAvailability()
        }
        .alert("Export Private Key", isPresented: $showExportAlert) {
            Button("Copy to Clipboard") {
                UIPasteboard.general.string = exportedKey
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your private key:\n\n\(exportedKey)\n\nKeep this safe! Anyone with this key can spend your funds.")
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showPINSetup) {
            pinSetupSheet
        }
    }

    // MARK: - Security Section

    private var securitySection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12))
                Text("Security")
                    .font(System7Theme.titleFont(size: 12))
                Spacer()
            }
            .foregroundColor(System7Theme.black)

            // Face ID / Touch ID toggle
            if biometricAvailable {
                HStack {
                    Image(systemName: getBiometricIcon())
                        .font(.system(size: 14))
                        .foregroundColor(System7Theme.black)

                    Text(getBiometricName())
                        .font(System7Theme.bodyFont(size: 11))
                        .foregroundColor(System7Theme.black)

                    Spacer()

                    Toggle("", isOn: $useFaceID)
                        .labelsHidden()
                        .onChange(of: useFaceID) { newValue in
                            if newValue {
                                authenticateWithBiometrics()
                            } else {
                                // Disable biometric auth
                                UserDefaults.standard.set(false, forKey: "useBiometricAuth")
                            }
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(System7Theme.white)
                .overlay(
                    Rectangle()
                        .stroke(System7Theme.black, lineWidth: 1)
                )
            }

            // PIN Code toggle
            HStack {
                Image(systemName: "number.square")
                    .font(.system(size: 14))
                    .foregroundColor(System7Theme.black)

                Text("PIN Code")
                    .font(System7Theme.bodyFont(size: 11))
                    .foregroundColor(System7Theme.black)

                Spacer()

                Toggle("", isOn: $usePINCode)
                    .labelsHidden()
                    .onChange(of: usePINCode) { newValue in
                        if newValue {
                            showPINSetup = true
                        } else {
                            // Clear PIN
                            UserDefaults.standard.removeObject(forKey: "walletPIN")
                        }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(System7Theme.white)
            .overlay(
                Rectangle()
                    .stroke(System7Theme.black, lineWidth: 1)
            )
        }
        .padding(12)
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
    }

    // MARK: - Export Section

    private var exportSection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "key")
                    .font(.system(size: 12))
                Text("Backup")
                    .font(System7Theme.titleFont(size: 12))
                Spacer()
            }
            .foregroundColor(System7Theme.black)

            // Warning
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 12))

                Text("Never share your private key. Store it securely offline.")
                    .font(System7Theme.bodyFont(size: 9))
                    .foregroundColor(System7Theme.darkGray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(System7Theme.white)
            .overlay(
                Rectangle()
                    .stroke(Color.orange.opacity(0.5), lineWidth: 1)
            )

            // Export button
            System7Button(title: "Export Private Key") {
                exportPrivateKey()
            }
        }
        .padding(12)
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
    }

    // MARK: - PIN Setup Sheet

    private var pinSetupSheet: some View {
        VStack(spacing: 20) {
            Text("Set PIN Code")
                .font(System7Theme.titleFont(size: 16))
                .foregroundColor(System7Theme.black)

            VStack(spacing: 12) {
                SecureField("Enter 4-6 digit PIN", text: $pinCode)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 200)

                SecureField("Confirm PIN", text: $confirmPIN)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 200)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    pinCode = ""
                    confirmPIN = ""
                    usePINCode = false
                    showPINSetup = false
                }
                .foregroundColor(.red)

                Button("Save") {
                    savePIN()
                }
                .disabled(pinCode.count < 4 || pinCode != confirmPIN)
            }
        }
        .padding(30)
        .background(System7Theme.lightGray)
    }

    // MARK: - Actions

    private func exportPrivateKey() {
        do {
            exportedKey = try walletManager.exportSpendingKey()
            showExportAlert = true
            print("🔑 Private key exported (shown in alert)")
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func checkBiometricAvailability() {
        let context = LAContext()
        var error: NSError?
        biometricAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        // Load saved preferences
        useFaceID = UserDefaults.standard.bool(forKey: "useBiometricAuth")
        usePINCode = UserDefaults.standard.string(forKey: "walletPIN") != nil
    }

    private func getBiometricName() -> String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)

        switch context.biometryType {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        default:
            return "Biometric"
        }
    }

    private func getBiometricIcon() -> String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)

        switch context.biometryType {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        default:
            return "lock"
        }
    }

    private func authenticateWithBiometrics() {
        let context = LAContext()
        let reason = "Enable biometric authentication for ZipherX"

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, error in
            DispatchQueue.main.async {
                if success {
                    UserDefaults.standard.set(true, forKey: "useBiometricAuth")
                    useFaceID = true
                } else {
                    useFaceID = false
                    if let error = error {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            }
        }
    }

    private func savePIN() {
        guard pinCode.count >= 4 && pinCode.count <= 6 else {
            errorMessage = "PIN must be 4-6 digits"
            showError = true
            return
        }

        guard pinCode == confirmPIN else {
            errorMessage = "PINs do not match"
            showError = true
            return
        }

        // Save PIN (in production, hash this!)
        UserDefaults.standard.set(pinCode, forKey: "walletPIN")
        pinCode = ""
        confirmPIN = ""
        showPINSetup = false
    }
}

#Preview {
    SettingsView()
        .environmentObject(WalletManager.shared)
}
