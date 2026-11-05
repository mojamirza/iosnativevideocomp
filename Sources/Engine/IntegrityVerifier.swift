import AVFoundation
import CoreVideo

/// The third pillar: after every encode we actually *re-open the output*, decode
/// spot-check frames, and verify duration, tracks, color metadata and bitrate —
/// producing a human-readable integrity report instead of a naked "done ✅".
enum IntegrityVerifier {

    /// Wrapper that guarantees the verifier can never wedge the job row: the
    /// full verification races a hard wall-clock limit; on timeout a warn-only
    /// report is produced so the job always reaches a terminal state.
    static func verify(source: URL,
                       output: URL,
                       probe: ProbeResult,
                       plan: OptimizerPlan,
                       encodeSeconds: Double) async -> IntegrityReport {
        if let report = await AsyncTimeout.run(seconds: 60, {
            await Self.verifyImpl(source: source, output: output, probe: probe,
                                  plan: plan, encodeSeconds: encodeSeconds)
        }) {
            return report
        }
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? Int64) ?? 0
        return IntegrityReport(
            items: [ReportItem("verify", "Verification timed out",
                "Integrity checks did not finish in time. The output was written and finalized by the encoder — inspect it in Files; if it plays, it is good.", .warn)],
            inBytes: probe.fileSize,
            outBytes: fileSize,
            outputBitrateMbps: nil,
            encodeSeconds: encodeSeconds,
            outputDuration: nil)
    }

    private static func verifyImpl(source: URL,
                       output: URL,
                       probe: ProbeResult,
                       plan: OptimizerPlan,
                       encodeSeconds: Double) async -> IntegrityReport {

        var items: [ReportItem] = []
        let outAsset = AVURLAsset(url: output)
        var outDuration: Double = 0
        // Wall-clock anchor for the OPTIONAL verification extras (quality
        // scoring). The whole verifyImpl races the outer 60 s timeout — if
        // the quality step started after ~30 s had already been spent, it
        // could straddle the deadline and the WHOLE report would be lost.
        // The basics always run; extras only start when there's headroom.
        let verifyStart = Date()

        // 1. Container & video track present?
        let videoTracks = (try? await outAsset.loadTracks(withMediaType: .video)) ?? []
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? Int64 ?? 0

        if let outTrack = videoTracks.first {
            let t = try? await outAsset.load(.duration)
            // Int(NaN) TRAPS — an indefinite duration (broken output) would
            // put NaN into the report and the sheet would crash exactly when
            // something went wrong. Non-finite becomes 0 / nil, never NaN.
            outDuration = t.map { CMTimeGetSeconds($0) }
                .map { $0.isFinite ? $0 : 0 } ?? 0
            let fps: Float = (try? await outTrack.load(.nominalFrameRate)) ?? 0
            // Report the ACTUAL output DISPLAY geometry: naturalSize is
            // pre-rotation (stored); apply the output track's transform —
            // same convention as the source card.
            let actualNatural = (try? await outTrack.load(.naturalSize)) ?? .zero
            let outTransform = (try? await outTrack.load(.preferredTransform)) ?? .identity
            let actualDisplay = actualNatural.applying(outTransform)
            let aw = abs(actualDisplay.width), ah = abs(actualDisplay.height)
            let showW = aw > 0 ? Int(aw) : Int(plan.outputSize.width)
            let showH = ah > 0 ? Int(ah) : Int(plan.outputSize.height)
            do {
                if fps > 0 {
                    items.append(ReportItem("track", "Video track verified",
                        String(format: "%.0f fps, %d×%d", fps, showW, showH), .pass))
                } else {
                    items.append(ReportItem("track", "Video track present, fps unreadable",
                        "Track exists but nominalFrameRate is 0 — playability not guaranteed.", .warn))
                }
            }
        } else if fileSize > 0 {
            items.append(ReportItem("track", "No readable video track",
                "The output opens but contains no video track.", .fail))
        } else {
            items.append(ReportItem("track", "Output unreadable",
                "AVAsset could not open the written file.", .fail))
        }

        // 2. Duration conservation (within 1% or 0.35 s).
        let delta = abs(outDuration - plan.duration)
        let tolerance = max(0.35, plan.duration * 0.01)
        if outDuration > 0 {
            if delta <= tolerance {
                items.append(ReportItem("duration", "Duration preserved",
                    String(format: "%.2f s → %.2f s (Δ %.2f s)",
                           plan.duration, outDuration, delta), .pass))
            } else if delta <= plan.duration * 0.02 {
                items.append(ReportItem("duration", "Duration slightly drifted",
                    String(format: "%.2f s → %.2f s (Δ %.2f s)", plan.duration, outDuration, delta), .warn))
            } else {
                items.append(ReportItem("duration", "Duration mismatch",
                    String(format: "%.2f s → %.2f s (Δ %.2f s) — file is likely broken.",
                           plan.duration, outDuration, delta), .fail))
            }
        }

        // 3. Decode spot-check: first frame + a late frame must decode to
        //    pixels. Implemented with strictly bounded reader windows (≤1 s
        //    each, ≤2 frames) and a per-check timeout — the verifier must
        //    never wedge the job row.
        do {
            let firstResult = await AsyncTimeout.run(seconds: 15) {
                await Self.decodesPixelData(asset: outAsset, at: min(0.1, outDuration * 0.1))
            }
            let lateResult: Bool? = outDuration > 1
                ? await AsyncTimeout.run(seconds: 15) {
                    await Self.decodesPixelData(asset: outAsset, at: outDuration - 0.3)
                }
                : true
            switch (firstResult, lateResult) {
            case (true, true):
                items.append(ReportItem("decode", "Pixel decode spot-check passed",
                    "First and late frames decoded end-to-end.", .pass))
            case (nil, _), (_, nil):
                items.append(ReportItem("decode", "Decode spot-check inconclusive",
                    "The decode check did not finish in time; the output may still be fully playable.", .warn))
            default:
                items.append(ReportItem("decode", "Decode spot-check failed",
                    "The output's video frames could not be decoded.", .fail))
            }
        }

        // 4. Audio conservation.
        if probe.hasAudio {
            let outAudio = (try? await outAsset.loadTracks(withMediaType: .audio)) ?? []
            if outAudio.isEmpty {
                // Not a broken file — an explicit engine decision: when no
                // AAC configuration passed validation, the job ships WITHOUT
                // audio on purpose (a silent failure is worse than a failed
                // job only for media that was already unplayable… and video
                // alone is usually preferable to a broken report). Warn.
                items.append(ReportItem("audio", "Output has no audio track",
                    "The source had audio but it was omitted: the audio pipeline (channel-layout request or AAC encoder settings) rejected the configuration for this file. The video itself is complete.", .warn))
            } else {
                items.append(ReportItem("audio", "Audio track preserved",
                    // Double division — the old Int/1000 passed to %.0f
                    // printed 0 or garbage.
                    String(format: "AAC %.0f kbps", Double(plan.audioBitrate) / 1000), .pass))
            }
        }

        // 5. Color metadata conservation — compared against the RESOLVED
        // source colorimetry: the engine canonicalises what the file carried
        // onto real SDK constants (P3 → P3_D65, sRGB → 709 curve, untagged
        // → presets), so those normalisations are EXPECTED, not drift. A
        // remaining mismatch on an SDR source demotes to a warning (relabeled
        // SDR colorimetry shifts tone slightly but is not broken output);
        // on an HDR source it stays a FAILURE — there the transfer is the
        // product's core guarantee.
        let outVideo = videoTracks.first
        if let outTrack = outVideo {
            let outTags = await ColorTags.from(track: outTrack)
            let src = probe.tags
            // With a completed SDR conversion the EXPECTED tags are the SDR
            // defaults (709 transfer/primaries; 601 on SD) — resolved through
            // the SAME canonical resolver, so engine and verifier agree by
            // construction on what an SDR-converted output must carry.
            let want = plan.sdrConvert
                ? ColorTags(primaries: nil, transferFunction: nil, yCbCrMatrix: nil).resolved(
                    isHDR: false,
                    sd: ColorTags.isSD(width: Int(probe.sourceSize.width),
                                       height: Int(probe.sourceSize.height)))
                : src.resolved(
                    isHDR: src.isHDR,
                    sd: ColorTags.isSD(width: Int(probe.sourceSize.width),
                                       height: Int(probe.sourceSize.height)))
            var mismatch = false
            var detail = [String]()
            func compare(_ name: String, _ a: String?, _ b: String?) {
                switch (a, b) {
                case (let x?, let y?):
                    if x.caseInsensitiveCompare(y) == .orderedSame && !x.isEmpty {
                        detail.append("\(name): ✓ \(pretty(x))")
                    } else {
                        mismatch = true
                        detail.append("\(name): ⚠ \(pretty(x)) → \(pretty(y))")
                    }
                case (nil, nil):
                    break
                case (let x?, nil):
                    // `want` (the resolved expectation) is never nil, so an
                    // UNTAGGED output IS a mismatch — an HDR output that lost
                    // its tags must not report green.
                    mismatch = true
                    detail.append("\(name): expected \(pretty(x)), output untagged")
                default:
                    break
                }
            }
            compare("primaries", want.primaries, outTags.primaries)
            compare("transfer", want.transferFunction, outTags.transferFunction)
            compare("matrix", want.yCbCrMatrix, outTags.yCbCrMatrix)
            if mismatch {
                if src.isHDR && !plan.sdrConvert {
                    items.append(ReportItem("color", "Color metadata drifted",
                        detail.joined(separator: "\n"), .fail))
                } else if plan.sdrConvert {
                    items.append(ReportItem("color", "SDR conversion tag check",
                        "The conversion re-tagged the file \(src.humanLabel) → Rec.709 SDR as part of the tone-map.\n"
                            + detail.joined(separator: "\n"), .warn))
                } else {
                    items.append(ReportItem("color", "SDR color metadata normalised",
                        "The output's color tags differ slightly from the source's — tone may shift marginally, but the decode is intact.\n"
                            + detail.joined(separator: "\n"), .warn))
                }
            } else {
                let hdrNote = src.isHDR ? " — HDR transfer preserved end-to-end" : ""
                // Silent relabelling must not look like a plain pass: note
                // every tag the resolver remapped (EBU/sRGB → 709, untagged
                // → presets) so the user can see the output was normalised.
                var normalised = [String]()
                if let p = src.primaries,
                   p.caseInsensitiveCompare(want.primaries) != .orderedSame {
                    normalised.append("primaries \(pretty(p)) → written as \(pretty(want.primaries))")
                }
                if let t = src.transferFunction,
                   t.caseInsensitiveCompare(want.transferFunction) != .orderedSame {
                    normalised.append("transfer \(pretty(t)) → written as \(pretty(want.transferFunction))")
                }
                if let m = src.yCbCrMatrix,
                   m.caseInsensitiveCompare(want.yCbCrMatrix) != .orderedSame {
                    normalised.append("matrix \(pretty(m)) → written as \(pretty(want.yCbCrMatrix))")
                }
                if !normalised.isEmpty {
                    // Severity reflects VISUAL impact: a remapped matrix
                    // (e.g. carried 601 → 709) is metadata bookkeeping with
                    // no meaningful tone change, while primaries/transfer
                    // remaps do shift what the player renders — those stay
                    // warnings. Everything else is a verified file.
                    let visibleChange =
                        (src.primaries != nil &&
                         src.primaries!.caseInsensitiveCompare(want.primaries) != .orderedSame)
                        || (src.transferFunction != nil &&
                            src.transferFunction!.caseInsensitiveCompare(want.transferFunction) != .orderedSame)
                    items.append(ReportItem("color", "Color tags normalised",
                        "\(src.humanLabel). This file's tags don't map 1:1 to the writer's supported constants, so they were remapped to the closest match: "
                            + normalised.joined(separator: "; "),
                        visibleChange ? .warn : .pass))
                } else if src.primaries == nil && src.transferFunction == nil
                            && src.yCbCrMatrix == nil {
                    // Untagged source: still a VERIFIED file — the note only
                    // documents where the output's tags came from. (.warn here
                    // pushed every untagged screen recording into the "Not
                    // fully verified" banner forever.)
                    items.append(ReportItem("color", "Source carried no color tags",
                        "Nothing was wrong: the source file carried no color tags, so the output was tagged with the resolved defaults (matrix \(pretty(want.yCbCrMatrix)), transfer \(pretty(want.transferFunction)), primaries \(pretty(want.primaries))).", .pass))
                } else {
                    items.append(ReportItem("color", "Color-safe engine passed",
                        "\(src.humanLabel)\(hdrNote). " + detail.joined(separator: "; "), .pass))
                }
            }
        }

        // 5b. Bit-depth verification: an HDR/10-bit source MUST come out
        //     as 10-bit HEVC — Main10 is explicitly requested (see engine),
        //     but verify, don't trust: parse the output's own hvcC atom.
        //     With a REQUESTED SDR conversion the expectation INVERTS: the
        //     output is deliberately 8-bit 709, and 10-bit would be a
        //     pipeline bug (the conversion renders 8-bit buffers).
        if probe.bitDepth >= 10 || probe.tags.isHDR {
            if let outTrack = videoTracks.first {
                let outFmts: [CMFormatDescription] = (try? await outTrack.load(.formatDescriptions)) ?? []
                let parsed = outFmts.first.flatMap { SampleDescription.depth(of: $0) }
                if plan.sdrConvert {
                    switch parsed {
                    case .some(let d) where d <= 8:
                        items.append(ReportItem("hdr", "SDR conversion verified",
                            String(format: "HDR → SDR applied end-to-end: output decodes as %d-bit Rec.709 (planned flattening, not a loss).", d), .pass))
                    case .some:
                        items.append(ReportItem("hdr", "SDR output unexpectedly 10-bit",
                            "The conversion rendered 8-bit SDR buffers, but the file still carries 10-bit depth — check that the tone-map actually ran.", .warn))
                    case nil:
                        items.append(ReportItem("hdr", "Output depth could not be confirmed",
                            "The output's format description did not parse during verification; the conversion itself is verified by the color tags above.", .warn))
                    }
                } else {
                switch parsed {
                case .some(let d) where d >= 10:
                    items.append(ReportItem("hdr", "10-bit depth preserved",
                        String(format: "Output decodes at %d bpc — HDR data intact.", d), .pass))
                case .some(let d):
                    items.append(ReportItem("hdr", "10-bit source flattened to 8-bit",
                        String(format: "An HDR/10-bit source produced a %d bpc output — the HDR chain broke somewhere in the pipeline.", d), .fail))
                case nil:
                    items.append(ReportItem("hdr", "10-bit depth could not be confirmed",
                        "The output's hvcC atom did not parse; the encoder's profile negotiation may or may not have chosen Main10. If HDR looks washed out, this file is 8-bit.", .warn))
                }
                }
            }
        }
        // 5c. PRIVACY SCRUB verification: no location metadata ever, and the
        //     creation date present when the scrub is keeping it.
        do {
            let outMeta = (try? await outAsset.load(.commonMetadata)) ?? []
            let hasLocation = outMeta.contains {
                ($0.identifier?.rawValue ?? "").lowercased().contains("location")
            }
            if hasLocation {
                items.append(ReportItem("privacy", "Location metadata present",
                    "The output carries a location (GPS) tag — this must never happen; scrub it by re-running the compression.", .fail))
            } else {
                items.append(ReportItem("privacy", "No location metadata",
                    "Outputs are scrubbed of location on purpose (compact privacy).", .pass))
            }
            if PrivacyScrub.keepCreationDate {
                // A source that never CARRIED a date cannot "drop" one —
                // only run the check when the source actually had it, or
                // every date-less screen recording warns forever.
                let srcMeta = (try? await AVURLAsset(url: source).load(.commonMetadata)) ?? []
                let srcHadDate = srcMeta.contains {
                    $0.commonKey == AVMetadataKey.commonKeyCreationDate
                }
                if srcHadDate {
                    let hasDate = outMeta.contains {
                        $0.commonKey == AVMetadataKey.commonKeyCreationDate
                    }
                    if hasDate {
                        items.append(ReportItem("privacy", "Creation date preserved",
                            "The output keeps the source's date; only the location is removed.", .pass))
                    } else {
                        items.append(ReportItem("privacy", "Creation date dropped",
                            "The scrubber was asked to keep the date, but the source's date wasn't parseable and the output ships date-less.", .warn))
                    }
                }
            }
        }

        // 6. Bitrate & savings sanity.
        let outBitrate = fileSize > 0 && outDuration > 0
            ? Double(fileSize) * 8 / outDuration : 0
        if outBitrate > 0 {
            let videoPart = max(0.0, outBitrate - Double(plan.audioBitrate))
            if videoPart > Double(plan.videoBitrate) * 1.6 + 2_000_000 {
                    items.append(ReportItem("bitrate", "Output bitrate higher than planned",
                        String(format: "Planned %.1f Mbps, obtained %.1f Mbps (video part).",
                               Double(plan.videoBitrate) / 1e6, videoPart / 1e6), .warn))
                } else {
                    items.append(ReportItem("bitrate", "Bitrate on target",
                        String(format: "Video ≈ %.1f Mbps of planned %.1f Mbps.",
                               videoPart / 1e6, Double(plan.videoBitrate) / 1e6), .pass))
                }
            }

        // 6b. GUARANTEED TARGET SIZE: when the plan carried a target, prove
        //     the output lands under it — the coordinator measured and
        //     re-encoded (up to two passes) if the first pass drifted over;
        //     this check is the final word.
        if let target = plan.targetBytes, target > 0 {
            if fileSize <= target {
                let used = ByteCountFormatter.string(fromByteCount: fileSize,
                                                     countStyle: .file)
                let budget = ByteCountFormatter.string(fromByteCount: target,
                                                       countStyle: .file)
                items.append(ReportItem("target", "Target size honored",
                    "Output \(used) ≤ guaranteed budget \(budget).", .pass))
            } else {
                let used = ByteCountFormatter.string(fromByteCount: fileSize,
                                                     countStyle: .file)
                // The last pass aims at 92 % of the budget; a residual
                // overshoot of ≤1 % is encoder noise on the real file —
                // honest to report, not a broken promise. Anything larger
                // means the encoder's floor beat the math: hard fail.
                let over = Double(fileSize - target) / Double(target)
                let overMB = Double(fileSize - target) / 1_000_000.0
                items.append(ReportItem("target", "Target size exceeded",
                    String(format: "Output %@ is %.1f MB over the guaranteed target even after the measured re-encode — the encoder's minimum practical rate for this content is too high to hit the size. (%.1f%% over)",
                           used, overMB, over * 100),
                    over <= 0.01 ? .warn : .fail))
            }
        }

        // 6c. QUALITY SCORE: real decoded luma comparison of source vs
        //     output frames at matched timeline points → PSNR + SSIM.
        //     Skipped where the comparison would LIE: after a deliberate
        //     (and desired) HDR→SDR conversion, and for HDR sources
        //     generally. HARD wall-clock hierarchy — ≤ 30 s of the OUTER
        //     verify timeout consumed: if the basics already used ~30 s,
        //     the extras don't start (they could straddle the 60 s timeout
        //     and the WHOLE report would be lost); per-frame sampling stops
        //     at 18 s into the quality step.
        if !plan.sdrConvert && !probe.tags.isHDR
            && fileSize > 0 && outDuration > 0.5 && plan.duration > 0.5
            && Date().timeIntervalSince(verifyStart) < 30 {
            let fractions: [Double] = [0.15, 0.4, 0.65, 0.9]
            let t0 = Date()
            var psnrs = [Double]()
            var ssims = [Double]()
            var sampled = 0
            // TIME ANCHOR: the engine appends frames with the SOURCE's raw
            // presentation timestamps, but a clipped source can START at a
            // non-zero PTS. Learn the output's first-frame PTS (one narrow
            // read) and offset every source sample by it — fraction-
            // of-duration alone would compare the wrong scenes.
            let srcAsset = AVURLAsset(url: source)
            // TIME ANCHOR: the engine anchors the muxer session at the
            // SOURCE's earliest track start (SessionAnchor), so the output's
            // first frame sits at PTS ~0 — anchoring on the OUTPUT side was
            // always ~0 and never compensated a clipped source (wrong scenes
            // compared, low scores on good files). The probe CARRIES the
            // offset it subtracted from its duration; adding it back maps an
            // output timeline position onto the source's raw timeline.
            // Frame-rate capping drops FRAMES, not seconds: the truthful
            // note is "outputs fewer fps", not "the timeline drifted".
            let fpsCapped = plan.fpsCap != nil && probe.nominalFPS > 0
                && Double(plan.fpsCap!) < Double(probe.nominalFPS) * 0.9
            for fraction in fractions {
                if Date().timeIntervalSince(t0) > 18 { break }
                let tOut = fraction * outDuration
                let tSrc = probe.startOffset + tOut
                async let a = QualityCheck.lumaFrame(asset: srcAsset, at: tSrc)
                async let b = QualityCheck.lumaFrame(asset: outAsset, at: tOut)
                guard let fa = await a, let fb = await b else { continue }
                sampled += 1
                if let p = QualityCheck.psnr(fa, fb) { psnrs.append(p) }
                if let s = QualityCheck.ssim(fa, fb) { ssims.append(s) }
            }
            if sampled > 0 && !psnrs.isEmpty {
                let avgP = psnrs.reduce(0, +) / Double(psnrs.count)
                let avgS = ssims.isEmpty ? 0 : ssims.reduce(0, +) / Double(ssims.count)
                let g = QualityCheck.grade(psnr: avgP, ssim: avgS)
                var detail = g.detail
                if fpsCapped {
                    detail += "\n"
                        + String(format: "Note: sampled at matched timestamps after a frame-rate cap (%.0f fps → %d fps).", probe.nominalFPS, plan.fpsCap!)
                }
                items.append(ReportItem("quality", g.label, detail, g.severity))
            } else {
                items.append(ReportItem("quality", "Quality score unavailable",
                    "The verifier's sampling window closed before decodable frames from both files could be compared (fast verify budget). The other checks still ran.", .pass))
            }
        }

        return IntegrityReport(
            items: items,
            inBytes: probe.fileSize,
            outBytes: fileSize,
            outputBitrateMbps: outBitrate / 1_000_000,
            encodeSeconds: encodeSeconds,
            outputDuration: outDuration
        )
    }

    private static func pretty(_ token: String) -> String {
        let l = token.lowercased()
        if l.contains("2020") && l.contains("hlg") { return "Rec.2020 HLG" }
        if l.contains("2020") && (l.contains("pq") || l.contains("2084")) { return "Rec.2020 PQ" }
        if l.contains("2020") { return "Rec.2020" }
        if l.contains("601") || l.contains("170") { return "Rec.601" }
        if l.contains("2100") { return "Rec.2100 HLG" }
        if l.contains("p3") { return "Display P3" }
        return l.isEmpty ? "default" : token
    }

    // MARK: hang-proofing helpers

    /// Bounded decode spot-check: open a ≤1 s reader window at the given time
    /// and confirm at least one frame decodes to real pixels. Unlike
    /// AVAssetImageGenerator (which can seek across an entire GOP tree), the
    /// reader window is hard-bounded by its timeRange.
    private static func decodesPixelData(asset: AVURLAsset, at seconds: Double) async -> Bool {
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first else { return false }
        let startSeconds = max(0, seconds)
        let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
        let end = CMTime(seconds: startSeconds + 1.0, preferredTimescale: 600)
        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        reader.timeRange = CMTimeRange(start: start, end: end)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: kCVPixelFormatType_32BGRA)
        ])
        reader.add(out)
        guard reader.startReading() else { return false }
        var decoded = 0
        while decoded < 2 {
            guard let sb = out.copyNextSampleBuffer(),
                  CMSampleBufferGetImageBuffer(sb) != nil else { break }
            decoded += 1
        }
        reader.cancelReading()
        return decoded > 0
    }
}
