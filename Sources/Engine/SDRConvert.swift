import CoreImage
import CoreVideo
import AVFoundation

// =====================================================================
// REAL HDR → SDR CONVERSION — a deliberate, opt-in path ("Convert to
// SDR" in the editor). NOT a relabeling: every pixel is mathematically
// tone-mapped, primaries-converted and re-encoded.
//
// The pipeline per frame (10-bit HLG/PQ decode → 8-bit SDR encode):
//   1. The reader decodes to 10-bit YCbCr with the SOURCE's YCbCr matrix
//      attachment intact.
//   2. The engine STRIPS the buffer's transfer + primaries attachments —
//      those two drive Core Image's automatic color management, and this
//      converter must NOT let CI decode-and-re-encode the transfer itself
//      (double application is the classic washed-out failure).
//   3. A Core Image Metal kernel does ALL of the color math in explicit,
//      unit-tested steps:
//        · BT.2100 inverse OETF (HLG or PQ) → scene-linear
//        · BT.2020 → BT.709 primaries conversion (linear domain)
//        · exposure to diffuse-white-relative SDR linear
//        · BT.709 OETF re-encode
//   4. CI renders into the 8-bit YUV output buffer (709 matrix attached
//      for the pack step), and the engine re-attaches the full 709
//      triplet for the writer — the file's tags EXACTLY match the pixels.
//
// Highlight policy: content above SDR diffuse white multiplies past the
// encodable range and clips at the encode — the standard burn-in behavior
// of every SDR conversion — reported as such in the job's report.
// =====================================================================

enum HDRScheme {
    case hlg
    case pq

    /// From the source's transfer tag ("itu_r_2100_hlg" etc.).
    init?(transfer: String?) {
        let t = (transfer ?? "").lowercased()
        if t.contains("hlg") { self = .hlg }
        else if t.contains("pq") || t.contains("2084") { self = .pq }
        else { return nil }
    }
}

/// The PURE math — the single source of truth for the conversion. The same
/// formulas appear verbatim inside the Metal kernel (Core Image kernels
/// cannot call Swift); these functions are what the unit tests validate,
/// reference value by reference value.
enum SDRMath {

    /// HLG scene-linear of the 203-nit (SDR/HLG shared) diffuse white,
    /// computed from BT.2100: inverse-OETF(0.75) ≈ 0.26662 — 0.26662 × gain
    /// must land at 1.0, anchoring both systems' white points together.
    static let hlgDiffuseLinear = 0.2666
    /// Exposure applied to HLG scene-linear (1.0 = 1000-nit reference).
    static let hlgGain = 1.0 / 0.2666

    /// PQ is ABSOLUTE (Y ∈ [0,1] = luminance ∈ [0,10 000] nits): no mastered
    /// metadata is read (probe does not extract MaxCLL), so the widely used
    /// 10 000-nit nominal peak assumption applies and diffuse white lands
    /// at the same 203-nit anchor as HLG.
    static let pqGain = 10_000.0 / 203.0

    static let diffuseNits = 203.0

    /// BT.2100 HLG inverse OETF: E′ (0…1) → scene-linear E (1.0 ≈ 1000 nits
    /// system reference). Piecewise: E′ ≤ 0.5 quadratic, else exponential —
    /// the standard a/b/c constants of the spec.
    static func hlgToLinear(_ s: Double) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        if s <= 0.5 { return (s * s) / 3.0 }
        return (exp((s - c) / a) + b) / 12.0
    }

    /// SMPTE ST 2084 (PQ) inverse EOTF: E′ → Y, normalised to the 10 000-nit
    /// peak (1.0 = 10 000 nits). m1/m2/c1/c2/c3 are the standard constants.
    static func pqToLinear(_ s: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375
        let c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let E = pow(max(s, 0.0), m2)
        let num = max(E - c1, 0.0)
        let den = c2 - c3 * E
        guard den > 0 else { return 0 }
        return pow(num / den, 1.0 / m1)
    }

    /// Scene-linear (BT.2020 primaries) → scene-linear (BT.709 primaries),
    /// canonical linear-domain 3×3 (sums exactly 1.0 per row).
    static func bt2020To709(_ r: Double, _ g: Double, _ b: Double)
        -> (r: Double, g: Double, b: Double) {
        (
            1.6605 * r - 0.5876 * g - 0.0728 * b,
            -0.1246 * r + 1.1329 * g - 0.0083 * b,
            -0.0182 * r - 0.1006 * g + 1.1187 * b
        )
    }

    /// ITU-R BT.709 OETF encode (piecewise linear/0.45 power) — what the
    /// output file's `ITU_R_709_2` transfer tag PROMISES the bits are.
    static func encode709(_ v: Double) -> Double {
        if v <= 0.018 { return 4.5 * v }
        return 1.099 * pow(max(v, 0.0), 0.45) - 0.099
    }

    /// Full per-channel pipeline in one function (used by tests as the
    /// reference for the GPU kernel's output).
    static func convert(_ signal: Double, scheme: HDRScheme) -> Double {
        var lin: Double
        var gain: Double
        switch scheme {
        case .hlg:
            lin = hlgToLinear(signal)
            gain = hlgGain
        case .pq:
            lin = pqToLinear(signal)      // Y ∈ [0,1] = 10 000-nit normalised
            gain = pqGain
        }
        lin *= gain
        lin = min(lin, 4.0)               // highlight plateau (clips at encode)
        return encode709(lin)
    }
}

final class SDRConverter {

    /// Core Image Metal kernel (runtime-compiled; no .metal build file — the
    /// app target never needs Metal-specific build config). The formulas are
    /// VERBATIM mirrors of `SDRMath` — the kernel must never drift.
    static let kernelSource = """
    #include <CoreImage/CoreImage.h>

    extern "C" coreimage::float4 vidcompress_sdr(
            coreimage::sampler src, coreimage::float2 scale, float scheme, float gain) {
        coreimage::float2 sc = src.coord() * scale;
        coreimage::float3 s = sampleBilinear(src, sc).rgb;
        if (scheme < 0.5) {
            // BT.2100 HLG inverse OETF (piecewise; a/b/c = spec constants).
            float a = 0.17883277, b = 0.28466892, c = 0.55991073;
            float3 hi = (exp((s - c) / a) + b) / 12.0;
            float3 lo = (s * s) / 3.0;
            s = select(hi, lo, s <= 0.5);
        } else {
            // SMPTE ST 2084 PQ inverse EOTF → Y normalised to 10 000 nits.
            float m1 = 0.1593017578125, m2 = 78.84375;
            float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
            float3 E = powr(max(float3(0.0), s), float3(m2));
            float3 num = max(float3(0.0), E - float3(c1));
            float3 den = max(float3(c2) - float3(c3) * E, float3(1e-9));
            s = powr(num / den, float3(1.0 / m1));
        }
        // BT.2020 → BT.709 linear primaries conversion.
        float3 lin = float3(
            s.x * 1.6605 + s.y * (-0.5876) + s.z * (-0.0728),
            s.x * (-0.1246) + s.y * 1.1329 + s.z * (-0.0083),
            s.x * (-0.0182) + s.y * (-0.1006) + s.z * 1.1187);
        // Exposure to diffuse-white-relative SDR; plateau above white.
        lin *= float3(gain);
        lin = min(lin, float3(4.0));
        // BT.709 OETF re-encode (piecewise linear/0.45 power).
        float3 enc;
        enc.x = (lin.x <= 0.018) ? (4.5 * lin.x) : (1.099 * powr(max(lin.x, 0.0), 0.45) - 0.099);
        enc.y = (lin.y <= 0.018) ? (4.5 * lin.y) : (1.099 * powr(max(lin.y, 0.0), 0.45) - 0.099);
        enc.z = (lin.z <= 0.018) ? (4.5 * lin.z) : (1.099 * powr(max(lin.z, 0.0), 0.45) - 0.099);
        return float4(clamp(enc, 0.0, 1.0), 1.0);
    }
    """

    /// One lazily-built converter per process (kernel compile + GPU context
    /// are expensive; the encode pipeline is serialized anyway).
    static let shared: SDRConverter? = {
        guard let kernel = CIKernel(source: kernelSource) else { return nil }
        return SDRConverter(kernel: kernel)
    }()

    private let kernel: CIKernel
    private let context = CIContext(options: [.cacheIntermediates: false])

    private init(kernel: CIKernel) {
        self.kernel = kernel
    }

    /// Tone-map + (optionally) scale ONE frame into the 8-bit SDR
    /// destination buffer.
    ///
    /// Attachments are managed HERE so Core Image's automatic color
    /// management can never double-apply a transfer:
    ///   · SRC: transfer + primaries attachments are nulled out (the
    ///     `kCFNull` trick) — with no colorspace attached CI treats the
    ///     decoded pixels as raw values, leaving every transfer decision to
    ///     the kernel's explicit math. The YCbCr MATRIX stays: it is what
    ///     converts the planar YUV decode into RGB for the kernel.
    ///   · DST: only the Rec.709 YCbCr matrix is pre-attached, so CI's
    ///     RGB→YUV pack uses the same matrix the file will declare. The
    ///     engine re-attaches the FULL SDR triplet on this buffer after the
    ///     render (see CompressionEngine) so writer and pixels agree.
    func render(from src: CVImageBuffer, to dst: CVImageBuffer, scheme: HDRScheme) throws {
        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        let dstW = CVPixelBufferGetWidth(dst)
        let dstH = CVPixelBufferGetHeight(dst)
        guard srcW > 0, srcH > 0, dstW > 0, dstH > 0 else {
            throw NSError(domain: "VidCompress.sdr", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid buffer dimensions"])
        }

        // SRC: null the transfer + primaries attachments so Core Image's
        // automatic color management treats the decode as raw values — the
        // kernel owns every transfer decision. The YCbCr matrix stays: it
        // drives the planar-decode → RGB conversion the kernel consumes.
        CVBufferSetAttachment(src, kCVImageBufferColorPrimariesKey,
                              kCFNull as CFTypeRef, .shouldPropagate)
        CVBufferSetAttachment(src, kCVImageBufferTransferFunctionKey,
                              kCFNull as CFTypeRef, .shouldPropagate)
        // DST: pre-attach ONLY the Rec.709 YCbCr matrix, so the RGB→YUV
        // pack matches what the file will declare. Transfer/primaries stay
        // off — CI must not gamma-convert the kernel's 709-encoded output
        // on the way out (colorSpace: nil render, below).
        CVBufferSetAttachment(dst, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(dst, kCVImageBufferColorPrimariesKey,
                              kCFNull as CFTypeRef, .shouldPropagate)
        CVBufferSetAttachment(dst, kCVImageBufferTransferFunctionKey,
                              kCFNull as CFTypeRef, .shouldPropagate)

        // The kernel scales by sampling — no separate scale filter pass.
        let scaleX = Float(srcW) / Float(dstW)
        let scaleY = Float(srcH) / Float(dstH)
        let gain: Float = scheme == .hlg ? Float(SDRMath.hlgGain) : Float(SDRMath.pqGain)

        let image = CIImage(cvPixelBuffer: src)
        let outputExtent = CGRect(x: 0, y: 0, width: dstW, height: dstH)
        let srcExtent = CGRect(x: 0, y: 0, width: srcW, height: srcH)
        let mapped = kernel.apply(
            extent: outputExtent,
            roiCallback: { (_: Int32, _: CGRect) -> CGRect in srcExtent },
            arguments: [image,
                        NSNumber(value: scaleX), NSNumber(value: scaleY),
                        NSNumber(value: scheme == .hlg ? 0.0 : 1.0),
                        NSNumber(value: gain)])
        guard let mapped else {
            throw NSError(domain: "VidCompress.sdr", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "tone-map kernel produced no image"])
        }

        // colorSpace nil = pass-through: the kernel ALREADY encoded 709
        // signal values; CI must not gamma-convert them on the way out.
        context.render(mapped, to: dst,
                       bounds: outputExtent,
                       colorSpace: nil)
    }
}
