import SwiftUI

// MARK: - Classic Mac Window
struct System7Window<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                // Close box - white fill with black border for visibility
                Rectangle()
                    .fill(System7Theme.white)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Rectangle()
                            .stroke(System7Theme.black, lineWidth: 1)
                    )
                    .padding(.leading, 8)

                Spacer()

                Text(title)
                    .font(System7Theme.titleFont(size: 12))
                    .foregroundColor(System7Theme.black)

                Spacer()

                // Placeholder for symmetry
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 12, height: 12)
                    .padding(.trailing, 8)
            }
            .frame(height: 20)
            .background(
                // Title bar stripes
                HStack(spacing: 1) {
                    ForEach(0..<50, id: \.self) { _ in
                        Rectangle()
                            .fill(System7Theme.black)
                            .frame(width: 1)
                    }
                }
                .opacity(0.3)
            )
            .background(System7Theme.white)
            .overlay(
                Rectangle()
                    .stroke(System7Theme.black, lineWidth: 1)
            )

            // Content area
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(System7Theme.white)
                .overlay(
                    Rectangle()
                        .stroke(System7Theme.black, lineWidth: 1)
                )
        }
        .background(System7Theme.white)
    }
}

// MARK: - Menu Bar
struct System7MenuBar: View {
    @State private var showQuote = false
    @State private var currentQuote: (quote: String, author: String) = ("", "")

    var body: some View {
        HStack {
            // Apple menu - tap for privacy quote
            Button(action: {
                currentQuote = PrivacyQuotes.randomQuote()
                showQuote = true
            }) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 14))
                    .foregroundColor(System7Theme.black)
                    .padding(.horizontal, 8)
            }

            Text("File")
                .font(System7Theme.titleFont(size: 12))
                .padding(.horizontal, 8)

            Text("Edit")
                .font(System7Theme.titleFont(size: 12))
                .padding(.horizontal, 8)

            Spacer()

            // Network status
            Image(systemName: "network")
                .font(.system(size: 12))
                .padding(.horizontal, 8)
        }
        .frame(height: 20)
        .background(System7Theme.white)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(System7Theme.black),
            alignment: .bottom
        )
        .alert("Privacy Quote", isPresented: $showQuote) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\"\(currentQuote.quote)\"\n\n- \(currentQuote.author)")
        }
    }
}

// MARK: - Tab Button
struct System7TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(System7Theme.bodyFont(size: 10))
                .foregroundColor(System7Theme.black)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .background(isSelected ? System7Theme.white : System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
        .overlay(
            // Raised/sunken effect
            Rectangle()
                .strokeBorder(
                    LinearGradient(
                        colors: isSelected
                            ? [System7Theme.darkGray, System7Theme.white]
                            : [System7Theme.white, System7Theme.darkGray],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .padding(1)
        )
    }
}

// MARK: - Classic Button
struct System7Button: View {
    let title: String
    let action: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(System7Theme.bodyFont(size: 11))
                .foregroundColor(System7Theme.black)
                .system7ButtonStyle(isPressed: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
    }
}

// MARK: - Text Field
struct System7TextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(System7Theme.bodyFont(size: 11))
            .padding(8)
            .background(System7Theme.white)
            .overlay(
                Rectangle()
                    .stroke(System7Theme.black, lineWidth: 1)
            )
            .overlay(
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
    }
}

// MARK: - Progress Bar
struct System7ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(System7Theme.white)
                    .overlay(
                        Rectangle()
                            .stroke(System7Theme.black, lineWidth: 1)
                    )

                Rectangle()
                    .fill(System7Theme.black)
                    .frame(width: geometry.size.width * progress)
                    .padding(2)
            }
        }
        .frame(height: 16)
    }
}

// MARK: - Alert/Dialog
struct System7Alert: View {
    let title: String
    let message: String
    let primaryButton: String
    let secondaryButton: String?
    let primaryAction: () -> Void
    let secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                // Alert icon
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundColor(System7Theme.black)

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(System7Theme.titleFont(size: 12))
                        .foregroundColor(System7Theme.black)

                    Text(message)
                        .font(System7Theme.bodyFont(size: 11))
                        .foregroundColor(System7Theme.black)
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
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 2)
        )
    }
}

// MARK: - QR Code View (for Receive)
struct System7QRCode: View {
    let data: String

    var body: some View {
        if let qrImage = generateQRCode(from: data) {
            Image(uiImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(8)
                .background(System7Theme.white)
                .overlay(
                    Rectangle()
                        .stroke(System7Theme.black, lineWidth: 2)
                )
        } else {
            Rectangle()
                .fill(System7Theme.lightGray)
                .overlay(
                    Text("QR Error")
                        .font(System7Theme.bodyFont())
                )
        }
    }

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

/// Full-screen cypherpunk sync overlay with task list
struct CypherpunkSyncView: View {
    let progress: Double
    let status: String
    var tasks: [SyncTask] = []

    @State private var currentMessage: String = "Synchronizing with the network..."
    @State private var glitchOffset: CGFloat = 0
    @State private var showGlitch: Bool = false

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
        "Trustless verification in progress..."
    ]

    private let timer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()
    private let glitchTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Dark background
            Color.black.opacity(0.92)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer()

                // Matrix-style title with glitch effect
                ZStack {
                    Text("SYNCING")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0, green: 1, blue: 0.25))
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
                    .foregroundColor(Color(red: 0, green: 0.7, blue: 0.2))
                    .tracking(3)

                // Rotating cypherpunk message
                Text(currentMessage)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(red: 0, green: 1, blue: 0.25))
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
                            .stroke(Color(red: 0, green: 0.4, blue: 0.1), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                }

                // Progress bar
                VStack(spacing: 8) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color(red: 0, green: 0.2, blue: 0.05))
                                .frame(height: 12)

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
                                .frame(width: geometry.size.width * min(max(progress, 0.02), 1.0), height: 12)
                                .animation(.linear(duration: 0.3), value: progress)

                            Rectangle()
                                .stroke(Color(red: 0, green: 0.6, blue: 0.15), lineWidth: 1)
                                .frame(height: 12)
                        }
                    }
                    .frame(height: 12)
                    .padding(.horizontal, 40)

                    // Progress percentage
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0, green: 1, blue: 0.25))

                    // Status text
                    if !status.isEmpty {
                        Text(status)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(red: 0, green: 0.5, blue: 0.1))
                    }
                }
                .padding(.top, 8)

                Spacer()

                // Footer quote
                VStack(spacing: 4) {
                    Text("\"We must defend our own privacy\"")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(red: 0, green: 0.4, blue: 0.1))
                        .italic()

                    Text("- Cypherpunk's Manifesto")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(Color(red: 0, green: 0.3, blue: 0.08))
                }
                .padding(.bottom, 30)
            }
        }
        .onReceive(timer) { _ in
            withAnimation {
                currentMessage = syncMessages.randomElement() ?? syncMessages[0]
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
                            .stroke(Color(red: 0, green: 0.3, blue: 0.08), lineWidth: 1)
                            .frame(width: 14, height: 14)
                    case .inProgress:
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: Color(red: 0, green: 1, blue: 0.25)))
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(red: 0, green: 0.8, blue: 0.2))
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
                        .foregroundColor(Color(red: 0, green: 0.5, blue: 0.1))
                }
            }

            // Progress bar for in-progress tasks
            if let progress = task.progress, case .inProgress = task.status, progress > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color(red: 0, green: 0.15, blue: 0.03))
                            .frame(height: 3)

                        Rectangle()
                            .fill(Color(red: 0, green: 0.8, blue: 0.2))
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
