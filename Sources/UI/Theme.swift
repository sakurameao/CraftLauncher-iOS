import SwiftUI

/// Visual language for the launcher.
///
/// Deliberately restrained: the accent palette alludes to the game's grass-and-stone
/// identity without reproducing any of Mojang's artwork, wordmarks or textures.
/// Nothing here is a trademark of anyone else.
enum Theme {

    // MARK: - Palette

    /// Background ramp, dark-first. The launcher is used full-screen next to a game
    /// that is almost always dark, so a light theme would flash badly on launch.
    enum Palette {
        static let background = Color(red: 0.055, green: 0.063, blue: 0.078)
        static let surface = Color(red: 0.094, green: 0.106, blue: 0.125)
        static let surfaceRaised = Color(red: 0.129, green: 0.145, blue: 0.169)
        static let surfaceHighlight = Color(red: 0.169, green: 0.188, blue: 0.216)
        static let border = Color.white.opacity(0.08)
        static let borderStrong = Color.white.opacity(0.16)

        /// Grass green — the primary action colour.
        static let accent = Color(red: 0.373, green: 0.718, blue: 0.286)
        static let accentDim = Color(red: 0.259, green: 0.510, blue: 0.204)

        /// Diamond cyan — information and links.
        static let info = Color(red: 0.361, green: 0.808, blue: 0.831)
        /// Redstone red — destructive actions and errors.
        static let danger = Color(red: 0.878, green: 0.290, blue: 0.290)
        /// Gold — warnings.
        static let warning = Color(red: 0.949, green: 0.729, blue: 0.259)

        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.62)
        static let textTertiary = Color.white.opacity(0.38)
    }

    // MARK: - Metrics

    enum Metric {
        static let corner: CGFloat = 14
        static let cornerSmall: CGFloat = 9
        static let spacing: CGFloat = 16
        static let spacingTight: CGFloat = 8
        static let spacingLoose: CGFloat = 24
        static let rowHeight: CGFloat = 56
    }

    // MARK: - Reusable styling

    /// Standard card background: a raised surface with a hairline border, which
    /// reads as depth on a dark background without needing a shadow.
    struct Card: ViewModifier {
        var padding: CGFloat = Theme.Metric.spacing

        func body(content: Content) -> some View {
            content
                .padding(padding)
                .background(Theme.Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metric.corner, style: .continuous)
                        .strokeBorder(Theme.Palette.border, lineWidth: 1)
                )
        }
    }

    /// A filled, tappable row. Used for lists of versions, mods and accounts.
    struct ListRow: ViewModifier {
        var isSelected = false

        func body(content: Content) -> some View {
            content
                .padding(.horizontal, Theme.Metric.spacing)
                .padding(.vertical, 12)
                .frame(minHeight: Theme.Metric.rowHeight)
                .background(isSelected ? Theme.Palette.surfaceHighlight : Theme.Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.cornerSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metric.cornerSmall, style: .continuous)
                        .strokeBorder(
                            isSelected ? Theme.Palette.accent.opacity(0.6) : Theme.Palette.border,
                            lineWidth: 1
                        )
                )
        }
    }
}

extension View {
    func cardStyle(padding: CGFloat = Theme.Metric.spacing) -> some View {
        modifier(Theme.Card(padding: padding))
    }

    func listRowStyle(isSelected: Bool = false) -> some View {
        modifier(Theme.ListRow(isSelected: isSelected))
    }
}

// MARK: - Shared components

/// A section heading, matching the cadence of the rest of the UI.
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A labelled value for detail readouts.
struct LabeledValue: View {
    let label: String
    let value: String
    var monospaced = false
    var tint: Color = Theme.Palette.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Pill-shaped tag, used for version type, loader and mod state.
struct Tag: View {
    let text: String
    var tint: Color = Theme.Palette.textSecondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.16))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

/// Placeholder shown when a list has no content, with an explanation of what to do.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ProminentButtonStyle())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 420)
        .padding(Theme.Metric.spacingLoose)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Primary action button: filled with the accent colour, with a dimmed disabled
/// state that still reads as a button rather than vanishing.
struct ProminentButtonStyle: ButtonStyle {
    var tint: Color = Theme.Palette.accent
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        let base = isDestructive ? Theme.Palette.danger : tint
        return configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(base == Theme.Palette.accent ? Color.black.opacity(0.85) : Color.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(base.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.cornerSmall, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary button: outlined, for actions that must not compete with the primary.
struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.Palette.surfaceHighlight.opacity(configuration.isPressed ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.cornerSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metric.cornerSmall, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )
    }
}

/// Determinate or indeterminate progress line, styled to match.
struct ProgressLine: View {
    var value: Double?
    var tint: Color = Theme.Palette.accent

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Palette.surfaceHighlight)
                if let value {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, min(1, value)) * geometry.size.width)
                        .animation(.easeOut(duration: 0.2), value: value)
                } else {
                    // Indeterminate: a travelling highlight. SwiftUI has no built-in
                    // indeterminate bar, and a spinner would be heavier here.
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule()
                            .fill(tint)
                            .frame(width: geometry.size.width * 0.3)
                            .offset(x: (geometry.size.width * 1.3) * phase - geometry.size.width * 0.3)
                    }
                }
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
    }
}

/// The app's mark: a stylised block, drawn with shapes.
///
/// Original artwork — not derived from any Mojang asset.
struct LauncherMark: View {
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.Palette.accent, Theme.Palette.accentDim],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            // A carved notch, so the mark reads as a cube face rather than a blob.
            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .fill(Color.black.opacity(0.22))
                .frame(width: size * 0.42, height: size * 0.42)
            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                .frame(width: size * 0.42, height: size * 0.42)
        }
        .frame(width: size, height: size)
    }
}
