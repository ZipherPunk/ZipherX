import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Receive View - Display z-address and QR code
/// Themed design
struct ReceiveView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var themeManager: ThemeManager
    @State private var showCopied = false

    // Theme shortcut
    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // QR Code
                qrCodeSection

                // Address display
                addressSection

                // Copy button
                System7Button(title: "Copy Address") {
                    copyAddress()
                }

                // Privacy notice
                privacyNotice
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.backgroundColor)
        .overlay(
            copiedToast
        )
    }

    private var qrCodeSection: some View {
        VStack(spacing: 8) {
            Text("Scan to Receive ZCL")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)

            System7QRCode(data: walletManager.zAddress)
                .frame(width: 180, height: 180)
        }
    }

    private var addressSection: some View {
        VStack(spacing: 8) {
            Text("Your Shielded Address")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)

            // Address in a scrollable text box
            ScrollView(.horizontal, showsIndicators: false) {
                Text(walletManager.zAddress)
                    .font(theme.monoFont)
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(theme.surfaceColor)
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(theme.borderColor, lineWidth: theme.borderWidth)
            )
            .cornerRadius(theme.cornerRadius)

            // Address type indicator
            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 10))
                Text("z-address (Sapling)")
                    .font(theme.captionFont)
            }
            .foregroundColor(theme.textPrimary)
        }
    }

    private var privacyNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("Privacy Note")
                    .font(theme.titleFont)
            }
            .foregroundColor(theme.textPrimary)

            Text("This address provides full privacy. Transactions are encrypted and cannot be traced.")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        )
        .cornerRadius(theme.cornerRadius)
    }

    private var copiedToast: some View {
        Group {
            if showCopied {
                VStack {
                    Spacer()

                    Text("Address Copied!")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(theme.surfaceColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.cornerRadius)
                                .stroke(theme.borderColor, lineWidth: 2)
                        )
                        .cornerRadius(theme.cornerRadius)
                        .shadow(color: theme.shadowColor, radius: theme.usesShadows ? 5 : 0)

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
}

#Preview {
    ReceiveView()
        .environmentObject(WalletManager.shared)
        .environmentObject(ThemeManager.shared)
}
