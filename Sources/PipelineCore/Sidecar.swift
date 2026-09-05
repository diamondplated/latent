import Foundation

public enum SidecarError: Error, CustomStringConvertible {
    /// File on disk has a schema version newer than this build understands.
    /// Don't proceed — saving over it would silently drop top-level fields the
    /// older Codable struct doesn't model.
    case unsupportedVersion(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .unsupportedVersion(let found, let supported):
            return "Sidecar version \(found) is newer than supported (\(supported)); upgrade the app"
        }
    }
}

/// On-disk representation of a non-destructive edit.
///
/// Lives next to the original as `<filename>.enhance.json`. Holds the ordered
/// list of stages with their parameters. The original is never modified;
/// applying the sidecar deterministically reproduces the enhanced output.
///
/// Forward-compat: unknown stage IDs are preserved on read so a newer-version
/// sidecar opened in an older app round-trips without losing data. Top-level
/// fields don't have the same protection; bumping `version` indicates a
/// schema change that older builds must refuse to load (see `load`).
public struct EnhanceSidecar: Codable, Sendable {
    public static let supportedVersion = 1

    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var steps: [SidecarStep]

    public struct SidecarStep: Codable, Sendable {
        public var stageID: StageID
        public var enabled: Bool
        public var parameters: ParameterBag

        public init(stageID: StageID, enabled: Bool, parameters: ParameterBag) {
            self.stageID = stageID
            self.enabled = enabled
            self.parameters = parameters
        }
    }

    public init(steps: [SidecarStep] = []) {
        self.version = 1
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
        self.steps = steps
    }

    /// Return a copy with the supplied stage definitions replacing matching
    /// stage IDs. Unknown stages keep both their data and relative order, so an
    /// older Latent build can edit the stages it understands without erasing a
    /// recipe written by a newer build. Duplicate known-stage entries are
    /// collapsed to one canonical replacement; replacements absent from the
    /// original are appended in the order supplied.
    public func replacingSteps(with replacements: [SidecarStep]) -> EnhanceSidecar {
        let replacementByID = Dictionary(
            replacements.map { ($0.stageID, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let replacementIDs = Set(replacementByID.keys)
        var emitted = Set<StageID>()
        var merged: [SidecarStep] = []
        merged.reserveCapacity(max(steps.count, replacements.count))

        for step in steps {
            guard replacementIDs.contains(step.stageID) else {
                merged.append(step)
                continue
            }
            guard emitted.insert(step.stageID).inserted,
                  let replacement = replacementByID[step.stageID] else {
                continue
            }
            merged.append(replacement)
        }

        for replacement in replacements {
            guard emitted.insert(replacement.stageID).inserted,
                  let canonical = replacementByID[replacement.stageID] else {
                continue
            }
            merged.append(canonical)
        }

        var copy = self
        copy.steps = merged
        return copy
    }

    public static func sidecarURL(for imageURL: URL) -> URL {
        imageURL.appendingPathExtension("enhance.json")
    }

    public static func load(for imageURL: URL) throws -> EnhanceSidecar? {
        let url = sidecarURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(EnhanceSidecar.self, from: data)
        if sidecar.version > Self.supportedVersion {
            throw SidecarError.unsupportedVersion(found: sidecar.version, supported: Self.supportedVersion)
        }
        return sidecar
    }

    public func save(for imageURL: URL) throws {
        var copy = self
        copy.updatedAt = Date()
        let url = Self.sidecarURL(for: imageURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(copy)
        try data.write(to: url, options: .atomic)
    }
}

/// Type-erased parameter bag for sidecar serialization.
///
/// Stages serialize their `Params` via Codable; the sidecar holds JSON-encoded
/// parameter values without knowing each stage's concrete type. This lets the
/// pipeline grow new stages without breaking sidecar compat.
public struct ParameterBag: Codable, Sendable, Hashable {
    public let raw: Data

    public init(raw: Data) { self.raw = raw }

    public init<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.raw = try encoder.encode(value)
    }

    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: raw)
    }

    // Codable: encode as a raw JSON value, not a wrapper.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let any = try container.decode(JSONValue.self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.raw = try encoder.encode(any)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let any = try JSONDecoder().decode(JSONValue.self, from: raw)
        try container.encode(any)
    }
}

/// Minimal JSONValue type so ParameterBag can encode/decode arbitrary JSON.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
