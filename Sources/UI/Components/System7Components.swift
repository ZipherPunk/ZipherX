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
                .padding(.horizontal, 10)
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
