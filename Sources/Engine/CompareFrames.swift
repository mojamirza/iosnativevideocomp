import AVFoundation
import UIKit

/// N10: matched BEFORE/AFTER frame capture for the persisted wipe compare.
/// The Compare feature was nearly unreachable: the player's Source/Output
/// toggle needs both FILES, but done jobs delete their import copy the
/// moment they finish — only failed rows in the same session could ever
/// compare. This capture runs in run()'s success path BEFORE
/// deleteSourceImport, freezing one matched scene pair as small JPEGs that
/// live on the JobRecord: the wipe slider then works on every done row,
/// after relaunch, with the source long gone.
enum CompareFrames {

    /// One frame from the SOURCE and one from the OUTPUT of the SAME
    /// scene, timeline-mapped exactly like the verifier (output t ==
    /// source trimStart + startOffset + the same fraction of the trimmed
    /// duration — QualityCheck's anchor-corrected alignment). The frame is
    /// sampled at 35% of the trimmed timeline: mid-scene beats t = 0
    /// (fades, black lead-ins, unstable first frames).
    /// nil when either frame fails — the compare UI simply doesn't show,
    /// the encode result is never affected.
    static func capture(source: URL, output: URL, plan: OptimizerPlan) -> (before: Data, after: Data)? {
        let fraction = 0.35
        let duration = plan.duration > 0.5 ? plan.duration : plan.source.duration
        let srcTime = plan.trimStart + plan.source.startOffset + fraction * duration
        let outTime = fraction * duration
        guard let before = frame(at: srcTime, from: source),
              let after = frame(at: outTime, from: output) else { return nil }
        return (before, after)
    }

    /// JPEG ≤1024px (the poster-normalization budget: ~200 KB, fine for
    /// external storage). appliesPreferredTrackTransform bakes rotation —
    /// the before/after pair is orientation-true like the player views.
    private static func frame(at seconds: Double, from url: URL) -> Data? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1024, height: 1024)
        // Frame-exact: a ±2 s tolerance can land on a different scene in a
        // hard-cut edit, which would make the comparison lie.
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard let (cgImage, _) = try? gen.image(at: time) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8)
    }
}
