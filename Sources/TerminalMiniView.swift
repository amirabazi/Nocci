import AppKit

enum TerminalMetrics {
    static let defaultSize = NSSize(width: 800, height: 520)
    static let minimumSize = NSSize(width: 480, height: 300)
    /// Room left of the tab strip for the traffic lights.
    static let stripLeading: CGFloat = 80
    static let stripHeight: CGFloat = 28
    static let frameName = "NocciTerminal"
    /// The mini view's fixed height and font. It shows as
    /// many whole rows as fit inside the padding.
    static let miniHeight: CGFloat = 120
    static let miniFontSize: CGFloat = 10
    static let miniPadding: CGFloat = 6
}

/// The bottom of one session's screen, drawn from SwiftTerm's buffer at a
/// small size, left-aligned and clipped at the right, with the keys typed
/// into it forwarded to that session. It never resizes the
/// session: two SwiftTerm views cannot share one session, so this reads the
/// buffer instead of hosting a second terminal view. Main thread only.
final class TerminalMiniView: NSView {
    private let session: TerminalSession
    private let font = NSFont.monospacedSystemFont(ofSize: TerminalMetrics.miniFontSize, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: TerminalMetrics.miniFontSize, weight: .bold)
    private var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }
    private var rowCount: Int { max(1, Int((bounds.height - 2 * TerminalMetrics.miniPadding) / lineHeight)) }

    init(session: TerminalSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: TerminalMetrics.miniHeight))
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal for \(session.label)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    /// The newest mini view of a session takes its redraws. The handler holds
    /// the view weakly, so one that is gone simply stops drawing, and a view
    /// leaving can never cancel the one that replaced it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        session.onScreenChange = { [weak self] in self?.needsDisplay = true }
        window.makeFirstResponder(self)
        needsDisplay = true
    }

    /// Every key, Escape and arrows included, goes to the session: the user's
    /// keystrokes and nothing else.
    override func keyDown(with event: NSEvent) {
        session.forward(event)
    }

    /// Command-V while answering. It is the user's own paste, sent by the
    /// session's view exactly as the window sends one.
    @objc func paste(_ sender: Any?) {
        session.paste()
    }

    override func accessibilityValue() -> Any? { session.screenText(last: rowCount) }

    /// Each cell at its own grid column; anything past the right edge is
    /// clipped, since the session keeps the window's width.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        let left = TerminalMetrics.miniPadding
        var y = TerminalMetrics.miniPadding
        for row in session.screenRows(last: rowCount) {
            for cell in row.cells {
                let x = left + CGFloat(cell.column) * advance
                guard x < bounds.maxX else { break }
                if let background = cell.background {
                    background.setFill()
                    NSRect(x: x, y: y, width: CGFloat(cell.width) * advance, height: lineHeight).fill()
                }
                guard cell.character != " " else { continue }
                var attributes: [NSAttributedString.Key: Any] = [.font: cell.bold ? boldFont : font,
                                                                 .foregroundColor: cell.foreground]
                if cell.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                (cell.character as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            }
            if let column = row.cursor {
                NSColor(white: 0.9, alpha: 0.55).setFill()
                NSRect(x: left + CGFloat(column) * advance, y: y, width: advance, height: lineHeight).fill()
            }
            y += lineHeight
        }
    }
}

/// Holds a notch session's own view. It takes the view only once it has a size, since a zero frame would squeeze
/// the session to one column; the newest container, by claim, takes it from an older one; and it never takes it
/// from anything but another container, so the window keeps it after Open in window.
final class TerminalContainer: NSView {
    private static var claims = 0
    private var claim = 0

    var session: NSView? {
        didSet {
            if let oldValue, oldValue !== session, oldValue.superview === self { oldValue.removeFromSuperview() }
            if session != nil {
                Self.claims += 1
                claim = Self.claims
            }
            attach()
        }
    }
    /// Set while the terminal has the keyboard.
    var focus = false {
        didSet { attach() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        attach()
    }

    override func layout() {
        super.layout()
        attach()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        attach()
    }

    private func attach() {
        guard let session, bounds.width > 0, bounds.height > 0 else { return }
        if session.superview !== self {
            let canTake = session.superview == nil || ((session.superview as? TerminalContainer).map { $0.claim < claim } ?? false)
            if canTake {
                addSubview(session)
            }
        }
        guard session.superview === self else { return }
        if session.frame != bounds { session.frame = bounds }
        if focus, let window, window.firstResponder !== session { window.makeFirstResponder(session) }
    }
}
