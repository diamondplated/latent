import os

/// Structured logging for Latent. Categories map to functional areas so
/// Console.app filtering works out of the box. Usage:
///   Log.scan.info("Found \(count) photos")
///   Log.pipeline.error("Stage failed: \(error)")
enum Log {
    private static let subsystem = "com.latent.photo-viewer"

    /// Folder scanning and file discovery.
    static let scan = Logger(subsystem: subsystem, category: "scan")

    /// Enhancement pipeline execution.
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")

    /// CLIP search indexing and queries.
    static let search = Logger(subsystem: subsystem, category: "search")

    /// Image I/O (reading, writing, thumbnails).
    static let io = Logger(subsystem: subsystem, category: "io")

    /// Cache operations (pipeline cache, thumbnail cache, prefetch).
    static let cache = Logger(subsystem: subsystem, category: "cache")

    /// GPS extraction and map view.
    static let geo = Logger(subsystem: subsystem, category: "geo")
}
