import Foundation

extension BrowserStore {
  /// Records a successful main-frame document commit, independently of the
  /// requested tab URL or its back/forward stack. Same-document navigation,
  /// failed requests, and transient Peek documents do not call this method.
  @discardableResult public func recordHistoryVisit(profileID: String, address: String,
      title: String = "", visitedAt: Date = Date()) -> String? {
    if let repository {
      return repository.mutate(windowID: owningWindowID) {
        $0.recordHistoryVisit(profileID: profileID, address: address, title: title, visitedAt: visitedAt)
      }
    }
    guard let id = Self.appendHistoryVisit(to: &state, profileID: profileID,
      address: address, title: title, visitedAt: visitedAt) else { return nil }
    save()
    return id
  }

  /// A delayed document title belongs to the exact committed visit. Updating
  /// it neither creates a visit nor changes the recorded browsing time.
  public func updateHistoryVisitTitle(id: String, profileID: String, address: String, title: String) {
    if let repository {
      return repository.mutate(windowID: owningWindowID) {
        $0.updateHistoryVisitTitle(id: id, profileID: profileID, address: address, title: title)
      }
    }
    guard state.profiles.contains(where: { $0.id == profileID && !$0.isPrivate }),
      let url = BrowserAddress.webURL(address)?.absoluteString,
      let index = state.history.firstIndex(where: { $0.id == id && $0.profileID == profileID && $0.url == url }) else { return }
    let value = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    guard !value.isEmpty, value != state.history[index].title else { return }
    state.history[index].title = value
    save()
  }

  /// Also used within Peek's existing durable promotion transaction.
  @discardableResult static func appendHistoryVisit(to state: inout BrowserState,
      profileID: String, address: String, title: String, visitedAt: Date, historical: Bool = false) -> String? {
    guard state.profiles.contains(where: { $0.id == profileID && !$0.isPrivate }),
      let url = BrowserAddress.webURL(address)?.absoluteString,
      visitedAt.timeIntervalSince1970.isFinite, visitedAt.timeIntervalSince1970 > 0 else { return nil }
    let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    let id: String
    if let recent = state.history.firstIndex(where: { $0.profileID == profileID }),
      state.history[recent].url == url,
      visitedAt.timeIntervalSince(state.history[recent].visitedAt) >= 0,
      visitedAt.timeIntervalSince(state.history[recent].visitedAt) < 60 {
      if !title.isEmpty { state.history[recent].title = title }
      state.nativeHistoryBindings.removeValue(forKey: state.history[recent].id)
      state.history[recent].visitedAt = visitedAt
      id = state.history[recent].id
    } else {
      let entry = HistoryEntry(profileID: profileID, url: url,
        title: title.isEmpty ? url : title, visitedAt: visitedAt)
      state.history.insert(entry, at: 0)
      id = entry.id
    }
    // A durable native journal can replay older commits after restart. Never
    // move a newer visible visit backwards or evict it in favor of older replay.
    if historical { state.history.sort { $0.visitedAt > $1.visitedAt } }
    state.history = Array(state.history.prefix(20_000))
    return id
  }
}
