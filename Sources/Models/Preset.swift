import Foundation
import AVFoundation

/// Output codec family. Both are driven by VideoToolbox through AVAssetWriter.
/// STABLE raw keys ("hevc", "h264") — never display strings: presets and
/// history records would break the moment a label is renamed or localised.
/// Legacy builds persisted the display strings; init(from:) accepts those.
enum VideoCodec: String, Codable, CaseIterable, Identifiable, Hashable {
    case hevc, h264

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hevc: return "HEVC (H.265)"
        case .h264: return "H.264"
        }
    }

    var avCodecType: AVVideoCodecType {
        switch self {
        case .hevc: return .hevc
        case .h264: return .h264
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "hevc", "HEVC (H.265)": self = .hevc      // legacy display string
        case "h264", "H.264":        self = .h264      // legacy display string
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "Unknown codec value: \(raw)"))
        }
    }
}

/// Target resolution class (the standard tiers). "keep" preserves the source.
/// STABLE raw keys ("keep", "uhd"…) with display strings shown in the UI —
/// old stores saved the display strings as raw values, so init(from:)
/// decodes BOTH spellings.
enum ResolutionClass: String, Codable, CaseIterable, Identifiable, Hashable {
    case keep, uhd, qhd, fhd, hd, sd

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keep: return "Keep original"
        case .uhd:  return "2160p (4K)"
        case .qhd:  return "1440p (2K)"
        case .fhd:  return "1080p"
        case .hd:   return "720p"
        case .sd:   return "480p"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "keep", "Keep original": self = .keep
        case "uhd",  "2160p (4K)":    self = .uhd
        case "qhd",  "1440p (2K)":    self = .qhd
        case "fhd",  "1080p":         self = .fhd
        case "hd",   "720p":          self = .hd
        case "sd",   "480p":          self = .sd
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "Unknown resolution class: \(raw)"))
        }
    }

    /// Long-side limit for the class (never upscales, keeps aspect ratio).
    var longSideLimit: CGFloat? {
        switch self {
        case .keep: return nil
        case .uhd: return 3840
        case .qhd: return 2560
        case .fhd: return 1920
        case .hd: return 1280
        case .sd: return 854
        }
    }

    /// Returns a scaled output DISPLAY size (even numbers) for a given source
    /// display size. Never upscales.
    /// Note: width and height are floored (then evened) INDEPENDENTLY, which
    /// shifts the aspect ratio by up to 1px on each axis — deliberate (the
    /// encoder requires even dimensions); the engine's separate sx/sy scale
    /// factors pass that sub-pixel deviation through unchanged.
    func outputSize(for source: CGSize) -> CGSize {
        let w = max(2, source.width), h = max(2, source.height)
        let target: CGSize
        if let limit = longSideLimit {
            target = cappedSize(source: source, limit: limit)
        } else {
            target = CGSize(width: w, height: h)
        }
        // Encoders want even dimensions.
        return CGSize(width: max(2, Int(target.width) - Int(target.width) % 2),
                      height: max(2, Int(target.height) - Int(target.height) % 2))
    }

    private func cappedSize(source: CGSize, limit: CGFloat) -> CGSize {
        let longSide = max(source.width, source.height)
        guard longSide > limit else { return source }
        let s = limit / longSide
        return CGSize(width: floor(source.width * s), height: floor(source.height * s))
    }
}

/// A reusable compression configuration: codec, resolution and an exact
/// video bitrate (kept simple on purpose — no adaptive heuristics).
/// Values are CLAMPED on construction (both the memberwise init and JSON
/// decoding) — untrusted numbers must never reach the engine: e.g. a huge
/// fps cap would trap CMTimeScale(cap)*2.
struct Preset: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var codec: VideoCodec
    var resolution: ResolutionClass
    var fixedBitrateMbps: Double = 4.0
    var fpsCap: Int?                 // nil = keep native frame rate
    var audioBitrateKbps: Int = 128
    var isUserDefined: Bool = false

    static let bitrateRange: ClosedRange<Double> = 0.1...40
    static let fpsCapRange: ClosedRange<Int> = 1...240
    static let audioRange: ClosedRange<Int> = 32...320

    /// Deterministic UUID derived from a FIXED system key (never the display
    /// name), so renaming or localising a built-in can't reset the saved
    /// "last used" selection or orphan stored references.
    private static func stableID(_ key: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x6c62272e07bb0142
        for b in key.utf8 {
            h1 = (h1 ^ UInt64(b)) &* 0x100000001b3
            h2 = (h2 &+ UInt64(b)) &* 0x9E3779B97F4A7C15
        }
        var bytes = [UInt8]()
        var x = h1
        for _ in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: x)); x >>= 8 }
        x = h2
        for _ in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: x)); x >>= 8 }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static let builtIn: [Preset] = {
        var list = [
            Preset(name: "High quality", codec: .hevc, resolution: .keep,
                   fixedBitrateMbps: 8, fpsCap: nil, audioBitrateKbps: 128),
            Preset(name: "Medium (720p)", codec: .hevc, resolution: .hd,
                   fixedBitrateMbps: 4, fpsCap: nil, audioBitrateKbps: 128),
            Preset(name: "Low (480p)", codec: .hevc, resolution: .sd,
                   fixedBitrateMbps: 1.5, fpsCap: nil, audioBitrateKbps: 96),
        ]
        list[0].id = stableID("builtin.high")
        list[1].id = stableID("builtin.720p")
        list[2].id = stableID("builtin.480p")
        return list
    }()

    private enum CodingKeys: String, CodingKey {
        case id, name, codec, resolution, fixedBitrateMbps,
             fpsCap, audioBitrateKbps, isUserDefined
    }

    /// Normalises every field into its validated range. Shared by both inits.
    private func normalized(name: String, codec: VideoCodec, resolution: ResolutionClass,
                            bitrate: Double, fpsCap: Int?, audio: Int, userDefined: Bool) -> Preset {
        var p = Preset()
        p.id = id
        p.name = name.isEmpty ? "Custom" : name
        p.codec = codec
        p.resolution = resolution
        p.fixedBitrateMbps = min(Preset.bitrateRange.upperBound, max(Preset.bitrateRange.lowerBound, bitrate))
        p.fpsCap = fpsCap.map { min(Preset.fpsCapRange.upperBound, max(Preset.fpsCapRange.lowerBound, $0)) }
        p.audioBitrateKbps = min(Preset.audioRange.upperBound, max(Preset.audioRange.lowerBound, audio))
        p.isUserDefined = userDefined
        return p
    }

    init(name: String, codec: VideoCodec, resolution: ResolutionClass,
         fixedBitrateMbps: Double = 4.0, fpsCap: Int? = nil,
         audioBitrateKbps: Int = 128, isUserDefined: Bool = false) {
        let p = normalized(name: name, codec: codec, resolution: resolution,
                           bitrate: fixedBitrateMbps, fpsCap: fpsCap,
                           audio: audioBitrateKbps, userDefined: isUserDefined)
        self = p
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        codec = try c.decode(VideoCodec.self, forKey: .codec)
        resolution = try c.decode(ResolutionClass.self, forKey: .resolution)
        let bitrate = try c.decodeIfPresent(Double.self, forKey: .fixedBitrateMbps) ?? 4.0
        let cap = try c.decodeIfPresent(Int.self, forKey: .fpsCap)
        let audio = try c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) ?? 128
        let user = try c.decodeIfPresent(Bool.self, forKey: .isUserDefined) ?? false
        self = normalized(name: name, codec: codec, resolution: resolution,
                          bitrate: bitrate, fpsCap: cap, audio: audio, userDefined: user)
    }

    var modeSummary: String {
        String(format: "%.1f Mbps", fixedBitrateMbps)
    }
}
