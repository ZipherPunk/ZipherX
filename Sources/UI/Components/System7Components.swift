import SwiftUI
import LocalAuthentication
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Platform-specific Neon Colors
// macOS: Neon Orange (Bitcoin-inspired)
// iOS: Neon Green (Matrix-inspired)
enum NeonColors {
    // macOS Orange colors
    private static let orangePrimary = Color(red: 1.0, green: 0.4, blue: 0.0)
    private static let orangePrimaryDark = Color(red: 0.8, green: 0.3, blue: 0.0)
    private static let orangePrimaryDim = Color(red: 0.5, green: 0.2, blue: 0.0)
    private static let orangePrimaryVeryDim = Color(red: 0.3, green: 0.12, blue: 0.0)
    private static let orangeProgressBg = Color(red: 0.2, green: 0.08, blue: 0.0)
    private static let orangeProgressFillStart = Color(red: 0.8, green: 0.3, blue: 0.0)
    private static let orangeProgressFillEnd = Color(red: 1.0, green: 0.5, blue: 0.0)

    // iOS Green colors
    private static let greenPrimary = Color(red: 0, green: 1, blue: 0.25)
    private static let greenPrimaryDark = Color(red: 0, green: 0.7, blue: 0.2)
    private static let greenPrimaryDim = Color(red: 0, green: 0.5, blue: 0.1)
    private static let greenPrimaryVeryDim = Color(red: 0, green: 0.3, blue: 0.08)
    private static let greenProgressBg = Color(red: 0, green: 0.2, blue: 0.05)
    private static let greenProgressFillStart = Color(red: 0, green: 0.8, blue: 0.2)
    private static let greenProgressFillEnd = Color(red: 0, green: 1, blue: 0.4)

    // Runtime platform detection (guaranteed to work)
    private static var isMacOS: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    // Public computed properties that select platform-appropriate colors
    static var primary: Color { isMacOS ? orangePrimary : greenPrimary }
    static var primaryDark: Color { isMacOS ? orangePrimaryDark : greenPrimaryDark }
    static var primaryDim: Color { isMacOS ? orangePrimaryDim : greenPrimaryDim }
    static var primaryVeryDim: Color { isMacOS ? orangePrimaryVeryDim : greenPrimaryVeryDim }
    static var progressBg: Color { isMacOS ? orangeProgressBg : greenProgressBg }
    static var progressFillStart: Color { isMacOS ? orangeProgressFillStart : greenProgressFillStart }
    static var progressFillEnd: Color { isMacOS ? orangeProgressFillEnd : greenProgressFillEnd }
}

// MARK: - Classic Mac Window
struct System7Window<Content: View>: View {
    @EnvironmentObject var themeManager: ThemeManager
    let title: String
    let content: Content

    private var theme: AppTheme { themeManager.currentTheme }

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                // Close box
                RoundedRectangle(cornerRadius: theme.cornerRadius / 2)
                    .fill(theme.surfaceColor)
                    .frame(width: 12, height: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadius / 2)
                            .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                    )
                    .padding(.leading, 8)

                Spacer()

                Text(title)
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)

                Spacer()

                // Placeholder for symmetry
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 12, height: 12)
                    .padding(.trailing, 8)
            }
            .frame(height: 24)
            .background(
                // Title bar gradient/pattern based on theme
                theme.hasRetroStyling ?
                    AnyView(
                        HStack(spacing: 1) {
                            ForEach(0..<50, id: \.self) { _ in
                                Rectangle()
                                    .fill(theme.borderColor)
                                    .frame(width: 1)
                            }
                        }
                        .opacity(0.3)
                    )
                    : AnyView(
                        LinearGradient(
                            colors: [theme.surfaceColor, theme.backgroundColor],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .background(theme.surfaceColor)
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(theme.borderColor, lineWidth: theme.borderWidth)
            )

            // Content area
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surfaceColor)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                )
        }
        .background(theme.surfaceColor)
        .cornerRadius(theme.cornerRadius)
        .shadow(color: theme.shadowColor, radius: theme.usesShadows ? 5 : 0)
    }
}

// MARK: - Menu Bar
struct System7MenuBar: View {
    @EnvironmentObject var themeManager: ThemeManager
    @State private var showQuote = false
    @State private var currentQuote: (quote: String, author: String) = ("", "")
    @State private var appleGlow: Bool = false

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        HStack {
            // Apple menu - tap for privacy quote
            // Larger tap area with proper safe area padding
            Button(action: {
                currentQuote = PrivacyQuotes.randomQuote()
                showQuote = true
            }) {
                ZStack {
                    // Glow effect (always use accent color for glow)
                    if appleGlow {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(theme.primaryColor)
                            .blur(radius: 4)
                            .opacity(0.6)
                    }

                    // Main icon
                    Image(systemName: "apple.logo")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(appleGlow ? theme.primaryColor : theme.primaryColor.opacity(0.7))
                        .shadow(color: theme.primaryColor.opacity(appleGlow ? 0.8 : 0.3), radius: appleGlow ? 6 : 2)
                }
                .frame(width: 44, height: 44) // Larger tap target
                .contentShape(Rectangle())
            }
            .padding(.leading, 8) // Extra left padding for edge accessibility

            Text("File")
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)
                .padding(.horizontal, 8)

            Text("Edit")
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)
                .padding(.horizontal, 8)

            Spacer()

            // Network status
            Image(systemName: "network")
                .font(.system(size: 12))
                .foregroundColor(theme.textPrimary)
                .padding(.horizontal, 8)
        }
        .frame(height: 28) // Slightly taller for better tap area
        .background(theme.surfaceColor)
        .overlay(
            Rectangle()
                .frame(height: theme.borderWidth)
                .foregroundColor(theme.borderColor),
            alignment: .bottom
        )
        .alert("Privacy Quote", isPresented: $showQuote) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\"\(currentQuote.quote)\"\n\n- \(currentQuote.author)")
        }
        .onAppear {
            // Start pulsing animation
            withAnimation(Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                appleGlow = true
            }
        }
    }
}

// MARK: - Tab Button
struct System7TabButton: View {
    @EnvironmentObject var themeManager: ThemeManager
    let title: String
    let isSelected: Bool
    let action: () -> Void

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.bodyFont)
                .foregroundColor(isSelected ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .background(isSelected ? theme.surfaceColor : theme.backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        )
        .overlay(
            // Raised/sunken effect for retro themes
            theme.hasRetroStyling ?
                AnyView(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .strokeBorder(
                            LinearGradient(
                                colors: isSelected
                                    ? [theme.textSecondary.opacity(0.5), theme.surfaceColor]
                                    : [theme.surfaceColor, theme.textSecondary.opacity(0.5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                        .padding(1)
                )
                : AnyView(EmptyView())
        )
        .cornerRadius(theme.cornerRadius)
        .shadow(color: isSelected && theme.usesShadows ? theme.shadowColor : .clear, radius: 2)
    }
}

// MARK: - Classic Button
struct System7Button: View {
    @EnvironmentObject var themeManager: ThemeManager
    let title: String
    let action: () -> Void
    @State private var isPressed = false

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.bodyFont)
                .foregroundColor(theme.buttonText)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isPressed ? theme.buttonBackground.opacity(0.8) : theme.buttonBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                )
                .overlay(
                    // 3D effect for retro themes
                    theme.hasRetroStyling ?
                        AnyView(
                            RoundedRectangle(cornerRadius: theme.cornerRadius)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: isPressed
                                            ? [theme.textSecondary.opacity(0.5), theme.surfaceColor]
                                            : [theme.surfaceColor, theme.textSecondary.opacity(0.5)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                                .padding(1)
                        )
                        : AnyView(EmptyView())
                )
                .cornerRadius(theme.cornerRadius)
                .shadow(color: theme.usesShadows && !isPressed ? theme.shadowColor : .clear, radius: 2, y: 1)
        }
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
    }
}

// MARK: - Text Field
struct System7TextField: View {
    @EnvironmentObject var themeManager: ThemeManager
    let placeholder: String
    @Binding var text: String

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        TextField(placeholder, text: $text)
            .font(theme.bodyFont)
            .foregroundColor(theme.textPrimary)
            .padding(10)
            .background(theme.surfaceColor)
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(theme.borderColor, lineWidth: theme.borderWidth)
            )
            .overlay(
                // Inset effect for retro themes
                theme.hasRetroStyling ?
                    AnyView(
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [theme.textSecondary.opacity(0.3), theme.surfaceColor],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                            .padding(1)
                    )
                    : AnyView(EmptyView())
            )
            .cornerRadius(theme.cornerRadius)
    }
}

// MARK: - Progress Bar
struct System7ProgressBar: View {
    @EnvironmentObject var themeManager: ThemeManager
    let progress: Double

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: theme.cornerRadius / 2)
                    .fill(theme.backgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadius / 2)
                            .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                    )

                RoundedRectangle(cornerRadius: theme.cornerRadius / 2)
                    .fill(theme.primaryColor)
                    .frame(width: max(0, geometry.size.width * progress - 4))
                    .padding(2)
            }
        }
        .frame(height: 16)
    }
}

// MARK: - Alert/Dialog
struct System7Alert: View {
    @EnvironmentObject var themeManager: ThemeManager
    let title: String
    let message: String
    let primaryButton: String
    let secondaryButton: String?
    let primaryAction: () -> Void
    let secondaryAction: (() -> Void)?

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                // Alert icon
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundColor(theme.warningColor)

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(theme.titleFont)
                        .foregroundColor(theme.textPrimary)

                    Text(message)
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                if let secondaryButton = secondaryButton,
                   let secondaryAction = secondaryAction {
                    System7Button(title: secondaryButton, action: secondaryAction)
                }

                System7Button(title: primaryButton, action: primaryAction)
            }
        }
        .padding(20)
        .background(theme.surfaceColor)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: 2)
        )
        .cornerRadius(theme.cornerRadius)
        .shadow(color: theme.shadowColor, radius: theme.usesShadows ? 10 : 0)
    }
}

// MARK: - QR Code View (for Receive)
struct System7QRCode: View {
    @EnvironmentObject var themeManager: ThemeManager
    let data: String

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        if let qrImage = generateQRCode(from: data) {
            #if os(iOS)
            Image(uiImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(8)
                .background(Color.white) // QR codes need white background for scanning
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                )
                .cornerRadius(theme.cornerRadius)
            #elseif os(macOS)
            Image(nsImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(8)
                .background(Color.white) // QR codes need white background for scanning
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                )
                .cornerRadius(theme.cornerRadius)
            #endif
        } else {
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .fill(theme.backgroundColor)
                .overlay(
                    Text("QR Error")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.errorColor)
                )
        }
    }

    #if os(iOS)
    private func generateQRCode(from string: String) -> UIImage? {
        let data = string.data(using: .ascii)
        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(data, forKey: "inputMessage")
            filter.setValue("H", forKey: "inputCorrectionLevel")

            if let output = filter.outputImage {
                let transform = CGAffineTransform(scaleX: 10, y: 10)
                let scaledOutput = output.transformed(by: transform)
                let context = CIContext()
                if let cgImage = context.createCGImage(scaledOutput, from: scaledOutput.extent) {
                    return UIImage(cgImage: cgImage)
                }
            }
        }
        return nil
    }
    #elseif os(macOS)
    private func generateQRCode(from string: String) -> NSImage? {
        let data = string.data(using: .ascii)
        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(data, forKey: "inputMessage")
            filter.setValue("H", forKey: "inputCorrectionLevel")

            if let output = filter.outputImage {
                let transform = CGAffineTransform(scaleX: 10, y: 10)
                let scaledOutput = output.transformed(by: transform)
                let rep = NSCIImageRep(ciImage: scaledOutput)
                let nsImage = NSImage(size: rep.size)
                nsImage.addRepresentation(rep)
                return nsImage
            }
        }
        return nil
    }
    #endif
}

// MARK: - Cypherpunk Loading Components

/// Cypherpunk-themed loading messages
struct CypherpunkMessages {
    /// Messages shown during tree initialization
    static let treeLoadingMessages = [
        "Decrypting the matrix...",
        "Privacy shield activating...",
        "Loading 1 million secrets...",
        "Scanning the void...",
        "Zk-proofs compiling...",
        "Anonymity set growing...",
        "Shielded pool syncing...",
        "Entropy harvesting...",
        "Trust no one. Verify everything.",
        "Your keys, your coins.",
        "Building merkle paths...",
        "Commitment tree growing...",
        "Zero-knowledge loading...",
        "Privacy is not a crime.",
        "Cypherpunks write code.",
        "Satoshi would be proud.",
        "ECC took 6 years for this...",
        "We did it in weeks.",
        "Shielded by default.",
        "No trusted setup required.",
        "Groth16 warming up...",
        "Bulletproofs standing by...",
        "Ring signatures ready...",
        "Privacy mode: MAXIMUM",
        "Surveillance resistance: ON"
    ]

    /// Messages shown during transaction building
    static let txBuildingMessages = [
        "Generating zero-knowledge proof...",
        "Proving you own it without revealing it...",
        "Mathematics protecting your privacy...",
        "Creating shielded output...",
        "Binding signature computing...",
        "Groth16 magic happening...",
        "50ms of pure cryptography...",
        "NSA-proof transaction building...",
        "Privacy shield: ENGAGED",
        "Making surveillance obsolete...",
        "Encrypting memo end-to-end...",
        "Shielding your transaction...",
        "Zero knowledge = Zero traces",
        "Your transaction, your business.",
        "Private by design."
    ]

    /// Messages shown during broadcast
    static let broadcastMessages = [
        "Transmitting to the void...",
        "Broadcasting to cypherpunk nodes...",
        "Peer-to-peer propagation...",
        "Decentralized delivery...",
        "No middlemen involved.",
        "Direct to blockchain...",
        "Shielded packet sent.",
        "Privacy preserved.",
        "Transaction in flight..."
    ]

    /// Success messages
    static let successMessages = [
        "Privacy achieved.",
        "Shielded and sealed.",
        "Zero traces left.",
        "Transaction complete.",
        "Anonymity preserved.",
        "Mission accomplished.",
        "Cypherpunk victory.",
        "Surveillance: DEFEATED"
    ]

    /// Get random message from array
    static func random(from messages: [String]) -> String {
        messages.randomElement() ?? messages[0]
    }
}

/// Cypherpunk-themed loading overlay for tree initialization
struct CypherpunkLoadingView: View {
    let progress: Double
    let status: String
    let isFirstLaunch: Bool

    @State private var currentMessage: String = CypherpunkMessages.treeLoadingMessages[0]
    @State private var glitchOffset: CGFloat = 0
    @State private var showGlitch: Bool = false

    private let timer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()
    private let glitchTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Dark background
            Color.black.opacity(0.95)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Matrix-style title with glitch effect
                ZStack {
                    Text("ZIPHERX")
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundColor(NeonColors.primary)
                        .offset(x: showGlitch ? glitchOffset : 0)

                    // Glitch red channel
                    if showGlitch {
                        Text("ZIPHERX")
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .foregroundColor(.red.opacity(0.5))
                            .offset(x: -glitchOffset)
                    }
                }

                // Subtitle
                Text("SHIELDED BY DEFAULT")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(NeonColors.primaryDark)
                    .tracking(4)

                Spacer()

                // Loading indicator
                VStack(spacing: 16) {
                    // First launch message
                    if isFirstLaunch {
                        Text("First launch initialization...")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(NeonColors.primaryDim)
                    }

                    // Rotating cypherpunk message
                    Text(currentMessage)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(NeonColors.primary)
                        .multilineTextAlignment(.center)
                        .animation(.easeInOut(duration: 0.3), value: currentMessage)

                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background
                            Rectangle()
                                .fill(NeonColors.progressBg)
                                .frame(height: 12)

                            // Progress fill
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            NeonColors.progressFillStart,
                                            NeonColors.progressFillEnd
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geometry.size.width * min(progress, 1.0), height: 12)
                                .animation(.linear(duration: 0.3), value: progress)

                            // Border
                            Rectangle()
                                .stroke(NeonColors.primaryDim, lineWidth: 1)
                                .frame(height: 12)
                        }
                    }
                    .frame(height: 12)
                    .padding(.horizontal, 40)

                    // Progress percentage
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(NeonColors.primary)

                    // Technical status (if user wants to see it)
                    if !status.isEmpty {
                        Text(status)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(NeonColors.primaryDim)
                    }
                }

                Spacer()

                // Footer
                VStack(spacing: 4) {
                    Text("Privacy is not a feature")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(NeonColors.primaryDim)

                    Text("It's a right.")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(NeonColors.primaryDark)
                }
                .padding(.bottom, 40)
            }
        }
        .onReceive(timer) { _ in
            withAnimation {
                currentMessage = CypherpunkMessages.random(from: CypherpunkMessages.treeLoadingMessages)
            }
        }
        .onReceive(glitchTimer) { _ in
            // Random glitch effect
            if Int.random(in: 0...20) == 0 {
                showGlitch = true
                glitchOffset = CGFloat.random(in: -3...3)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    showGlitch = false
                }
            }
        }
    }
}

/// Transaction progress overlay with cypherpunk messages
struct CypherpunkTxProgressView: View {
    let steps: [SendProgressStep]
    let currentStep: String

    @State private var currentMessage: String = CypherpunkMessages.txBuildingMessages[0]

    private let timer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Title with animation
                Text("SENDING TRANSACTION")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(NeonColors.primary)
                    .tracking(2)

                // Cypherpunk message
                Text(currentMessage)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(NeonColors.progressFillStart)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .animation(.easeInOut(duration: 0.3), value: currentMessage)

                // Progress steps
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(steps) { step in
                        CypherpunkProgressStepRow(step: step)
                    }
                }
                .padding(20)
                .background(Color.black.opacity(0.5))
                .overlay(
                    Rectangle()
                        .stroke(NeonColors.primaryVeryDim, lineWidth: 1)
                )
                .padding(.horizontal, 20)

                // Footer message
                Text("Do not close the app")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NeonColors.primaryDim)
            }
        }
        .onReceive(timer) { _ in
            // Update message based on current step
            let messages: [String]
            switch currentStep {
            case "proof":
                messages = CypherpunkMessages.txBuildingMessages
            case "broadcast":
                messages = CypherpunkMessages.broadcastMessages
            default:
                messages = CypherpunkMessages.txBuildingMessages
            }
            withAnimation {
                currentMessage = CypherpunkMessages.random(from: messages)
            }
        }
    }
}

/// Individual progress step row with cypherpunk styling
struct CypherpunkProgressStepRow: View {
    let step: SendProgressStep

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // Status indicator
                Group {
                    switch step.status {
                    case .pending:
                        Circle()
                            .stroke(NeonColors.primaryVeryDim, lineWidth: 1)
                            .frame(width: 16, height: 16)
                    case .inProgress:
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: NeonColors.primary))
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(NeonColors.progressFillStart)
                            .frame(width: 16, height: 16)
                    case .failed:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .frame(width: 16, height: 16)
                    }
                }

                // Step title
                Text(step.title)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(stepTextColor)

                Spacer()

                // Detail
                if let detail = step.detail {
                    Text(detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(NeonColors.primaryDim)
                }
            }

            // Progress bar if applicable
            if let progress = step.progress, step.status == .inProgress, progress > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(NeonColors.progressBg)
                            .frame(height: 4)

                        Rectangle()
                            .fill(NeonColors.progressFillStart)
                            .frame(width: geometry.size.width * min(progress, 1.0), height: 4)
                    }
                }
                .frame(height: 4)
                .padding(.leading, 26)
            }

            // Error message
            if case .failed(let error) = step.status {
                Text(error)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.red)
                    .padding(.leading, 26)
            }
        }
    }

    private var stepTextColor: Color {
        switch step.status {
        case .pending:
            return NeonColors.primaryVeryDim
        case .inProgress:
            return NeonColors.primary
        case .completed:
            return NeonColors.primaryDark
        case .failed:
            return .red
        }
    }
}

/// Full-screen cypherpunk sync overlay with task list
struct CypherpunkSyncView: View {
    let progress: Double
    let status: String
    var tasks: [SyncTask] = []
    var startTime: Date? = nil  // When sync started
    var estimatedDuration: TimeInterval? = nil  // Estimated total duration in seconds
    var isComplete: Bool = false  // Show completion message
    var completionDuration: TimeInterval? = nil  // Actual duration when complete
    var onEnterWallet: (() -> Void)? = nil  // Callback when user clicks enter button

    @State private var currentMessage: String = "Synchronizing with the network..."
    @State private var glitchOffset: CGFloat = 0
    @State private var showGlitch: Bool = false
    @State private var elapsedTime: TimeInterval = 0
    @State private var showCompletionAnimation: Bool = false

    private let syncMessages = [
        "Establishing secure connection...",
        "Verifying cryptographic proofs...",
        "Scanning the blockchain for your notes...",
        "Building your financial privacy...",
        "Decrypting shielded transactions...",
        "Maintaining your sovereignty...",
        "The network can't see you...",
        "Your transactions, your business...",
        "Privacy is power...",
        "Trustless verification in progress...",
        "Cryptographic freedom loading...",
        "Cypherpunks write code...",
        "Privacy is not a crime...",
        "Be your own bank...",
        "Code is law..."
    ]

    private let completionMessages = [
        "SOVEREIGNTY UNLOCKED",
        "PRIVACY SHIELD ACTIVE",
        "YOU ARE NOW INVISIBLE",
        "FREEDOM INITIALIZED",
        "CRYPTOGRAPHIC ARMOR ON",
        "THE MATRIX CANNOT SEE YOU",
        "PRIVACY IS YOUR RIGHT"
    ]

    private let timer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()
    private let glitchTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private let elapsedTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Dark background
            Color.black.opacity(0.92)
                .ignoresSafeArea()

            if isComplete {
                // Completion view
                completionView
            } else {
                // Normal sync view
                syncingView
            }
        }
        .onReceive(elapsedTimer) { _ in
            if let start = startTime, !isComplete {
                elapsedTime = Date().timeIntervalSince(start)
            }
        }
        .onReceive(timer) { _ in
            if !isComplete {
                withAnimation {
                    currentMessage = syncMessages.randomElement() ?? syncMessages[0]
                }
            }
        }
        .onReceive(glitchTimer) { _ in
            if Int.random(in: 0...25) == 0 {
                showGlitch = true
                glitchOffset = CGFloat.random(in: -3...3)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    showGlitch = false
                }
            }
        }
        .onChange(of: isComplete) { complete in
            if complete {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                    showCompletionAnimation = true
                }
            }
        }
    }

    // MARK: - Syncing View
    private var syncingView: some View {
        VStack(spacing: 16) {
            Spacer()

            // Matrix-style title with glitch effect
            ZStack {
                Text("SYNCING")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(NeonColors.primary)
                    .offset(x: showGlitch ? glitchOffset : 0)

                if showGlitch {
                    Text("SYNCING")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(.red.opacity(0.5))
                        .offset(x: -glitchOffset)
                }
            }

            // Subtitle
            Text("PROTECTING YOUR PRIVACY")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(NeonColors.primaryDark)
                .tracking(3)

            // Elapsed time and ETA
            timeDisplayView
                .padding(.top, 4)

            // Rotating cypherpunk message
            Text(currentMessage)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(NeonColors.primary)
                .multilineTextAlignment(.center)
                .animation(.easeInOut(duration: 0.3), value: currentMessage)
                .padding(.top, 8)

            // Task list (if available)
            if !tasks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tasks) { task in
                        CypherpunkSyncTaskRow(task: task)
                    }
                }
                .padding(16)
                .background(Color.black.opacity(0.5))
                .overlay(
                    Rectangle()
                        .stroke(NeonColors.primaryVeryDim, lineWidth: 1)
                )
                .padding(.horizontal, 20)
            }

            // Progress bar
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(NeonColors.progressBg)
                            .frame(height: 12)

                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        NeonColors.progressFillStart,
                                        NeonColors.progressFillEnd
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * min(max(progress, 0.02), 1.0), height: 12)
                            .animation(.linear(duration: 0.3), value: progress)

                        Rectangle()
                            .stroke(NeonColors.primaryDim, lineWidth: 1)
                            .frame(height: 12)
                    }
                }
                .frame(height: 12)
                .padding(.horizontal, 40)

                // Progress percentage
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(NeonColors.primary)

                // Status text
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(NeonColors.primaryDim)
                }
            }
            .padding(.top, 8)

            Spacer()

            // Footer quote
            VStack(spacing: 4) {
                Text("\"We must defend our own privacy\"")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(NeonColors.primaryVeryDim)
                    .italic()

                Text("- Cypherpunk's Manifesto")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(NeonColors.primaryVeryDim)
            }
            .padding(.bottom, 30)
        }
    }

    // MARK: - Completion View
    private var completionView: some View {
        VStack(spacing: 20) {
            Spacer()

            // Success icon
            ZStack {
                Circle()
                    .stroke(NeonColors.primary, lineWidth: 3)
                    .frame(width: 80, height: 80)
                    .scaleEffect(showCompletionAnimation ? 1.0 : 0.5)
                    .opacity(showCompletionAnimation ? 1.0 : 0.0)

                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(NeonColors.primary)
                    .scaleEffect(showCompletionAnimation ? 1.0 : 0.0)
            }

            // Completion message
            Text(completionMessages.randomElement() ?? "SOVEREIGNTY UNLOCKED")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(NeonColors.primary)
                .scaleEffect(showCompletionAnimation ? 1.0 : 0.8)
                .opacity(showCompletionAnimation ? 1.0 : 0.0)

            // Duration display
            if let duration = completionDuration {
                VStack(spacing: 4) {
                    Text("Initialization complete in")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(NeonColors.primaryDim)

                    Text(formatDuration(duration))
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(NeonColors.primary)
                }
                .opacity(showCompletionAnimation ? 1.0 : 0.0)
                .padding(.top, 8)
            }

            Spacer()

            // Enter button with cypherpunk message
            if let action = onEnterWallet {
                Button(action: action) {
                    HStack(spacing: 12) {
                        Text(enterButtonMessages.randomElement() ?? "[ ENTER THE VOID ]")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(NeonColors.primary)
                    .cornerRadius(0)  // Sharp edges for cypherpunk look
                    .overlay(
                        Rectangle()
                            .stroke(NeonColors.primary.opacity(0.8), lineWidth: 2)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .opacity(showCompletionAnimation ? 1.0 : 0.0)
                .scaleEffect(showCompletionAnimation ? 1.0 : 0.8)
                .padding(.bottom, 20)
            }

            // Cypherpunk footer
            VStack(spacing: 8) {
                Text("\"Privacy is necessary for an open society\"")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(NeonColors.primaryDim)
                    .italic()

                Text("Your financial sovereignty is now active.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NeonColors.primaryVeryDim)
            }
            .opacity(showCompletionAnimation ? 1.0 : 0.0)
            .padding(.bottom, 40)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                showCompletionAnimation = true
            }
        }
    }

    private let enterButtonMessages = [
        "[ ENTER THE VOID ]",
        "[ JACK IN ]",
        "[ ACCESS GRANTED ]",
        "[ INITIALIZE FREEDOM ]",
        "[ BREACH THE MATRIX ]",
        "[ ENGAGE STEALTH MODE ]",
        "[ UNLOCK SOVEREIGNTY ]",
        "[ GO DARK ]",
        "[ ACTIVATE SHIELD ]",
        "[ BEGIN TRANSMISSION ]"
    ]

    // MARK: - Time Display
    private var timeDisplayView: some View {
        HStack(spacing: 20) {
            // Elapsed time
            VStack(spacing: 2) {
                Text("ELAPSED")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(NeonColors.primaryVeryDim)
                Text(formatDuration(elapsedTime))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(NeonColors.primaryDim)
            }

            // Separator
            Text("|")
                .foregroundColor(NeonColors.primaryVeryDim)

            // Estimated remaining
            if let estimated = estimatedDuration, progress > 0.05 {
                VStack(spacing: 2) {
                    Text("REMAINING")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(NeonColors.primaryVeryDim)
                    Text(formatDuration(estimatedRemaining))
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(NeonColors.primaryDim)
                }
            } else if let estimated = estimatedDuration {
                VStack(spacing: 2) {
                    Text("ESTIMATED")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(NeonColors.primaryVeryDim)
                    Text("~\(formatDuration(estimated))")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(NeonColors.primaryDim)
                }
            }
        }
    }

    // MARK: - Helpers
    private var estimatedRemaining: TimeInterval {
        guard progress > 0.05 else { return estimatedDuration ?? 0 }
        // Calculate based on elapsed time and progress
        let estimatedTotal = elapsedTime / progress
        return max(0, estimatedTotal - elapsedTime)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return String(format: "0:%02d", seconds)
        }
    }
}

/// Individual sync task row with cypherpunk styling
struct CypherpunkSyncTaskRow: View {
    let task: SyncTask

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                // Status indicator
                Group {
                    switch task.status {
                    case .pending:
                        Circle()
                            .stroke(NeonColors.primaryVeryDim, lineWidth: 1)
                            .frame(width: 14, height: 14)
                    case .inProgress:
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: NeonColors.primary))
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(NeonColors.progressFillStart)
                            .font(.system(size: 14))
                    case .failed:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 14))
                    }
                }

                // Task title
                Text(task.title)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(taskTextColor)

                Spacer()

                // Detail (e.g., "2923000 / 2924000")
                if let detail = task.detail {
                    Text(detail)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(NeonColors.primaryDim)
                }
            }

            // Progress bar for in-progress tasks
            if let progress = task.progress, case .inProgress = task.status, progress > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(NeonColors.progressBg)
                            .frame(height: 3)

                        Rectangle()
                            .fill(NeonColors.progressFillStart)
                            .frame(width: geometry.size.width * min(progress, 1.0), height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.leading, 22)
            }
        }
    }

    private var taskTextColor: Color {
        switch task.status {
        case .pending:
            return NeonColors.primaryVeryDim
        case .inProgress:
            return NeonColors.primary
        case .completed:
            return NeonColors.primaryDark
        case .failed:
            return .red
        }
    }
}

// MARK: - Cypherpunk Main View

/// Cypherpunk-themed main wallet interface
/// Single screen with balance, send/receive buttons, and transaction history
struct CypherpunkMainView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var networkManager: NetworkManager
    @EnvironmentObject var themeManager: ThemeManager
    @Binding var showSettings: Bool
    @Binding var showSend: Bool
    @Binding var showReceive: Bool

    @State private var transactions: [TransactionHistoryItem] = []
    @State private var isLoadingHistory = true
    @State private var selectedTransaction: TransactionHistoryItem?
    @State private var glitchOffset: CGFloat = 0
    @State private var showGlitch: Bool = false
    @State private var previousBalance: UInt64 = 0
    @State private var showFireworks = false
    @State private var fireworksAmount: Double = 0

    // Matrix green colors (primary = orange on macOS, green on iOS)
    private let matrixGreen = NeonColors.primary
    private let matrixGreenDark = NeonColors.primaryDark
    private let matrixGreenDarker = NeonColors.primaryVeryDim
    // Received transactions are ALWAYS green (money coming in = good)
    private let receivedGreen = Color(red: 0, green: 0.85, blue: 0.25)

    private let glitchTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Dark background with subtle matrix pattern
            Color.black
                .ignoresSafeArea()

            // Matrix rain effect (subtle background)
            MatrixRainBackground()
                .opacity(0.15)

            VStack(spacing: 0) {
                // Top bar with settings gear
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Spacer()
                    .frame(height: 20)

                // Balance section (centered and prominent)
                balanceSection
                    .padding(.horizontal, 20)

                Spacer()
                    .frame(height: 30)

                // Send / Receive buttons
                actionButtons
                    .padding(.horizontal, 20)

                Spacer()
                    .frame(height: 24)

                // Transaction history
                transactionHistory
                    .frame(maxHeight: .infinity)

                // Network status bar at bottom
                networkStatusBar
            }

            // Fireworks overlay
            if showFireworks {
                FireworksView(isShowing: $showFireworks, amount: fireworksAmount)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .sheet(item: $selectedTransaction) { transaction in
            TransactionDetailView(transaction: transaction)
                .environmentObject(themeManager)
                .environmentObject(networkManager)
        }
        .onAppear {
            previousBalance = walletManager.shieldedBalance
            loadTransactionHistory()
        }
        .onChange(of: walletManager.shieldedBalance) { newValue in
            if newValue != previousBalance {
                loadTransactionHistory()
            }
            // Detect incoming ZCL
            if newValue > previousBalance && previousBalance > 0 {
                let increase = newValue - previousBalance
                fireworksAmount = Double(increase) / 100_000_000.0
                withAnimation {
                    showFireworks = true
                }
            }
            previousBalance = newValue
        }
        .onReceive(glitchTimer) { _ in
            if Bool.random() && Double.random(in: 0...1) < 0.05 {
                showGlitch = true
                glitchOffset = CGFloat.random(in: -3...3)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    showGlitch = false
                    glitchOffset = 0
                }
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // Network indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(networkManager.isConnected ? matrixGreen : Color.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: networkManager.isConnected ? matrixGreen : Color.red, radius: 4)

                Text("\(networkManager.connectedPeers) PEERS (\(networkManager.knownAddressCount))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(matrixGreenDark)
            }

            Spacer()

            // App title
            Text("ZIPHERX")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(matrixGreen)
                .tracking(2)

            Spacer()

            // Settings gear button
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22))
                    .foregroundColor(matrixGreen)
                    .shadow(color: matrixGreen.opacity(0.5), radius: 4)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: - Balance Section

    private var balanceSection: some View {
        VStack(spacing: 8) {
            // "BALANCE" label
            Text("SHIELDED BALANCE")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(matrixGreenDark)
                .tracking(3)

            // Main ZCL balance with glitch effect
            ZStack {
                Text(formatBalance(walletManager.shieldedBalance))
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .foregroundColor(matrixGreen)
                    .shadow(color: matrixGreen.opacity(0.8), radius: 10)
                    .offset(x: showGlitch ? glitchOffset : 0)

                if showGlitch {
                    Text(formatBalance(walletManager.shieldedBalance))
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.cyan.opacity(0.5))
                        .offset(x: -glitchOffset)
                }
            }

            // ZCL label
            Text("ZCL")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(matrixGreenDark)

            // USD value (placeholder - would need price feed)
            Text("≈ $\(formatUSDValue()) USD")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(matrixGreenDarker)

            // Privacy badge
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10))
                Text("FULLY SHIELDED")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1)
            }
            .foregroundColor(matrixGreenDark)
            .padding(.top, 4)

            // Pending balance
            if walletManager.pendingBalance > 0 {
                HStack(spacing: 4) {
                    Text("PENDING:")
                        .font(.system(size: 10, design: .monospaced))
                    Text("+\(formatBalance(walletManager.pendingBalance)) ZCL")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundColor(Color.yellow)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 16) {
            // SEND button
            Button(action: { showSend = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                    Text("SEND")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [matrixGreen, matrixGreenDark],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .cornerRadius(8)
                .shadow(color: matrixGreen.opacity(0.5), radius: 8)
            }
            .buttonStyle(PlainButtonStyle())

            // RECEIVE button
            Button(action: { showReceive = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 20))
                    Text("RECEIVE")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                }
                .foregroundColor(matrixGreen)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(matrixGreen, lineWidth: 2)
                )
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: - Transaction History

    private var transactionHistory: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("TRANSACTION HISTORY")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(matrixGreenDark)
                    .tracking(2)

                Spacer()

                if isLoadingHistory {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(matrixGreen)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            // Divider
            Rectangle()
                .fill(matrixGreenDarker)
                .frame(height: 1)

            // Transaction list
            if transactions.isEmpty && !isLoadingHistory {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundColor(matrixGreenDarker)
                    Text("NO TRANSACTIONS YET")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(matrixGreenDarker)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(transactions, id: \.uniqueId) { tx in
                            transactionRow(tx)
                                .onTapGesture {
                                    selectedTransaction = tx
                                }
                        }
                    }
                }
            }
        }
        .background(Color.black.opacity(0.5))
    }

    private func transactionRow(_ tx: TransactionHistoryItem) -> some View {
        HStack(spacing: 12) {
            // Direction icon
            Image(systemName: tx.type == .received ? "arrow.down.left" : "arrow.up.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(tx.type == .received ? receivedGreen : Color.orange)
                .frame(width: 24)

            // Details
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.type == .received ? "RECEIVED" : "SENT")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(tx.type == .received ? receivedGreen : Color.orange)

                if let date = tx.dateString {
                    Text(date)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(matrixGreenDarker)
                }
            }

            Spacer()

            // Amount
            Text("\(tx.type == .received ? "+" : "-")\(String(format: "%.8f", tx.valueInZCL))")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(tx.type == .received ? receivedGreen : Color.orange)

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(matrixGreenDarker)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.3))
        .overlay(
            Rectangle()
                .fill(matrixGreenDarker.opacity(0.3))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Network Status Bar

    private var networkStatusBar: some View {
        HStack(spacing: 16) {
            // Zclassic network version
            HStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.system(size: 9))
                Text("ZCL v2.1.2-1")
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundColor(matrixGreenDarker)

            Spacer()

            // Sync status
            if walletManager.isSyncing {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .tint(matrixGreen)
                    Text("SYNCING...")
                        .font(.system(size: 9, design: .monospaced))
                }
                .foregroundColor(matrixGreen)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                    Text("SYNCED")
                        .font(.system(size: 9, design: .monospaced))
                }
                .foregroundColor(matrixGreenDark)
            }

            Spacer()

            // Block height
            HStack(spacing: 4) {
                Image(systemName: "cube.fill")
                    .font(.system(size: 9))
                Text("\(networkManager.chainHeight)")
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundColor(matrixGreenDarker)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.8))
    }

    // MARK: - Helpers

    private func formatBalance(_ zatoshis: UInt64) -> String {
        let zcl = Double(zatoshis) / 100_000_000.0
        if zcl == 0 {
            return "0.00000000"
        } else {
            return String(format: "%.8f", zcl)
        }
    }

    private func formatUSDValue() -> String {
        // Placeholder - would need actual price feed
        // For now, show approximate value (ZCL ~ $0.02)
        let zcl = Double(walletManager.shieldedBalance) / 100_000_000.0
        let usd = zcl * 0.02 // Approximate price
        return String(format: "%.2f", usd)
    }

    private func loadTransactionHistory() {
        isLoadingHistory = true
        print("📜 TXHIST [S7]: loadTransactionHistory() CALLED")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // ALWAYS populate from notes to ensure sent transactions are included
                // This uses INSERT OR REPLACE so it's safe to call multiple times
                print("📜 TXHIST [S7]: Populating history from notes...")
                let populated = try WalletDatabase.shared.populateHistoryFromNotes()
                print("📜 TXHIST [S7]: Populated \(populated) entries from notes")

                // Now fetch the history
                let items = try WalletDatabase.shared.getTransactionHistory(limit: 50)
                print("📜 TXHIST [S7]: getTransactionHistory returned \(items.count) items")

                // Debug: count sent vs received
                let sentCount = items.filter { $0.type == .sent }.count
                let receivedCount = items.filter { $0.type == .received }.count
                print("📜 TXHIST [S7]: sent=\(sentCount), received=\(receivedCount)")

                DispatchQueue.main.async {
                    self.transactions = items
                    self.isLoadingHistory = false
                }
            } catch {
                print("📜 TXHIST [S7] ERROR: \(error)")
                DispatchQueue.main.async {
                    self.isLoadingHistory = false
                }
            }
        }
    }
}

// MARK: - Matrix Rain Background

struct MatrixRainBackground: View {
    @State private var columns: [MatrixColumn] = []

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for column in columns {
                    for (index, char) in column.characters.enumerated() {
                        let y = column.y + CGFloat(index) * 14
                        if y > 0 && y < size.height {
                            let opacity = 1.0 - (Double(index) / Double(column.characters.count))
                            context.opacity = opacity * 0.5
                            context.draw(
                                Text(char)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(NeonColors.primary),
                                at: CGPoint(x: column.x, y: y)
                            )
                        }
                    }
                }
            }
            .onAppear {
                setupColumns(in: geometry.size)
                startAnimation()
            }
        }
    }

    private func setupColumns(in size: CGSize) {
        let columnCount = Int(size.width / 20)
        columns = (0..<columnCount).map { i in
            MatrixColumn(
                x: CGFloat(i) * 20,
                y: CGFloat.random(in: -size.height...0),
                speed: CGFloat.random(in: 2...6),
                characters: generateMatrixChars()
            )
        }
    }

    private func generateMatrixChars() -> [String] {
        let chars = "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン0123456789"
        return (0..<Int.random(in: 5...15)).map { _ in
            String(chars.randomElement()!)
        }
    }

    private var screenHeight: CGFloat {
        #if os(iOS)
        return UIScreen.main.bounds.height
        #else
        return NSScreen.main?.frame.height ?? 800
        #endif
    }

    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            for i in columns.indices {
                columns[i].y += columns[i].speed
                if columns[i].y > screenHeight + 200 {
                    columns[i].y = CGFloat.random(in: -300...(-100))
                    columns[i].characters = generateMatrixChars()
                }
            }
        }
    }
}

struct MatrixColumn: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var speed: CGFloat
    var characters: [String]
}

// MARK: - Fireworks Animation for Incoming ZCL

/// Individual firework particle
struct FireworkParticle: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var velocityX: CGFloat
    var velocityY: CGFloat
    var color: Color
    var size: CGFloat
    var opacity: Double
    var trail: [(CGFloat, CGFloat)] = []
}

/// Fireworks celebration view for incoming ZCL
struct FireworksView: View {
    @Binding var isShowing: Bool
    let amount: Double // Amount in ZCL

    @State private var particles: [FireworkParticle] = []
    @State private var explosions: [(x: CGFloat, y: CGFloat, time: Date)] = []

    private let colors: [Color] = [
        .yellow, .orange, .red, .pink, .purple, .blue, .cyan, .green, .mint
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Semi-transparent background
                Color.black.opacity(0.6)
                    .ignoresSafeArea()

                // Particles
                ForEach(particles) { particle in
                    Circle()
                        .fill(particle.color)
                        .frame(width: particle.size, height: particle.size)
                        .opacity(particle.opacity)
                        .position(x: particle.x, y: particle.y)
                        .shadow(color: particle.color, radius: 3)
                }

                // Amount display
                VStack(spacing: 8) {
                    Text("🚀")
                        .font(.system(size: 60))

                    Text("+\(String(format: "%.8f", amount)) ZCL")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
                        .shadow(color: .green, radius: 10)

                    Text("INCOMING!")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .white, radius: 5)
                }
                .scaleEffect(particles.isEmpty ? 0.5 : 1.0)
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: particles.isEmpty)
            }
            .onAppear {
                startFireworks(in: geometry.size)
            }
            .onTapGesture {
                withAnimation {
                    isShowing = false
                }
            }
        }
    }

    private func startFireworks(in size: CGSize) {
        // Launch multiple fireworks
        for i in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.3) {
                launchFirework(in: size)
            }
        }

        // Auto-dismiss after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation(.easeOut(duration: 0.5)) {
                isShowing = false
            }
        }
    }

    private func launchFirework(in size: CGSize) {
        let centerX = CGFloat.random(in: size.width * 0.2...size.width * 0.8)
        let centerY = CGFloat.random(in: size.height * 0.2...size.height * 0.5)
        let color = colors.randomElement() ?? .yellow

        // Create explosion particles
        let particleCount = Int.random(in: 20...35)
        var newParticles: [FireworkParticle] = []

        for _ in 0..<particleCount {
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let speed = CGFloat.random(in: 2...8)

            let particle = FireworkParticle(
                x: centerX,
                y: centerY,
                velocityX: cos(angle) * speed,
                velocityY: sin(angle) * speed,
                color: color,
                size: CGFloat.random(in: 3...6),
                opacity: 1.0
            )
            newParticles.append(particle)
        }

        particles.append(contentsOf: newParticles)

        // Animate particles
        animateParticles()
    }

    private func animateParticles() {
        // Physics update loop
        Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
            var allFaded = true

            for i in particles.indices.reversed() {
                // Apply gravity
                particles[i].velocityY += 0.15

                // Apply velocity
                particles[i].x += particles[i].velocityX
                particles[i].y += particles[i].velocityY

                // Fade out
                particles[i].opacity -= 0.015
                particles[i].size *= 0.99

                if particles[i].opacity > 0 {
                    allFaded = false
                }

                // Remove faded particles
                if particles[i].opacity <= 0 {
                    particles.remove(at: i)
                }
            }

            if allFaded || particles.isEmpty {
                timer.invalidate()
            }
        }
    }
}

// MARK: - Mined Celebration View

/// Cypherpunk celebration when transaction is mined (confirmed)
struct MinedCelebrationView: View {
    @Binding var isShowing: Bool
    let amount: Double // Amount in ZCL
    let txid: String
    let isOutgoing: Bool

    // Cypherpunk messages for mined transactions
    private let minedMessages = [
        "Proof of work complete. Your transaction is now immutable.",
        "Consensus achieved. The network validates your privacy.",
        "Block sealed. Your financial sovereignty preserved.",
        "Hash verified. Another step toward freedom.",
        "Miners have spoken. Your transaction lives forever.",
        "Decentralization in action. No middleman required.",
        "Cryptographic proof complete. Trust no one, verify everything.",
        "On-chain confirmation. Your privacy is now history."
    ]

    @State private var selectedMessage: String = ""
    @State private var showContent = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Dark overlay with green tint
                Color.black.opacity(0.85)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    // Mining/pickaxe icon
                    Text("⛏️")
                        .font(.system(size: 50))
                        .scaleEffect(showContent ? 1.0 : 0.5)
                        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: showContent)

                    // MINED! title
                    Text("MINED!")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(NeonColors.primary)
                        .shadow(color: NeonColors.primary.opacity(0.8), radius: 10)

                    // Amount
                    Text("\(isOutgoing ? "-" : "+")\(String(format: "%.8f", amount)) ZCL")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(isOutgoing ? .orange : .green)
                        .shadow(color: isOutgoing ? .orange.opacity(0.5) : .green.opacity(0.5), radius: 5)

                    // Transaction type
                    Text(isOutgoing ? "SENT CONFIRMED" : "RECEIVED CONFIRMED")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))

                    // Cypherpunk message
                    Text(selectedMessage)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(NeonColors.primary.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .padding(.top, 8)

                    // TXID
                    VStack(spacing: 4) {
                        Text("TXID:")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)

                        Text("\(txid.prefix(20))...")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(NeonColors.primary.opacity(0.6))
                    }
                    .padding(.top, 12)

                    // Tap to dismiss
                    Text("tap to dismiss")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.5))
                        .padding(.top, 20)
                }
                .scaleEffect(showContent ? 1.0 : 0.8)
                .opacity(showContent ? 1.0 : 0.0)
            }
            .onAppear {
                selectedMessage = minedMessages.randomElement() ?? minedMessages[0]
                withAnimation(.easeOut(duration: 0.3)) {
                    showContent = true
                }

                // Auto-dismiss after 4 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        isShowing = false
                    }
                }
            }
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.2)) {
                    isShowing = false
                }
            }
        }
    }
}

// MARK: - Lock Screen View

/// Face ID lock screen overlay
struct LockScreenView: View {
    @EnvironmentObject var themeManager: ThemeManager
    let onUnlock: () -> Void

    @State private var isAuthenticating = false
    @State private var authError: String?
    @State private var showRetryButton = false

    private var theme: AppTheme { themeManager.currentTheme }
    private var biometricManager: BiometricAuthManager { BiometricAuthManager.shared }

    var body: some View {
        ZStack {
            // Blurred/dimmed background
            theme.backgroundColor
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Lock icon
                Image(systemName: biometricManager.biometricType.systemImageName)
                    .font(.system(size: 64))
                    .foregroundColor(theme.primaryColor)
                    .opacity(isAuthenticating ? 0.6 : 1.0)
                    .scaleEffect(isAuthenticating ? 1.1 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isAuthenticating)

                // Title
                Text("ZipherX Locked")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)

                // Subtitle
                Text("Authenticate with \(biometricManager.biometricType.displayName) to unlock")
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Error message
                if let error = authError {
                    Text(error)
                        .font(theme.captionFont)
                        .foregroundColor(theme.errorColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                // Unlock button
                if showRetryButton {
                    Button(action: attemptUnlock) {
                        HStack {
                            Image(systemName: biometricManager.biometricType.systemImageName)
                            Text("Tap to Unlock")
                        }
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(theme.buttonBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.cornerRadius)
                                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                        )
                        .cornerRadius(theme.cornerRadius)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    // Auto-authenticate on appear
                    Text("Authenticating...")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()
                    .frame(height: 50)
            }
        }
        .onAppear {
            // Auto-prompt for Face ID when lock screen appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                attemptUnlock()
            }
        }
    }

    private func attemptUnlock() {
        isAuthenticating = true
        authError = nil
        showRetryButton = false

        biometricManager.authenticateForAppUnlock { success, error in
            isAuthenticating = false

            if success {
                onUnlock()
            } else {
                if let laError = error as? LAError {
                    switch laError.code {
                    case .userCancel:
                        authError = "Authentication cancelled"
                    case .userFallback:
                        authError = "Use passcode instead"
                    case .biometryNotAvailable:
                        authError = "\(biometricManager.biometricType.displayName) not available"
                    case .biometryNotEnrolled:
                        authError = "\(biometricManager.biometricType.displayName) not enrolled"
                    case .biometryLockout:
                        authError = "Too many attempts. Try passcode."
                    default:
                        authError = "Authentication failed"
                    }
                } else {
                    authError = "Authentication failed"
                }
                showRetryButton = true
            }
        }
    }
}
