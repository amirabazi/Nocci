import Foundation
import CoreGraphics

/// One on-screen window, as the public window list reports it. Titles are
/// never read, so listing needs no Screen Recording permission.
struct WindowRecord: Equatable {
    /// Global display coordinates with the origin at the top left, as
    /// `CGDisplayBounds` uses.
    var bounds: CGRect
    var layer: Int
    var ownerPID: Int32
    var ownerName: String

    /// The windows on screen now. Desktop elements stay in the list: leaving
    /// them out also drops the Dock's window, which the rule depends on.
    static func onScreen() -> [WindowRecord] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int else { return nil }
            return WindowRecord(bounds: bounds, layer: layer, ownerPID: Int32(pid),
                                ownerName: info[kCGWindowOwnerName as String] as? String ?? "")
        }
    }
}

/// Whether a full-screen app owns a display, decided from public window
/// data only. macOS offers no public call for a Space's type.
enum FullScreenRule {
    /// `CGWindowLevelForKey(.mainMenuWindow)`.
    static let menuBarLayer = 24
    /// The owner the window list reports for the menu bar (probed on 24 September 2026).
    static let menuBarOwner = "Window Server"
    /// `CGWindowLevelForKey(.dockWindow)`.
    static let dockLayer = 20
    static let dockOwner = "Dock"

    /// True when an ordinary window spans the display's full width from its
    /// bottom up to the menu bar's bottom edge or higher, and the Dock has no
    /// window over that display. A full-screen Space still lists its menu bar
    /// but not the Dock, while a zoomed window on an ordinary desktop keeps
    /// both. Without a listed menu bar, the camera safe area is the limit.
    static func covers(windows: [WindowRecord], display: CGRect, safeTop: CGFloat, ownPID: Int32) -> Bool {
        let tolerance: CGFloat = 1
        let dockShown = windows.contains { window in
            window.layer == dockLayer && window.ownerName == dockOwner && window.bounds.intersects(display)
        }
        guard !dockShown else { return false }
        let menuBarBottom = windows
            .filter { window in
                window.layer == menuBarLayer && window.ownerName == menuBarOwner
                    && window.bounds.minY <= display.minY + tolerance && window.bounds.intersects(display)
            }
            .map(\.bounds.maxY).max()
        let top = menuBarBottom ?? display.minY + safeTop
        return windows.contains { window in
            window.layer == 0 && window.ownerPID != ownPID
                && window.bounds.minX <= display.minX + tolerance
                && window.bounds.maxX >= display.maxX - tolerance
                && window.bounds.maxY >= display.maxY - tolerance
                && window.bounds.minY <= top + tolerance
        }
    }
}
