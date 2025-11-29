import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Receive View - Display z-address and QR code
/// Classic Macintosh System 7 design
struct ReceiveView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var showCopied = false
    @State private var showExportAlert = false
    @State private var exportedKey = ""

    var body: some View {
        VStack(spacing: 16) {
            // QR Code
            qrCodeSection

            // Address display
            addressSection

            // Copy button
            System7Button(title: "Copy Address") {
                copyAddress()
            }

            // Export key button
            System7Button(title: "Export Private Key") {
                exportKey()
            }

            // Privacy notice
            privacyNotice

            Spacer()
        }
        .padding()
        .overlay(
            copiedToast
        )
        .alert("Private Key", isPresented: $showExportAlert) {
            Button("Copy to Clipboard") {
                copyToClipboard(exportedKey)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("WARNING: Never share this key!\n\n\(exportedKey)")
        }
    }

    private var qrCodeSection: some View {
        VStack(spacing: 8) {
            Text("Scan to Receive ZCL")
                .font(System7Theme.bodyFont(size: 10))
                .foregroundColor(System7Theme.darkGray)

            System7QRCode(data: walletManager.zAddress)
                .frame(width: 180, height: 180)
        }
    }

    private var addressSection: some View {
        VStack(spacing: 8) {
            Text("Your Shielded Address")
                .font(System7Theme.bodyFont(size: 10))
                .foregroundColor(System7Theme.darkGray)

            // Address in a scrollable text box
            ScrollView(.horizontal, showsIndicators: false) {
                Text(walletManager.zAddress)
                    .font(System7Theme.bodyFont(size: 9))
                    .foregroundColor(System7Theme.black)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(System7Theme.white)
            .overlay(
                Rectangle()
                    .stroke(System7Theme.black, lineWidth: 1)
            )
            .overlay(
                // Sunken effect (inset field)
                Rectangle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [System7Theme.darkGray, System7Theme.white],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .padding(1)
            )

            // Address type indicator
            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 10))
                Text("z-address (Sapling)")
                    .font(System7Theme.bodyFont(size: 9))
            }
            .foregroundColor(System7Theme.black)
        }
    }

    private var privacyNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("Privacy Note")
                    .font(System7Theme.titleFont(size: 10))
            }

            Text("This address provides full privacy. Transactions are encrypted and cannot be traced.")
                .font(System7Theme.bodyFont(size: 9))
                .foregroundColor(System7Theme.darkGray)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
    }

    private var copiedToast: some View {
        Group {
            if showCopied {
                VStack {
                    Spacer()

                    Text("Address Copied!")
                        .font(System7Theme.bodyFont(size: 11))
                        .foregroundColor(System7Theme.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(System7Theme.white)
                        .overlay(
                            Rectangle()
                                .stroke(System7Theme.black, lineWidth: 2)
                        )

                    Spacer()
                        .frame(height: 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showCopied)
    }

    // MARK: - Actions

    private func copyAddress() {
        copyToClipboard(walletManager.zAddress)

        withAnimation {
            showCopied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showCopied = false
            }
        }
    }

    private func copyToClipboard(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    private func exportKey() {
        do {
            exportedKey = try walletManager.exportSpendingKey()
            showExportAlert = true
            // SECURITY: Never log private keys
        } catch {
            print("❌ Key export failed")
        }
    }
}

#Preview {
    ReceiveView()
        .environmentObject(WalletManager.shared)
}
