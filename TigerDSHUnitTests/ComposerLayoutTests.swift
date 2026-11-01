import XCTest
import SwiftUI
import UIKit
@testable import TigerDSH

/// The composer's controls at the widths the single row has to survive (Codex R11 P2).
///
/// The old row was one `HStack` whose model pill carried `.fixedSize(horizontal: true, …)`: the pill could not give
/// way, so a long model name, an effort label and three attachments pushed the send disc out of the box — and the
/// reader lost the one control the whole composer exists for. The pill shrinks inside its cap now, and `Composer`
/// hands the same controls to `ViewThatFits` twice, so when even that does not fit, the model and the pictures move
/// to a row of their own.
///
/// These tests render the controls at a real width and read the picture, because that is the honest way to ask "did
/// it fit": the send disc is the only solid ink on the right of the arrangement, so the ink's own bounding box is
/// its frame, and a control that overflows is either clipped at the edge or gone from the picture entirely.
@MainActor
final class ComposerLayoutTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        guard let path = ProcessInfo.processInfo.environment["DSH_UNIT_LOG"] else { return }
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
        setvbuf(stdout, nil, _IONBF, 0)
    }

    /// A chat whose model name and effort are deliberately long: the pill at its widest.
    private func longModelChat() -> ChatModel {
        let chat = ChatModel(id: "session-composer", app: nil)
        let model: JSON = .obj([
            ("short", .string("deepseek-v4.1-flash-extended-preview")),
            ("effort", .string("maximum reasoning effort")),
            ("label", .string("DeepSeek v4.1 Flash, maximum reasoning effort"))])
        chat.proj = ["model": model]
        return chat
    }

    /// Three attachments, so the row carries the pictures it has to make room for.
    private func threeAttachments() -> [Attachment] {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { ctx in
            UIColor.systemBlue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return (0..<3).map { Attachment(name: "shot\($0).png", mediaType: "image/png", data: png) }
    }

    /// The darkest pixels of the right half, as a box: the send disc (the stop square, at full opacity).
    private func discBox(width: CGFloat, attachments: [Attachment], stopMode: Bool = true) -> (CGRect, Int, CGSize) {
        let chat = longModelChat()
        let app = AppModel()
        let controls = ComposerControls(
            chat: chat, sheet: .constant(nil), attachments: .constant(attachments),
            mic: MicRecorder(), stopMode: stopMode, canSend: true,
            discInk: .white, discFill: .black, stopTaps: 0, app: app, hasSpeech: false,
            showPhotos: .constant(false), showFiles: .constant(false), showCamera: .constant(false),
            send: {}, savedRaw: .constant("[]"))
            .padding(4)
            .frame(width: width, alignment: .leading)
            .background(Color.white)
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: controls)
        renderer.scale = 2
        guard let cg = renderer.cgImage, let data = cg.dataProvider?.data as Data? else { return (.zero, 0, .zero) }
        let bpp = max(1, cg.bitsPerPixel / 8)
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<cg.height {
            for x in (cg.width / 2)..<cg.width {
                let i = (y * cg.width + x) * bpp
                if data[data.startIndex + i] < 70, data[data.startIndex + i + 1] < 70, data[data.startIndex + i + 2] < 70 {
                    xs.append(x); ys.append(y)
                }
            }
        }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return (.zero, 0, CGSize(width: cg.width, height: cg.height))
        }
        return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), xs.count,
                CGSize(width: cg.width, height: cg.height))
    }

    /// The photographed width, with the pill at its widest and three pictures beside it: the disc is still whole,
    /// still round, and still on the right of the box — which is what `.fixedSize` on the pill used to break.
    func testTheDiscSurvivesALongModelAndThreePictures() {
        let (box, px, size) = discBox(width: 402, attachments: threeAttachments())
        print("composer layout: 402 pt, long model + 3 pictures — disc \(box) of \(size), \(px) px")
        XCTAssertGreaterThan(px, 200, "the send disc was not drawn at 402 pt with a long model and three pictures")
        XCTAssertEqual(box.width, box.height, accuracy: 2, "the disc is not round: \(box)")
        XCTAssertGreaterThanOrEqual(box.width, 24, "the disc was squashed to \(box)")
        XCTAssertLessThanOrEqual(box.maxX, size.width, "the disc ran off the right edge: \(box)")
        XCTAssertGreaterThan(box.minX, size.width * 0.5, "the disc is not on the right of the box: \(box)")
    }

    /// The narrow case: 320 pt with the same long model and three pictures. Whatever arrangement is chosen, the
    /// disc stays whole and inside the box.
    func testTheDiscSurvivesANarrowBox() {
        let (box, px, size) = discBox(width: 320, attachments: threeAttachments())
        print("composer layout: 320 pt, long model + 3 pictures — disc \(box) of \(size), \(px) px")
        XCTAssertGreaterThan(px, 200, "the send disc was not drawn at 320 pt")
        XCTAssertEqual(box.width, box.height, accuracy: 2, "the disc is not round: \(box)")
        XCTAssertGreaterThanOrEqual(box.width, 24, "the disc was squashed to \(box)")
        XCTAssertLessThanOrEqual(box.maxX, size.width - 2, "the disc ran off the right edge: \(box)")
        XCTAssertGreaterThan(box.minX, size.width * 0.5, "the disc is not on the right of the box: \(box)")
    }

    /// And with nothing to send, the disc is the stop square at full opacity — the same control, the same place.
    func testTheStopDiscIsInTheSamePlaceAsTheSendDisc() {
        let (send, sendPx, _) = discBox(width: 402, attachments: [], stopMode: false)
        let (stop, stopPx, _) = discBox(width: 402, attachments: [], stopMode: true)
        print("composer layout: 402 pt — send disc \(send) (\(sendPx) px), stop disc \(stop) (\(stopPx) px)")
        XCTAssertGreaterThan(sendPx, 200, "the send disc was not drawn")
        XCTAssertGreaterThan(stopPx, 200, "the stop disc was not drawn")
        XCTAssertEqual(send.midX, stop.midX, accuracy: 1, "the disc moved when the chat started running")
        XCTAssertEqual(send.midY, stop.midY, accuracy: 1, "the disc moved when the chat started running")
    }

    // MARK: the queued card's pill

    /// One inbox item, in the shape the host sends it: a user-authored message waiting for the next turn.
    private func queued(_ text: String, _ id: String = "q1", kind: String = "user") -> JSON {
        .obj([
            ("id", .string(id)),
            ("content", .array([.obj([("type", .string("text")), ("text", .string(text))])])),
            ("source", .obj([("kind", .string(kind))]))])
    }

    private func queueChat(nextTurn: [JSON] = [], nextStep: [JSON] = []) -> ChatModel {
        let chat = ChatModel(id: "session-queue", app: nil)
        chat.proj = ["inbox": .obj([("next-turn", .array(nextTurn)), ("next-step", .array(nextStep))])]
        return chat
    }

    /// t12 reported "the queued card has no Send now pill" and the tree it printed held no card at all: the run had
    /// ended before the message was queued, so there was nothing to draw. The card and the pill were never the
    /// problem — but that claim should not rest on a run's timing, so the render condition is pinned here, on the
    /// two functions `QueueCards`' own body draws from.
    ///
    /// It is asserted at that level rather than by reading `queue.sendnow` off a hosted view because SwiftUI builds
    /// its accessibility nodes only when a client asks for them: the identifier is simply not on the hierarchy a
    /// unit test can walk (measured — the walk came back empty). The screen half stays in the UI smoke test, which
    /// is the client that asks.
    func testTheQueuedCardOffersSendNowOnlyWhileTheTurnIsRunning() {
        let live = QueueCards.cards(queueChat(nextTurn: [queued("queue this one")]))
        XCTAssertEqual(live.count, 1, "a user's queued next-turn message is not drawn")
        XCTAssertEqual(live.first?.kind, "next-turn")
        XCTAssertTrue(QueueCards.offersSendNow(live[0].kind, running: true),
                      "a queued next-turn message with the chat running has no Send now pill")
        XCTAssertFalse(QueueCards.offersSendNow(live[0].kind, running: false),
                       "the pill is offered while the run is not running")

        let stepped = QueueCards.cards(queueChat(nextStep: [queued("a later step")]))
        XCTAssertEqual(stepped.first?.kind, "next-step")
        XCTAssertFalse(QueueCards.offersSendNow(stepped[0].kind, running: true),
                       "a next-step card must not offer Send now")

        XCTAssertTrue(QueueCards.cards(queueChat(nextTurn: [queued("from the assistant", kind: "assistant")])).isEmpty,
                      "a message the assistant queued is not a queued card")
        XCTAssertTrue(QueueCards.cards(queueChat()).isEmpty, "an empty inbox draws no card")
    }
}
