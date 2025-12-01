import SwiftUI

/// Mode selection view shown on first launch (macOS only)
/// Allows user to choose between Light and Full Node modes
struct ModeSelectionView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var modeManager = WalletModeManager.shared
    @State private var selectedMode: WalletMode = .light
    @State private var isAnimating = false

    var onModeSelected: (WalletMode) -> Void

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Mode cards
            ScrollView {
                VStack(spacing: 20) {
                    // Light mode card
                    modeCard(mode: .light)

                    #if os(macOS)
                    // Full node card (macOS only)
                    modeCard(mode: .fullNode)
                    #endif

                    // Continue button
                    continueButton
                        .padding(.top, 20)
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.backgroundColor)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5)) {
                isAnimating = true
            }
        }
    }

    private var headerView: some View {
        VStack(spacing: 16) {
            // Logo
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 64))
                .foregroundColor(theme.primaryColor)
                .scaleEffect(isAnimating ? 1.0 : 0.8)
                .animation(.spring(response: 0.6, dampingFraction: 0.7), value: isAnimating)

            Text("Welcome to ZipherX")
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)

            Text("Choose your wallet mode")
                .font(theme.bodyFont)
                .foregroundColor(theme.textSecondary)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
        .background(theme.surfaceColor)
    }

    private func modeCard(mode: WalletMode) -> some View {
        let isSelected = selectedMode == mode
        let isAvailable = mode.isAvailableOnCurrentPlatform

        return Button(action: {
            if isAvailable {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    selectedMode = mode
                }
            }
        }) {
            VStack(alignment: .leading, spacing: 16) {
                // Header row
                HStack {
                    Image(systemName: mode.icon)
                        .font(.system(size: 28))
                        .foregroundColor(isSelected ? theme.primaryColor : theme.textSecondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(mode.displayName)
                            .font(theme.titleFont)
                            .foregroundColor(isAvailable ? theme.textPrimary : theme.textSecondary)

                        Text(mode.description)
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                    }

                    Spacer()

                    // Selection indicator
                    ZStack {
                        Circle()
                            .stroke(isSelected ? theme.primaryColor : theme.borderColor, lineWidth: 2)
                            .frame(width: 24, height: 24)

                        if isSelected {
                            Circle()
                                .fill(theme.primaryColor)
                                .frame(width: 14, height: 14)
                        }
                    }
                }

                Divider()
                    .background(theme.borderColor)

                // Features list
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(mode.features, id: \.self) { feature in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(theme.successColor)

                            Text(feature)
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)
                        }
                    }
                }

                // Storage requirement
                HStack {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)

                    Text("Storage: \(mode.storageRequirement)")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                }
                .padding(.top, 4)

                // Not available warning (iOS for full node)
                if !isAvailable {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(theme.warningColor)
                        Text("Not available on this platform")
                            .font(theme.captionFont)
                            .foregroundColor(theme.warningColor)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .fill(theme.surfaceColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(isSelected ? theme.primaryColor : theme.borderColor, lineWidth: isSelected ? 2 : 1)
            )
            .opacity(isAvailable ? 1.0 : 0.6)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isAvailable)
    }

    private var continueButton: some View {
        Button(action: {
            modeManager.setMode(selectedMode)
            onModeSelected(selectedMode)
        }) {
            HStack {
                Text("Continue with \(selectedMode.displayName)")
                    .font(theme.bodyFont)

                Image(systemName: "arrow.right")
                    .font(.system(size: 14))
            }
            .foregroundColor(theme.textPrimary)
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
            .background(theme.primaryColor)
            .cornerRadius(theme.cornerRadius)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    ModeSelectionView { mode in
        print("Selected mode: \(mode)")
    }
    .environmentObject(ThemeManager.shared)
    .frame(width: 500, height: 700)
}
