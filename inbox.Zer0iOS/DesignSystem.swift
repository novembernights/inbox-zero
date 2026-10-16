import SwiftUI

enum InboxDesign {
    enum SurfaceLevel: Int {
        case background100 = 100
        case raised200 = 200
        case elevated300 = 300

        var color: Color {
            Color(uiColor: UIColor { traits in
                let dark = traits.userInterfaceStyle == .dark
                switch self {
                case .background100:
                    return dark
                        ? UIColor(red: 0.045, green: 0.047, blue: 0.053, alpha: 0.94)
                        : UIColor(red: 0.958, green: 0.963, blue: 0.972, alpha: 0.92)
                case .raised200:
                    return dark
                        ? UIColor(red: 0.095, green: 0.099, blue: 0.110, alpha: 0.96)
                        : UIColor(red: 0.978, green: 0.981, blue: 0.988, alpha: 0.96)
                case .elevated300:
                    return dark
                        ? UIColor(red: 0.145, green: 0.150, blue: 0.165, alpha: 0.98)
                        : UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 0.98)
                }
            })
        }
    }

    enum Typography {
        // System typography avoids distributing a font without its license.
        static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
            .system(style, design: .default, weight: weight)
        }

        static let body = font(.body)
        static let headline = font(.headline, weight: .semibold)
        static let subheadline = font(.subheadline)
        static let caption = font(.caption)
        static let brand = font(.title2, weight: .semibold)
        static let screenTitle = font(.title2, weight: .bold)
        static let screenSubtitle = font(.subheadline)
        static let metadata = font(.subheadline, weight: .semibold)
        static let briefing = font(.title3, weight: .semibold)
        static let section = font(.title3, weight: .bold)
        static let queueCount = font(.title, weight: .medium)
        static let queueLabel = font(.headline)
        static let itemTitle = font(.subheadline, weight: .semibold)
        static let itemDetail = font(.caption)
    }

    enum Spacing {
        static let xSmall: CGFloat = 5
        static let small: CGFloat = 8
        static let medium: CGFloat = 13
        static let large: CGFloat = 21
        static let xLarge: CGFloat = 34
    }

    enum Radius {
        static let compact: CGFloat = 12
        static let control: CGFloat = 18
        static let card: CGFloat = 24
        static let feature: CGFloat = 28

        static func concentric(parent: CGFloat, inset: CGFloat) -> CGFloat {
            max(0, parent - inset)
        }
    }

    enum Icon {
        /// Lucide's source artwork uses a 2-unit stroke. Keep the app's icon
        /// geometry intact while giving every symbol the same lighter weight.
        static let strokeWidth: CGFloat = 1.25
    }

    static let minimumTouchTarget: CGFloat = 44

    /// Clearance for controls that float immediately above the system's
    /// liquid-glass tab bar. iOS 26 visually extends the tab bar beyond the
    /// content safe area, so bottom accessories need an explicit resting gap.
    static let floatingTabBarClearance: CGFloat = 76
}

struct InboxSurface: ViewModifier {
    var radius: CGFloat = InboxDesign.Radius.card
    var material: Material = .thinMaterial

    func body(content: Content) -> some View {
        content
            .background(material, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 0.5)
            }
    }
}

struct InboxContentSurface: ViewModifier {
    var radius: CGFloat = InboxDesign.Radius.card
    var level: InboxDesign.SurfaceLevel = .raised200
    var emphasized = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                level.color,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.075 : 0.55),
                                Color.white.opacity(colorScheme == .dark ? 0.018 : 0.08),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.055), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: Color.black.opacity(emphasized ? (colorScheme == .dark ? 0.30 : 0.09) : 0),
                radius: emphasized ? 18 : 0,
                x: 0,
                y: emphasized ? 8 : 0
            )
    }
}

extension View {
    func inboxSurface(radius: CGFloat = InboxDesign.Radius.card, material: Material = .thinMaterial) -> some View {
        modifier(InboxSurface(radius: radius, material: material))
    }

    func inboxContentSurface(
        radius: CGFloat = InboxDesign.Radius.card,
        level: InboxDesign.SurfaceLevel = .raised200,
        emphasized: Bool = false
    ) -> some View {
        modifier(InboxContentSurface(radius: radius, level: level, emphasized: emphasized))
    }

    func inboxInteractiveHighlight() -> some View {
        hoverEffect(.highlight)
    }

}

struct FrostedVoicePill: View {
    let isRecording: Bool
    let accent: Color
    var idleTitle = "Ask by voice"
    var listeningTitle = "Listening…"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: InboxDesign.Spacing.small) {
            if isRecording {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                    waveform(phase: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                LucideIcon(name: "audio-lines", size: 30)
            }
            Text(isRecording ? listeningTitle : idleTitle)
                .font(InboxDesign.Typography.font(.subheadline, weight: .semibold))
        }
        .foregroundStyle(.primary)
        .frame(width: isRecording ? 178 : 158, height: 56)
        .glassEffect(
            isRecording ? .regular.tint(accent.opacity(0.18)).interactive() : .regular.interactive(),
            in: Capsule()
        )
        .animation(.snappy(duration: 0.28), value: isRecording)
        .contentShape(Capsule())
    }

    private func waveform(phase: TimeInterval) -> some View {
        HStack(spacing: 2.5) {
            ForEach(0..<4, id: \.self) { index in
                let oscillation = (sin((phase * 8.5) + (Double(index) * 1.2)) + 1) / 2
                Capsule(style: .continuous)
                    .fill(Color.primary)
                    .frame(width: 2.5, height: reduceMotion ? 12 : 8 + (oscillation * 14))
            }
        }
        .frame(width: 18, height: 24)
    }
}

struct ContextActionPill<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .font(InboxDesign.Typography.font(.subheadline, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
                .padding(.horizontal, InboxDesign.Spacing.medium)
                .contentShape(Capsule())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
    }
}

struct ContextUtilityButton<Content: View>: View {
    let accessibilityLabel: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(accessibilityLabel)
    }
}
