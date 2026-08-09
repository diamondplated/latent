import SwiftUI
import PhotoServe

/// Pairing UI for the phone companion: turn it on, show the QR, approve or
/// deny the phone that scans it, revoke devices later.
///
/// The sheet only reads `PhoneAccessUI` and calls into the controller. It
/// never touches the server, the pairing manager, or `AppState` directly.
struct PairingSheet: View {
    let controller: PhoneAccessController
    let ui: PhoneAccessUI

    @Environment(\.dismiss) private var dismiss
    @State private var qr: NSImage?
    @State private var isStarting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Phone access")
                .font(.title2.weight(.semibold))

            if let pending = ui.pendingDevice {
                approvalPrompt(pending)
            }

            if ui.isEnabled {
                enabledBody
            } else {
                disabledBody
            }

            if let error = ui.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                if ui.isEnabled {
                    Button("Turn off") {
                        Task { await controller.disable() }
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        // Opening the sheet on an already-running server rotates the code, so
        // the QR on screen is always one that still works.
        .onAppear {
            guard ui.isEnabled, ui.pairingURL == nil else { return }
            turnOn()
        }
        .onChange(of: ui.pairingURL, initial: true) { _, url in
            qr = url.flatMap { QRRenderer.image(for: $0, size: 240) }
        }
        // A code dies after `codeLifetime`. Someone who opens the sheet, walks
        // to the couch and then scans would otherwise get a 401 on the phone
        // and nothing at all on the Mac. Rotate before it lapses; the task
        // dies with the sheet.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(PairingManager.codeLifetime - 15))
                // `pairingURL == nil` means the sheet is closing and the code
                // has been cleared — do not mint a fresh one behind it.
                guard !Task.isCancelled, ui.isEnabled, ui.pairingURL != nil else { return }
                turnOn()
            }
        }
    }

    // MARK: - Sections

    private var disabledBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use your phone to flip through the folder that's open here — pick, reject and label from the couch.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Latent serves the folder on your local network only, to phones you approve. Nothing is uploaded anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn on phone access") { turnOn() }
                .controlSize(.large)
                .disabled(isStarting)
        }
    }

    @ViewBuilder
    private var enabledBody: some View {
        if let url = ui.pairingURL {
            VStack(alignment: .leading, spacing: 12) {
                if let qr {
                    // Natural size is 240 pt over a 480 px bitmap — drawn 1:1
                    // on Retina. No `.resizable()`: rescaling is what softens
                    // the modules.
                    Image(nsImage: qr)
                        .frame(maxWidth: .infinity)
                }
                Text(url)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("Scan with your phone's camera. Anyone who scans still needs your approval.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if !ui.devices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Paired devices")
                    .font(.headline)
                ForEach(ui.devices) { device in
                    HStack {
                        Image(systemName: "iphone")
                            .foregroundStyle(.secondary)
                        Text(device.name)
                        Spacer()
                        Button("Revoke") {
                            Task { await controller.revoke(deviceID: device.id) }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func approvalPrompt(_ pending: PhoneAccessUI.PendingDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(pending.name) at \(pending.host) wants access")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Allow") {
                    Task { await controller.resolveApproval(true) }
                }
                .keyboardShortcut(.return)
                Button("Deny") {
                    Task { await controller.resolveApproval(false) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func turnOn() {
        isStarting = true
        Task {
            do {
                _ = try await controller.enable()
            } catch {
                await MainActor.run {
                    ui.lastError = error.localizedDescription
                }
            }
            isStarting = false
        }
    }
}
