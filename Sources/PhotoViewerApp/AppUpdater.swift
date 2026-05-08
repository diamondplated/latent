import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater {
    private static let placeholderPublicKey = "SPARKLE_PUBLIC_ED_KEY_NOT_CONFIGURED"

    private let controller: SPUStandardUpdaterController?

    init() {
        guard Self.hasConfiguredFeed, Self.hasConfiguredPublicKey else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var isConfigured: Bool {
        controller != nil
    }

    var updater: SPUUpdater? {
        controller?.updater
    }

    func checkForUpdates() {
        guard let controller else {
            NSApp.presentError(UpdateConfigurationError())
            return
        }
        controller.checkForUpdates(nil)
    }

    private static var hasConfiguredFeed: Bool {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "https"
    }

    private static var hasConfiguredPublicKey: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }
        return !key.isEmpty && key != placeholderPublicKey
    }
}

private struct UpdateConfigurationError: LocalizedError {
    var errorDescription: String? {
        "Updates are not configured in this build."
    }

    var recoverySuggestion: String? {
        "Build Latent with SPARKLE_PUBLIC_ED_KEY set, then publish a signed appcast from GitHub Releases."
    }
}

struct UpdaterSettingsView: View {
    private let updater: SPUUpdater?

    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool

    init(updater: SPUUpdater?) {
        self.updater = updater
        self.automaticallyChecksForUpdates = updater?.automaticallyChecksForUpdates ?? false
        self.automaticallyDownloadsUpdates = updater?.automaticallyDownloadsUpdates ?? false
    }

    var body: some View {
        Form {
            Section("Updates") {
                if let updater {
                    Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                        .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                            updater.automaticallyChecksForUpdates = newValue
                        }

                    Toggle("Automatically download updates", isOn: $automaticallyDownloadsUpdates)
                        .disabled(!automaticallyChecksForUpdates)
                        .onChange(of: automaticallyDownloadsUpdates) { _, newValue in
                            updater.automaticallyDownloadsUpdates = newValue
                        }
                } else {
                    Text("Updates are disabled in this build.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
