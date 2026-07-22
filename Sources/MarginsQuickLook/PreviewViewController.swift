import AppKit
import QuickLookUI

// View-based Quick Look preview: a scrollable NSTextView showing the file
// rendered by the shared Margins parser (MarkdownRenderer) into one themed
// NSAttributedString. View-based (not data-based) is what lets the preview
// inherit the panel's light/dark appearance and paint a themed background —
// a data-based QLPreviewReply exposes no appearance or background hook.
//
// The principal class is resolved by NSExtension as "<module>.<Class>"; the
// build stamps -module-name MarginsQuickLook.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    override func loadView() {
        scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder

        // Canonical scrollable NSTextView setup: the text view must be
        // vertically resizable with an unbounded maxSize and a width-tracking
        // container, or it never grows past its initial frame and renders blank.
        let contentSize = scrollView.contentSize
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 28, height: 24)
        // Match the app: no smart substitutions on read-only content.
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        self.view = scrollView
    }

    // View-based providers implement one of preparePreviewOfFile / searchable.
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        // effectiveAppearance is the QL panel's, so light/dark follows the host.
        let theme = QLTheme.forAppearance(view.effectiveAppearance)
        textView.backgroundColor = theme.bg
        scrollView.backgroundColor = theme.bg
        textView.textStorage?.setAttributedString(PreviewRenderer.render(fileURL: url, theme: theme))
        handler(nil)
    }
}
