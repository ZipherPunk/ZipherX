import SwiftUI

/// Macintosh System 7 Design System
enum System7Theme {
    // MARK: - Colors (1-bit inspired with some grays)
    static let black = Color.black
    static let white = Color.white
    static let gray = Color(white: 0.75)
    static let darkGray = Color(white: 0.5)
    static let lightGray = Color(white: 0.9)

    // MARK: - Typography
    static let chicagoFont = "Chicago"
    static let monacoFont = "Monaco"
    static let genevaFont = "Geneva"

    // System fonts (fallback to SF Mono for similar feel)
    static func systemFont(size: CGFloat) -> Font {
        .custom("Menlo", size: size)
    }

    static func titleFont(size: CGFloat = 12) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }

    static func bodyFont(size: CGFloat = 11) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    // MARK: - Desktop Pattern
    static var desktopPattern: some View {
        Canvas { context, size in
            // Classic Mac desktop pattern (diagonal lines)
            let patternSize: CGFloat = 4
            for x in stride(from: 0, to: size.width + patternSize, by: patternSize) {
                for y in stride(from: 0, to: size.height + patternSize, by: patternSize) {
                    if (Int(x / patternSize) + Int(y / patternSize)) % 2 == 0 {
                        context.fill(
                            Path(CGRect(x: x, y: y, width: patternSize / 2, height: patternSize / 2)),
                            with: .color(gray)
                        )
                    }
                }
            }
        }
        .background(lightGray)
    }

    // MARK: - Borders
    static func classicBorder(raised: Bool = true) -> some View {
        RoundedRectangle(cornerRadius: 0)
            .strokeBorder(
                LinearGradient(
                    colors: raised ? [white, darkGray] : [darkGray, white],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 2
            )
    }
}

// MARK: - View Extensions
extension View {
    func system7ButtonStyle(isPressed: Bool = false) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isPressed ? System7Theme.darkGray : System7Theme.lightGray)
            .overlay(
                Rectangle()
                    .strokeBorder(
                        LinearGradient(
                            colors: isPressed
                                ? [System7Theme.darkGray, System7Theme.white]
                                : [System7Theme.white, System7Theme.darkGray],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2
                    )
            )
            .overlay(
                Rectangle()
                    .stroke(System7Theme.black, lineWidth: 1)
            )
    }
}
