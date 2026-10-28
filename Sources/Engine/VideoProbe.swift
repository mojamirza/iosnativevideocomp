import AVFoundation
import CoreVideo

/// Color metadata of a video track. This is the backbone of the **color-safe engine**:
/// every decoded pixel buffer gets re-tagged with the *source's* color primaries /
/// transfer function / YCbCr matrix, and those exact values are also written into the
/// output container. HDR transfers (HLG / PQ) are detected here and never tonemapped,
/// decoded to an 8-bit intermediate, or otherwise mangled.
struct ColorTags: Hashable {
    var primaries: String?          // e.g. "itu_r_709_2", "itu_r_2020"
    var transferFunction: String?   // e.g. "itu_r_2100_hlg", "itu_r_2100_pq"
    var yCbCrMatrix: String?        // e.g. "itu_r_709_2", "itu_r_2020"

    var isHDR: Bool {
        let t = (transferFunction ?? "").lowercased()
        return t.contains("hlg") || t.contains("pq") || t.contains("2084")
    }

    /// Pull tags from the track's format description extensions.
    static func from(track: AVAssetTrack) async -> ColorTags {
        var t = ColorTags(primaries: nil, transferFunction: nil, yCbCrMatrix: nil)
        do {
            let fmts: [CMFormatDescription] = try await track.load(.formatDescriptions)
            guard let fmt = fmts.first else { return t }
            t.primaries = CMFormatDescriptionGetExtension(
                fmt, kCMFormatDescriptionExtension_ColorPrimaries) as? String
            t.transferFunction = CMFormatDescriptionGetExtension(
                fmt, kCMFormatDescriptionExtension_TransferFunction) as? String
            t.yCbCrMatrix = CMFormatDescriptionGetExtension(
                fmt, kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        } catch {
            // Metadata unknown; engine falls back to sRGB-safe defaults.
        }
        return t
    }

    /// (Re-)attach the source color tags to a pixel buffer (Core Video attachments).
    static func attach(to buffer: CVImageBuffer, tags: ColorTags?) {
        guard let tags else { return }
        CVBufferRemoveAllAttachments(buffer)
        if let p = tags.primaries {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, p as CFString, .shouldPropagate)
        }
        if let tf = tags.transferFunction {
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, tf as CFString, .shouldPropagate)
        }
        if let m = tags.yCbCrMatrix {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, m as CFString, .shouldPropagate)
        }
    }

    /// AVAssetWriter settings so the muxed file carries the same tags as the source.
    func writerColorProperties() -> [String: Any]? {
        var props: [String: Any] = [:]
        if let p = primaries { props[AVVideoColorPrimariesKey] = p }
        if let t = transferFunction { props[AVVideoTransferFunctionKey] = t }
        if let m = yCbCrMatrix { props[AVVideoYCbCrMatrixKey] = m }
        return props.isEmpty ? nil : props
    }

    var humanLabel: String {
        if isHDR {
            return (transferFunction ?? "").lowercased().contains("hlg") ? "HDR (HLG)" : "HDR (Dolby Vision/PQ)"
        }
        switch primaries ?? "" {
        case let p where p.contains("2020"): return "Rec.2020 SDR"
        case "itu_r_601_4", "smpte170m": return "SDTV (Rec.601)"
        default: return "Rec.709 / sRGB"
        }
    }
}

/// Snapshot of a source video produced by probing with AVFoundation.
struct ProbeResult: Hashable {
    var duration: Double
    var sourceSize: CGSize
    var nominalFPS: Float
    var codecSubType: String        // "avc1", "hev1", ...
    var tags: ColorTags
    var hasAudio: Bool
    var videoDataRate: Double       // bits/second
    var audioDataRate: Double       // bits/second
    var fileSize: Int64

    static func codecName(_ fourCC: FourCharCode) -> String {
        var name = ""
        for shift in [24, 16, 8, 0] {
            let byte = UInt8((fourCC >> shift) & 0xFF)
            if let scalar = UnicodeScalar(byte) { name.append(Character(scalar)) }
        }
        return name
    }

    static func probe(url: URL) async throws -> ProbeResult {
        let asset = AVURLAsset(url: url)
        let durationTime = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else {
            throw NSError(domain: "VidCompress.probe", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No video track found in this file."])
        }

        let naturalSize = try await track.load(.naturalSize)
        let nominalFPS = try await track.load(.nominalFrameRate)
        let dataRate = (try? await track.load(.estimatedDataRate)) ?? 0.0
        let fmts: [CMFormatDescription] = (try? await track.load(.formatDescriptions)) ?? []
        let subType = fmts.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioRate = 0.0
        if let audio = audioTracks.first {
            audioRate = (try? await audio.load(.estimatedDataRate)) ?? 0.0
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0

        // Caveat: `naturalSize` already reflects rotation for modern sources;
        // the decoder's appliesPreferredTrackTransform handles the rest.
        return ProbeResult(
            duration: CMTimeGetSeconds(durationTime),
            sourceSize: naturalSize,
            nominalFPS: nominalFPS > 0 ? nominalFPS : 30,
            codecSubType: subType,
            tags: await ColorTags.from(track: track),
            hasAudio: !(audioTracks.isEmpty),
            videoDataRate: dataRate,
            audioDataRate: audioRate,
            fileSize: size
        )
    }
}

extension CGSize {
    var megapixels: Double { Double(width * height) / 1_000_000 }
}
