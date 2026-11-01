import SwiftUI

/// The app's design tokens: spacing, radii, colour and type in one place, so a screen is styled by naming a token
/// rather than picking a number. The palette is the Oct 9 reference's: warm paper in the light, warm charcoal in the
/// dark, and one muted deep slate accent used for actions and for the reader's own messages. The legacy names
/// (`navy`, `gray`) are kept — the call sites are everywhere — but their values are the warm ones the build of
/// record shipped (LOOK-SPEC, D seq 9829/15963/17244).
enum Tok {
    // Spacing, 4-based.
    static let sp1: CGFloat = 4    // hairline gaps inside one control
    static let sp2: CGFloat = 8    // icon to label
    static let sp3: CGFloat = 12   // tile padding
    static let sp4: CGFloat = 16   // screen margin and card padding
    static let sp5: CGFloat = 24   // between sections
    static let sp6: CGFloat = 32   // above a section title

    // Radii. Nothing else in the app rounds a corner.
    static let rTile: CGFloat = 12
    static let rCard: CGFloat = 16
    static let rField: CGFloat = 20
    /// A message bubble's corner, and the tighter one where two bubbles of the same side meet.
    static let rBubble: CGFloat = 20
    static let rBubbleTight: CGFloat = 6
    /// How wide a message may be: a bubble at 78% of the screen, a reply column a little wider because code blocks
    /// and tables live inside it and already scroll sideways.
    static let bubbleWidth: CGFloat = 0.78
    static let replyWidth: CGFloat = 0.88
    /// The widest the transcript and composer get. No phone today comes near it (the largest is 440 pt); the iPhone
    /// Duo's open inner screen does, and a reply spread across all of it is hard to read (duo-plan step 2).
    static let readingColumn: CGFloat = 680
    /// Between two messages of the same side, and between one group and the next.
    static let gapInGroup: CGFloat = 4
    static let gapBetweenGroups: CGFloat = 14

    static let accent = Color(red: 0.216, green: 0.263, blue: 0.337)   // muted deep slate, the one accent

    /// The ink an ACTION is written in, which is not the same thing as the slate a bubble is filled with
    /// (Codex R11 P2). The slate measures about 1.5:1 against the dark canvas and 1.5:1 against the raised surface,
    /// so small action text and the context ring drawn in it are barely there in the dark. The light keeps the
    /// photographed slate; the dark takes the paper, which is the same pair the bubbles already use the other way
    /// round. `Tok.accent` stays what it is: the fill of the reader's own message.
    static func actionTint(_ s: ColorScheme) -> Color { s == .dark ? paper : accent }
    /// The two hues kept for the process rows, plus the two states every app needs. The accent stays for actions
    /// and for the reader's own messages; these never fill anything larger than a glyph and a word.
    static let think = Color(red: 0.48, green: 0.33, blue: 0.78)      // reasoning rows
    static let tool = Color(red: 0.94, green: 0.49, blue: 0.08)       // tool rows
    static let run = Color(red: 0.13, green: 0.66, blue: 0.35)        // a row whose work is still happening
    static let ok = Color(red: 0.18, green: 0.72, blue: 0.36)
    static let danger = Color(red: 0.86, green: 0.24, blue: 0.24)
    static let navy = Color(red: 0.122, green: 0.118, blue: 0.110)     // warm charcoal
    static let navyRaised = Color(red: 0.160, green: 0.155, blue: 0.145)
    static let paper = Color(red: 0.965, green: 0.961, blue: 0.945)    // warm off-white
    static let ink = Color(red: 0.090, green: 0.086, blue: 0.078)      // warm near-black
    static let gray = Color(red: 0.480, green: 0.462, blue: 0.435)     // warm grey

    /// The raised surface for the places that cannot read a colour scheme (View extensions): a dynamic colour, warm
    /// in both appearances, so the panels stop being the system's cool grey.
    static let warmSurface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.160, green: 0.155, blue: 0.145, alpha: 1)
        : UIColor(red: 0.988, green: 0.984, blue: 0.972, alpha: 1) })

    static func canvas(_ s: ColorScheme) -> Color { s == .dark ? navy : paper }
    static func surface(_ s: ColorScheme) -> Color { s == .dark ? navyRaised : .white }
    static func hairline(_ s: ColorScheme) -> Color { s == .dark ? .white.opacity(0.09) : .black.opacity(0.07) }
    static func secondaryText(_ s: ColorScheme) -> Color { s == .dark ? .white.opacity(0.62) : gray }

    /// The stroke a flat panel or the composer wears: a white highlight in the light, a faint one in the dark. With
    /// no shadow and no material under it, this hairline is what makes an opaque surface read as a raised object.
    static let edge = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.13) : UIColor(white: 1, alpha: 0.56) })

    /// The quiet fill of the composer's round controls (+, mic, model): one step lighter than the box they sit in.
    static let controlFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.05) })
    /// The composer box: a raised step above the canvas, lighter than the panels in the dark so it reads as glass.
    static let composerFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.200, green: 0.195, blue: 0.186, alpha: 1)
        : UIColor(red: 0.995, green: 0.993, blue: 0.985, alpha: 1) })

    // Type. Counts, durations and token figures always take `.monospacedDigit()`.
    static let title = Font.title3.weight(.semibold)
    static let heading = Font.headline
    static let body = Font.body
    static let meta = Font.footnote
    static let chip = Font.caption2.weight(.medium)
}

/// The native iOS 26/27 chrome, in one place. The app still runs on iOS 18, so every helper here is the same view
/// with the system's own glass, bar or minimisation when the phone has it, and the app's own drawing when it does not.
///
/// The CONTENT panels are deliberately not glass any more: the build of record flattened them to opaque warm fills
/// with a hairline stroke and no shadow (LOOK-SPEC, D seq 16248/16258/17244/17483; C seq 22423/22448). Native
/// toolbar circles — the drawer's search button — are separate and stay native.
extension View {
    /// A floating control in a circle — the jump-to-bottom arrow. Solid warm surface, no material.
    @ViewBuilder func floatingCircle(interactive: Bool = true) -> some View {
        background(Tok.warmSurface, in: Circle())
    }

    /// A panel in place of a hand-painted material card: one opaque warm fill and a hairline edge, no shadow.
    @ViewBuilder func panelChrome(_ cornerRadius: CGFloat, material: Material = .thinMaterial) -> some View {
        background(Tok.warmSurface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Tok.edge, lineWidth: 0.8) }
    }

    /// The message field's own container: a raised fill a step above the canvas, a hairline edge, and a soft shadow
    /// that lifts it off the transcript the way the reference's composer floats.
    @ViewBuilder func composerFieldChrome() -> some View {
        background(Tok.composerFill, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Tok.edge, lineWidth: 0.8) }
            .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    /// Kept as a call-site name: with the content panels flat there is no glass left to merge.
    @ViewBuilder func glassGroup<C: View>(spacing: CGFloat = 8, @ViewBuilder content: () -> C) -> some View {
        content()
    }

    /// A round icon control in the system's own glass where the phone has it — the drawer's search button — and the
    /// system's bordered circle before that. Same shape and same tap target either way.
    @ViewBuilder func glassCircleButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.circle)
        }
    }

    /// A comfortable tap target for an icon-only control: 44 pt is the platform minimum.
    func tapTarget() -> some View { frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }

    /// A bar that shrinks away while the content scrolls, as Apple's own apps do on iOS 27.
    @ViewBuilder func minimizingBar() -> some View {
        if #available(iOS 27.0, *) {
            toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
        } else {
            self
        }
    }
}

/// Every custom control answers a touch: a small dim and a hair of scale while it is pressed. The reference's rows
/// and chips all do this, and it is the difference between a control and a picture of one.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A sheet's own canvas: the list inside goes transparent and the app's canvas shows behind it, so a sheet matches
/// the screen it was opened from. Applied at the presentation site, where it reaches the list inside.
struct SheetCanvas: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(AppModel.self) private var app
    @State private var level = 0
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden).background(Tok.canvas(scheme))
            .overlay(alignment: .top) { ToastView(level: level) }
            .onAppear { app.sheetDepth += 1; level = app.sheetDepth }
            .onDisappear { app.sheetDepth = max(0, app.sheetDepth - 1) }
    }
}

extension View {
    func sheetCanvas() -> some View { modifier(SheetCanvas()) }
}

/// The system draws a bar of its own on iOS 26+; older phones get the app's painted fill.
struct LegacyBarFill: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.background(alignment: .top) {
                Rectangle().fill(.bar).ignoresSafeArea(edges: .bottom)
                    .mask(LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.12)))
            }
        }
    }
}
