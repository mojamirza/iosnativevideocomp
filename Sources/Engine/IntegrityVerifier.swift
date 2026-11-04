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
            let want = src.resolved(
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
                if src.isHDR {
                    items.append(ReportItem("color", "Color metadata drifted",
                        detail.joined(separator: "\n"), .fail))
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

        // 5b. 10-bit depth preservation: an HDR/10-bit source MUST come out
        // as 10-bit HEVC. Main10 is explicitly requested now (see engine),
        // but verify, don't trust — parse the output's own hvcC atom; if
        // auto-negotiation ever picked Main (8-bit), the HDR chain broke.
        if probe.bitDepth >= 10 || probe.tags.isHDR {
            if let outTrack = videoTracks.first {
                let outFmts: [CMFormatDescription] = (try? await outTrack.load(.formatDescriptions)) ?? []
                let parsed = outFmts.first.flatMap { SampleDescription.depth(of: $0) }
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
        //     the output lands under it — the coordinator re-encodes once if
        //     the first pass drifted over; this check is the final word.
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
                let overMB = Double(fileSize - target) / 1_000_000.0
                items.append(ReportItem("target", "Target size exceeded",
                    String(format: "Output \(used) is %.1f MB over the guaranteed target even after the measured re-encode — the encoder's minimum practical rate for this content is too high to hit the size.", overMB), .fail))
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
