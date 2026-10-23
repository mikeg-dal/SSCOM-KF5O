import AppKit
import SwiftUI

/// Text view for the receive window. It is read-only, but keystrokes typed into it are
/// sent to the device (SSCOM's "terminal emulation"), and pasting sends the clipboard.
final class TerminalTextView: NSTextView {
    var onKey: ((NSEvent) -> Void)?
    var onPaste: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Leave Command shortcuts (copy, select all, find...) to AppKit.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
        } else {
            onKey?(event)
        }
    }

    override func paste(_ sender: Any?) {
        if let s = NSPasteboard.general.string(forType: .string) { onPaste?(s) }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(paste(_:)) ? onPaste != nil : super.validateUserInterfaceItem(item)
    }
}

struct ReceiveView: NSViewRepresentable {
    let session: Session

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TerminalTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        // scrollableTextView() makes a plain NSTextView; swap in our subclass with the same setup.
        let term = TerminalTextView(frame: tv.frame, textContainer: tv.textContainer)
        term.autoresizingMask = tv.autoresizingMask
        term.minSize = tv.minSize
        term.maxSize = tv.maxSize
        term.isVerticallyResizable = true
        term.isHorizontallyResizable = false
        term.isEditable = false
        term.isSelectable = true
        term.isRichText = false
        term.usesFindBar = true
        term.isIncrementalSearchingEnabled = true
        term.allowsUndo = false
        term.isAutomaticQuoteSubstitutionEnabled = false
        term.isAutomaticDashSubstitutionEnabled = false
        term.isAutomaticSpellingCorrectionEnabled = false
        term.textContainerInset = NSSize(width: 4, height: 4)
        term.layoutManager?.allowsNonContiguousLayout = true
        term.setAccessibilityLabel(String(localized: "Received data"))
        term.setAccessibilityIdentifier("receive.log")
        term.onKey = { [weak session] e in session?.terminalKey(e) }
        term.onPaste = { [weak session] s in session?.terminalPaste(s) }
        scroll.documentView = term
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        session.display.textView = term
        session.rerender()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
