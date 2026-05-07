import SwiftUI

struct ContentView: View {
    @State private var state = AppState()

    var body: some View {
        Group {
            if state.folder == nil {
                EmptyStateView { state.openFolder() }
            } else {
                BrowserView(state: state)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.openFolder()
                } label: {
                    Label("Open Folder…", systemImage: "folder")
                }
            }
        }
    }
}

struct EmptyStateView: View {
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Open a folder of photos to begin")
                .font(.title2)
            Text("Latent browses folders directly — no library import.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Folder…") { onOpen() }
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
                .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
