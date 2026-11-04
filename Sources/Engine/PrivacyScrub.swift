import AVFoundation

/// PRIVACY SCRUB — outputs carry NO location metadata, ever, and the creation
/// date is preserved as a DELIBERATE choice. Before this existed the writer
/// simply never carried a metadata track, so a re-compressed file silently
/// lost its creation date as a re-muxing side effect (and would have lost
/// GPS the same way — by accident, not by policy).
///
/// Engine contract: the writer gets exactly ONE item — the source's creation
/// date, nothing else. GPS (`.quickTimeMetadataLocationISO6709` /
/// `com.apple.quicktime.location.ISO6709`) is never copied on any path, and
/// there is no switch that re-enables it.
enum PrivacyScrub {

    /// Setup-flow toggle (on by default). When off, the output ships with an
    /// empty metadata track — no date, no location, fully anonymous file.
    static let keepDateKey = "privacy.keepCreationDate"
    static var keepCreationDate: Bool {
        get { UserDefaults.standard.object(forKey: keepDateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keepDateKey) }
    }

    /// Writer metadata items derived from the source asset (synchronous
    /// common-metadata access; safe on any thread).
    static func items(for source: AVAsset) -> [AVMetadataItem] {
        guard keepCreationDate else { return [] }
        let src = source.commonMetadata.first {
            $0.commonKey == AVMetadataKey.commonKeyCreationDate
        }
        guard let srcItem = src else { return [] }
        // The date can arrive typed (dateValue) or as a string (ISO-8601 /
        // yyyy-MM-dd); accept both.
        var date = srcItem.dateValue
        if date == nil {
            for f in [ISO8601DateFormatter()] + DateFormatter.isoFormats() {
                if let s = srcItem.stringValue, let d = f.date(from: s) {
                    date = d
                    break
                }
            }
        }
        guard let date else { return [] }
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataCreationDate
        // dataType is left to AVFoundation: assigning dateValue types it
        // correctly (a hand-set fourCC here risks an invalid item).
        item.dateValue = date
        return [item]
    }
}

private extension DateFormatter {
    static func isoFormats() -> [DateFormatter] {
        ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss Z",
         "MM/dd/yyyy HH:mm:ss", "yyyy-MM-dd"].map {
            let f = DateFormatter()
            f.dateFormat = $0
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }
    }
}
