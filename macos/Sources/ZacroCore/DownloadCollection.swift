import Foundation

/// Reconciles the bounded Library with a profile's authoritative native list.
/// A truncated list cannot prove deletion, and an intervening event always wins.
public enum DownloadCollection {
  public static func isActive(status: String, canResume: Bool?) -> Bool {
    status == "downloading" || status == "paused" || (status == "interrupted" && canResume == true)
  }
  public static func ordered(_ records: [DownloadRecord], limit: Int = 1_000) -> [DownloadRecord] {
    Array(records.sorted { lhs, rhs in
      let leftActive = isActive(status: lhs.status, canResume: lhs.canResume)
      let rightActive = isActive(status: rhs.status, canResume: rhs.canResume)
      if leftActive != rightActive { return leftActive }
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
      return lhs.id < rhs.id
    }.prefix(max(0, limit)))
  }
  public static func reconcile(existing: [DownloadRecord], updates: [DownloadRecord],
      profileID: String, nativeGUIDs: Set<String>, complete: Bool,
      unchangedGUIDs: Set<String>) -> [DownloadRecord] {
    let retained = existing.filter { record in
      guard complete, record.profileID == profileID, let guid = record.nativeGUID,
        unchangedGUIDs.contains(guid) else { return true }
      return nativeGUIDs.contains(guid)
    }
    var records = Dictionary(retained.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for record in updates where record.profileID == profileID { records[record.id] = record }
    return ordered(Array(records.values))
  }
}
