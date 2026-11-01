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

    // ------------------------------------------------------------------
    // THE one canonical colorimetry resolver (claim-hardening): used by
    // BOTH attach() and writerColorProperties(), so the two consumers can
    // never drift. The old code wrote ad-hoc lowercase literals
    // ("itu_r_709_2", "itu_r_2100_pq") — those are NOT valid constant
    // values: the SDK's constant VALUES are uppercase ("ITU_R_709_2"), and
    // PQ's canonical name is SMPTE_ST_2084_PQ ("itu_r_2100_pq" does not
    // exist at all). Feeding an invalid value to AVAssetWriterInput
    // raises an uncatchable Objective-C exception. Any token this file
    // carried is mapped onto a REAL constant; anything unrecognised falls
    // to the canonical default for its class.
    // ------------------------------------------------------------------

    /// (primaries, transferFunction, matrix) as canonical constant strings.
    /// The fallbacks: Rec.601 family for SD (≤720 px wide, matrix only —
    /// AVVideo has no 601 primaries/transfer constant), Rec.709 for HD,
    /// Rec.2020 + HLG/PQ for HDR. `displayWidth` is the SOURCE display
    /// width — colorimetry describes the content, not the output scale.
    func resolved(isHDR: Bool, displayWidth: Int)
        -> (primaries: String, transferFunction: String, yCbCrMatrix: String) {
        let t = (transferFunction ?? "").lowercased()
        let p = (primaries ?? "").lowercased()
        let m = (yCbCrMatrix ?? "").lowercased()
        let sd = displayWidth > 0 && displayWidth <= 720
        let carriedNothing = t.isEmpty && p.isEmpty && m.isEmpty

        // TRANSFER: HLG / PQ / HDR-fallback PQ / 709. (There is no "601"
        // transfer constant, so untagged SD keeps 709's transfer curve.)
        let tf: String
        if t.contains("hlg") { tf = "ITU_R_2100_HLG" }
        else if t.contains("pq") || t.contains("2084") { tf = "SMPTE_ST_2084_PQ" }
        else if isHDR { tf = "SMPTE_ST_2084_PQ" }
        else { tf = "ITU_R_709_2" }

        // PRIMARIES: 2020 for HDR or a carried 2020; otherwise 709 (the
        // only other primaries that every consumer accepts safely).
        let pri: String
        if p.contains("2020") || isHDR { pri = "ITU_R_2020" }
        else { pri = "ITU_R_709_2" }

        // MATRIX: 2020 for HDR; a carried 601/170-family stays 601_4; and
        // UNTAGGED SD sources default to 601_4 — the usual SD colorimetry.
        let mat: String
        if m.contains("2020") || isHDR { mat = "ITU_R_2020" }
        else if m.contains("601") || m.contains("170")
                 || (carriedNothing && sd) { mat = "ITU_R_601_4" }
        else { mat = "ITU_R_709_2" }

        return (pri, tf, mat)
    }

    /// (Re-)attach the source color tags to a pixel buffer BEFORE any scaling
    /// or rendering into it. The buffer's attachments drive how Core Video /
    /// VideoToolbox / Core Image interpret its content, so tagging late means
    /// the conversion already happened with wrong defaults.
    ///
    /// First the source's side-channel metadata is copied over (mastering
    /// display, content light level — otherwise the output HEVC loses those
    /// hints), then the three core tags are enforced from the RESOLVED
    /// canonical constants. The clean-aperture attachment is deliberately
    /// NOT copied: it holds ABSOLUTE pixel geometry, and a 1920×1080
    /// aperture copied onto an 854×480 buffer is simply wrong.
    static func attach(to buffer: CVImageBuffer, tags: ColorTags, from source: CVImageBuffer? = nil) {
        if let source, let dict = CVBufferGetAttachments(source, .shouldPropagate) as? [String: Any] {
            for (key, value) in dict {
                guard key != kCVImageBufferColorPrimariesKey as String,
                      key != kCVImageBufferTransferFunctionKey as String,
                      key != kCVImageBufferYCbCrMatrixKey as String,
                      key != kCVImageBufferCleanApertureKey as String,
                      let cfValue = value as CFTypeRef? else { continue }
                CVBufferSetAttachment(buffer, key as CFString, cfValue, .shouldPropagate)
            }
        }
        // Resolve ALL THREE tags through the canonical resolver — even when
        // the source file is missing some — using the SOURCE's display
        // width for the SD/HD decision (colorimetry follows the content).
        let sourceWidth = source.map { CVPixelBufferGetWidth($0) }
            ?? CVPixelBufferGetWidth(buffer)
        let r = tags.resolved(isHDR: tags.isHDR, displayWidth: sourceWidth)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              ColorCanon.cvPrimaries(r.primaries), .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              ColorCanon.cvTransfer(r.transferFunction), .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              ColorCanon.cvMatrix(r.yCbCrMatrix), .shouldPropagate)
    }

    /// Canonical strings → the SDK's real constants, in one table. The
    /// buffer path uses CoreVideo constants; the writer path uses the
    /// AVFoundation twins. Never a hand-typed literal value.
    enum ColorCanon {
        static func cvPrimaries(_ c: String) -> CFString {
            c.contains("2020") ? kCVImageBufferColorPrimaries_ITU_R_2020
                               : kCVImageBufferColorPrimaries_ITU_R_709_2
        }
        static func cvTransfer(_ c: String) -> CFString {
            if c.contains("HLG") { return kCVImageBufferTransferFunction_ITU_R_2100_HLG }
            if c.contains("2084") { return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ }
            return kCVImageBufferTransferFunction_ITU_R_709_2
        }
        static func cvMatrix(_ c: String) -> CFString {
            if c.contains("2020") { return kCVImageBufferYCbCrMatrix_ITU_R_2020 }
            if c.contains("601") { return kCVImageBufferYCbCrMatrix_ITU_R_601_4 }
            return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
        static func avPrimaries(_ c: String) -> String {
            c.contains("2020") ? AVVideoColorPrimaries_ITU_R_2020
                               : AVVideoColorPrimaries_ITU_R_709_2
        }
        static func avTransfer(_ c: String) -> String {
            if c.contains("HLG") { return AVVideoTransferFunction_ITU_R_2100_HLG }
            if c.contains("2084") { return AVVideoTransferFunction_SMPTE_ST_2084_PQ }
            return AVVideoTransferFunction_ITU_R_709_2
        }
        static func avMatrix(_ c: String) -> String {
            if c.contains("2020") { return AVVideoYCbCrMatrix_ITU_R_2020 }
            if c.contains("601") { return AVVideoYCbCrMatrix_ITU_R_601_4 }
            return AVVideoYCbCrMatrix_ITU_R_709_2
        }
    }

    /// AVAssetWriter settings so the muxed file carries the same tags as the
    /// source. ALL three keys are always provided — a partial dictionary is
    /// undefined behavior and can raise an uncatchable Objective-C exception
    /// — and every value is a REAL SDK constant resolved in one place (see
    /// `resolved`). `displayWidth` is the source display width (SD/HD rule).
    func writerColorProperties(displayWidth: Int) -> [String: Any] {
        let r = resolved(isHDR: isHDR, displayWidth: displayWidth)
        return [
            AVVideoColorPrimariesKey: ColorCanon.avPrimaries(r.primaries),
            AVVideoTransferFunctionKey: ColorCanon.avTransfer(r.transferFunction),
            AVVideoYCbCrMatrixKey: ColorCanon.avMatrix(r.yCbCrMatrix),
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
        // BIT DEPTH — hvcC atom FIRST: for HEVC the true bit depth lives in
        // the sample description (bitDepthLumaMinus8), not the generic
        // 'depth' tag. The old depth>=30 rule misfired: 32 is 8-bit + alpha
        // (would force 10-bit), and real 10-bit files can't be relied on to
        // report 30. Chain: hvcC parse → HDR transfer tags → 8.
        let bitDepth: Int
        if let d = fmts.first.flatMap({ SampleDescription.depth(of: $0) }) {
            bitDepth = d
        } else if tags.isHDR {
            bitDepth = 10
        } else {
            bitDepth = 8
        }

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

/// Reads bit depth out of the video sample description itself.
enum SampleDescription {

    /// True bits per component from an "hvcC" (HEVC) sample-description atom:
    /// bitDepthLumaMinus8 is a 3-bit field in byte 17 → 8/10/12. Returns nil
    /// when the atom is absent or unparseable (H.264, malformed data) —
    /// callers fall back to HDR tags, then 8.
    static func depth(of fmt: CMFormatDescription) -> Int? {
        guard let atoms = CMFormatDescriptionGetExtension(
                  fmt,
                  extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
                  as? [String: Any],
              let raw = atoms["hvcC"],
              let data = raw as? Data,
              data.count > 17 else { return nil }
        let minus8 = Int(data[data.startIndex + 17]) & 0x7
        return minus8 >= 1 && minus8 <= 4 ? minus8 + 8 : nil   // 10..12 bpc
    }
}

extension CGSize {
    var megapixels: Double { Double(width * height) / 1_000_000 }
}
