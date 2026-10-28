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
struct IntegrityReport: Codable, Hashable {
    var items: [ReportItem]
    var inBytes: Int64
    var outBytes: Int64
    var outputBitrateMbps: Double
    var encodeSeconds: Double
    var outputDuration: Double

    var passed: Bool { !items.contains { $0.severity == .fail } }

    var savingsPercent: Double {
        guard inBytes > 0 else { return 0 }
        return Double(max(0, inBytes - outBytes)) / Double(inBytes) * 100
    }
}
