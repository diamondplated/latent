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
    /// Video container extensions. AVFoundation natively handles .mp4 /
    /// .mov / .m4v / .m4a (audio) plus most HEVC/H.264 in those containers.
    /// .mkv / .webm / .avi / .flv / .wmv work iff the user has the codecs
    /// installed (system VideoToolbox + AVFoundation extensions). When
    /// AVPlayer can't read the file we surface a clear error.
    static let videoExts: Set<String> = [
        "mp4", "mov", "m4v", "qt", "3gp", "3g2",
        "mkv", "webm", "avi", "flv", "wmv", "ogv", "mts", "m2ts",
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
/// natively (mp4/mov/m4v/HEVC/H.264) plus whatever the user has codec
/// extensions installed for (mkv/webm/avi etc.). When AVPlayer can't
/// read a file we degrade to a clear error message rather than going
/// silent.
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
        guard needNew else { return }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        nsView.player = player
        // Auto-play on selection — viewer behavior, not media-app behavior.
        // The user can still pause from the controls.
        player.play()
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
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
    static func generate(url: URL, maxDimension: Int = 256) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
            // CMTime: try 1s, but if duration is shorter use 10% of it.
            // copyCGImage handles errors by returning nil so a video that
            // can't be decoded just doesn't get a thumbnail.
            let durationSec = (try? await asset.load(.duration).seconds) ?? 0
            let target = max(0, min(1.0, durationSec * 0.1))
            let time = CMTime(seconds: max(target, durationSec > 1 ? 1 : target), preferredTimescale: 600)
            do {
                let cg = try await generator.image(at: time).image
                return cg
            } catch {
                return nil
            }
        }.value
    }
}
