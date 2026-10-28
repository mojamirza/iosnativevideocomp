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
    var codecLabel: String = ""
    var resolutionLabel: String = ""

    init(jobID: UUID, createdAt: Date, sourceName: String, presetName: String,
         outputFileName: String?, inBytes: Int64, outBytes: Int64, duration: Double,
         stateRaw: String, errorMessage: String?, reportJSON: Data?,
         codecLabel: String, resolutionLabel: String) {
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
        self.codecLabel = codecLabel
        self.resolutionLabel = resolutionLabel
    }
}
