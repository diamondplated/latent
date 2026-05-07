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

    init(locations: [PhotoLocation], onSelectCluster: @escaping ([URL]) -> Void) {
        self.locations = locations
        self.onSelectCluster = onSelectCluster

        // Initial camera: geographic mean of the input set, or a default view
        // if empty. A default of San Francisco gives a recognizable empty map.
        let initialCenter: CLLocationCoordinate2D
        let initialSpan: MKCoordinateSpan
        if locations.isEmpty {
            initialCenter = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
            initialSpan = MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0)
        } else {
            let meanLat = locations.map(\.latitude).reduce(0, +) / Double(locations.count)
            let meanLon = locations.map(\.longitude).reduce(0, +) / Double(locations.count)
            initialCenter = CLLocationCoordinate2D(latitude: meanLat, longitude: meanLon)

            // Pick a span that fits all points with a bit of padding.
            let lats = locations.map(\.latitude)
            let lons = locations.map(\.longitude)
            let latRange = (lats.max() ?? meanLat) - (lats.min() ?? meanLat)
            let lonRange = (lons.max() ?? meanLon) - (lons.min() ?? meanLon)
            initialSpan = MKCoordinateSpan(
                latitudeDelta: max(latRange * 1.4, 0.01),
                longitudeDelta: max(lonRange * 1.4, 0.01)
            )
        }
        let region = MKCoordinateRegion(center: initialCenter, span: initialSpan)
        _cameraPosition = State(initialValue: .region(region))
    }

    var body: some View {
        ZStack {
            if locations.isEmpty {
                emptyState
            } else {
                map
            }
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
        }
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
