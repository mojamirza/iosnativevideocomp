import AVFoundation
import CoreMedia

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
///
/// Robustness contract: the metadata item is the one piece of the writer
/// setup AVFoundation might refuse for a given container/muxer combination
/// (CI only builds — the first run on a real device decides). If the writer
/// rejects it, the engine fails the job as `metadataRejected` and retries
/// the encode ONCE with an empty metadata list; `sessionDisabled` then keeps
/// every later encode of the session metadata-free (a missing date is a
/// report warning — a failed job is not).
enum PrivacyScrub {

    /// Setup-flow toggle (on by default). When off, the output ships with an
    /// empty metadata track — no date, no location, fully anonymous file.
    static let keepDateKey = "privacy.keepCreationDate"
    static var keepCreationDate: Bool {
        get { UserDefaults.standard.object(forKey: keepDateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keepDateKey) }
    }

    private static let lock = NSLock()
    private static var _sessionDisabled = false

    /// Session-wide kill switch: set the first time a writer refuses to start
    /// with the scrubbed metadata items. Read/written from the engine's tasks
    /// (off the main actor), hence the lock.
    static var sessionDisabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _sessionDisabled }
        set { lock.lock(); _sessionDisabled = newValue; lock.unlock() }
    }

    /// Writer metadata items derived from the source asset. ASYNC — the
    /// engine calls this off the main actor, and `load(.commonMetadata)` is
    /// the modern non-blocking accessor (the old synchronous `commonMetadata`
    /// could stall on slow storage).
    static func items(for source: AVAsset) async -> [AVMetadataItem] {
        guard keepCreationDate, !sessionDisabled else { return [] }
        let common = (try? await source.load(.commonMetadata)) ?? []
        let src = common.first {
            $0.commonKey == AVMetadataKey.commonKeyCreationDate
        }
        guard let srcItem = src else { return [] }
        // TIMEZONE: reuse the source's own string when it is UNAMBIGUOUSLY
        // ISO-shaped (it carries the original UTC offset); a US-order
        // fallback-parsed string, or only a typed dateValue, falls back to
        // being reformatted as ISO-8601.
        var dateString: String?
        if let s = srcItem.stringValue {
            // Reuse the raw string ONLY when it is unambiguously ISO-shaped
            // (the two ISO-8601 patterns in the fallback list). A
            // "MM/dd/yyyy HH:mm:ss" fallback-parsed date MUST NOT be written
            // back as-is — US-order day/month invites misparsing by other
            // players; anything non-ISO is reformatted into ISO-8601.
            let formats = DateFormatter.isoFormats()
            if ISO8601DateFormatter().date(from: s) != nil
                || formats[0].date(from: s) != nil
                || formats[1].date(from: s) != nil {
                dateString = s
            } else if let d = formats.compactMap({ $0.date(from: s) }).first {
                dateString = ISO8601DateFormatter().string(from: d)
            }
        }
        if dateString == nil, let date = srcItem.dateValue {
            dateString = ISO8601DateFormatter().string(from: date)
        }
        guard let dateString else { return [] }
        let item = AVMutableMetadataItem()
        // COMMON identifier + UTF-8 data type with an NSString value and the
        // "und" language tag — Apple's DOCUMENTED shape for UTF-8-typed
        // common metadata. (A Data value is not that shape: if the writer
        // refused it, the first dated job would trip metadataRejected, flip
        // the kill switch, and every later file would silently ship
        // date-less — the fallback hiding the bug instead of the metadata
        // working.) If even the documented shape is refused, the engine's
        // startWriting guard fails the job as metadataRejected and retries
        // once with NO metadata.
        item.identifier = .commonIdentifierCreationDate
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = dateString as NSString
        item.extendedLanguageTag = "und"
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
