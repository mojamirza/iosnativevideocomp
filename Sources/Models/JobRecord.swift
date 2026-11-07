import Foundation
import SwiftData

@Model
final class JobRecord {
    var jobID: UUID = UUID()
    var createdAt: Date = Date()
    var sourceName: String = ""
    var presetName: String = ""
    var outputFileName: String?
    var inBytes: Int64 = 0
    var outBytes: Int64 = 0
    var duration: Double = 0
    var stateRaw: String = "done"
    var errorMessage: String?
    var reportJSON: Data?
    var presetJSON: Data?
    var codecLabel: String = ""
    var resolutionLabel: String = ""
    /// User-picked poster image (normalized JPEG); nil = automatic.
    /// External storage: binaries don't belong in the main store.
    @Attribute(.externalStorage) var posterData: Data?
    /// Persisted per-video adjustments (queue persistence).
    var rotationDegrees: Int = 0
    var trimStart: Double = 0
    var trimEnd: Double?
    /// Set when a queued/in-flight row was auto-resumed at launch — bounds
    /// the resume to ONE attempt so a crashing encode can't loop forever.
    var autoResumed: Bool = false

    init(jobID: UUID, createdAt: Date, sourceName: String, presetName: String,
         outputFileName: String?, inBytes: Int64, outBytes: Int64, duration: Double,
         stateRaw: String, errorMessage: String?, reportJSON: Data?,
         presetJSON: Data? = nil, codecLabel: String, resolutionLabel: String,
         posterData: Data? = nil, rotationDegrees: Int = 0, trimStart: Double = 0,
         trimEnd: Double? = nil, autoResumed: Bool = false) {
        self.jobID = jobID
        self.createdAt = createdAt
        self.sourceName = sourceName
        self.presetName = presetName
        self.outputFileName = outputFileName
        self.inBytes = inBytes
        self.outBytes = outBytes
        self.duration = duration
        self.stateRaw = stateRaw
        self.errorMessage = errorMessage
        self.reportJSON = reportJSON
        self.presetJSON = presetJSON
        self.codecLabel = codecLabel
        self.resolutionLabel = resolutionLabel
        self.posterData = posterData
        self.rotationDegrees = rotationDegrees
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.autoResumed = autoResumed
    }
}
