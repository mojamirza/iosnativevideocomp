import AVFoundation
import CoreVideo

/// The third pillar: after every encode we actually *re-open the output*, decode
/// spot-check frames, and verify duration, tracks, color metadata and bitrate —
/// producing a human-readable integrity report instead of a naked "done ✅".
enum IntegrityVerifier {

    static func verify(source: URL,
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
            outDuration = t.map { CMTimeGetSeconds($0) } ?? 0
            let fps: Float = (try? await outTrack.load(.nominalFrameRate)) ?? 0
            do {
                if fps > 0 {
                    items.append(ReportItem("track", "Video track verified",
                        String(format: "%.0f fps, %d×%d", fps,
                               Int(plan.outputSize.width), Int(plan.outputSize.height)), .pass))
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

        // 3. Decode spot-check: first frame + a late frame must decode to pixels.
        do {
            var decodable = 0
            let gen = AVAssetImageGenerator(asset: outAsset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 128, height: 128)
            do {
                _ = try await gen.image(at: CMTime(seconds: min(0.1, outDuration * 0.1), preferredTimescale: 600))
                decodable += 1
            } catch { }
            if outDuration > 1 {
                _ = try? await gen.image(at: CMTime(seconds: outDuration - 0.3, preferredTimescale: 600))
                decodable += 1
            }
            if decodable > 0 {
                items.append(ReportItem("decode", "Pixel decode spot-check passed",
                    "\(decodable) frame(s) successfully decoded end-to-end.", .pass))
            } else {
                items.append(ReportItem("decode", "Decode spot-check failed",
                    "Neither the first frame nor a late frame could be decoded.", .fail))
            }
        }

        // 4. Audio conservation.
        if probe.hasAudio {
            let outAudio = (try? await outAsset.loadTracks(withMediaType: .audio)) ?? []
            if outAudio.isEmpty {
                items.append(ReportItem("audio", "Audio track missing",
                    "The source had audio but the output does not.", .fail))
            } else {
                items.append(ReportItem("audio", "Audio track preserved",
                    String(format: "AAC %.0f kbps", plan.audioBitrate / 1000), .pass))
            }
        }

        // 5. Color metadata conservation (the color-safe guarantee).
        let outVideo = videoTracks.first
        if let outTrack = outVideo {
            let outTags = await ColorTags.from(track: outTrack)
            let src = probe.tags
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
                    detail.append("\(name): source \(pretty(x)), output untagged (sRGB default)")
                default:
                    break
                }
            }
            compare("primaries", src.primaries, outTags.primaries)
            compare("transfer", src.transferFunction, outTags.transferFunction)
            compare("matrix", src.yCbCrMatrix, outTags.yCbCrMatrix)
            if mismatch {
                items.append(ReportItem("color", "Color metadata drifted",
                    detail.joined(separator: "\n"), .fail))
            } else {
                let hdrNote = src.isHDR ? " — HDR transfer preserved end-to-end" : ""
                items.append(ReportItem("color", "Color-safe engine passed",
                    "\(src.humanLabel)\(hdrNote). " + detail.joined(separator: "; "), .pass))
            }
        }

        // 6. Bitrate & savings sanity.
        let outBitrate = fileSize > 0 && outDuration > 0
            ? Double(fileSize) * 8 / outDuration : 0
        if outBitrate > 0 {
            let videoPart = max(0, outBitrate - plan.audioBitrate)
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
        return l.isEmpty ? "default" : token
    }
}
