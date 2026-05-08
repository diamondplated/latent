import SwiftUI
import MapKit
import PhotoGeo

/// MapKit-based view of photos that have GPS metadata.
///
/// # Clustering strategy
///
/// We use a coarse geohash-prefix grouping driven by the current map camera's
/// altitude (zoom). At high altitude (zoomed out, looking at a continent) we
/// truncate locations to ~1° lat/lon buckets so an entire trip becomes one
/// pin; as the user zooms in, the bucket shrinks until each photo gets its
/// own pin.
///
/// We deliberately avoid MKClusterAnnotation / MKMapView's built-in clustering
/// because the modern SwiftUI `Map { ... }` API in macOS 14 doesn't expose it
/// cleanly — the SwiftUI marker DSL operates above the MKAnnotationView layer
/// where MapKit's clustering normally happens. Manual bucketing is simpler,
/// gives us total control over what a "tap a cluster" handler receives, and
/// scales fine for folders containing thousands of photos.
struct PhotoMapView: View {
    let locations: [PhotoLocation]
    let onSelectCluster: ([URL]) -> Void

    @State private var cameraPosition: MapCameraPosition
    /// Approximate camera altitude in meters. Used to choose a clustering
    /// granularity. Updated by `onMapCameraChange`.
    @State private var altitudeMeters: Double = 1_000_000
    /// The location set currently fit by the camera. Tracked separately from
    /// camera movement so new folders fit once without yanking the map after
    /// the user starts panning around.
    @State private var fittedLocationSetID: LocationSetID?
    @State private var userAdjustedCameraSinceFit = false
    @State private var suppressingProgrammaticCameraChange = false

    init(locations: [PhotoLocation], onSelectCluster: @escaping ([URL]) -> Void) {
        self.locations = locations
        self.onSelectCluster = onSelectCluster

        let region = Self.fittedRegion(for: locations)
        _cameraPosition = State(initialValue: .region(region))
        _fittedLocationSetID = State(initialValue: locations.isEmpty ? nil : LocationSetID(locations: locations))
    }

    var body: some View {
        ZStack {
            if locations.isEmpty {
                emptyState
            } else {
                map
            }
        }
        .onAppear {
            fitCameraIfNeeded(for: locationSetID)
        }
        .onChange(of: locationSetID) { _, newSetID in
            fitCameraIfNeeded(for: newSetID)
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $cameraPosition) {
            ForEach(clusters, id: \.id) { cluster in
                Annotation(
                    cluster.label,
                    coordinate: cluster.coordinate,
                    anchor: .bottom
                ) {
                    PhotoClusterPin(count: cluster.urls.count)
                        .onTapGesture {
                            onSelectCluster(cluster.urls)
                        }
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            // `distance` is the camera height above the surface in meters.
            // Smaller = zoomed in.
            altitudeMeters = context.camera.distance
            guard fittedLocationSetID != nil else { return }
            if suppressingProgrammaticCameraChange {
                suppressingProgrammaticCameraChange = false
            } else {
                userAdjustedCameraSinceFit = true
            }
        }
    }

    private var locationSetID: LocationSetID? {
        locations.isEmpty ? nil : LocationSetID(locations: locations)
    }

    @MainActor
    private func fitCameraIfNeeded(for newSetID: LocationSetID?) {
        guard let newSetID else {
            fittedLocationSetID = nil
            userAdjustedCameraSinceFit = false
            return
        }

        guard shouldFitCamera(to: newSetID) else { return }

        suppressingProgrammaticCameraChange = true
        withAnimation(.easeInOut(duration: 0.25)) {
            cameraPosition = .region(Self.fittedRegion(for: locations))
        }
        fittedLocationSetID = newSetID
        userAdjustedCameraSinceFit = false

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            suppressingProgrammaticCameraChange = false
        }
    }

    private func shouldFitCamera(to newSetID: LocationSetID) -> Bool {
        guard let fittedLocationSetID else { return true }
        if fittedLocationSetID == newSetID { return false }
        if !userAdjustedCameraSinceFit { return true }

        // If this is likely the same folder gradually gaining GPS results,
        // preserve the user's pan/zoom. A mostly different URL set is a real
        // new loaded set and should get one fresh fit.
        return !newSetID.substantiallyOverlaps(with: fittedLocationSetID)
    }

    private static func fittedRegion(for locations: [PhotoLocation]) -> MKCoordinateRegion {
        guard !locations.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0)
            )
        }

        let lats = locations.map(\.latitude)
        let lons = locations.map(\.longitude)
        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? minLat
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? minLon
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.01)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "map")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No photos with GPS data")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Clustering

    /// Group input locations into buckets sized by current zoom level. Each
    /// bucket gets one pin at the bucket's centroid; tapping it surfaces all
    /// URLs that fell in.
    private var clusters: [Cluster] {
        let bucketSize = bucketSizeDegrees(forAltitude: altitudeMeters)
        var buckets: [BucketKey: [PhotoLocation]] = [:]
        for loc in locations {
            // Use floor() to map a coordinate to its bucket origin. Two coords
            // within the same bucket-sized cell collapse to the same key.
            let latBucket = Int((loc.latitude / bucketSize).rounded(.down))
            let lonBucket = Int((loc.longitude / bucketSize).rounded(.down))
            buckets[BucketKey(lat: latBucket, lon: lonBucket), default: []].append(loc)
        }

        return buckets.map { (key, photos) in
            // Centroid of the cluster: arithmetic mean of member coordinates.
            // Cheap and looks correct for the small geographic ranges typical
            // of a single trip's photos. For a global cluster spanning the
            // antimeridian this would behave oddly; we accept that.
            let centerLat = photos.map(\.latitude).reduce(0, +) / Double(photos.count)
            let centerLon = photos.map(\.longitude).reduce(0, +) / Double(photos.count)
            return Cluster(
                id: key,
                coordinate: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                urls: photos.map(\.url),
                label: photos.count == 1
                    ? photos[0].url.lastPathComponent
                    : "\(photos.count) photos"
            )
        }
        .sorted { $0.urls.count > $1.urls.count }  // larger clusters drawn first
    }

    /// Bucket size in degrees at a given camera altitude. Hand-tuned thresholds:
    /// the goal is roughly "each pin represents one screen-area's worth of
    /// photos." 1° ≈ 111km lat, narrower lon at higher latitudes — close
    /// enough for visual clustering.
    private func bucketSizeDegrees(forAltitude altitude: Double) -> Double {
        switch altitude {
        case 0..<5_000: return 0.0001       // ~10m, basically per-photo
        case 5_000..<50_000: return 0.001   // ~100m, neighborhood
        case 50_000..<500_000: return 0.01  // ~1km, city
        case 500_000..<5_000_000: return 0.1 // ~10km, region
        default: return 1.0                  // ~100km, country
        }
    }
}

// MARK: - Pin view

private struct PhotoClusterPin: View {
    let count: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 30, height: 30)
                .shadow(radius: 2)
            if count > 1 {
                Text("\(count)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Cluster types

/// One pin's worth of grouped photos.
private struct Cluster: Identifiable {
    let id: BucketKey
    let coordinate: CLLocationCoordinate2D
    let urls: [URL]
    let label: String
}

/// Integer bucket coordinates; Hashable so we can use it as a dictionary key.
private struct BucketKey: Hashable {
    let lat: Int
    let lon: Int
}

private struct LocationSetID: Equatable {
    let keys: [LocationKey]
    let urls: Set<URL>

    init(locations: [PhotoLocation]) {
        let builtKeys = locations
            .map { LocationKey(url: $0.url, latitude: $0.latitude, longitude: $0.longitude) }
            .sorted { lhs, rhs in
                if lhs.url.path != rhs.url.path { return lhs.url.path < rhs.url.path }
                if lhs.latitude != rhs.latitude { return lhs.latitude < rhs.latitude }
                return lhs.longitude < rhs.longitude
            }
        self.keys = builtKeys
        self.urls = Set(builtKeys.map(\.url))
    }

    func substantiallyOverlaps(with other: LocationSetID) -> Bool {
        let overlap = urls.intersection(other.urls).count
        guard overlap > 0 else { return false }
        return Double(overlap) / Double(min(urls.count, other.urls.count)) >= 0.5
    }
}

private struct LocationKey: Equatable {
    let url: URL
    let latitude: Double
    let longitude: Double
}
