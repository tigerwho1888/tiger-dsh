import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The message field. It is a UIKit text view rather than a SwiftUI text field for two reasons the operator hit on
/// the phone: only UIKit's paste configuration lets a pasted screenshot become an attachment the way iOS does it
/// (long-press, Paste — no extra button anywhere), and a text view can send on return while still growing over
/// several lines.
struct MessageField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let onSend: () -> Void
    let onImage: (UIImage) -> Void

    /// The body face the rest of the app uses, with the rounded design. The preferred font already carries the
    /// reader's Dynamic Type size, so only the design changes.
    static var roundedBody: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .body)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: d, size: 0)
    }

    func makeUIView(context: Context) -> PasteTextView {
        // TextKit 1, on this view and on its measuring twin: every crash since 10-14 (five, iOS 27.2 beta) is a
        // freed object released in the main thread's autorelease pool with no app frame on the stack, and the one
        // UIKit object this app feeds on every pass while a reply streams is this field's text (Codex r90/r91).
        let v = PasteTextView(usingTextLayoutManager: false)
        v.delegate = context.coordinator
        v.onImage = onImage
        // A UIKit text view does not read SwiftUI's fontDesign environment, so the app's rounded face is asked for
        // here explicitly: the reference's message box is rounded like everything else around it, and a draft typed
        // into a text view was the one place the app fell back to the plain system face.
        v.font = Self.roundedBody
        v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.isScrollEnabled = false
        v.returnKeyType = .send
        v.accessibilityIdentifier = "composer.field"
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Images from the clipboard are ours to handle; text keeps the system's own paste.
        v.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.image.identifier, UTType.text.identifier, UTType.plainText.identifier,
        ])
        return v
    }

    /// The field is as tall as the message, up to a cap; past the cap it scrolls inside itself. The height is a
    /// pure function of the text and the width SwiftUI proposes, so layout can never feed back into itself — the
    /// earlier version measured inside `updateUIView` with a width of zero on the first pass and pinned the bar at
    /// the cap.
    ///
    /// The measuring is done on a twin that never scrolls (the coordinator's), not on the displayed view: a
    /// scrolling text view's `sizeThatFits` answers with the scroll view's fit, so measuring on `v` meant writing
    /// `isScrollEnabled` twice per pass — and an over-cap draft toggled it false→true on every measurement, which
    /// invalidates the text view's layout inside the bottom safe-area inset each time (Codex R8 P2). The displayed
    /// view's scrolling mode is now written only when it changes.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: PasteTextView, context: Context) -> CGSize? {
        // A width-less pass (the first one in some hierarchies) must never be allowed to measure the text: at
        // width 0 every character is its own line and the field would be pinned at the cap. One line is the answer.
        guard let w = proposal.width, w > 0 else { return CGSize(width: proposal.width ?? 0, height: Self.minHeight) }
        let m = context.coordinator.measure
        if m.font != v.font { m.font = v.font }
        if m.textContainerInset != v.textContainerInset { m.textContainerInset = v.textContainerInset }
        if m.textContainer.lineFragmentPadding != v.textContainer.lineFragmentPadding { m.textContainer.lineFragmentPadding = v.textContainer.lineFragmentPadding }
        if m.text != v.text { m.text = v.text }
        let h = m.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        let scrolls = h > Self.maxHeight
        if v.isScrollEnabled != scrolls { v.isScrollEnabled = scrolls }
        return CGSize(width: w, height: min(max(h.rounded(.up), Self.minHeight), Self.maxHeight))
    }

    func updateUIView(_ v: PasteTextView, context: Context) {
        if v.text != text { v.text = text }
        v.onImage = onImage
        // The picker above sets `focused` after inserting a suggestion, which has to become real first-responder
        // state here; the delegate keeps the two in step the other way. Only a CHANGE of that intent moves the
        // responder — never a re-assertion of it.
        //
        // `updateUIView` is not a rare event: it runs on every SwiftUI update, and while an answer streams in that
        // is the ~25 passes a second the live answer redraws on (every chunk writes `streamError`, which the
        // composer's body reads). Asking the window again on each of those passes is free while it succeeds and a
        // trap when it cannot: with a dialog owning the responder the request was refused, so the next pass asked
        // again, and each refused request costs iOS an input-session teardown and rebuild. t15's spindump is this
        // line — 501 of 501 main-thread samples over five seconds, the same chain entered ~250 times — while the
        // app answered no accessibility query for 110 s and the smoke test failed on the dialog's own row.
        let want = focused
        if context.coordinator.appliedFocus != want {
            context.coordinator.appliedFocus = want
            if want, !v.isFirstResponder { v.becomeFirstResponder() }
            if !want, v.isFirstResponder { v.resignFirstResponder() }
        }
    }

    /// Two lines tall even when empty, so the field and not the row of buttons under it is most of the box — at one
    /// line the controls took half of it (operator, 2026-10-14) — and up to about eight lines before it scrolls.
    static let minHeight: CGFloat = 44
    static let maxHeight: CGFloat = 176

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focused: $focused, onSend: onSend) }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>
        private let focused: Binding<Bool>
        private let onSend: () -> Void

        /// The focus this field has already been told about, so `updateUIView` moves the responder on a change of
        /// intent only. `nil` until the first pass, which is what makes a freshly made view ask once even when the
        /// intent is already `true` (a rebuilt view is not the first responder the old one was).
        var appliedFocus: Bool?

        /// The field's twin, for measuring: it never scrolls, so `sizeThatFits` answers with the text's own height
        /// — and the DISPLAYED view is not written to on every layout pass (Codex R8 P2).
        let measure: PasteTextView = {
            let v = PasteTextView(usingTextLayoutManager: false)
            v.isScrollEnabled = false
            v.backgroundColor = .clear
            v.textContainerInset = .zero
            v.textContainer.lineFragmentPadding = 0
            return v
        }()

        init(text: Binding<String>, focused: Binding<Bool>, onSend: @escaping () -> Void) {
            self.text = text
            self.focused = focused
            self.onSend = onSend
        }

        func textViewDidChange(_ v: UITextView) { text.wrappedValue = v.text }
        func textViewDidBeginEditing(_ v: UITextView) { if !focused.wrappedValue { focused.wrappedValue = true } }
        func textViewDidEndEditing(_ v: UITextView) { if focused.wrappedValue { focused.wrappedValue = false } }

        /// The return key sends, the way Messages does, instead of adding a line.
        func textView(_ v: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            // Not while an input method is still composing (Chinese, Japanese): that Return confirms the word, and
            // sending then went out with the unfinished text (Codex r156).
            if replacement == "\n" && v.markedTextRange == nil { onSend(); return false }
            return true
        }
    }
}

/// A text view that turns a pasted image into an attachment and leaves text to the system.
final class PasteTextView: UITextView {
    var onImage: ((UIImage) -> Void)?

    /// Every request this view makes to hold the responder, counted through `Trace` (Simulator/Debug only, nothing
    /// in a shipping build). A request that FAILS is invisible from outside the view — the field simply is not the
    /// first responder — which is how one was made twenty-five times a second for a minute and a half without
    /// anything on screen saying so (see `MessageFieldFocusTests`).
    override func becomeFirstResponder() -> Bool {
        Trace.count("field.focus")
        return super.becomeFirstResponder()
    }

    /// The edit menu's Paste runs through this, not through `paste(itemProviders:)` — overriding the latter left
    /// the operator's screenshot pasting as nothing at all. The read is the user's own tap, so iOS does not ask.
    override func paste(_ sender: Any?) {
        if let img = UIPasteboard.general.image {
            onImage?(img)
        } else {
            super.paste(sender)
        }
    }

    /// A text view offers Paste only when the clipboard holds text, so a screenshot on the clipboard left the
    /// operator with no Paste to tap at all. `hasImages` is a check, not a read: it shows no permission prompt.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }
}
