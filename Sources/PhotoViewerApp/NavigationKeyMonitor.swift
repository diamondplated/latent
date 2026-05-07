import SwiftUI
import AppKit

/// Window-level NSEvent monitor that swallows arrow keys and routes them to
/// `AppState` selection methods regardless of which control has focus.
///
/// Why this exists: SwiftUI's `.onKeyPress` only fires when the receiving
/// view (or one of its descendants) has keyboard focus. As soon as the user
/// clicks a slider in the enhancement panel, focus moves there and arrow
/// keys start dragging the slider instead of navigating photos. Confusing.
///
/// `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` runs before any
/// view in the window sees the event, so we always get first crack at
/// arrow keys. We return `nil` to swallow the event, the original event
/// for any other key (so typing in TextFields still works).
@MainActor
final class NavigationKeyMonitor {
    private var monitor: Any?
    /// Timestamp of the most recent Escape press. Used to detect a double-
    /// tap (two Escapes within `escapeDoubleTapWindow`) which closes the
    /// album. A single Escape does nothing — staying out of the way of
    /// SwiftUI's default Escape handling for sheets / cancel buttons.
    private var lastEscape: Date?
    private let escapeDoubleTapWindow: TimeInterval = 0.45

    func install(state: AppState) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak state] event in
            guard let self, let state else { return event }
            return self.handle(event: event, state: state)
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Returns nil to swallow the event, original event to let it propagate.
    private func handle(event: NSEvent, state: AppState) -> NSEvent? {
        // Don't fight TextFields / TextEditors for arrow keys. If the first
        // responder is a text view, let arrows work as cursor movement.
        if let responder = event.window?.firstResponder,
           responder is NSText || responder.isKind(of: NSTextView.self) {
            return event
        }

        // Modifier-laden arrow keys (cmd-left for window-back, etc.) are not
        // ours to claim.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .isDisjoint(with: [.command, .control, .option]) == false {
            return event
        }

        switch event.keyCode {
        case 123, 126: // left, up
            state.selectPrevious()
            return nil
        case 124, 125, 49: // right, down, space — all advance
            state.selectNext()
            return nil
        case 53: // escape
            return handleEscape(state: state, event: event)
        default:
            return event
        }
    }

    /// Two Escapes within ~450ms close the album. Single Escape passes
    /// through so existing dialog/sheet/cancel behavior keeps working.
    private func handleEscape(state: AppState, event: NSEvent) -> NSEvent? {
        guard state.folder != nil else { return event }
        let now = Date()
        if let last = lastEscape, now.timeIntervalSince(last) < escapeDoubleTapWindow {
            state.closeFolder()
            lastEscape = nil
            return nil  // swallow the second Esc
        }
        lastEscape = now
        return event  // let the first Esc propagate
    }
}
