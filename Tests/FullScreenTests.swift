import Foundation
import CoreGraphics

@main
struct FullScreenTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        // Top-left global coordinates, as CGDisplayBounds and the window list use.
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let other = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let safeTop: CGFloat = 32
        let own: Int32 = 99
        // A full-screen Space still lists its menu bar (probed on 24 September 2026).
        let menuBar = WindowRecord(bounds: CGRect(x: 0, y: 0, width: 1512, height: 33), layer: FullScreenRule.menuBarLayer,
                                   ownerPID: 1, ownerName: FullScreenRule.menuBarOwner)
        let otherMenuBar = WindowRecord(bounds: CGRect(x: 1512, y: 0, width: 1920, height: 25),
                                        layer: FullScreenRule.menuBarLayer, ownerPID: 1,
                                        ownerName: FullScreenRule.menuBarOwner)
        let dock = WindowRecord(bounds: display, layer: FullScreenRule.dockLayer, ownerPID: 2,
                                ownerName: FullScreenRule.dockOwner)
        let otherDock = WindowRecord(bounds: other, layer: FullScreenRule.dockLayer, ownerPID: 2,
                                     ownerName: FullScreenRule.dockOwner)
        let belowMenuBar = WindowRecord(bounds: CGRect(x: 0, y: 33, width: 1512, height: 949), layer: 0,
                                        ownerPID: 10, ownerName: "Safari")
        let wholeDisplay = WindowRecord(bounds: display, layer: 0, ownerPID: 11, ownerName: "Game")
        let otherWhole = WindowRecord(bounds: other, layer: 0, ownerPID: 12, ownerName: "Keynote")
        func covers(_ windows: [WindowRecord], _ screen: CGRect = display) -> Bool {
            FullScreenRule.covers(windows: windows, display: screen, safeTop: safeTop, ownPID: own)
        }

        check(!covers([menuBar, dock, belowMenuBar]), "A zoomed window with the Dock's window present is not full screen")
        check(covers([menuBar, belowMenuBar]), "A native full-screen window below the menu bar, Dock gone, is full screen")
        check(covers([menuBar, wholeDisplay]), "A window over the whole display, Dock gone, is full screen")
        check(covers([menuBar, otherDock, belowMenuBar]), "Another display's Dock does not count for this one")
        check(!covers([menuBar, dock, otherMenuBar, otherWhole]), "Full screen on the other display leaves this one alone")
        check(covers([menuBar, dock, otherMenuBar, otherWhole], other),
              "The same window is full screen for its own display")
        check(!covers([menuBar, WindowRecord(bounds: CGRect(x: 0, y: 33, width: 1400, height: 949), layer: 0,
                                             ownerPID: 10, ownerName: "Safari")]), "A narrower window is not full screen")
        check(!covers([menuBar, WindowRecord(bounds: CGRect(x: 0, y: 60, width: 1512, height: 922), layer: 0,
                                             ownerPID: 10, ownerName: "Safari")]),
              "A window starting below the menu bar's bottom edge is not full screen")
        check(!covers([menuBar, WindowRecord(bounds: CGRect(x: 0, y: 33, width: 1512, height: 900), layer: 0,
                                             ownerPID: 10, ownerName: "Safari")]),
              "A window stopping above the display's bottom is not full screen")
        check(FullScreenRule.covers(windows: [otherMenuBar, WindowRecord(bounds: CGRect(x: 1512, y: 25, width: 1920,
                                                                                        height: 1055),
                                                                         layer: 0, ownerPID: 12, ownerName: "Keynote")],
                                    display: other, safeTop: 0, ownPID: own),
              "Without a notch and with the menu bar kept in full screen, a window from the menu bar down counts")
        check(covers([WindowRecord(bounds: CGRect(x: 0, y: 32, width: 1512, height: 950), layer: 0,
                                   ownerPID: 10, ownerName: "Safari")]),
              "With no menu bar listed, a window from the camera safe area down is full screen")
        check(!covers([menuBar, WindowRecord(bounds: display, layer: 0, ownerPID: own, ownerName: "Nocci")]),
              "Nocci's own window never counts")
        check(!covers([menuBar, WindowRecord(bounds: display, layer: 3, ownerPID: 13, ownerName: "Floating")]),
              "Only ordinary windows count")
        check(!covers([]), "An empty list is not full screen")
        print("\(checks) full-screen checks passed")
    }
}
