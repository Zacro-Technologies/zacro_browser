import Foundation
import Testing
@testable import CefKit

@Suite struct DevToolsEnvelopeTests {
    @Test func flattenedResponseKeepsPayloadAndEnvelopeSessionsSeparate() throws {
        let input = Data(#"{"id":42,"result":{"sessionId":"new-child","value":7},"sessionId":"parent"}"#.utf8)
        guard case .response(let id, let session, let result) = try CefDevToolsEnvelope.parse(input) else {
            Issue.record("Expected flattened reply"); return
        }
        #expect(id == 42 && session == "parent")
        let payload = try JSONSerialization.jsonObject(with: result.get()) as? [String: Any]
        #expect(payload?["sessionId"] as? String == "new-child")
        #expect(payload?["value"] as? Int == 7)
    }

    @Test func flattenedProtocolErrorPreservesCode() throws {
        let input = Data(#"{"sessionId":"child","error":{"code":-32601,"message":"Unknown method"},"id":9}"#.utf8)
        guard case .response(let id, let session, let result) = try CefDevToolsEnvelope.parse(input) else {
            Issue.record("Expected error reply"); return
        }
        #expect(id == 9 && session == "child")
        do { _ = try result.get(); Issue.record("Expected protocol rejection") }
        catch let error as CefDevToolsError { #expect(error.isUnsupportedMethod) }
    }

    @Test func childEventKeepsTwoDifferentSessionIDs() throws {
        let input = Data(#"{"method":"Target.attachedToTarget","params":{"sessionId":"grandchild"},"sessionId":"child"}"#.utf8)
        guard case .event(let method, let params, let session) = try CefDevToolsEnvelope.parse(input) else {
            Issue.record("Expected event"); return
        }
        #expect(method == "Target.attachedToTarget")
        #expect(session == "child" && params["sessionId"] as? String == "grandchild")
    }

    @Test func onlyExactNativeBrokerTokenHasRootResponses() {
        #expect(CefDevToolsEnvelope.responseSession(for: "zacro.native.browser.v1") == nil)
        #expect(CefDevToolsEnvelope.responseSession(for: "zacro.native.browser.v1.child") == "zacro.native.browser.v1.child")
        #expect(CefDevToolsEnvelope.responseSession(for: "real-child") == "real-child")
        #expect(CefDevToolsEnvelope.responseSession(for: nil) == nil)
    }

    @Test(arguments: ["[]", "{", #"{"id":true,"result":{}}"#,
      #"{"id":-1,"result":{}}"#, #"{"id":2147483648,"result":{}}"#,
      #"{"id":1,"result":[],"sessionId":"a"}"#, #"{"id":1,"result":{},"sessionId":true}"#,
      #"{"id":1,"result":{},"sessionId":""}"#,
      #"{"id":1,"result":{},"error":{"code":1,"message":"x"}}"#,
      #"{"id":1,"error":{"code":true,"message":"x"}}"#,
      #"{"id":1,"method":"Runtime.event","result":{}}"#,
      #"{"method":"Runtime.event","params":[]}"#])
    func invalidEnvelopesReject(_ input: String) {
        #expect(throws: (any Error).self) { try CefDevToolsEnvelope.parse(Data(input.utf8)) }
    }

    @Test func byteLimitIsAppliedBeforeJSONParsing() {
        let input = Data(#"{"id":1,"result":{"x":"large"}}"#.utf8)
        do { _ = try CefDevToolsEnvelope.parse(input, maximumBytes: 8); Issue.record("Expected byte limit") }
        catch let error as CefDevToolsError {
            if case .responseTooLarge = error {} else { Issue.record("Wrong limit error") }
        } catch { Issue.record("Unexpected limit error") }
    }
}
