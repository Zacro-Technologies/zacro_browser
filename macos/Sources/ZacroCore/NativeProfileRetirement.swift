import Foundation

enum NativeProfileRetirement {
  static func validID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 1_024
      && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}

extension BrowserStore {
  /// Internal session receipts are the authority to retire native storage.
  /// An existing profile always wins over inconsistent receipt metadata.
  public var pendingNativeProfileRetirements: [String] {
    state.pendingNativeProfileRetirements.filter { id in
      NativeProfileRetirement.validID(id) && !state.profiles.contains { $0.id == id }
    }
  }

  /// Call only after the engine has durably recorded the same retirement.
  /// A failed acknowledgement deliberately leaves the receipt for replay.
  public func acknowledgeNativeProfileRetirement(_ id: String) throws {
    if let repository {
      return try repository.mutateDurably(windowID: owningWindowID) {
        try $0.acknowledgeNativeProfileRetirement(id)
      }
    }
    guard state.pendingNativeProfileRetirements.contains(id) else { return }
    guard !state.profiles.contains(where: { $0.id == id }) else {
      throw ShortcutError("An existing profile cannot be retired.")
    }
    try commit(purgeRecovery: true) { $0.pendingNativeProfileRetirements.removeAll { $0 == id } }
  }
}
