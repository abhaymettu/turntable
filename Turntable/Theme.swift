import SwiftUI
import UIKit

// MARK: - Tokens

/// Thin layer over the system palette, not a design system of its own. Everything here is
/// either an Apple semantic colour, an Apple material, or the one accent this app owns.
/// State is never carried by colour alone: every coloured thing sits next to a word or a
/// distinct SF Symbol, which is what keeps it readable for a colour-blind reader.
enum Theme {
    /// Ember. Warm and high in lightness, so it separates from the neutrals by brightness
    /// and not only by hue. Applied as the app `.tint`, so system controls pick it up.
    static let accent = Color(red: 1.0, green: 0.44, blue: 0.22)

    /// True black, for OLED. The system dark background is a dark grey; this app wants the
    /// pixels off, so the ground is set explicitly and the chrome stays translucent over it.
    static let ground = Color.black

    static let separator = Color(uiColor: .separator)

    // Concentric radii: outer card, artwork inside it, small tiles inside that.
    static let cardRadius: CGFloat = 22
    static let artRadius: CGFloat = 18

    /// What a card pads its content by, and therefore what its inner corners owe the outer.
    /// Concentric means the gap between the two curves is the padding between them all the
    /// way round the arc, so an inner radius is the outer minus the inset, never a second
    /// round number picked by eye.
    static let cardInset: CGFloat = 14
    static let innerRadius: CGFloat = cardRadius - cardInset

    /// The system's own springs rather than hand-picked numbers. `.smooth` is critically
    /// damped, which is Apple's move/reposition setting (damping 1.0, response ~0.4);
    /// `.snappy` carries the small overshoot they reserve for motion a gesture threw.
    /// Bounce is spent only where a real state change earns the overshoot.
    static let spring = Animation.smooth(duration: 0.35)
    static let springy = Animation.snappy(duration: 0.4)
    static let quick = Animation.smooth(duration: 0.2)

    /// UIKit's dark bar backgrounds are a grey blur. On a true-black app they read as
    /// lighter strips pasted over the ground, so both bars take the ground itself and keep
    /// the system blur above it. Set once at launch rather than per screen.
    static func installBarAppearance() {
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundColor = .black
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        nav.backgroundColor = .black
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }
}

// MARK: - Surfaces

extension View {
    /// A card on the black ground: system material, system separator edge, concentric corner.
    func card(_ radius: CGFloat = Theme.cardRadius, material: Material = .regularMaterial) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(material, in: shape)
            .overlay(shape.strokeBorder(Theme.separator, lineWidth: 0.5))
            .clipShape(shape)
    }

    /// True black behind a screen, edge to edge, with the system chrome floating over it.
    func screenGround() -> some View {
        background(Theme.ground.ignoresSafeArea())
    }
}

extension View {
    /// `searchFocused` landed in iOS 18 and this app still builds for 17, where the field
    /// simply opens unfocused.
    @ViewBuilder
    func searchFocusedIfAvailable(_ binding: FocusState<Bool>.Binding) -> some View {
        if #available(iOS 18, *) { searchFocused(binding) } else { self }
    }
}

/// Pressable things answer on touch-down, the way system controls do.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressStyle {
    static var press: PressStyle { PressStyle() }
}

// MARK: - Components

/// Symbol plus word, always both, in Dynamic Type. The chips are how this app reports
/// state, so the meaning lives in the text and the glyph and colour only echoes it.
struct Chip: View {
    let symbol: String
    let text: String
    var emphasis: Bool = false

    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .imageScale(.small)
            .foregroundStyle(emphasis ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(emphasis ? Theme.accent.opacity(0.4) : Theme.separator, lineWidth: 0.5))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text)
    }
}

/// The one loud button on a screen, the system's own prominent style in the app tint.
struct PrimaryButton: View {
    let title: String
    var symbol: String?
    var loading = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if loading {
                    ProgressView().controlSize(.small).tint(.black)
                } else if let symbol {
                    Image(systemName: symbol).imageScale(.medium)
                }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Theme.accent)
        // Black reads on ember and on nothing else. A disabled prominent button drops its
        // fill to a dark tint, so the label goes back to the system's colour or it vanishes.
        .foregroundStyle(enabled && !loading ? AnyShapeStyle(.black) : AnyShapeStyle(.secondary))
        .disabled(!enabled || loading)
        .animation(Theme.quick, value: enabled)
    }
}

/// A thin capsule track. The same shape carries track position and episode position, so
/// progress reads the same everywhere in the app.
struct ProgressTrack: View {
    let progress: Double
    var height: CGFloat = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Theme.accent)
                    // A zero-width capsule still paints its own caps, which would leave an
                    // ember dot sitting on a track that has not started.
                    .frame(width: progress <= 0 ? 0 : max(height, geo.size.width * progress.clamped()))
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .linear(duration: 0.5), value: progress)
        .accessibilityHidden(true)
    }
}

private extension Double {
    func clamped() -> Double { isFinite ? Swift.min(1, Swift.max(0, self)) : 0 }
}

/// The app's mark: a record. Stands in for missing artwork, anchors onboarding, and turns
/// while music plays. Reduced motion holds it still; the transport glyph still says the state.
struct VinylMark: View {
    var size: CGFloat
    var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Angle = .zero

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.08))
            ForEach(1..<5) { ring in
                Circle()
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                    .padding(size * 0.055 * CGFloat(ring))
            }
            Circle()
                .fill(Theme.accent)
                .frame(width: size * 0.30, height: size * 0.30)
            Circle()
                .fill(Color.black)
                .frame(width: size * 0.075, height: size * 0.075)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Theme.separator, lineWidth: 0.5))
        .rotationEffect(angle)
        .accessibilityHidden(true)
        .task(id: spinning) { await spin() }
    }

    /// Slower than 33 rpm on purpose: at this size a real speed reads as a flicker.
    private func spin() async {
        guard spinning, !reduceMotion else { return }
        while !Task.isCancelled {
            withAnimation(.linear(duration: 6)) { angle += .degrees(360) }
            try? await Task.sleep(for: .seconds(6))
        }
    }
}

/// A failure never gets the whole screen. It is one note above the button, with the exact
/// reason, a symbol, and no colour-only signalling.
struct FailureNote: View {
    let text: String

    var body: some View {
        Label {
            Text(text).font(.footnote).foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.accent)
        }
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(14, material: .thinMaterial)
        .accessibilityElement(children: .combine)
    }
}

/// The taps the app answers with.
///
/// Haptics are the part of "native" a screenshot cannot show, and the part that goes
/// missing first. They are spent on the four moments that are actually physical: a
/// transport control taking effect, a character landing in the pairing code, and a pairing
/// finishing one way or the other. Nothing decorative gets one.
@MainActor
enum Haptics {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func notify(_ kind: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(kind)
    }
}

/// Formats seconds the way every clock in this app formats them.
func clockString(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    if total >= 3600 {
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    return String(format: "%d:%02d", total / 60, total % 60)
}
