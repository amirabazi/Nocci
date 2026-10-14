import Foundation
import CoreGraphics

@main
struct HoverTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 180, notchHeight: 32)
        // Park the pointer at the physical top edge, just below it, both corners,
        // and the compact bottom edge for 10s each. Exactly one expansion, no closes.
        let points = [CGPoint(x: 756, y: 982), CGPoint(x: 756, y: 981),
                      CGPoint(x: geometry.compact.minX, y: 982),
                      CGPoint(x: geometry.compact.maxX, y: 982),
                      CGPoint(x: 756, y: geometry.compact.minY)]
        for point in points {
            var state = NotchHoverState(), expanded = false
            var transitions = [Bool]()
            for frame in 0..<600 {
                if let next = state.update(pointer: point, geometry: geometry, expanded: expanded,
                                           pinned: false, visible: true, now: Double(frame) / 60) {
                    expanded = next; transitions.append(next)
                }
            }
            check(transitions == [true], "Stationary pointer must never oscillate: \(point)")
        }
        var state = NotchHoverState()
        let inside = CGPoint(x: 756, y: 981)
        let card = CGPoint(x: geometry.expanded.minX + 20, y: geometry.expanded.minY + 30)
        let outside = CGPoint(x: 0, y: 0)
        func update(_ point: CGPoint, _ time: Double, expanded: Bool = true, pinned: Bool = false, visible: Bool = true) -> Bool? {
            state.update(pointer: point, geometry: geometry, expanded: expanded, pinned: pinned, visible: visible, now: time)
        }
        check(update(card, 0) == nil, "Moving from compact region to cards keeps open")
        check(update(outside, 1) == nil, "Leaving arms delay")
        check(update(outside, 1.17) == nil, "Do not close early")
        check(update(inside, 1.18) == nil, "Re-entry cancels pending close")
        check(update(outside, 2) == nil, "Second exit starts a fresh delay")
        check(update(outside, 2.19) == false, "Real exit closes after delay")
        check(update(outside, 3, expanded: false) == nil, "Remain closed outside")
        check(update(card, 4, expanded: false) == nil, "Hidden card area must not trigger expansion")
        check(update(inside, 5, expanded: false) == true, "Re-entry opens again")
        check(update(outside, 6, pinned: true) == nil, "Pinned popup stays open")
        check(update(inside, 7, expanded: false, visible: false) == nil, "Hidden app must not open")
        check(update(CGPoint(x: geometry.expanded.maxX + 3, y: 960), 8) == nil, "Edge jitter stays open")
        let otherScreen = NotchGeometry(screen: CGRect(x: -1512, y: 982, width: 1512, height: 982), notchWidth: 180, notchHeight: 32)
        check(otherScreen.contains(CGPoint(x: -756, y: 1964), expanded: false), "Secondary display uses global coordinates")
        check(!otherScreen.contains(inside, expanded: false), "Other display's top edge must not trigger")
        // MARK: Notification hold
        //
        // A notification click expands the panel with a deadline instead of
        // pinning it, so no user setting is written. The hold sits after the
        // visibility guard, so it can never reopen a hidden panel.
        var held = NotchHoverState()
        func hold(_ point: CGPoint, _ time: TimeInterval, until: TimeInterval?,
                  expanded: Bool = true, visible: Bool = true) -> Bool? {
            held.update(pointer: point, geometry: geometry, expanded: expanded, pinned: false,
                        visible: visible, now: time, holdUntil: until)
        }
        check(hold(outside, 0, until: 8, expanded: false) == true, "A hold opens the panel with the pointer away")
        check(hold(outside, 4, until: 8) == nil, "A hold keeps the panel open with the pointer away")
        check(hold(outside, 7.99, until: 8) == nil, "The hold lasts until its deadline")
        check(hold(outside, 8, until: 8) == nil, "The lapsed hold arms the ordinary exit delay rather than closing at once")
        check(hold(outside, 8.17, until: 8) == nil, "The lapsed hold still respects the exit delay")
        check(hold(outside, 8.19, until: 8) == false, "The panel closes once the hold has lapsed and the delay has passed")

        var visited = NotchHoverState()
        func visit(_ point: CGPoint, _ time: TimeInterval, until: TimeInterval?) -> Bool? {
            visited.update(pointer: point, geometry: geometry, expanded: true, pinned: false,
                           visible: true, now: time, holdUntil: until)
        }
        check(visit(card, 1, until: 8) == nil, "Entering during a hold keeps the panel open")
        check(visit(outside, 9, until: 8) == nil, "Leaving after the hold lapsed arms the delay")
        check(visit(outside, 9.19, until: 8) == false, "Normal hover resumes once the hold has lapsed")

        var hidden = NotchHoverState()
        check(hidden.update(pointer: outside, geometry: geometry, expanded: false, pinned: false,
                            visible: false, now: 0, holdUntil: 8) == nil,
              "A hold must not reopen a hidden panel")

        var absent = NotchHoverState()
        check(absent.update(pointer: outside, geometry: geometry, expanded: true, pinned: false,
                            visible: true, now: 0, holdUntil: nil) == nil,
              "No hold behaves exactly as before")

        // MARK: Composing a prompt
        //
        // While the Projects compose view is open the panel stays up however
        // far the pointer wanders, exactly like the notification hold: after
        // the visibility guard, resetting the exit timer rather than bypassing it.
        var composing = NotchHoverState()
        func compose(_ point: CGPoint, _ time: TimeInterval, on: Bool) -> Bool? {
            composing.update(pointer: point, geometry: geometry, expanded: true, pinned: false,
                             visible: true, now: time, composing: on)
        }
        check(compose(outside, 0, on: true) == nil, "Composing keeps the panel open with the pointer away")
        check(compose(outside, 5, on: true) == nil, "Composing keeps it open however long the pointer stays away")
        check(compose(outside, 5.01, on: false) == nil, "Ending compose arms the ordinary exit delay rather than closing at once")
        check(compose(outside, 5.18, on: false) == nil, "The exit delay still applies after composing")
        check(compose(outside, 5.20, on: false) == false, "The panel closes once the delay has passed")

        var hiddenCompose = NotchHoverState()
        check(hiddenCompose.update(pointer: outside, geometry: geometry, expanded: false, pinned: false,
                                   visible: false, now: 0, composing: true) == nil,
              "Composing never reopens a hidden panel")

        var armed = NotchHoverState()
        check(armed.update(pointer: outside, geometry: geometry, expanded: true, pinned: false, visible: true, now: 0) == nil,
              "Leaving arms the delay")
        check(armed.update(pointer: outside, geometry: geometry, expanded: true, pinned: false, visible: true,
                           now: 0.17, composing: true) == nil, "Starting to compose cancels a pending close")
        check(armed.update(pointer: outside, geometry: geometry, expanded: true, pinned: false, visible: true,
                           now: 0.30, composing: false) == nil,
              "After composing the delay starts afresh instead of carrying the old one")

        var plain = NotchHoverState()
        check(plain.update(pointer: outside, geometry: geometry, expanded: true, pinned: false, visible: true,
                           now: 0, composing: false) == nil
              && plain.update(pointer: outside, geometry: geometry, expanded: true, pinned: false, visible: true,
                              now: 0.19, composing: false) == false,
              "Not composing behaves exactly as before")

        // MARK: Pace adds height without changing anything else
        let base = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 180, notchHeight: 32)
        let taller = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 180, notchHeight: 32,
                                   details: NotchMetrics.detailsHeight(list: false, pace: true))
        check(base.expanded == NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                             notchWidth: 180, notchHeight: 32, details: NotchMetrics.detailsHeight).expanded,
              "No extra height leaves the geometry exactly as it was")
        check(base.compact == taller.compact, "Extra height never changes the compact strip")
        check(taller.expanded.height == base.expanded.height + NotchMetrics.paceExtraHeight,
              "Extra height grows the expanded panel by exactly that much")
        check(taller.expanded.maxY == base.expanded.maxY,
              "The panel still hangs from the same top edge")
        let belowBase = CGPoint(x: 756, y: base.expanded.minY - 10)
        check(!base.contains(belowBase, expanded: true) && taller.contains(belowBase, expanded: true),
              "A point under the old panel is inside the taller one")

        // MARK: The compact strip is exactly the display's own notch
        //
        // Notch height differs between Mac models, so it is always read from
        // the screen at layout time. The strip must match it exactly: a taller
        // strip hangs a visible black chin below the physical notch.
        for notch in [CGFloat(32), 37, 26, 41.5] {
            let fitted = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                       notchWidth: 180, notchHeight: notch)
            check(fitted.compact.height == notch, "Compact strip matches a \(notch) point notch exactly")
            check(fitted.compact.maxY == 982, "Compact strip still hangs from the screen top edge")
            check(fitted.expanded.height == notch + NotchMetrics.detailsHeight,
                  "Expanded panel is the notch plus the details, with no chin")
        }

        // MARK: Wings are sized by what they carry
        //
        // Both wings always match, or the transparent gap stops lining up with
        // the camera housing. A single visible provider puts a window label in
        // the right wing, which needs more room than a logo.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let logos = NotchGeometry(screen: screen, notchWidth: 180, notchHeight: 33,
                                  wingWidth: NotchMetrics.compactWing(caption: false))
        let labels = NotchGeometry(screen: screen, notchWidth: 180, notchHeight: 33,
                                   wingWidth: NotchMetrics.compactWing(caption: true))
        check(logos.compact.width == 180 + 2 * NotchMetrics.compactWing,
              "A wing holds the flare, a logo and a value, on both sides")
        check(labels.compact.width > logos.compact.width,
              "A window label needs more room than a logo")
        for geometry in [logos, labels] {
            check(geometry.compact.midX == screen.midX, "The notch gap stays centred on the display")
            check(geometry.compact.width - 180 == 2 * ((geometry.compact.width - 180) / 2),
                  "Both wings are the same width")
        }
        check(NotchMetrics.compactWing > NotchMetrics.flareInset + NotchMetrics.compactInnerGap,
              "A wing leaves room for content between the flare and the notch")

        // MARK: The fixed canvas and click-through
        //
        // The panel's window stays at one frame; only the shape inside it
        // animates. The canvas must hold the open panel and its shadow, and
        // the window must take clicks only over the shape actually drawn.
        let fixed = NotchGeometry(screen: screen, notchWidth: 180, notchHeight: 33)
        check(fixed.canvas.maxY == screen.maxY, "The canvas hangs from the top edge")
        check(fixed.canvas.midX == screen.midX, "The canvas is centred on the notch")
        check(fixed.canvas.contains(fixed.expanded) && fixed.canvas.contains(fixed.compact),
              "The canvas holds the collapsed strip and the open panel")
        check(fixed.canvas.width == NotchMetrics.expandedWidth + 2 * NotchMetrics.shadowMargin
              && fixed.canvas.minY == fixed.expanded.minY - NotchMetrics.shadowMargin,
              "The canvas leaves room for the shadow beside and below the open panel")
        let paced = NotchGeometry(screen: screen, notchWidth: 180, notchHeight: 33,
                                  details: NotchMetrics.detailsHeight(list: false, pace: true))
        check(paced.canvas.height == fixed.canvas.height + NotchMetrics.paceExtraHeight,
              "A taller panel gets a taller canvas")
        check(NotchMetrics.compactWidth(notchWidth: 180, caption: false) == fixed.compact.width
              && NotchMetrics.compactWidth(notchWidth: 180, caption: true)
                == NotchGeometry(screen: screen, notchWidth: 180, notchHeight: 33,
                                 wingWidth: NotchMetrics.compactWing(caption: true)).compact.width,
              "The view and the geometry agree on the collapsed width")

        let topEdge = CGPoint(x: screen.midX, y: screen.maxY)
        check(fixed.accepts(topEdge, expanded: false), "The top edge over the camera takes clicks")
        check(!fixed.accepts(CGPoint(x: fixed.compact.minX - 1, y: screen.maxY - 5), expanded: false),
              "Beside the collapsed strip, clicks reach the menu bar")
        check(!fixed.accepts(CGPoint(x: screen.midX, y: fixed.compact.minY - 1), expanded: false),
              "Below the collapsed strip, clicks reach the window underneath")
        let openCard = CGPoint(x: fixed.expanded.minX + 20, y: fixed.expanded.minY + 30)
        check(!fixed.accepts(openCard, expanded: false) && fixed.accepts(openCard, expanded: true),
              "The panel's area takes clicks only while it is open")
        let margin = CGPoint(x: fixed.expanded.maxX + 3, y: fixed.expanded.midY)
        check(fixed.contains(margin, expanded: true) && !fixed.accepts(margin, expanded: true),
              "The hover margin keeps the panel open without taking clicks beside it")
        check(!fixed.accepts(CGPoint(x: fixed.canvas.minX + 2, y: fixed.canvas.minY + 2), expanded: true),
              "The shadow margin never takes clicks")

        // A secondary display sits at non-zero global coordinates.
        let secondScreen = CGRect(x: -1512, y: 982, width: 1512, height: 982)
        let second = NotchGeometry(screen: secondScreen, notchWidth: 180, notchHeight: 33)
        check(second.canvas.maxY == secondScreen.maxY && second.canvas.midX == secondScreen.midX,
              "The canvas follows a secondary display's global coordinates")
        check(second.accepts(CGPoint(x: secondScreen.midX, y: secondScreen.maxY), expanded: false)
              && !second.accepts(topEdge, expanded: false),
              "Click-through is decided in global coordinates, per display")

        // MARK: The header lives in the notch row
        check(NotchMetrics.detailsHeight == NotchMetrics.detailsTopPadding + NotchMetrics.cardHeight
                + NotchMetrics.sectionGap + NotchMetrics.footerHeight + NotchMetrics.panelPadding,
              "The details are the top gap, the cards, the footer and the bottom margin, with no header row")

        // MARK: Each tab has its own fixed height
        //
        // Width never changes between tabs: the tab icons sit left of the
        // camera, so any width change would move them from under the pointer.
        let tallest = NotchMetrics.detailsHeight(list: true, pace: false)
        let usageTab = NotchGeometry(screen: screen, notchWidth: 180, notchHeight: 33,
                                     details: NotchMetrics.detailsHeight(list: false, pace: false),
                                     tallestDetails: tallest)
        let listTab = NotchGeometry(screen: screen, notchWidth: 180, notchHeight: 33,
                                    details: tallest, tallestDetails: tallest)
        check(listTab.expanded.height > usageTab.expanded.height, "List tabs are taller than the usage cards")
        check(listTab.expanded.width == usageTab.expanded.width && listTab.expanded.midX == usageTab.expanded.midX,
              "Width never changes between tabs")
        check(usageTab.canvas == listTab.canvas, "The window does not change when the tab does")
        check(usageTab.compact == listTab.compact, "The collapsed strip does not change with the tab")
        let tabIcon = CGPoint(x: usageTab.expanded.minX + NotchMetrics.panelPadding + 16, y: screen.maxY - 16)
        check(usageTab.contains(tabIcon, expanded: true) && listTab.contains(tabIcon, expanded: true),
              "The tab icons are inside every tab's panel, so switching never starts the close delay")
        check(NotchMetrics.slotHeight(list: true, pace: true) == NotchMetrics.slotHeight(list: true, pace: false),
              "Pace adds height to the usage cards only")
        check(NotchMetrics.slotHeight(list: false, pace: true) == NotchMetrics.cardHeight + NotchMetrics.paceExtraHeight,
              "Pace still adds its row to the usage cards")
        check(NotchMetrics.listHeight >= NotchMetrics.cardHeight(pace: true),
              "A list tab is never shorter than the usage cards with pace")
        check(NotchGeometry(screen: screen, notchWidth: 180, notchHeight: 33).canvas
                == NotchGeometry(screen: screen, notchWidth: 180, notchHeight: 33,
                                 details: NotchMetrics.detailsHeight, tallestDetails: nil).canvas,
              "Without a taller tab the canvas fits the shown one")

        // MARK: The notch terminal's slot
        //
        // Taller only while the Projects tile shows a notch terminal; the
        // width never changes.
        check(NotchMetrics.detailsHeight(slot: NotchMetrics.listHeight) == NotchMetrics.detailsHeight(list: true, pace: false),
              "A slot's details add the same gaps and footer as a tab's")
        check(NotchMetrics.terminalSlot(screenHeight: 982, above: 38) == 560,
              "A 14-inch MacBook Pro at its default size gets the full slot")
        check(NotchMetrics.terminalSlot(screenHeight: 956, above: 38) == 560, "So does a 13-inch MacBook Air")
        let shortRoom = 720 - 62 - NotchMetrics.detailsHeight(slot: 0) - 80
        check(NotchMetrics.terminalSlot(screenHeight: 720, above: 62) == shortRoom && shortRoom < 560,
              "A short screen lowers the slot so the panel ends 80 points above its bottom")
        check(NotchMetrics.terminalSlot(screenHeight: 400, above: 62) == NotchMetrics.listHeight,
              "The slot is never shorter than the list tabs")
        let listSlot = NotchMetrics.listHeight, usageSlot = NotchMetrics.cardHeight
        let noSession = NotchMetrics.slots(tabs: [usageSlot, listSlot], shown: listSlot, terminal: nil, showingTerminal: false)
        check(noSession.shown == listSlot && noSession.tallest == listSlot, "Without a notch session nothing changes")
        let elsewhere = NotchMetrics.slots(tabs: [usageSlot, listSlot], shown: usageSlot, terminal: 560, showingTerminal: false)
        check(elsewhere.shown == usageSlot && elsewhere.tallest == 560,
              "While a notch session exists the canvas fits the terminal whatever the tab")
        let showingSlot = NotchMetrics.slots(tabs: [usageSlot, listSlot], shown: listSlot, terminal: 560, showingTerminal: true)
        check(showingSlot.shown == 560 && showingSlot.tallest == 560, "The Projects tile shows the terminal slot")
        check(NotchMetrics.slots(tabs: [usageSlot], shown: usageSlot, terminal: nil, showingTerminal: true).shown == usageSlot,
              "Without a session there is no terminal slot to show")
        let terminalPanel = NotchGeometry(screen: screen, notchWidth: 180, notchHeight: 33,
                                          details: NotchMetrics.detailsHeight(slot: 560),
                                          tallestDetails: NotchMetrics.detailsHeight(slot: 560))
        let listPanel = NotchGeometry(screen: screen, notchWidth: 180, notchHeight: 33,
                                      details: NotchMetrics.detailsHeight(list: true, pace: false),
                                      tallestDetails: NotchMetrics.detailsHeight(slot: 560))
        check(terminalPanel.expanded.width == listPanel.expanded.width && terminalPanel.expanded.midX == listPanel.expanded.midX
              && terminalPanel.canvas == listPanel.canvas
              && terminalPanel.expanded.height == listPanel.expanded.height + 560 - NotchMetrics.listHeight,
              "Showing the terminal grows the panel downwards only, inside the same window")
        let iconPoint = CGPoint(x: listPanel.expanded.minX + NotchMetrics.panelPadding + 16, y: screen.maxY - 16)
        check(terminalPanel.contains(iconPoint, expanded: true) && terminalPanel.accepts(iconPoint, expanded: true),
              "The tab icons stay under the pointer while the terminal is shown")
        let floatingTerminal = NotchGeometry(screen: screen, notchWidth: 0, notchHeight: 24,
                                             details: NotchMetrics.detailsHeight(slot: 560), style: .floating)
        check(floatingTerminal.card?.height == NotchMetrics.floatingHeaderHeight + NotchMetrics.detailsHeight(slot: 560),
              "A screen without a notch shows the same slot in its card")

        // MARK: Opening after a pause
        //
        // Hover opens only once the pointer has rested on the strip for the
        // delay. Leaving resets it. Without a delay (click only) hover never
        // opens the panel. Pinned, hold and composing still open at once.
        var paused = NotchHoverState(), pausedOpen = false, openedAt = -1.0
        var pausedTransitions = [Bool]()
        for frame in 0..<600 {
            let time = Double(frame) / 60
            if let next = paused.update(pointer: inside, geometry: geometry, expanded: pausedOpen, pinned: false,
                                        visible: true, now: time, openDelay: 0.3) {
                pausedOpen = next; pausedTransitions.append(next)
                if next { openedAt = time }
            }
        }
        check(pausedTransitions == [true], "A resting pointer opens once after the pause and never oscillates")
        check(openedAt >= 0.3 && openedAt < 0.32, "It opens when the pause has passed, not before")

        var brief = NotchHoverState()
        func briefly(_ point: CGPoint, _ time: TimeInterval) -> Bool? {
            brief.update(pointer: point, geometry: geometry, expanded: false, pinned: false, visible: true,
                         now: time, openDelay: 0.3)
        }
        check(briefly(inside, 0) == nil, "Entering starts the pause")
        check(briefly(outside, 0.2) == nil, "Leaving before the pause ends does not open")
        check(briefly(inside, 0.25) == nil, "Coming back starts the pause again")
        check(briefly(inside, 0.5) == nil, "The pause counts from the return, not the first entry")
        check(briefly(inside, 0.56) == true, "It opens once the pause has passed since the return")

        var clickOnly = NotchHoverState(), hoverOpened = false
        for frame in 0..<600 {
            if clickOnly.update(pointer: inside, geometry: geometry, expanded: false, pinned: false,
                                visible: true, now: Double(frame) / 60, openDelay: nil) == true {
                hoverOpened = true
            }
        }
        check(!hoverOpened, "Click only never opens from hover")
        var clicked = NotchHoverState()
        check(clicked.update(pointer: inside, geometry: geometry, expanded: true, pinned: false, visible: true,
                             now: 0, openDelay: nil) == nil,
              "A panel opened by a click stays open while the pointer is inside")
        check(clicked.update(pointer: outside, geometry: geometry, expanded: true, pinned: false, visible: true,
                             now: 1, openDelay: nil) == nil
              && clicked.update(pointer: outside, geometry: geometry, expanded: true, pinned: false, visible: true,
                                now: 1.19, openDelay: nil) == false,
              "It closes after the usual delay once the pointer leaves")

        var pinnedPause = NotchHoverState(), heldPause = NotchHoverState(), hiddenPause = NotchHoverState()
        check(pinnedPause.update(pointer: outside, geometry: geometry, expanded: false, pinned: true, visible: true,
                                 now: 0, openDelay: nil) == true, "Pinning still opens at once")
        check(heldPause.update(pointer: outside, geometry: geometry, expanded: false, pinned: false, visible: true,
                               now: 0, holdUntil: 8, openDelay: 0.3) == true, "A notification hold still opens at once")
        check(hiddenPause.update(pointer: inside, geometry: geometry, expanded: false, pinned: false, visible: false,
                                 now: 0, openDelay: 0) == nil, "A hidden panel never opens")

        // MARK: Peek
        //
        // While the pointer rests on the collapsed strip it grows a few points.
        // The chin takes clicks only while it is drawn; the hover rectangle
        // never grows, so menu items beside the notch stay unaffected.
        let chin = CGPoint(x: screen.midX, y: fixed.compact.minY - 2)
        check(!fixed.accepts(chin, expanded: false) && fixed.accepts(chin, expanded: false, peeking: true),
              "The peek chin takes clicks only while peeking")
        check(!fixed.contains(chin, expanded: false), "Peeking never grows the hover rectangle")
        check(!fixed.accepts(CGPoint(x: screen.midX, y: fixed.compact.minY - NotchMetrics.peekHeight - 1),
                             expanded: false, peeking: true), "Below the chin, clicks pass through")

        // MARK: Bounce
        let beside = CGPoint(x: fixed.compact.maxX + NotchMetrics.bounceWidth / 2 - 1, y: screen.maxY - 5)
        check(!fixed.accepts(beside, expanded: false) && fixed.accepts(beside, expanded: false, bouncing: true),
              "The bounce takes clicks only while it is drawn")
        check(!fixed.contains(beside, expanded: false), "A bounce never grows the hover rectangle")

        // MARK: Screens without a notch
        //
        // A pill hangs from the top centre; the open card floats below it.
        // The open hover rectangle has no hole between them, and the menu bar
        // beside the pill keeps its clicks.
        check(NotchMetrics.pillHeight(menuBar: 24) == 24 && NotchMetrics.pillHeight(menuBar: 0) == 24
              && NotchMetrics.pillHeight(menuBar: 30) == 30, "A hiding menu bar still gives the pill a height")
        let pillHeight = NotchMetrics.pillHeight(menuBar: 24)
        let floating = NotchGeometry(screen: screen, notchWidth: 0, notchHeight: pillHeight,
                                     details: NotchMetrics.detailsHeight, style: .floating)
        check(floating.compact.width == NotchMetrics.pillWidth(wing: NotchMetrics.compactWing)
              && floating.compact.height == pillHeight && floating.compact.maxY == screen.maxY
              && floating.compact.midX == screen.midX, "The pill hangs from the top centre")
        let floatingCard = floating.card!
        check(floatingCard.width == NotchMetrics.expandedWidth
              && floatingCard.maxY == screen.maxY - pillHeight - NotchMetrics.floatingGap
              && floatingCard.height == NotchMetrics.floatingHeaderHeight + NotchMetrics.detailsHeight,
              "The card floats a small gap below the pill")
        check(floating.expanded.maxY == screen.maxY && floating.expanded.minY == floatingCard.minY,
              "The open hover rectangle runs from the top edge to the card's bottom")
        let gap = CGPoint(x: screen.midX, y: screen.maxY - pillHeight - NotchMetrics.floatingGap / 2)
        check(floating.contains(gap, expanded: true) && floating.accepts(gap, expanded: true),
              "No hole between the pill and the card")
        let menuItem = CGPoint(x: screen.midX + 200, y: screen.maxY - 5)
        check(floating.contains(menuItem, expanded: true) && !floating.accepts(menuItem, expanded: true),
              "Beside the pill the panel stays open but the menu bar keeps its clicks")
        check(floating.canvas.contains(floating.expanded) && floating.canvas.maxY == screen.maxY,
              "The floating canvas holds the pill and the card")
        check(NotchGeometry(screen: screen, notchWidth: 180, notchHeight: 33).card == nil,
              "The notch style has no separate card")

        // MARK: Closed until the pointer leaves (a terminal summon)
        var summoned = NotchHoverState()
        func summonHover(_ point: CGPoint, _ time: Double, expanded: Bool, pinned: Bool = false, visible: Bool = true,
                         holdUntil: Double? = nil, composing: Bool = false) -> Bool? {
            summoned.update(pointer: point, geometry: geometry, expanded: expanded, pinned: pinned, visible: visible,
                            now: time, holdUntil: holdUntil, composing: composing, openDelay: 0.3)
        }
        let strip = CGPoint(x: 756, y: 981)
        summoned.closeUntilPointerLeaves()
        check(summonHover(strip, 0, expanded: true) == false, "A summon closes an open panel under the pointer at once")
        check((1...300).allSatisfy { summonHover(strip, Double($0) / 30, expanded: false) == nil },
              "Resting on the strip afterwards never opens it")
        summoned.reset()
        check(summonHover(strip, 10.1, expanded: false) == nil, "Menu tracking's reset does not end a summon's hold")
        check(summonHover(outside, 10.2, expanded: false) == nil, "Leaving the strip ends it")
        check(summonHover(strip, 10.3, expanded: false) == nil && summonHover(strip, 10.65, expanded: false) == true,
              "Afterwards the strip opens after the usual pause")
        summoned.closeUntilPointerLeaves()
        check(summonHover(strip, 11, expanded: true, pinned: true) == nil
              && summonHover(strip, 11.1, expanded: false, pinned: true) == true, "A pinned panel stays open")
        check(summonHover(strip, 11.2, expanded: true, holdUntil: 20) == nil, "A notification's hold wins")
        check(summonHover(strip, 11.3, expanded: true, composing: true) == nil, "Composing wins")
        check(summonHover(strip, 11.4, expanded: false, visible: false) == nil, "A hidden panel never opens")
        check(summonHover(strip, 11.5, expanded: true) == false, "Without them a summon still closes the panel")
        summoned.clearCloseUntilPointerLeaves()
        check(summonHover(strip, 12, expanded: true) == nil, "After a click the open panel stays open under the pointer")
        check(summonHover(outside, 12.5, expanded: true) == nil, "Leaving after a click arms the ordinary delay")
        summoned.closeUntilPointerLeaves()
        check(summonHover(outside, 13, expanded: true) == nil, "A summon restarts the exit delay rather than bypassing it")
        check(summonHover(outside, 13.17, expanded: true) == nil && summonHover(outside, 13.2, expanded: true) == false,
              "Outside the strip the hold ends and the ordinary 180 ms applies")

        // MARK: Adaptive polling
        //
        // Far from the notch the poll slows down; near it, or while anything
        // is open or held, it runs at 30 Hz as before.
        let canvas = geometry.canvas
        func rate(_ point: CGPoint, visible: Bool = true, busy: Bool = false) -> TimeInterval {
            HoverPolling.interval(pointer: point, canvas: canvas, visible: visible, busy: busy)
        }
        check(rate(inside) == HoverPolling.fast, "The strip itself is polled at full speed")
        check(rate(card) == HoverPolling.fast, "The panel's area is polled at full speed")
        check(rate(CGPoint(x: canvas.minX - 300, y: 982)) == HoverPolling.fast, "The menu bar beside the notch is near")
        check(rate(outside) == HoverPolling.slow, "A pointer far away is polled slowly")
        check(rate(outside, busy: true) == HoverPolling.fast, "An open, pinned, held or composing panel is polled at full speed anywhere")
        check(rate(inside, visible: false) == HoverPolling.slow && rate(inside, visible: false, busy: true) == HoverPolling.slow,
              "A hidden notch takes no hover decision, so it is polled slowly")
        check(rate(CGPoint(x: -756, y: 1964)) == HoverPolling.slow, "A pointer on another display is far away")
        check(HoverPolling.fast == 1.0 / 30.0 && HoverPolling.slow <= 0.1, "Full speed is unchanged and slow is at least 10 Hz")
        // A pointer flung at the strip from far away, at up to 4000 points a
        // second, from below and from both sides along the menu bar. The poll
        // runs at whatever rate the last sample chose, so it is late only if
        // the pointer crosses the margin and reaches the strip between two
        // slow samples.
        let target = CGPoint(x: 756, y: 981)
        for (start, speed) in [(CGPoint(x: 756, y: 0), 4000.0), (CGPoint(x: 0, y: 975), 4000.0),
                               (CGPoint(x: 1512, y: 975), 4000.0), (CGPoint(x: 100, y: 100), 3000.0)] {
            let distance = hypot(target.x - start.x, target.y - start.y)
            func position(_ time: Double) -> CGPoint {
                let travelled = min(1, CGFloat(time * speed) / distance)
                return CGPoint(x: start.x + (target.x - start.x) * travelled, y: start.y + (target.y - start.y) * travelled)
            }
            // When the strip is first entered, and the worst the slow poll's phase can do.
            var entry = 0.0
            while !geometry.contains(position(entry), expanded: false) { entry += 0.0005 }
            let late = stride(from: 0.0, to: HoverPolling.slow, by: HoverPolling.slow / 20).map { phase -> Double in
                var time = phase
                while !geometry.contains(position(time), expanded: false) { time += rate(position(time)) }
                return time - entry
            }.max()!
            check(late <= HoverPolling.fast + 0.001,
                  "A pointer flung from \(start) at \(Int(speed)) points a second is seen within one full-speed poll of entering the strip")
        }

        print("\(checks) hover regression checks passed")
    }
}
