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

    /// SD classification — ONE rule used by attach() AND writerColorProperties()
    /// with the same SOURCE display dimensions, so the two consumers can never
    /// disagree. Covers 720×480 / 720×576 / 640×480 SD; excludes 720×1280
    /// portrait HD (which a width-only rule would misread as SD) and 854×480.
    static func isSD(width: Int, height: Int) -> Bool {
        max(width, height) <= 720 && min(width, height) <= 576
    }

    // ------------------------------------------------------------------
    // THE one canonical colorimetry resolver (claim-hardening): used by
    // BOTH attach() and writerColorProperties(), so the two consumers can
    // never drift. The old code wrote ad-hoc lowercase literals
    // ("itu_r_709_2", "itu_r_2100_pq") — those are NOT valid constant
    // values: the SDK's constant VALUES are uppercase ("ITU_R_709_2"), and
    // PQ's canonical name is SMPTE_ST_2084_PQ ("itu_r_2100_pq" does not
    // exist at all). Feeding an invalid value to AVAssetWriterInput
    // raises an uncatchable Objective-C exception. 
    //
    // PRESERVATION RULE: what the file carried is kept (mapped onto the
    // matching real constant) whenever one exists — P3, SMPTE-C, EBU and
    // 2020 primaries are NOT relabeled to 709, otherwise Display-P3
    // content shifts colour on every path. Only files carrying nothing
    // (or something unrecognised) fall to the canonical default for their
    // class: Rec.601 family for SD (matrix only — there IS a 601 primaries
    // constant family but no file ever carries it as "601 primaries"),
    // Rec.709 for HD, Rec.2020 + HLG/PQ for HDR.
    // ------------------------------------------------------------------

    /// (primaries, transferFunction, matrix) as canonical constant strings.
    /// `sd` is the shared SD classification (see isSD(width:height:)).
    func resolved(isHDR: Bool, sd: Bool)
        -> (primaries: String, transferFunction: String, yCbCrMatrix: String) {
        let t = (transferFunction ?? "").lowercased()
        let p = (primaries ?? "").lowercased()
        let m = (yCbCrMatrix ?? "").lowercased()
        let carriedNothing = t.isEmpty && p.isEmpty && m.isEmpty

        // TRANSFER: HLG / PQ / HDR-fallback PQ / 709. (There is no "601"
        // transfer constant, so untagged SD keeps 709's transfer curve —
        // visually indistinguishable from an sRGB 2.2 curve at these gamma
        // levels, and the verifier compares against this same resolution.)
        let tf: String
        if t.contains("hlg") { tf = "ITU_R_2100_HLG" }
        else if t.contains("pq") || t.contains("2084") { tf = "SMPTE_ST_2084_PQ" }
        else if isHDR { tf = "SMPTE_ST_2084_PQ" }
        else { tf = "ITU_R_709_2" }

        // PRIMARIES: PRESERVE what exists (2020 / P3 / SMPTE-C); 2020 only
        // for HDR-with-nothing; 709 otherwise. NOTE: EBU_3213 is intentionally
        // absent — the AVFoundation constant is unavailable on iOS, so EBU
        // sources resolve to 709 alongside every other unrecognised color
        // space (consumers must stay in step with what can be written).
        let pri: String
        if p.contains("2020") { pri = "ITU_R_2020" }
        else if p.contains("p3") { pri = "P3_D65" }
        else if p.contains("smpte_c") || p.contains("smptec") { pri = "SMPTE_C" }
        else if isHDR && p.isEmpty { pri = "ITU_R_2020" }
        else { pri = "ITU_R_709_2" }

        // MATRIX: preserve carried 601/170; 2020 for HDR; UNTAGGED SD
        // sources default to 601_4 — the usual SD colorimetry.
        let mat: String
        if m.contains("2020") || (isHDR && m.isEmpty) { mat = "ITU_R_2020" }
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
        // the source file is missing some — with the SD/HD decision from the
        // SAME inputs (source buffer geometry + shared isSD rule) as the
        // writer path, so the store/W/R paths can never disagree.
        let sw = source.map { CVPixelBufferGetWidth($0) }
            ?? CVPixelBufferGetWidth(buffer)
        let sh = source.map { CVPixelBufferGetHeight($0) }
            ?? CVPixelBufferGetHeight(buffer)
        let r = tags.resolved(isHDR: tags.isHDR,
                              sd: ColorTags.isSD(width: sw, height: sh))
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
            if c.contains("2020") { return kCVImageBufferColorPrimaries_ITU_R_2020 }
            if c.contains("P3") { return kCVImageBufferColorPrimaries_P3_D65 }
            if c.contains("SMPTE_C") { return kCVImageBufferColorPrimaries_SMPTE_C }
            return kCVImageBufferColorPrimaries_ITU_R_709_2
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
            if c.contains("2020") { return AVVideoColorPrimaries_ITU_R_2020 }
            if c.contains("P3") { return AVVideoColorPrimaries_P3_D65 }
            if c.contains("SMPTE_C") { return AVVideoColorPrimaries_SMPTE_C }
            return AVVideoColorPrimaries_ITU_R_709_2
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
    /// `resolved`). `sd` comes from the shared isSD rule on the SOURCE
    /// display size, the same inputs attach() uses.
    func writerColorProperties(sd: Bool) -> [String: Any] {
        let r = resolved(isHDR: isHDR, sd: sd)
        return [
            AVVideoColorPrimariesKey: ColorCanon.avPrimaries(r.primaries),
            AVVideoTransferFunctionKey: ColorCanon.avTransfer(r.transferFunction),
            AVVideoYCbCrMatrixKey: ColorCanon.avMatrix(r.yCbCrMatrix),
        ]
    }

    /// Human label from the RAW tags — case-insensitive (files may carry
    /// either case) and P3-aware (Display P3 tagged sources show as P3,
    /// not the "Rec.709 / sRGB" catch-all).
    var humanLabel: String {
        if isHDR {
            return (transferFunction ?? "").lowercased().contains("hlg")
                ? "HDR (HLG)" : "HDR (PQ / Dolby Vision)"
        }
        let p = (primaries ?? "").lowercased()
        switch p {
        case let x where x.contains("2020"):
            return "Rec.2020 SDR"
        case let x where x.contains("p3"):
            return "Display P3"
        case let x where x.contains("601") || x.contains("170") || x.contains("smpte_c"):
            return "SDTV (Rec.601/170)"
        default:
            return "Rec.709 / sRGB"
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
    /// The muxer-anchor seconds the probe SUBTRACTED from `duration`
    /// (SessionAnchor: the earliest track start, when above zero). The
    /// verifier adds it back to map an output timeline position onto the
    /// SOURCE's raw timeline — the engine anchors the session at the
    /// source's start, so the output's first frame sits at PTS ~0 and a
    /// clipped source must be sampled with this offset.
    var startOffset: Double = 0

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

        // EVERY-CONSUMER duration = asset duration MINUS the muxer anchor
        // (SessionAnchor, the same helper the engine uses): a trimmed/edited
        // clip whose tracks start at 1 s gets its lead trimmed at encode
        // time, so the plan's duration must describe the OUTPUT timeline —
        // otherwise the verifier's duration check fails on a good file.
        var sourceDuration = CMTimeGetSeconds(durationTime)
        var startOffset = 0.0
        if sourceDuration.isFinite, sourceDuration > 0 {
            let videoStart = ((try? await track.load(.timeRange))?.start) ?? .zero
            var audioStart: CMTime?
            if let aTrack = audioTracks.first {
                audioStart = (try? await aTrack.load(.timeRange))?.start
            }
            let offset = CMTimeGetSeconds(SessionAnchor.start(
                video: videoStart, audio: audioStart))
            if offset.isFinite, offset > 0 {
                sourceDuration = max(0.1, sourceDuration - offset)
                startOffset = offset
            }
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0

        // Caveat: `naturalSize` already reflects rotation for modern sources;
        // the decoder's appliesPreferredTrackTransform handles the rest.
        return ProbeResult(
            duration: sourceDuration,
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
            fileSize: size,
            startOffset: startOffset
        )
    }
}

/// Reads bit depth out of the video sample description itself.
enum SampleDescription {

    /// True bits per component from a sample-description atom. HEVC comes
    /// from "hvcC"; AVC (H.264) from "avcC" — without that branch every
    /// H.264/SDR output reported "depth could not be confirmed" and warned
    /// forever. AVC is nominally 8-bit; profile_idc 110/122/244 (Hi10P and
    /// friends) would claim 10, but the engine never emits them — Main
    /// Auto Level lands at 8.
    /// bitDepthLumaMinus8 is a 3-bit field in hvcC byte 17 → 8/10/12. minus8
    /// == 0 is plain Main (8-bit) — it MUST be reported, not nil: the
    /// verifier's "HDR source flattened to 8-bit" case depends on knowing
    /// the truth. Returns nil only when the atom is absent/unparseable
    /// (bad data).
    static func depth(of fmt: CMFormatDescription) -> Int? {
        guard let atoms = CMFormatDescriptionGetExtension(
                  fmt,
                  extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
                  as? [String: Any] else { return nil }
        if let raw = atoms["hvcC"] as? Data, raw.count > 17 {
            let minus8 = Int(raw[raw.startIndex + 17]) & 0x7
            return minus8 <= 4 ? minus8 + 8 : nil
        }
        if let avcC = atoms["avcC"] as? Data, avcC.count > 1 {
            let profile = Int(avcC[avcC.startIndex + 1])
            return [110, 122, 244].contains(profile) ? 10 : 8
        }
        return nil
    }
}

/// Muxer anchor shared by the ENGINE and the PROBE (one helper — the two
/// consumers must agree by construction): the earliest track start above
/// zero. Any track starting at/below zero anchors everything to 0 so no
/// sample can append "before the session". The probe subtracts this offset
/// from its duration so plan.duration matches the OUTPUT's timeline —
/// otherwise the verifier fails a good trimmed clip's duration check.
enum SessionAnchor {
    /// The muxer anchor = the MINIMUM of both track starts, each clamped to
    /// at least zero. Earlier logic regressed: a video start of 0 was read
    /// as "no video anchor", so an audio starting at 0.5 s became the anchor
    /// and the video's PTS-0 frames fell before the session (trimmed) — the
    /// probe also subtracted that phantom offset from its duration.
    /// video 0 + audio 0.5 → 0 · video 1 + audio 0.5 → 0.5 · video 1 + audio
    /// nil → 1.
    static func start(video: CMTime, audio: CMTime?) -> CMTime {
        func pos(_ t: CMTime) -> CMTime {
            (t.isNumeric && t.seconds.isFinite && t.seconds > 0) ? t : .zero
        }
        let v = pos(video)
        guard let a = audio else { return v }
        return CMTimeMinimum(v, pos(a))
    }
}

extension CGSize {
    var megapixels: Double { Double(width * height) / 1_000_000 }
}
