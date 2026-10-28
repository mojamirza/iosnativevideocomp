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

/// What the Quality-Size Optimizer should optimise for when the bitrate is "auto".
enum QualityTier: String, Codable, CaseIterable, Identifiable, Hashable {
    case smallest, balanced, best

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smallest: return "Smallest file"
        case .balanced: return "Balanced"
        case .best: return "Best quality"
        }
    }

    var description: String {
        switch self {
        case .smallest: return "Aggressive bitrate, visually acceptable"
        case .balanced: return "Recommended mix of size and quality"
        case .best: return "Transparent-ish quality, larger file"
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

/// A reusable compression configuration, "detailed presets with output size and bitrate".
///
/// Bitrate resolution order:
/// 1. `sizeTargetMB`  – derive video bitrate from a desired output file size
/// 2. `fixedBitrateMbps` – explicit bitrate set by the user / preset
/// 3. `autoQuality != nil` – Quality-Size Optimizer picks the bitrate
struct Preset: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var codec: VideoCodec
    var resolution: ResolutionClass
    var autoQuality: QualityTier?
    var fixedBitrateMbps: Double?
    var sizeTargetMB: Double?
    var fpsCap: Int?                 // nil = keep native frame rate
    var audioBitrateKbps: Int = 128
    var isUserDefined: Bool = false

    static let auto: Preset = Preset(
        name: "Auto · Balanced (Adaptive)", codec: .hevc, resolution: .keep,
        autoQuality: .balanced, fixedBitrateMbps: nil, sizeTargetMB: nil, fpsCap: nil,
        audioBitrateKbps: 128
    )

    static let builtIn: [Preset] = [
        .auto,
        Preset(name: "Auto · Smallest File", codec: .hevc, resolution: .keep,
               autoQuality: .smallest, audioBitrateKbps: 96),
        Preset(name: "1080p HEVC · 5 Mbps", codec: .hevc, resolution: .fhd,
               fixedBitrateMbps: 5, audioBitrateKbps: 128),
        Preset(name: "720p HEVC · 2.5 Mbps", codec: .hevc, resolution: .hd,
               fixedBitrateMbps: 2.5, audioBitrateKbps: 96),
        Preset(name: "1080p H.264 · 8 Mbps (max compatibility)", codec: .h264, resolution: .fhd,
               fixedBitrateMbps: 8, audioBitrateKbps: 160),
        Preset(name: "4K HEVC · 12 Mbps", codec: .hevc, resolution: .fourK,
               fixedBitrateMbps: 12, audioBitrateKbps: 160),
    ]

    private enum CodingKeys: String, CodingKey {
        case id, name, codec, resolution, autoQuality, fixedBitrateMbps,
             sizeTargetMB, fpsCap, audioBitrateKbps, isUserDefined
    }

    init(name: String, codec: VideoCodec, resolution: ResolutionClass,
         autoQuality: QualityTier? = nil, fixedBitrateMbps: Double? = nil,
         sizeTargetMB: Double? = nil, fpsCap: Int? = nil,
         audioBitrateKbps: Int = 128, isUserDefined: Bool = false) {
        self.id = UUID()
        self.name = name
        self.codec = codec
        self.resolution = resolution
        self.autoQuality = autoQuality
        self.fixedBitrateMbps = fixedBitrateMbps
        self.sizeTargetMB = sizeTargetMB
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
        autoQuality = try c.decodeIfPresent(QualityTier.self, forKey: .autoQuality)
        fixedBitrateMbps = try c.decodeIfPresent(Double.self, forKey: .fixedBitrateMbps)
        sizeTargetMB = try c.decodeIfPresent(Double.self, forKey: .sizeTargetMB)
        fpsCap = try c.decodeIfPresent(Int.self, forKey: .fpsCap)
        audioBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) ?? 128
        isUserDefined = try c.decodeIfPresent(Bool.self, forKey: .isUserDefined) ?? false
    }

    var modeSummary: String {
        if let t = sizeTargetMB { return String(format: "≈ %.0f MB target", t) }
        if let b = fixedBitrateMbps { return String(format: "%.1f Mbps", b) }
        if let q = autoQuality { return "Adaptive · \(q.label)" }
        return "Adaptive"
    }
}
