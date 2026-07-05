import SwiftUI

/// Full-window keyboard shortcut cheat sheet, shown on `?` press.
/// Lists all vim-style keybindings organized by category. Dimmed
/// background + `.thinMaterial` card so it floats over the current view.
/// Any keypress or click dismisses it.
struct KeyboardShortcutOverlay: View {
    @Binding var isPresented: Bool

    private let sections: [(title: String, shortcuts: [(key: String, action: String)])] = [
        ("Navigation", [
            ("j / →", "Next photo"),
            ("k / ←", "Previous photo"),
            ("gg", "First photo"),
            ("G", "Last photo"),
            ("⌘↑", "Parent folder"),
        ]),
        ("Selection", [
            ("⌘ click", "Toggle multi-select"),
            ("⇧ click", "Range select"),
            ("⌘A", "Select all"),
            ("Esc", "Clear selection"),
            ("Esc Esc", "Close folder"),
        ]),
        ("Labels & Culling", [
            ("0–9", "Set color label (0 = clear)"),
            ("P", "Toggle pick"),
            ("X", "Toggle reject"),
        ]),
        ("Marks", [
            ("m + letter", "Set mark"),
            ("' + letter", "Jump to mark"),
        ]),
        ("Viewing", [
            ("B (hold)", "Blink original"),
            ("Double-click", "Zoom cycle (2× → 3× → 4× → fit)"),
            ("Pinch / scroll", "Zoom in/out"),
            ("Drag", "Pan"),
        ]),
        ("Actions", [
            ("⌫", "Move to Trash"),
            ("⌘Z", "Undo Trash"),
            ("⌘S", "Apply & Save (enhanced)"),
            ("⌘E", "Toggle enhancement panel"),
            ("⌘L", "Toggle folder tree"),
            ("⌘O", "Open folder"),
            ("?", "This cheat sheet"),
        ]),
    ]

    var body: some View {
        ZStack {
            // Dimmed background — click anywhere to dismiss.
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Two-column layout for the shortcut sections so the
                // overlay fits on a 13" screen without scrolling.
                let leftSections = Array(sections.prefix(3))
                let rightSections = Array(sections.suffix(from: 3))

                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(leftSections, id: \.title) { section in
                            shortcutSection(section)
                        }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(rightSections, id: \.title) { section in
                            shortcutSection(section)
                        }
                    }
                }

                Text("Press any key or click to dismiss")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(28)
            .frame(maxWidth: 640)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        }
        .onKeyPress(phases: .down) { _ in
            isPresented = false
            return .handled
        }
    }

    private func shortcutSection(_ section: (title: String, shortcuts: [(key: String, action: String)])) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(section.shortcuts, id: \.key) { shortcut in
                HStack(spacing: 12) {
                    Text(shortcut.key)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .frame(width: 100, alignment: .trailing)
                    Text(shortcut.action)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Spacer()
                }
            }
        }
    }
}
