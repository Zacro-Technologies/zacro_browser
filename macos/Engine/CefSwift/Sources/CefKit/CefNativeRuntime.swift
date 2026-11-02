import Foundation

public struct CefNavigationEntry: Sendable {
    public let url: URL
    public let title: String
    public init(url: URL, title: String) { self.url = url; self.title = title }
}

public struct CefNativeCapabilities: Decodable, Sendable {
    public let version: Int
    public let browserProtocol: Bool
    public let documentState: Bool
    public let browsingData: Bool
    public let navigationState: Bool
    public let encryptedNavigation: Bool?
    public let retainedDiscard: Bool?
    public let extensionActions: Bool?
    public let legacyNavigation: Bool?
    public let extensionStorage: Bool?
    public let extensionBrowser: Bool?
    public let volatileDiscard: Bool?
    public let bookmarks: Bool?
    public let historyRemoval: Bool?
    public let downloads: Bool?
}

public struct CefDocumentSafetyState: Decodable, Sendable {
    public let audible: Bool
    public let capturing: Bool
    public let beforeUnload: Bool
    public let devToolsOpen: Bool
    public let profileDownloads: Int
    public let extensionUI: Bool
    public let crashed: Bool
    public let loading: Bool

    /// Unknown state must never be interpreted as safe by the caller.
    public var permitsAutomaticUnload: Bool {
        !audible && !capturing && !beforeUnload && !devToolsOpen && !extensionUI && profileDownloads == 0 && !loading && !crashed
    }
}

@MainActor
extension CefBrowser {
    /// Registers the actual Chrome tab identifier against Swift's logical
    /// window/order. The returned ID is the one Chrome extensions use.
    public func registerExtensionTab(logicalID: String, windowID: Int, index: Int,
                                     active: Bool, pinned: Bool, discarded: Bool,
                                     autoDiscardable: Bool = true, splitViewID: Int = -1,
                                     openerTabID: Int? = nil, highlighted: Bool? = nil,
                                     groupID: Int = -1) async throws -> Int {
        guard !logicalID.isEmpty, logicalID.utf8.count <= 256, windowID > 0, index >= 0 else {
            throw CefDevToolsError.invalidMessage
        }
        guard splitViewID >= -1, groupID >= -1, openerTabID == nil || openerTabID! > 0 else { throw CefDevToolsError.invalidMessage }
        var parameters: [String: Any] = [
            "logicalID": logicalID, "windowID": windowID, "index": index,
            "active": active, "highlighted": highlighted ?? active, "pinned": pinned, "discarded": discarded,
            "autoDiscardable": autoDiscardable, "splitViewID": splitViewID, "groupID": groupID,
        ]
        if let openerTabID { parameters["openerTabID"] = openerTabID }
        let response = try await devTools.call("Zacro.registerExtensionTab", parameters: parameters)
        guard let identifier = response["tabID"] as? Int, identifier >= 0 else { throw CefDevToolsError.invalidMessage }
        return identifier
    }

    public func nativeCapabilities() async throws -> CefNativeCapabilities {
        let response = try await devTools.call("Zacro.getCapabilities")
        return try JSONDecoder().decode(CefNativeCapabilities.self, from: JSONSerialization.data(withJSONObject: response))
    }

    public func documentSafetyState() async throws -> CefDocumentSafetyState {
        let response = try await devTools.call("Zacro.getDocumentState")
        return try JSONDecoder().decode(CefDocumentSafetyState.self, from: JSONSerialization.data(withJSONObject: response))
    }

    /// Returns authenticated encrypted Chrome session state, including forms.
    /// The native runtime wraps its AES-GCM key with Chromium's configured OS
    /// encryption provider and binds the ciphertext to the originating profile.
    public func serializedNavigationState() async throws -> Data {
        let response = try await devTools.call("Zacro.serializeNavigation")
        guard response["version"] as? Int == 2, let value = response["state"] as? String,
              let bytes = Data(base64Encoded: value), bytes.count <= 6 * 1024 * 1024 else {
            throw CefDevToolsError.invalidMessage
        }
        return bytes
    }

    /// Restores only a fresh initial document or the exact empty document
    /// retained by discardDocument. A live page can never be overwritten.
    public func restoreNavigationState(_ state: Data) async throws {
        guard !state.isEmpty, state.count <= 6 * 1024 * 1024 else { throw CefDevToolsError.invalidMessage }
        let response = try await devTools.call("Zacro.restoreNavigation", parameters: ["state": state.base64EncodedString()], timeout: 50)
        guard response["restored"] as? Bool == true else { throw CefDevToolsError.invalidMessage }
    }

    /// Uses CEF's normal navigation path, but returns only after the issued
    /// primary-frame navigation commits. Redirects retain their navigation ID;
    /// errors, cancellation, closure and replacement reject the operation.
    public func loadAndWaitForNavigationCommit(_ url: URL) async throws {
        let response = try await devTools.call("Zacro.loadAndWaitForNavigationCommit",
            parameters: ["url": url.absoluteString], timeout: 50)
        guard response["committed"] as? Bool == true else { throw CefDevToolsError.invalidMessage }
    }

    /// Sleeps the document by navigating to an empty page and pruning history,
    /// retaining its native tab identity. Native discard first flushes current
    /// renderer history into its memory-only buffer. Public durable restoration
    /// still requires a separate encrypted capture before this operation.
    public func discardDocument() async throws {
        // Native bounds: 10 seconds for state ACKs, then 15 for blank commit.
        let response = try await devTools.call("Zacro.discardDocument", timeout: 30)
        guard response["discarded"] as? Bool == true else { throw CefDevToolsError.invalidMessage }
    }

    /// Restores the native in-memory history retained while sleeping. Private
    /// documents use this route exclusively and never export their page state.
    public func restoreDiscardedDocument() async throws {
        let response = try await devTools.call("Zacro.restoreDiscardedDocument", timeout: 50)
        guard response["restored"] as? Bool == true else { throw CefDevToolsError.invalidMessage }
    }

    /// Imports a safe URL/title-only history from an older browser database.
    /// This intentionally carries no page forms, POST bodies or credentials.
    public func restoreNavigationEntries(_ entries: [CefNavigationEntry], selectedIndex: Int) async throws {
        guard !entries.isEmpty, entries.count <= 500, entries.indices.contains(selectedIndex) else {
            throw CefDevToolsError.invalidMessage
        }
        let response = try await devTools.call("Zacro.restoreNavigationEntries", parameters: [
            "entries": entries.map { ["url": $0.url.absoluteString, "title": $0.title] },
            "selectedIndex": selectedIndex,
        ], timeout: 50)
        guard response["restored"] as? Bool == true else { throw CefDevToolsError.invalidMessage }
    }

    /// Removes real profile storage including IndexedDB, localStorage, service
    /// workers, CacheStorage and cookies. Extension origins are preserved.
    public func clearProfileBrowsingData(siteData: Bool, cache: Bool, history: Bool = false) async throws {
        guard siteData || cache || history else { return }
        let response = try await devTools.call("Zacro.clearBrowsingData", parameters: ["siteData": siteData, "cache": cache, "history": history], timeout: 120)
        guard response["cleared"] as? Bool == true else { throw CefDevToolsError.invalidMessage }
    }
}
