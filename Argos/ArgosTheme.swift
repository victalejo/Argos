import SwiftUI

/// Shared surfaces keep the workspace legible in both macOS appearances.
enum ArgosTheme {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.08)
    static let accent = Color.accentColor
    /// A deeper fill preserves white control-label contrast in dark appearance.
    static let controlAccent = Color("ControlAccent")

    static func motion(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22)
    }
}

struct WorkspaceBackdrop: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            ArgosTheme.canvas
            RadialGradient(
                colors: [Color.accentColor.opacity(0.09), .clear],
                center: .topLeading, startRadius: 0, endRadius: 650
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct WorkspaceIcon: View {
    let symbol: String
    var size: CGFloat = 52

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.27))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27)
                    .strokeBorder(Color.accentColor.opacity(0.15))
            }
            .accessibilityHidden(true)
    }
}

struct KeyboardHint: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(ArgosTheme.border)
            }
            .accessibilityHidden(true)
    }
}
