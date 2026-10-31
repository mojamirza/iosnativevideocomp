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
                fmt, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            t.transferFunction = CMFormatDescriptionGetExtension(
                fmt, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            t.yCbCrMatrix = CMFormatDescriptionGetExtension(
                fmt, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        } catch {
            // Metadata unknown; engine falls back to sRGB-safe defaults.
        }
        return t
    }

    /// (Re-)attach the source color tags to a pixel buffer BEFORE any scaling
    /// or rendering into it. The buffer's attachments drive how Core Video /
    /// VideoToolbox / Core Image interpret its content, so tagging late means
    /// the conversion already happened with wrong defaults.
    ///
    /// First the source's side-channel metadata is copied over (mastering
    /// display, content light level — otherwise the output HEVC loses those
    /// hints), then the three core tags are enforced from the probed values.
    static func attach(to buffer: CVImageBuffer, tags: ColorTags, from source: CVImageBuffer? = nil) {
        if let source, let dict = CVBufferGetAttachments(source, .shouldPropagate) as? [String: Any] {
            for (key, value) in dict {
                guard key != kCVImageBufferColorPrimariesKey as String,
                      key != kCVImageBufferTransferFunctionKey as String,
                      key != kCVImageBufferYCbCrMatrixKey as String,
                      let cfValue = value as CFTypeRef? else { continue }
                CVBufferSetAttachment(buffer, key as CFString, cfValue, .shouldPropagate)
            }
        }
        // Resolve ALL THREE tags even when the source file is missing some —
        // AVVideoColorPropertiesKey requires primaries + transfer + matrix
        // together, and a partial rendering on the buffer helps nothing.
        let p = tags.primaries ?? (tags.isHDR ? "itu_r_2020" : "itu_r_709_2")
        let tf = tags.transferFunction ?? (tags.isHDR ? "itu_r_2100_pq" : "itu_r_709_2")
        let m = tags.yCbCrMatrix ?? (tags.isHDR ? "itu_r_2020" : "itu_r_709_2")
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, p as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, tf as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, m as CFString, .shouldPropagate)
    }

    /// AVAssetWriter settings so the muxed file carries the same tags as the
    /// source. ALL three keys are always provided — a partial dictionary is
    /// undefined behavior and can raise an uncatchable Objective-C exception.
    /// Fields the file doesn't carry get sensible colorimetry defaults
    /// (Rec.2020 for HDR, Rec.709 otherwise) rather than being omitted.
    func writerColorProperties() -> [String: Any]? {
        let p = primaries ?? (isHDR ? "itu_r_2020" : "itu_r_709_2")
        let tf = transferFunction ?? (isHDR ? "itu_r_2100_pq" : "itu_r_709_2")
        let m = yCbCrMatrix ?? (isHDR ? "itu_r_2020" : "itu_r_709_2")
        return [
            AVVideoColorPrimariesKey: p,
            AVVideoTransferFunctionKey: tf,
            AVVideoYCbCrMatrixKey: m,
        ]
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
    var bitDepth: Int               // 8 or 10 (from format description)
    var preferredTransform: CGAffineTransform
    var isRotated: Bool
    var tags: ColorTags
    var hasAudio: Bool
    var videoDataRate: Double       // bits/second
    var audioDataRate: Double       // bits/second
    var fileSize: Int64

    static func codecName(_ fourCC: FourCharCode) -> String {
        var name = ""
        for shift in [24, 16, 8, 0] {
            let byte = UInt8((fourCC >> shift) & 0xFF)
            if byte >= 32 && byte <= 126 {
                name.append(Character(UnicodeScalar(byte)))
            } else {
                name.append("?".first!)
            }
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
        let preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        // naturalSize is the PRE-ROTATION (stored) size. What players actually
        // show — and what every resolution preset must be measured against —
        // is the DISPLAY size: naturalSize with the preferred transform applied.
        // (Portrait iPhone video: stored 1920×1080, displayed 1080×1920.)
        let displaySize = naturalSize.applying(preferredTransform)
        let sourceSize = CGSize(width: abs(displaySize.width),
                                height: abs(displaySize.height))
        let nominalFPS = try await track.load(.nominalFrameRate)
        let dataRate: Double = Double((try? await track.load(.estimatedDataRate)) ?? 0)
        let fmts: [CMFormatDescription] = (try? await track.load(.formatDescriptions)) ?? []
        let subType = fmts.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
        // QuickTime-style 'depth' extension is BITS PER PIXEL, not bits per
        // component: 24 (or 32 with alpha) means 8 bpc, ≥30 means 10 bpc.
        // Plain `>= 10` would classify every ordinary 8-bit file (depth 24)
        // as 10-bit. Files without the extension fall back to the transfer
        // function: HLG/PQ sources are always 10-bit pipelines.
        let tags = await ColorTags.from(track: track)
        let rawDepth = (fmts.first
            .flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_Depth) as? NSNumber }?
            .intValue) ?? 0
        let bitDepth = rawDepth >= 30 ? 10 : (tags.isHDR ? 10 : 8)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioRate = 0.0
        if let audio = audioTracks.first {
            audioRate = Double((try? await audio.load(.estimatedDataRate)) ?? 0)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0

        // Caveat: `naturalSize` already reflects rotation for modern sources;
        // the decoder's appliesPreferredTrackTransform handles the rest.
        return ProbeResult(
            duration: CMTimeGetSeconds(durationTime),
            sourceSize: sourceSize,   // display (post-rotation) size
            nominalFPS: nominalFPS > 0 ? nominalFPS : 30,
            codecSubType: subType,
            bitDepth: bitDepth,
            preferredTransform: preferredTransform,
            isRotated: !preferredTransform.isIdentity,
            tags: tags,
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
