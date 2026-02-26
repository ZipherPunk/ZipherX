import SwiftUI

// MARK: - Themed Window

/// A window that adapts to the current theme
struct ThemedWindow<Content: View>: View {
    @EnvironmentObject var themeManager: ThemeManager
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let theme = themeManager.currentTheme

        VStack(spacing: 0) {
            // Title bar
            titleBar(theme: theme)

            // Content area
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surfaceColor)
                .overlay(
                    Rectangle()
                        .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                )
        }
        .background(theme.surfaceColor)
        .cornerRadius(theme.cornerRadius)
        .shadow(color: theme.shadowColor, radius: theme.usesShadows ? 5 : 0)
    }

    @ViewBuilder
    private func titleBar(theme: AppTheme) -> some View {
        HStack {
            // Close box
            if theme.hasRetroStyling {
                Rectangle()
                    .fill(theme.surfaceColor)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Rectangle()
                            .stroke(theme.borderColor, lineWidth: 1)
                    )
                    .padding(.leading, 8)
            }

            Spacer()

            Text(title)
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)

            Spacer()

            // Placeholder for symmetry
            if theme.hasRetroStyling {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 12, height: 12)
                    .padding(.trailing, 8)
            }
        }
        .frame(height: theme.windowTitleBarHeight)
        .background(
            // Title bar stripes for Mac7
            Group {
                if theme.windowHasStripes {
                    HStack(spacing: 1) {
                        ForEach(0..<50, id: \.self) { _ in
                            Rectangle()
                                .fill(theme.borderColor)
                                .frame(width: 1)
                        }
                    }
                    .opacity(0.3)
                }
            }
        )
        .background(theme.surfaceColor)
        .overlay(
            Rectangle()
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        )
    }
}

// MARK: - Themed Button

struct ThemedButton: View {
    @EnvironmentObject var themeManager: ThemeManager
    let title: String
    let action: () -> Void
    var style: ButtonStyle = .primary

    enum ButtonStyle {
        case primary
        case secondary
        case danger
    }

    @State private var isPressed = false

    var body: some View {
        let theme = themeManager.currentTheme

        Button(action: action) {
            Text(title)
                .font(theme.bodyFont)
                .foregroundColor(buttonTextColor(theme: theme))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(buttonBackground(theme: theme))
                .overlay(buttonBorder(theme: theme))
                .cornerRadius(theme.cornerRadius)
        }
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
    }

    private func buttonTextColor(theme: AppTheme) -> Color {
        switch style {
        case .primary:
            return theme.hasRetroStyling ? theme.buttonText : .white
        case .secondary:
            return theme.buttonText
        case .danger:
            return .white
        }
    }

    private func buttonBackground(theme: AppTheme) -> some View {
        Group {
            if theme.hasRetroStyling {
                // Retro beveled style
                Rectangle()
                    .fill(isPressed ? theme.buttonShadow : theme.buttonBackground)
            } else {
                // Modern gradient
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .fill(backgroundGradient(theme: theme))
            }
        }
    }

    private func backgroundGradient(theme: AppTheme) -> LinearGradient {
        let baseColor: Color
        switch style {
        case .primary: baseColor = theme.primaryColor
        case .secondary: baseColor = theme.secondaryColor
        case .danger: baseColor = theme.errorColor
        }

        return LinearGradient(
            colors: [baseColor, baseColor.opacity(0.8)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private func buttonBorder(theme: AppTheme) -> some View {
        if theme.hasRetroStyling {
            // Classic beveled border
            Rectangle()
                .strokeBorder(
                    LinearGradient(
                        colors: isPressed
                            ? [theme.buttonShadow, theme.buttonHighlight]
                            : [theme.buttonHighlight, theme.buttonShadow],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
                .overlay(
                    Rectangle()
                        .stroke(theme.borderColor, lineWidth: 1)
                )
        } else {
            // Modern subtle border
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        }
    }
}

// MARK: - Themed Text Field

struct ThemedTextField: View {
    @EnvironmentObject var themeManager: ThemeManager
    let placeholder: String
    @Binding var text: String

    var body: some View {
        let theme = themeManager.currentTheme

        TextField(placeholder, text: $text)
            .font(theme.bodyFont)
            .foregroundColor(theme.textPrimary)
            .padding(10)
            .background(theme.surfaceColor)
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(theme.borderColor, lineWidth: theme.borderWidth)
            )
            .cornerRadius(theme.cornerRadius)
    }
}

// MARK: - Themed Progress Bar

struct ThemedProgressBar: View {
    @EnvironmentObject var themeManager: ThemeManager
    let progress: Double

    var body: some View {
        let theme = themeManager.currentTheme

        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                Rectangle()
                    .fill(theme.progressBarBackground)

                // Fill
                Rectangle()
                    .fill(theme.progressBarFill)
                    .frame(width: geometry.size.width * min(progress, 1.0))

                // Border
                Rectangle()
                    .stroke(theme.borderColor, lineWidth: theme.borderWidth)
            }
        }
        .frame(height: theme.progressBarHeight)
        .cornerRadius(theme.cornerRadius)
    }
}

// MARK: - Themed Card

struct ThemedCard<Content: View>: View {
    @EnvironmentObject var themeManager: ThemeManager
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let theme = themeManager.currentTheme

        content
            .padding(16)
            .background(theme.surfaceColor)
            .cornerRadius(theme.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(theme.borderColor, lineWidth: theme.borderWidth)
            )
            .shadow(color: theme.shadowColor, radius: theme.usesShadows ? 3 : 0)
    }
}

// MARK: - Themed Label

struct ThemedLabel: View {
    @EnvironmentObject var themeManager: ThemeManager
    let text: String
    var style: LabelStyle = .body

    enum LabelStyle {
        case title
        case body
        case caption
        case mono
    }

    var body: some View {
        let theme = themeManager.currentTheme

        Text(text)
            .font(fontForStyle(theme: theme))
            .foregroundColor(colorForStyle(theme: theme))
    }

    private func fontForStyle(theme: AppTheme) -> Font {
        switch style {
        case .title: return theme.titleFont
        case .body: return theme.bodyFont
        case .caption: return theme.captionFont
        case .mono: return theme.monoFont
        }
    }

    private func colorForStyle(theme: AppTheme) -> Color {
        switch style {
        case .title: return theme.textPrimary
        case .body: return theme.textPrimary
        case .caption: return theme.textSecondary
        case .mono: return theme.textPrimary
        }
    }
}

// MARK: - Themed Background

struct ThemedBackground: ViewModifier {
    @EnvironmentObject var themeManager: ThemeManager

    func body(content: Content) -> some View {
        content
            .background(themeManager.currentTheme.backgroundColor)
    }
}

extension View {
    func themedBackground() -> some View {
        modifier(ThemedBackground())
    }
}

// MARK: - Theme Preview View

struct ThemePreviewCard: View {
    @EnvironmentObject var themeManager: ThemeManager
    let themeType: ThemeType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // Preview thumbnail
                themePreview(for: themeType)
                    .frame(height: 60)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                    )

                // Theme name
                Text(themeType.displayName)
                    .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? .blue : .primary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private func themePreview(for type: ThemeType) -> some View {
        let theme = type.theme

        ZStack {
            // Background
            Rectangle()
                .fill(theme.backgroundColor)

            // Window preview
            VStack(spacing: 0) {
                // Title bar
                Rectangle()
                    .fill(theme.surfaceColor)
                    .frame(height: 8)
                    .overlay(
                        Rectangle()
                            .stroke(theme.borderColor, lineWidth: 0.5)
                    )

                // Content
                Rectangle()
                    .fill(theme.surfaceColor)

                // Button preview
                HStack {
                    RoundedRectangle(cornerRadius: theme.cornerRadius / 4)
                        .fill(theme.primaryColor)
                        .frame(width: 30, height: 8)
                }
                .padding(4)
            }
            .padding(8)
        }
    }
}
