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
    ///
    /// Strategy: only own the keys when a folder is actively loaded. In the
    /// empty-state / Recents view there's no photo to advance, so the keys
    /// belong to the system. This is the simplest gate that avoids the
    /// "inconsistent after Open" trap we kept hitting:
    ///   - Open dialog dismisses → firstResponder briefly points at the
    ///     dialog's field-editor (an NSTextView shared across windows).
    ///   - Earlier "bail when responder is NSText/NSTextView" matched this
    ///     and let the first arrow/space press through.
    ///   - Now we don't care about responder type at all once a folder is
    ///     loaded — the only thing arrow/space can mean in viewer mode is
    ///     "navigate".
    ///
    /// Modal panels (Open, Save) still bail unconditionally so the user can
    /// arrow-key around the sidebar.
    private func handle(event: NSEvent, state: AppState) -> NSEvent? {
        // Modal sheets / Open / Save dialogs keep their own keyboard semantics.
        if event.window is NSPanel { return event }

        // No folder loaded → not our keys to claim. The empty-state UI has
        // a Recents list whose tap targets are buttons (arrows don't move
        // through them anyway), but better not to mess with it.
        guard state.folder != nil else { return event }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let onlyCmd = (mods == .command)

        // Cmd-shortcuts we own. Handled BEFORE the general cmd-bail below
        // so SwiftUI's keyboardShortcut wiring doesn't have to fight the
        // window-level monitor for these particular keys.
        if onlyCmd {
            switch event.keyCode {
            case 6:  // ⌘Z — undo trash
                state.undoTrash()
                return nil
            case 0:  // ⌘A — select all photos
                state.selectAllPhotos()
                return nil
            default:
                break
            }
        }

        // Other modifier-laden keys (cmd-left for window-back, opt-arrows
        // for word-jump, etc.) are not ours to claim.
        if !mods.isDisjoint(with: [.command, .control, .option]) {
            return event
        }

        switch event.keyCode {
        case 123, 126: // left, up
            state.selectPrevious()
            return nil
        case 124, 125, 49: // right, down, space — all advance
            state.selectNext()
            return nil
        case 51, 117: // delete (backspace), forward delete — trash current
            // No-op if no photo is selected; we still swallow the event so
            // it doesn't trigger a "boop" system beep on an empty viewer.
            state.trashCurrentImage()
            return nil
        case 53: // escape
            // Multi-selection takes the first Esc. Falls through to the
            // existing double-tap close-folder logic when no multi is
            // active, so users who haven't built up a selection still
            // get the standard Esc behavior.
            if !state.multiSelection.isEmpty {
                state.clearMultiSelection()
                return nil
            }
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
