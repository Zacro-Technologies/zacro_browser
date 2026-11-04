import CCef
import Foundation

/// Native-generated authority for one reversible shutdown/maintenance attempt.
/// It has no WebContents transport and does not retain any OAuth document data.
@MainActor
public final class CefAuxiliaryAdmissionLease {
    public struct Status {
        public let requests: UInt64
        public let presented: UInt64
        public let unpresented: UInt64
        public var isQuiescent: Bool { requests == 0 }
    }
    private let high: UInt64
    private let low: UInt64
    private var released = false
    private var sealed = false
    private init(_ state: ccef_auxiliary_admission_state_t) {
        high = state.high; low = state.low
    }
    public static var isSupported: Bool { ccef_auxiliary_admission_available() != 0 }
    public static func acquireProcess() throws -> CefAuxiliaryAdmissionLease? {
        guard isSupported else { return nil } // Explicit stock-runtime diagnostics.
        return try acquire(operation: 2, context: nil)
    }
    static func acquireContext(_ context: UnsafeMutablePointer<cef_request_context_t>) throws -> CefAuxiliaryAdmissionLease? {
        guard isSupported else { return nil }
        return try acquire(operation: 1, context: UnsafeMutableRawPointer(context))
    }
    static func isBlocked(_ context: UnsafeMutablePointer<cef_request_context_t>) throws -> Bool {
        guard isSupported else { return false }
        return try call(6, context: UnsafeMutableRawPointer(context), high: 0, low: 0).requests != 0
    }
    private static func acquire(operation: Int32, context: UnsafeMutableRawPointer?) throws -> CefAuxiliaryAdmissionLease {
        let state = try call(operation, context: context, high: 0, low: 0)
        guard state.high != 0 || state.low != 0 else { throw failure(-20) }
        return CefAuxiliaryAdmissionLease(state)
    }
    public func status() throws -> Status {
        guard !released else { throw Self.failure(-21) }
        let result = try Self.call(3, context: nil, high: high, low: low)
        guard result.requests == result.presented + result.unpresented else { throw Self.failure(-22) }
        return Status(requests: result.requests, presented: result.presented, unpresented: result.unpresented)
    }
    public func waitForQuiescence() async throws {
        // Poll actual native destruction state while the CEF UI loop runs. No
        // URL/readiness heuristic and no timer can turn a live request into success.
        while true {
            try Task.checkCancellation()
            if try status().isQuiescent { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    public func release() throws {
        guard !released else { return }
        guard !sealed else { throw Self.failure(-4) }
        _ = try Self.call(4, context: nil, high: high, low: low)
        released = true
    }
    public func seal() throws {
        guard !released else { throw Self.failure(-21) }
        if sealed { return }
        _ = try Self.call(5, context: nil, high: high, low: low)
        sealed = true
    }
    // No automatic release in deinit: dropping a Swift waiter/transport must
    // never reopen native admission during teardown. Release is explicit.
    private static func call(_ operation: Int32, context: UnsafeMutableRawPointer?, high: UInt64, low: UInt64) throws -> ccef_auxiliary_admission_state_t {
        var state = ccef_auxiliary_admission_state_t()
        state.size = UInt32(MemoryLayout<ccef_auxiliary_admission_state_t>.size)
        let result = ccef_auxiliary_admission(operation, context, high, low, &state)
        guard result == 1 else { throw failure(result) }
        return state
    }
    private static func failure(_ code: Int32) -> Error {
        NSError(domain: "CefAuxiliaryAdmission", code: Int(code), userInfo: [NSLocalizedDescriptionKey:
            "Native authentication cleanup did not settle (\(code)). The browser context is retained."])
    }
}
