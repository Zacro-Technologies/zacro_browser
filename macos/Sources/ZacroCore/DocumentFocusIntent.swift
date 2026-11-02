/// A selection may request focus once. A later interaction abandons that request
/// until another selection (or an explicit activation) creates a fresh intent.
public struct DocumentFocusIntent: Sendable {
  public struct Selection: Equatable, Sendable {
    public let documentID: String
    public let profileID: String
    public init(documentID: String, profileID: String) {
      self.documentID = documentID; self.profileID = profileID
    }
  }
  public struct Token: Equatable, Sendable {
    public let selection: Selection
    fileprivate let generation: UInt64
  }
  public enum Phase: Sendable { case idle, pending, completed, abandoned }
  public private(set) var selection: Selection?
  public private(set) var phase: Phase = .idle
  private var generation: UInt64 = 0
  public init() {}

  public mutating func begin(_ selection: Selection, explicit: Bool = false) -> Token? {
    guard explicit || self.selection != selection else { return nil }
    generation &+= 1; self.selection = selection; phase = .pending
    return Token(selection: selection, generation: generation)
  }
  public func isPending(_ token: Token) -> Bool {
    phase == .pending && generation == token.generation && selection == token.selection
  }
  @discardableResult public mutating func complete(_ token: Token) -> Bool {
    guard isPending(token) else { return false }
    phase = .completed; return true
  }
  public mutating func abandon(_ selection: Selection?) {
    generation &+= 1; self.selection = selection; phase = selection == nil ? .idle : .abandoned
  }
  public mutating func clear() { abandon(nil) }
}
