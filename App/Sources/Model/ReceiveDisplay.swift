import AppKit

/// Owns the receive window's text view and batches text appends.
///
/// Incoming data can arrive thousands of times a second; appending to the text
/// storage that often would stall the UI, so text is buffered and flushed at
/// most every 50 ms (SSCOM itself refreshed its window on a 100 ms timer).
@Observable
final class ReceiveDisplay {
    @ObservationIgnored weak var textView: NSTextView? {
        didSet { applyStyle() }
    }
    @ObservationIgnored private var pending = ""
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    @ObservationIgnored var textColor = NSColor.textColor
    @ObservationIgnored var backgroundColor = NSColor.textBackgroundColor
    /// Characters currently shown, for the status bar.
    private(set) var characterCount = 0

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        pending += text
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            flush()
        }
    }

    /// Replaces the whole contents (after a mode change or trim).
    func replace(with text: String) {
        pending = ""
        guard let tv = textView, let storage = tv.textStorage else { return }
        storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        characterCount = storage.length
        tv.scrollToEndOfDocument(nil)
    }

    func clear() { replace(with: "") }

    var text: String { textView?.string ?? "" }

    func flush() {
        flushScheduled = false
        guard !pending.isEmpty, let tv = textView, let storage = tv.textStorage else { return }
        // Only follow new output when the user is already looking at the bottom.
        let atBottom: Bool = {
            guard let scroll = tv.enclosingScrollView else { return true }
            let visible = scroll.contentView.bounds
            return visible.maxY >= tv.bounds.height - 40
        }()
        storage.beginEditing()
        storage.append(NSAttributedString(string: pending, attributes: attributes))
        storage.endEditing()
        pending = ""
        characterCount = storage.length
        if atBottom { tv.scrollToEndOfDocument(nil) }
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: textColor]
    }

    func applyStyle() {
        guard let tv = textView else { return }
        tv.font = font
        tv.textColor = textColor
        tv.backgroundColor = backgroundColor
        tv.insertionPointColor = textColor
        if let storage = tv.textStorage {
            storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
    }
}
