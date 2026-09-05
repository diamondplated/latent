import SwiftUI
import AppKit
import AVKit
import AVFoundation
import ImageIO

/// What kind of media a URL is, so DetailView knows whether to draw a
/// CGImage, animate an NSImageView, or hand it to AVPlayer.
enum MediaKind: Sendable, Equatable {
    case staticImage
    case animatedImage   // GIF, animated PNG, animated HEIC/AVIF/WebP
    case video
    case unsupported
}

enum MediaTyping {
    /// Static image extensions our pipeline already handles.
    static let staticImageExts: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
        "webp", "avif", "jxl", "bmp",
        // RAW formats ImageIO can preview via their embedded JPEG.
        "cr2", "cr3", "nef", "arw", "raf", "dng", "orf", "rw2",
    ]
    /// Containers commonly used for animated single-file content. We still
    /// inspect frame count via CGImageSource at runtime — a static .png
    /// stays in the static path even though .png is also in this list,
    /// because `detect()` falls through to `.staticImage` if frameCount == 1.
    static let possiblyAnimatedExts: Set<String> = [
        "gif", "png", "heic", "heif", "webp", "avif",
    ]
    /// Video container extensions whose UTIs AVFoundation reports as
    /// audiovisual types on macOS. Keep this explicit instead of accepting
    /// every `public.movie` subtype: AVPlayer does not provide a stock
    /// Matroska/WebM/FLV/WMV/Ogg demuxer, even when VideoToolbox can decode a
    /// codec carried by one of those containers.
    ///
    /// A recognized container can still contain an unsupported codec. In that
    /// case AVPlayer owns the playback failure and presents its normal error.
    static let videoExts: Set<String> = [
        "mp4", "mpg4", "mov", "qt", "m4v",
        "3gp", "3gpp", "sdv", "3g2", "3gp2",
        "avi", "vfw", "mts", "m2ts",
        "mpg", "mpeg", "mpe", "m75", "m15", "m2v", "ts",
        "dv", "dif",
    ]

    static var allMediaExts: Set<String> {
        staticImageExts.union(possiblyAnimatedExts).union(videoExts)
    }

    /// Classify a URL. Cheap (extension check + at most one
    /// CGImageSourceCreate for animated detection).
    static func detect(_ url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if videoExts.contains(ext) { return .video }
        if possiblyAnimatedExts.contains(ext) {
            // Real frame count check — a .gif might be a single frame, an
            // .png is usually static. Don't burn a decode if we can avoid it.
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               CGImageSourceGetCount(src) > 1 {
                return .animatedImage
            }
            return .staticImage
        }
        if staticImageExts.contains(ext) { return .staticImage }
        return .unsupported
    }
}

// MARK: - Video keyboard routing

/// Commands the window-level key monitor can send to the currently visible
/// video without relying on AppKit first-responder focus. `AVPlayerView` only
/// receives key events after it has been clicked; keeping this tiny weak
/// registry lets keyboard playback work immediately after j/k navigation while
/// still leaving every unrelated key with the native responder chain.
@MainActor
final class VideoPlaybackRouter {
    static let shared = VideoPlaybackRouter()

    private weak var playerView: AVPlayerView?
    private var representedURL: URL?

    private init() {}

    func register(_ playerView: AVPlayerView, url: URL) {
        self.playerView = playerView
        representedURL = url
    }

    func unregister(_ playerView: AVPlayerView) {
        guard self.playerView === playerView else { return }
        self.playerView = nil
        representedURL = nil
    }

    /// Returns true only when the command was delivered to the player that is
    /// displaying `url`. The URL check prevents a retiring representable from
    /// receiving a key during a rapid selection change.
    @discardableResult
    func handle(keyCode: UInt16, for url: URL) -> Bool {
        guard representedURL == url,
              let player = playerView?.player else { return false }

        switch keyCode {
        case 49: // Space — play / pause
            if player.timeControlStatus == .paused {
                restartIfAtEnd(player)
                player.play()
            } else {
                player.pause()
            }
        case 123: // Left — five seconds back
            seek(player, by: -5)
        case 124: // Right — five seconds forward
            seek(player, by: 5)
        case 125: // Down — volume down
            player.volume = max(0, player.volume - 0.05)
        case 126: // Up — volume up
            player.volume = min(1, player.volume + 0.05)
        default:
            return false
        }
        return true
    }

    private func seek(_ player: AVPlayer, by delta: Double) {
        let current = player.currentTime().seconds
        guard current.isFinite else { return }

        var target = max(0, current + delta)
        let duration = player.currentItem?.duration.seconds ?? .nan
        if duration.isFinite {
            target = min(target, duration)
        }
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func restartIfAtEnd(_ player: AVPlayer) {
        let current = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? .nan
        guard current.isFinite, duration.isFinite, duration > 0,
              current >= duration - 0.05 else { return }
        player.seek(to: .zero)
    }
}

// MARK: - Animated image view

/// SwiftUI wrapper around `NSImageView` so animated GIF / APNG / animated
/// HEIC/WebP/AVIF play without us having to write our own frame stepper.
/// NSImageView's `animates = true` cycles frames at the rate baked into the
/// file (loop count + per-frame delays).
struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyDown
        v.animates = true
        v.canDrawSubviewsIntoLayer = true
        return v
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        // Re-load on URL change. NSImage(contentsOf:) detects the multi-
        // frame representation and NSImageView animates it once attached.
        let new = NSImage(contentsOf: url)
        if nsView.image != new {
            nsView.image = new
            nsView.animates = true
        }
    }
}

// MARK: - Video view

/// SwiftUI wrapper around AVKit's `AVPlayerView`. Auto-plays on appear,
/// pauses on disappear. Handles the format set AVFoundation supports
/// natively. Container recognition does not guarantee that every codec inside
/// the container is installed; AVPlayer presents its normal playback error
/// for those files.
struct VideoPlaybackView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.allowsPictureInPicturePlayback = true
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let needNew = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url != url
        if needNew {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            nsView.player = player
            // Auto-play on selection — viewer behavior, not media-app behavior.
            // The user can still pause from the controls.
            player.play()
        }
        VideoPlaybackRouter.shared.register(nsView, url: url)
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        VideoPlaybackRouter.shared.unregister(nsView)
        nsView.player?.pause()
        nsView.player = nil
    }
}

// MARK: - Video thumbnail

/// Pull a representative frame out of a video for the grid. Picks 10% in,
/// or 1s in, whichever is later — avoids the black-frame intros some
/// containers have at t=0. Cached size matches our static-image
/// thumbnail max so the grid stays consistent.
enum VideoThumbnail {
    /// AVAssetImageGenerator does not declare Sendable, but Apple documents
    /// `cancelAllCGImageGeneration()` as the cancellation entry point for its
    /// asynchronous requests. This wrapper limits the unchecked crossing to
    /// that single thread-safe operation.
    private final class GeneratorCancellation: @unchecked Sendable {
        let generator: AVAssetImageGenerator

        init(_ generator: AVAssetImageGenerator) {
            self.generator = generator
        }

        func cancel() {
            generator.cancelAllCGImageGeneration()
        }
    }

    static func generate(url: URL, maxDimension: Int = 256) async -> CGImage? {
        guard !Task.isCancelled else { return nil }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        let cancellation = GeneratorCancellation(generator)

        return await withTaskCancellationHandler {
            // Try 1s, but if duration is shorter use 10% of it. Any load,
            // codec, or cancellation failure simply yields no grid thumbnail.
            let durationSec = (try? await asset.load(.duration).seconds) ?? 0
            guard !Task.isCancelled else { return nil }
            let target = max(0, min(1.0, durationSec * 0.1))
            let time = CMTime(seconds: max(target, durationSec > 1 ? 1 : target), preferredTimescale: 600)
            do {
                let cg = try await generator.image(at: time).image
                return Task.isCancelled ? nil : cg
            } catch {
                return nil
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
