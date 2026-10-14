import Foundation
import CoreGraphics

/// A display with a camera housing gets the notch shape; one without gets a
/// pill with a floating card.
enum NotchStyle: Equatable { case notch, floating }

enum NotchMetrics {
    static let expandedWidth: CGFloat = 560

    /// The expanded panel's vertical rhythm below the notch row, which carries
    /// the tabs and buttons. `NotchView.details` lays itself out from exactly
    /// these values and `detailsHeight` is their sum, so the drawn panel and
    /// the hover rectangle cannot drift apart.
    static let panelPadding: CGFloat = 22
    static let detailsTopPadding: CGFloat = 14
    static let sectionGap: CGFloat = 14
    static let footerHeight: CGFloat = 20
    static let cardHeight: CGFloat = 184
    /// The Usage tab's details without pace, the baseline most checks use.
    static var detailsHeight: CGFloat { detailsHeight(list: false, pace: false) }

    /// Horizontal rhythm inside the panel: the gutter between the two provider
    /// tiles, their own padding, and their corner radius.
    static let cardGap: CGFloat = 16
    static let cardPadding: CGFloat = 14
    static let cardRadius: CGFloat = 18

    /// The pace line needs one more row inside each card, sized for the two
    /// lines its verdict is allowed to wrap to. It is additive and applied only
    /// when pace is switched on, so the default geometry, and the hover
    /// behaviour that depends on it, are unchanged for everyone else.
    static let paceExtraHeight: CGFloat = 34

    /// The shell's concave top corner eats this much of each outer edge, so no
    /// compact content may sit inside it. `NotchShape.topRadius` uses the same
    /// value: they have to agree or the flare clips a logo.
    static let flareInset: CGFloat = 10
    /// Breathing room between the notch's edge and the nearest logo or value.
    static let compactInnerGap: CGFloat = 4
    /// One wing: the flare, the widest content that wing can hold, and the gap.
    /// A logo (21) and a six-point space before a value as wide as "100%" (28).
    static let compactWing: CGFloat = flareInset + 55 + compactInnerGap
    /// The same, for a wing that carries the provider's own window label
    /// instead of a logo: "Session" (35), the space, and the value.
    static let compactCaptionWing: CGFloat = flareInset + 69 + compactInnerGap
    /// Room around the drawn shape inside the fixed window, so the SwiftUI
    /// shadow is never clipped. The window hangs from the top edge, so there
    /// is no margin above the shape.
    static let shadowMargin: CGFloat = 24
    /// Corner radii of the open shape. The collapsed shape keeps
    /// `NotchShape`'s defaults.
    static let openFlare: CGFloat = 16
    static let openBottomRadius: CGFloat = 24
    /// How far the collapsed strip grows while the pointer rests on it.
    static let peekHeight: CGFloat = 3
    /// How much wider the collapsed strip gets while it bounces for a new wait.
    static let bounceWidth: CGFloat = 16
    /// The floating style for screens without a notch.
    static let floatingGap: CGFloat = 6
    static let floatingRadius: CGFloat = 20
    static let floatingHeaderHeight: CGFloat = 32
    static let pillPadding: CGFloat = 12
    static let pillSpacing: CGFloat = 12

    /// The pill holds both wings' content side by side, without the camera
    /// gap or the flare.
    static func pillWidth(wing: CGFloat) -> CGFloat {
        2 * (wing - flareInset - compactInnerGap) + pillSpacing + 2 * pillPadding
    }

    /// The menu bar's height, or a standard 24 points when it hides itself.
    static func pillHeight(menuBar: CGFloat) -> CGFloat { menuBar > 0 ? menuBar : 24 }

    /// The list tabs (Pull Requests, Sessions, Projects) share one taller slot.
    /// Measured on 24 September 2026: a pull request row is 37 points and a
    /// session or project row 22 to 23, so 120 points more than the usage
    /// cards shows about three more of the tallest rows.
    static let listHeight: CGFloat = cardHeight + 120
    /// One tab's slot. Pace adds a row to the usage cards only.
    static func slotHeight(list: Bool, pace: Bool) -> CGFloat {
        list ? listHeight : cardHeight(pace: pace)
    }
    static func detailsHeight(list: Bool, pace: Bool) -> CGFloat {
        detailsHeight(slot: slotHeight(list: list, pace: pace))
    }
    static func detailsHeight(slot: CGFloat) -> CGFloat {
        detailsTopPadding + slot + sectionGap + footerHeight + panelPadding
    }
    /// The Projects tile while it shows a notch terminal.
    static let terminalHeight: CGFloat = 560
    /// Room kept between the open panel and the bottom of a short screen.
    static let terminalScreenMargin: CGFloat = 80
    /// The terminal slot on a screen `screenHeight` tall, with `above` points
    /// of notch, or pill, gap and card header, above the details: 560,
    /// lowered so the panel ends at least 80 points above the screen's
    /// bottom, and never shorter than the list tabs.
    static func terminalSlot(screenHeight: CGFloat, above: CGFloat) -> CGFloat {
        let room = screenHeight - above - detailsHeight(slot: 0) - terminalScreenMargin
        return max(listHeight, min(terminalHeight, room))
    }
    /// The slot the panel shows and the tallest slot in use, which sizes the
    /// canvas. `terminal` is the terminal slot while at least one notch
    /// session exists and nil otherwise; the Projects tile shows it only
    /// while `showingTerminal`.
    static func slots(tabs: [CGFloat], shown: CGFloat, terminal: CGFloat?,
                      showingTerminal: Bool) -> (shown: CGFloat, tallest: CGFloat) {
        let current = showingTerminal ? (terminal ?? shown) : shown
        return (current, (tabs + [current] + (terminal.map { [$0] } ?? [])).max() ?? current)
    }
    static func cardHeight(pace: Bool) -> CGFloat { cardHeight + (pace ? paceExtraHeight : 0) }
    /// Both wings are always the same width, otherwise the transparent gap
    /// stops lining up with the camera housing.
    static func compactWing(caption: Bool) -> CGFloat { caption ? compactCaptionWing : compactWing }
    /// The collapsed strip: the notch plus two matching wings. The view and
    /// `NotchGeometry` both use this, so the drawn strip and the hover
    /// rectangle cannot drift apart.
    static func compactWidth(notchWidth: CGFloat, caption: Bool) -> CGFloat {
        notchWidth + 2 * compactWing(caption: caption)
    }
}

/// Logical screen-space bounds, independent of the window's animated frame and
/// SwiftUI tracking areas. The top edge is inclusive, including the camera notch.
struct NotchGeometry {
    let compact: CGRect
    let expanded: CGRect
    /// The panel's fixed frame: the expanded rectangle plus room for its
    /// shadow at the sides and below. It never animates; the shape drawn
    /// inside it does.
    let canvas: CGRect
    /// The floating style's card below the pill; nil for the notch style.
    let card: CGRect?

    /// `details` is the shown tab's height below the notch row;
    /// `tallestDetails` is the tallest enabled tab's, which sizes the canvas
    /// so a tab switch never moves the window. For `.floating`, `notchHeight`
    /// is the pill's height and `notchWidth` is ignored.
    init(screen: CGRect, notchWidth: CGFloat, notchHeight: CGFloat,
         details: CGFloat = NotchMetrics.detailsHeight, tallestDetails: CGFloat? = nil,
         wingWidth: CGFloat = NotchMetrics.compactWing, style: NotchStyle = .notch) {
        let tallest = max(details, tallestDetails ?? details)
        let margin = NotchMetrics.shadowMargin
        let width = NotchMetrics.expandedWidth
        switch style {
        case .notch:
            let compactWidth = notchWidth + 2 * wingWidth
            compact = CGRect(x: screen.midX - compactWidth / 2, y: screen.maxY - notchHeight,
                             width: compactWidth, height: notchHeight)
            expanded = CGRect(x: screen.midX - width / 2, y: screen.maxY - notchHeight - details,
                              width: width, height: notchHeight + details)
            card = nil
            canvas = CGRect(x: expanded.minX - margin, y: screen.maxY - notchHeight - tallest - margin,
                            width: width + 2 * margin, height: notchHeight + tallest + margin)
        case .floating:
            let pill = NotchMetrics.pillWidth(wing: wingWidth)
            let above = notchHeight + NotchMetrics.floatingGap
            let cardHeight = NotchMetrics.floatingHeaderHeight + details
            let tallestCard = NotchMetrics.floatingHeaderHeight + tallest
            compact = CGRect(x: screen.midX - pill / 2, y: screen.maxY - notchHeight, width: pill, height: notchHeight)
            let cardRect = CGRect(x: screen.midX - width / 2, y: screen.maxY - above - cardHeight,
                                  width: width, height: cardHeight)
            card = cardRect
            expanded = CGRect(x: cardRect.minX, y: cardRect.minY, width: width, height: above + cardHeight)
            canvas = CGRect(x: expanded.minX - margin, y: screen.maxY - above - tallestCard - margin,
                            width: width + 2 * margin, height: above + tallestCard + margin)
        }
    }

    func contains(_ point: CGPoint, expanded isExpanded: Bool) -> Bool {
        // A small exit margin tolerates hand jitter at the expanded panel edges.
        // Keep the compact activation area exact so nearby menu items don't open it.
        let bounds = isExpanded ? expanded.insetBy(dx: -6, dy: -6) : compact
        return Self.inside(point, bounds)
    }

    /// Whether the panel takes a click at `point`: only over the shape
    /// currently drawn, top edge included, with no jitter margin. Anywhere
    /// else in the canvas the click belongs to whatever is underneath.
    func accepts(_ point: CGPoint, expanded isExpanded: Bool, peeking: Bool = false, bouncing: Bool = false) -> Bool {
        if isExpanded {
            guard let card else { return Self.inside(point, expanded) }
            // The card, and the pill with the gap under it, but not the menu
            // bar beside the pill.
            let stem = CGRect(x: compact.minX, y: card.maxY, width: compact.width, height: expanded.maxY - card.maxY)
            return Self.inside(point, card) || Self.inside(point, stem)
        }
        let grow = peeking ? NotchMetrics.peekHeight : 0
        let widen = bouncing ? NotchMetrics.bounceWidth / 2 : 0
        return Self.inside(point, CGRect(x: compact.minX - widen, y: compact.minY - grow,
                                         width: compact.width + 2 * widen, height: compact.height + grow))
    }

    /// Inclusive on every edge, so the display's top edge counts.
    private static func inside(_ point: CGPoint, _ bounds: CGRect) -> Bool {
        point.x >= bounds.minX && point.x <= bounds.maxX
            && point.y >= bounds.minY && point.y <= bounds.maxY
    }
}

/// Returns a requested state change only after the pointer truly leaves the
/// stable region. Animation events cannot arm or reset the exit delay.
struct NotchHoverState {
    private var outsideSince: TimeInterval?
    private var insideSince: TimeInterval?
    /// Set by a terminal summon: the panel stays closed until the pointer has
    /// been outside the collapsed strip once. `reset()` leaves it alone, since
    /// the hover poll resets on every menu dismissal.
    private var closedUntilLeft = false
    let exitDelay: TimeInterval = 0.18

    mutating func reset() { outsideSince = nil; insideSince = nil }

    mutating func closeUntilPointerLeaves() {
        closedUntilLeft = true
        reset()
    }

    /// A click on the strip opens the panel whatever a summon asked.
    mutating func clearCloseUntilPointerLeaves() { closedUntilLeft = false }

    /// `holdUntil` keeps an alert-opened panel up for a deadline instead of
    /// pinning it, so no user setting is written. It sits after the visibility
    /// guard, so a hidden panel still never reopens, and it resets the exit
    /// timer exactly as the pinned branch does. `composing` holds the panel
    /// the same way while a Projects prompt is being written. `openDelay` is
    /// how long the pointer must rest on the collapsed strip before hover
    /// opens it; nil means hover never opens it (a click still does). After a
    /// terminal summon, `closeUntilPointerLeaves` keeps the panel closed, after
    /// the same three branches, until the pointer leaves the collapsed strip.
    mutating func update(pointer: CGPoint, geometry: NotchGeometry,
                         expanded: Bool, pinned: Bool, visible: Bool,
                         now: TimeInterval, holdUntil: TimeInterval? = nil, composing: Bool = false,
                         openDelay: TimeInterval? = 0) -> Bool? {
        guard visible else { reset(); return nil }
        if pinned { reset(); return expanded ? nil : true }
        if let holdUntil, now < holdUntil { reset(); return expanded ? nil : true }
        if composing { reset(); return expanded ? nil : true }
        if closedUntilLeft {
            guard !geometry.contains(pointer, expanded: false) else { reset(); return expanded ? false : nil }
            closedUntilLeft = false
        }
        if geometry.contains(pointer, expanded: expanded) {
            outsideSince = nil
            guard !expanded else { insideSince = nil; return nil }
            guard let openDelay else { return nil }
            let since = insideSince ?? now
            guard now - since >= openDelay else { insideSince = since; return nil }
            insideSince = nil
            return true
        }
        insideSince = nil
        guard expanded else { reset(); return nil }
        guard let since = outsideSince else {
            outsideSince = now
            return nil
        }
        guard now - since >= exitDelay else { return nil }
        reset()
        return false
    }
}

/// How often the hover poll runs. Near the notch, or while anything is open,
/// held or pending, it runs at 30 Hz exactly as before; with the pointer far
/// away, where no hover decision can change, it runs at 10 Hz and saves two
/// wakeups in three. The margin is wide enough that a quick pointer crossing
/// it is caught at 30 Hz before it reaches the strip.
enum HoverPolling {
    static let fast: TimeInterval = 1.0 / 30.0
    static let slow: TimeInterval = 1.0 / 10.0
    static let margin: CGFloat = 320

    /// `busy` is anything that makes the next poll matter wherever the
    /// pointer is: an open or pinned panel, a hold, composing, a bounce.
    static func interval(pointer: CGPoint, canvas: CGRect, visible: Bool, busy: Bool) -> TimeInterval {
        guard visible else { return slow }
        if busy { return fast }
        return canvas.insetBy(dx: -margin, dy: -margin).contains(pointer) ? fast : slow
    }
}
