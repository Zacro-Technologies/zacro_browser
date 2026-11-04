import AppKit
import ZacroChromium

/// Read-only diagnostics for the disposable native side-panel error fixture.
/// No page state is changed, no observer is replaced, and no input is sent.
@MainActor enum NativeSidePanelPresentationDiagnostics {
  private static var enabled: Bool {
    CommandLine.arguments.contains("--engine-acceptance")
      && CommandLine.arguments.contains("--native-integration-acceptance")
  }
  static func snapshot(page: ChromiumPage, owner: BrowserWindowCoordinator) -> String {
    guard enabled else { return "disabled" }
    let window = page.nativeWindow
    let error = page.documentError
    let state: [String: Any] = [
      "pageID": page.id, "profileID": page.profileID, "ownerID": page.ownerWindowID ?? "nil",
      "nativeID": page.browser.map { Int($0.id) } ?? -1,
      "activePageID": owner.activePage?.id ?? "nil", "selectedDocumentID": owner.selectedDocumentID ?? "nil",
      "modelURL": owner.store.document(id: page.id)?.url ?? "nil", "pageURL": page.url?.absoluteString ?? "nil",
      "browserURL": page.browser?.url?.absoluteString ?? "nil", "loading": page.isLoading,
      "documentError": error.map { ["code": $0.code, "message": $0.message,
        "url": $0.url?.absoluteString ?? "nil", "rendererTerminated": $0.isRendererTermination] as [String: Any] } ?? [:],
      "actionsError": owner.actions.documentErrors[page.id] ?? "nil",
      "sidePanelVisible": page.isSidePanelVisible, "documentBounds": rect(page.documentBounds),
      "windowNumber": window?.windowNumber ?? -1, "windowVisible": window?.isVisible ?? false,
      "windowMiniaturized": window?.isMiniaturized ?? false, "windowFrame": rect(window?.frame),
      "windowContentBounds": rect(window?.contentView?.bounds), "windowAlpha": window?.alphaValue ?? -1,
      "parentWindowNumber": window?.parent?.windowNumber ?? -1,
      "ownerWindowNumber": owner.windowContext.window.windowNumber,
      "ownerVisible": owner.windowContext.window.isVisible,
      "ownerOpen": owner.windowContext.isOpen, "ownerClosing": owner.windowContext.isClosing,
      "ownerSheet": owner.windowContext.window.attachedSheet?.identifier?.rawValue ?? "nil",
      "ownerSheetPresentation": sheetPresentation(owner.windowContext.window.attachedSheet),
      "nativePageVisible": owner.actions.nativePageVisible, "contentFrame": rect(owner.actions.contentFrame),
      "errorPresented": owner.hasPresentedDocumentError(page.id),
      "errorPresentedBounds": rect(owner.presentedDocumentErrorBounds(page.id)),
      "nativeChildWindows": (window?.childWindows ?? []).map { child -> [String: Any] in
        ["identifier": child.identifier?.rawValue ?? "nil", "number": child.windowNumber,
          "visible": child.isVisible, "frame": rect(child.frame), "alpha": child.alphaValue,
          "attachedToPage": child.parent === window]
      },
    ]
    return encode(state)
  }
  static func showError(_ message: String, owner: BrowserWindowCoordinator) {
    guard enabled else { return }
    report("showError", snapshot: encode([
      "message": String(message.prefix(1_024)), "ownerID": owner.windowContext.id,
      "currentURL": String((owner.activePage?.url?.absoluteString ?? "nil").prefix(2_048)),
      "ownerSheetPresentation": sheetPresentation(owner.windowContext.window.attachedSheet),
    ]))
  }
  static func report(_ phase: String, snapshot: String) {
    guard enabled else { return }
    fputs("Native side-panel presentation \(phase): \(snapshot)\n", stderr)
  }
  static func nativeFailureSnapshot(page: ChromiumPage, owner: BrowserWindowCoordinator) async {
    guard enabled, let browser = page.browser, !browser.isClosed else { return }
    for method in ["Zacro.getDocumentState", "Page.getNavigationHistory"] {
      guard page.browser === browser, !browser.isClosed else { return }
      do {
        let result = try await browser.devTools.call(method, timeout: 2)
        guard page.browser === browser, !browser.isClosed else { return }
        if method == "Page.getNavigationHistory" {
          // The fixture only needs native address/index identity, never form
          // state, page text, or the encrypted capture payload.
          let entries = (result["entries"] as? [[String: Any]] ?? []).map { row in
            ["id": row["id"] ?? NSNull(), "url": row["url"] ?? NSNull(),
              "userTypedURL": row["userTypedURL"] ?? NSNull()]
          }
          report(method, snapshot: encode(["currentIndex": result["currentIndex"] ?? NSNull(), "entries": entries]))
        } else { report(method, snapshot: encode(result)) }
      } catch { report(method, snapshot: encode(["error": error.localizedDescription])) }
    }
    report("after-native-reads", snapshot: snapshot(page: page, owner: owner))
  }
  private static func rect(_ value: CGRect?) -> [String: Double] {
    guard let value else { return [:] }
    return ["x": Double(value.minX), "y": Double(value.minY),
      "width": Double(value.width), "height": Double(value.height)]
  }
  /// Only the exact owned attached sheet is inspected. Read noneditable
  /// labels and button titles, never form fields, secure input or other apps.
  private static func sheetPresentation(_ sheet: NSWindow?) -> [String: Any] {
    guard let sheet else { return [:] }
    var pending = sheet.contentView.map { [$0] } ?? []
    var visited = 0, labels: [String] = [], buttons: [String] = []
    while let view = pending.popLast(), visited < 256 {
      visited += 1
      guard view.window === sheet else { continue }
      if let field = view as? NSTextField, !(field is NSSecureTextField), !field.isEditable,
        !field.stringValue.isEmpty, labels.count < 12 {
        labels.append(String(field.stringValue.prefix(512)))
      }
      if let button = view as? NSButton, !button.title.isEmpty, buttons.count < 8 {
        buttons.append(String(button.title.prefix(80)))
      }
      pending.append(contentsOf: view.subviews.prefix(max(0, 256 - visited - pending.count)))
    }
    return ["identifier": sheet.identifier?.rawValue ?? "nil", "title": String(sheet.title.prefix(256)),
      "windowNumber": sheet.windowNumber, "parentWindowNumber": sheet.sheetParent?.windowNumber ?? -1,
      "visible": sheet.isVisible, "labels": labels, "buttons": buttons, "visitedViews": visited]
  }
  private static func encode(_ value: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8) else { return "invalid diagnostic object" }
    return text
  }
}
