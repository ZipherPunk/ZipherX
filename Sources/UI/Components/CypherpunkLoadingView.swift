import SwiftUI

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
                        .foregroundColor(Color(red: 0, green: 1, blue: 0.25))
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
                    .foregroundColor(Color(red: 0, green: 0.7, blue: 0.2))
                    .tracking(4)

                Spacer()

                // Loading indicator
                VStack(spacing: 16) {
                    // First launch message
                    if isFirstLaunch {
                        Text("First launch initialization...")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(red: 0, green: 0.6, blue: 0.15))
                    }

                    // Rotating cypherpunk message
                    Text(currentMessage)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(Color(red: 0, green: 1, blue: 0.25))
                        .multilineTextAlignment(.center)
                        .animation(.easeInOut(duration: 0.3), value: currentMessage)

                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background
                            Rectangle()
                                .fill(Color(red: 0, green: 0.2, blue: 0.05))
                                .frame(height: 12)

                            // Progress fill
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0, green: 0.8, blue: 0.2),
                                            Color(red: 0, green: 1, blue: 0.4)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geometry.size.width * min(progress, 1.0), height: 12)
                                .animation(.linear(duration: 0.3), value: progress)

                            // Border
                            Rectangle()
                                .stroke(Color(red: 0, green: 0.6, blue: 0.15), lineWidth: 1)
                                .frame(height: 12)
                        }
                    }
                    .frame(height: 12)
                    .padding(.horizontal, 40)

                    // Progress percentage
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0, green: 1, blue: 0.25))

                    // Technical status (if user wants to see it)
                    if !status.isEmpty {
                        Text(status)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(red: 0, green: 0.5, blue: 0.1))
                    }
                }

                Spacer()

                // Footer
                VStack(spacing: 4) {
                    Text("Privacy is not a feature")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(red: 0, green: 0.5, blue: 0.1))

                    Text("It's a right.")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0, green: 0.7, blue: 0.2))
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
                    .foregroundColor(Color(red: 0, green: 1, blue: 0.25))
                    .tracking(2)

                // Cypherpunk message
                Text(currentMessage)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(red: 0, green: 0.8, blue: 0.2))
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
                        .stroke(Color(red: 0, green: 0.4, blue: 0.1), lineWidth: 1)
                )
                .padding(.horizontal, 20)

                // Footer message
                Text("Do not close the app")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(red: 0, green: 0.5, blue: 0.1))
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
                            .stroke(Color(red: 0, green: 0.3, blue: 0.08), lineWidth: 1)
                            .frame(width: 16, height: 16)
                    case .inProgress:
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: Color(red: 0, green: 1, blue: 0.25)))
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(red: 0, green: 0.8, blue: 0.2))
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
                        .foregroundColor(Color(red: 0, green: 0.5, blue: 0.1))
                }
            }

            // Progress bar if applicable
            if let progress = step.progress, step.status == .inProgress, progress > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color(red: 0, green: 0.15, blue: 0.03))
                            .frame(height: 4)

                        Rectangle()
                            .fill(Color(red: 0, green: 0.8, blue: 0.2))
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
            return Color(red: 0, green: 0.3, blue: 0.08)
        case .inProgress:
            return Color(red: 0, green: 1, blue: 0.25)
        case .completed:
            return Color(red: 0, green: 0.7, blue: 0.2)
        case .failed:
            return .red
        }
    }
}

#Preview {
    CypherpunkLoadingView(progress: 0.45, status: "523,000 / 1,041,688 CMUs", isFirstLaunch: true)
}
