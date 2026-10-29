import Foundation
import AVFoundation

/// Output codec family. Both are driven by VideoToolbox through AVAssetWriter.
enum VideoCodec: String, Codable, CaseIterable, Identifiable, Hashable {
    case hevc = "HEVC (H.265)"
    case h264 = "H.264"

    var id: String { rawValue }

    var avCodecType: AVVideoCodecType {
        switch self {
        case .hevc: return .hevc
        case .h264: return .h264
        }
    }
}

/// Target resolution class. "keep" and "half" preserve the aspect ratio.
enum ResolutionClass: String, Codable, CaseIterable, Identifiable, Hashable {
    case keep = "Keep original"
    case half = "Half size"
    case fourK = "4K (2160p)"
    case fhd = "1080p"
    case hd = "720p"
    case sd = "480p"

    var id: String { rawValue }

    /// Returns a scaled output size (even numbers) for a given source size.
    /// Never upscales.
    func outputSize(for source: CGSize) -> CGSize {
        let w = max(2, source.width), h = max(2, source.height)
        let target: CGSize
        switch self {
        case .keep:
            target = CGSize(width: w, height: h)
        case .half:
            target = CGSize(width: w / 2, height: h / 2)
        case .fourK:
            target = cappedSize(source: source, limit: 3840)
        case .fhd:
            target = cappedSize(source: source, limit: 1920)
        case .hd:
            target = cappedSize(source: source, limit: 1280)
        case .sd:
            target = cappedSize(source: source, limit: 854)
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
struct Preset: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var codec: VideoCodec
    var resolution: ResolutionClass
    var fixedBitrateMbps: Double = 4.0
    var fpsCap: Int?                 // nil = keep native frame rate
    var audioBitrateKbps: Int = 128
    var isUserDefined: Bool = false

    /// Deterministic UUID derived from the preset name, so built-in IDs are
    /// stable across launches (last-used selection keeps working).
    private static func stableID(_ name: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x6c62272e07bb0142
        for b in name.utf8 {
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
        for i in list.indices { list[i].id = stableID(list[i].name) }
        return list
    }()

    private enum CodingKeys: String, CodingKey {
        case id, name, codec, resolution, fixedBitrateMbps,
             fpsCap, audioBitrateKbps, isUserDefined
    }

    init(name: String, codec: VideoCodec, resolution: ResolutionClass,
         fixedBitrateMbps: Double = 4.0, fpsCap: Int? = nil,
         audioBitrateKbps: Int = 128, isUserDefined: Bool = false) {
        self.id = UUID()
        self.name = name
        self.codec = codec
        self.resolution = resolution
        self.fixedBitrateMbps = fixedBitrateMbps
        self.fpsCap = fpsCap
        self.audioBitrateKbps = audioBitrateKbps
        self.isUserDefined = isUserDefined
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        codec = try c.decode(VideoCodec.self, forKey: .codec)
        resolution = try c.decode(ResolutionClass.self, forKey: .resolution)
        // Older presets (adaptive/size-target modes) decode to a sane default.
        fixedBitrateMbps = try c.decodeIfPresent(Double.self, forKey: .fixedBitrateMbps) ?? 4.0
        fpsCap = try c.decodeIfPresent(Int.self, forKey: .fpsCap)
        audioBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) ?? 128
        isUserDefined = try c.decodeIfPresent(Bool.self, forKey: .isUserDefined) ?? false
    }

    var modeSummary: String {
        String(format: "%.1f Mbps", fixedBitrateMbps)
    }
}
