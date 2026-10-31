import Foundation

/// Severity of a single line of the Output Integrity Report.
enum ReportSeverity: String, Codable, Hashable {
    case pass, warn, fail

    var symbol: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }
}

/// One check in the Output Integrity Report.
struct ReportItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
    var severity: ReportSeverity

    init(_ id: String, _ title: String, _ detail: String, _ severity: ReportSeverity) {
        self.id = id
        self.title = title
        self.detail = detail
        self.severity = severity
    }
}

/// The Output Integrity Report produced after every encode.
///
/// JSON-compat note: this struct is persisted in SwiftData records (reportJSON).
/// New fields are OPTIONAL and decoded with decodeIfPresent — adding a
/// non-optional field would make every existing record's stored report fail
/// to decode. schemaVersion distinguishes report generations.
struct IntegrityReport: Codable, Hashable {
    var schemaVersion: Int          // legacy reports decode to 0
    var items: [ReportItem]
    var inBytes: Int64
    var outBytes: Int64
    var outputBitrateMbps: Double?  // nil while unknown (e.g. verification timed out)
    var encodeSeconds: Double
    var outputDuration: Double?     // nil while unknown

    /// Three-state verdict. Warnings (timed-out verification, inconclusive
    /// decode checks) are NOT success: they surface as "not fully verified",
    /// visibly distinct from a green verified result. An EMPTY report has
    /// verified nothing and must never read as a pass.
    enum VerificationStatus: Hashable {
        case verified, warnings, failed
    }
    var status: VerificationStatus {
        if items.isEmpty { return .warnings }
        if items.contains(where: { $0.severity == .fail }) { return .failed }
        if items.contains(where: { $0.severity == .warn }) { return .warnings }
        return .verified
    }

    /// Kept for a compact UI check; warn-only reports are NOT a pass.
    var passed: Bool { status == .verified }

    /// Signed: negative values mean the output GREW over the source — the
    /// old max(0, …) made "output bigger than input" invisible (0%).
    var savingsPercent: Double {
        guard inBytes > 0 else { return 0 }
        return Double(inBytes - outBytes) / Double(inBytes) * 100
    }
    var grew: Bool { outBytes > inBytes }

    init(items: [ReportItem], inBytes: Int64, outBytes: Int64,
         outputBitrateMbps: Double?, encodeSeconds: Double, outputDuration: Double?) {
        self.schemaVersion = 1
        self.items = items
        self.inBytes = inBytes
        self.outBytes = outBytes
        self.outputBitrateMbps = outputBitrateMbps
        self.encodeSeconds = encodeSeconds
        self.outputDuration = outputDuration
    }

    // Lenient decode: every field optional + defaults; schemaVersion 0 for
    // reports written before the field existed.
    private enum Keys: String, CodingKey {
        case schemaVersion, items, inBytes, outBytes,
             outputBitrateMbps, encodeSeconds, outputDuration
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        items = try c.decodeIfPresent([ReportItem].self, forKey: .items) ?? []
        inBytes = try c.decodeIfPresent(Int64.self, forKey: .inBytes) ?? 0
        outBytes = try c.decodeIfPresent(Int64.self, forKey: .outBytes) ?? 0
        outputBitrateMbps = try c.decodeIfPresent(Double.self, forKey: .outputBitrateMbps)
        encodeSeconds = try c.decodeIfPresent(Double.self, forKey: .encodeSeconds) ?? 0
        outputDuration = try c.decodeIfPresent(Double.self, forKey: .outputDuration)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(items, forKey: .items)
        try c.encode(inBytes, forKey: .inBytes)
        try c.encode(outBytes, forKey: .outBytes)
        try c.encodeIfPresent(outputBitrateMbps, forKey: .outputBitrateMbps)
        try c.encode(encodeSeconds, forKey: .encodeSeconds)
        try c.encodeIfPresent(outputDuration, forKey: .outputDuration)
    }
}
