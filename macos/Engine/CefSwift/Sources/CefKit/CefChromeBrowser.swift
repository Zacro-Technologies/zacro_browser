import AppKit
import CCef
import Foundation

/// Options for a chrome-style browser window created via
/// ``CefChromeBrowser/create(url:options:delegate:)``.
@MainActor
public struct CefChromeBrowserOptions {
    /// Whether creation should show the CEF window. Native browser shells can
    /// keep an internal Chrome window hidden while hosting its document windows
    /// beneath their own AppKit window.
    public var showsWindowOnCreation: Bool = true

    /// Shows Chrome's own toolbar (back/forward/omnibox) inside the window.
    /// `false` (the default) hides Chrome's UI entirely — the window shows
    /// only web content while the full Chrome runtime remains available.
    public var showsChromeToolbar: Bool = false

    /// Creates the CEF window without a frame or title bar (and without the
    /// standard close/minimize/zoom buttons). Used by `CefChromeWebView` to
    /// blend the window into a host app; for standalone windows keep `false`.
    public var isFrameless: Bool = false

    /// Initial window frame in AppKit screen coordinates (points,
    /// bottom-left origin). `nil` centers a default-sized window.
    public var initialBounds: CGRect?

    /// Background color applied before the first paint.
    public var backgroundColor: NSColor?

    /// Isolated request context used by this Chrome browser.
    public var profile: CefProfile?
    /// Native-only, single-use identity token issued by the Chromium broker.
    public var nativeTabReservation: String?

    public init() {}
}

/// A browser hosted in a CEF Views window running the real **Chrome runtime
/// style** — the full Chrome browser machinery, including the WebUI pages
/// that never render in NSView-embedded (Alloy-style) browsers:
/// `chrome://history`, `chrome://extensions`, `chrome://settings`,
/// `chrome://downloads`, `chrome://flags`, plus extension installs and
/// Chrome profiles.
///
/// The wrapped ``browser`` is an ordinary ``CefBrowser``: delegate events,
/// JavaScript execution, downloads, DevTools and the JS bridge all work
/// exactly as they do for embedded browsers. The window itself is created
/// and owned by CEF (this is what unlocks Chrome style — CEF forces Alloy
/// for `parent_view` embedding); access it via ``nsWindow``.
///
/// Instances are kept alive by CefSwift until their window is destroyed, so
/// fire-and-forget creation is safe:
///
/// ```swift
/// CefChromeBrowser.create(url: URL(string: "chrome://history")!)
/// ```
@MainActor
public final class CefChromeBrowser {
    /// The browser wrapper. Its `id` is `-1` until CEF finishes creating the
    /// browser (views-hosted creation is asynchronous but typically completes
    /// within the `create` call).
    public let browser: CefBrowser

    /// The options this window was created with.
    public let options: CefChromeBrowserOptions

    /// Called after CEF destroys the window (user close, ``close()``, or app
    /// teardown). The instance is unusable afterwards.
    public var onWindowDestroyed: (() -> Void)?
    /// A real Chromium-created document, retaining POST data, referrer, named
    /// window identity and window.opener. The host can adopt it as a tab.
    public var onPopupCreated: ((CefChromeBrowser, CefWindowOpenRequest) -> Void)?
    public var beforeClose: (() async -> Bool)?
    private var closePreparation: Task<Void, Never>?
    private var closePrepared = false

    /// The AppKit window CEF created, once available. CEF owns this window —
    /// don't close or release it directly (use ``close()``); ordering,
    /// frame changes and child-window arrangements are fine.
    public var nsWindow: NSWindow? {
        rootView?.window
    }

    /// The root NSView of the CEF window (its `cef_window_handle_t`).
    public var rootView: NSView? {
        guard let rawWindow,
            let handle = rawWindow.pointee.get_window_handle?(rawWindow)
        else { return nil }
        return Unmanaged<NSView>.fromOpaque(handle).takeUnretainedValue()
    }

    /// Whether the CEF window is still alive.
    public var isWindowAlive: Bool { rawWindow != nil }

    // Owned +1 references; nil after the window is destroyed.
    private var rawWindow: UnsafeMutablePointer<cef_window_t>?
    private var rawBrowserView: UnsafeMutablePointer<cef_browser_view_t>?
    private weak var windowOwner: CefChromeBrowser?
    private weak var hostingWindow: NSWindow?
    private weak var presentationParent: NSWindow?
    private var hostedBrowsers: [CefChromeBrowser] = []
    private var manualFrame: CGRect?
    private var manualVisible = true
    private var pageCornerRadius: CGFloat = 0
    private var closeRequested = false
    private var pendingPopups: [Int32: CefChromeBrowser] = [:]
    private var popupRequest: CefWindowOpenRequest?
    public var onLayout: (() -> Void)?

    /// Border space (DIP) reserved around the browser view inside the window,
    /// so native overlays (e.g. a SwiftUI tab strip/omnibox) hosted on top of
    /// the window don't obscure the page. Applied via a BoxLayout's
    /// `inside_border_insets`. Default: zero (browser fills the window).
    private var insets: cef_insets_t = cef_insets_t(top: 0, left: 0, bottom: 0, right: 0)

    // Keep the Swift delegate owners reachable for the window's lifetime
    // (CEF's refs on the structs retain them too; this is belt and braces).
    private var viewDelegate: ChromeBrowserViewDelegate?
    private var windowDelegate: ChromeWindowDelegate?

    /// Instances stay alive until their window is destroyed.
    private static var liveInstances: [ObjectIdentifier: CefChromeBrowser] = [:]
    static var hasLiveWindows: Bool { !liveInstances.isEmpty }
    static var hasHostedWindows: Bool { liveInstances.values.contains { $0.windowOwner != nil } }
    static var rootBrowserIDs: Set<Int32> {
        Set(liveInstances.values.filter { $0.windowOwner == nil }.map { $0.browser.id })
    }

    private init(browser: CefBrowser, options: CefChromeBrowserOptions) {
        self.browser = browser
        self.options = options
    }

    // MARK: Creation

    /// Creates a chrome-style browser window loading `url`.
    ///
    /// Requires an initialized runtime. The window is shown immediately
    /// (at ``CefChromeBrowserOptions/initialBounds`` if set, otherwise
    /// centered). The returned instance is retained by CefSwift until the
    /// window is destroyed.
    @discardableResult
    public static func create(
        url: URL?,
        options: CefChromeBrowserOptions = .init(),
        delegate: CefBrowserDelegate? = nil
    ) -> CefChromeBrowser {
        precondition(
            CefRuntime.shared.isInitialized,
            "CefChromeBrowser.create requires CefRuntime.shared.initialize() to have succeeded first."
        )

        let client = BrowserClient()
        let cefBrowser = CefBrowser(raw: nil, client: client, delegate: delegate)
        client.attach(cefBrowser)
        let chrome = CefChromeBrowser(browser: cefBrowser, options: options)
        chrome.configurePopupClient(client)
        liveInstances[ObjectIdentifier(chrome)] = chrome
        let windowDelegate = ChromeWindowDelegate(chrome: chrome, options: options)
        chrome.windowDelegate = windowDelegate
        // Create the native window now; its document waits for context readiness.
        chrome.rawWindow = cef_window_create_top_level(windowDelegate.makeStruct())
        let buildDocument = { [weak chrome] in
            guard let chrome, let window = chrome.rawWindow, chrome.rawBrowserView == nil else { return }
            var settings = cef_browser_settings_t()
            settings.size = MemoryLayout<cef_browser_settings_t>.stride
            if let color = options.backgroundColor?.usingColorSpace(.sRGB) {
                settings.background_color = cefColor(color)
            }
            let viewDelegate = ChromeBrowserViewDelegate(chrome: chrome, options: options)
            chrome.viewDelegate = viewDelegate
            var extraInfo: UnsafeMutablePointer<cef_dictionary_value_t>?
            if let token = options.nativeTabReservation {
                extraInfo = cef_dictionary_value_create()
                if let extraInfo {
                    CefStringUtil.withCefString("_zacroTabReservation") { key in
                        CefStringUtil.withCefString(token) { value in
                            _ = extraInfo.pointee.set_string?(extraInfo, key, value)
                        }
                    }
                }
            }
            chrome.rawBrowserView = CefStringUtil.withCefString(url?.absoluteString ?? "") { cefURL in
                cef_browser_view_create(client.makeClient(), cefURL, &settings, extraInfo, options.profile?.makeRequestContext(), viewDelegate.makeStruct())
            }
            guard chrome.rawBrowserView != nil else {
                chrome.browser.failCreation("Chromium could not create the native document.")
                window.pointee.close?(window)
                return
            }
            chrome.handleWindowCreated(window)
            if chrome.windowOwner != nil {
                if chrome.manualVisible {
                    chrome.show()
                    chrome.applyPageFrame()
                } else { chrome.hide() }
            } else if !chrome.manualVisible, let view = chrome.rawBrowserView {
                let base = UnsafeMutableRawPointer(view).assumingMemoryBound(to: cef_view_t.self)
                base.pointee.set_visible?(base, 0)
            }
        }
        if let profile = options.profile { profile.whenReady(buildDocument) }
        else { buildDocument() }

        return chrome
    }

    private func configurePopupClient(_ client: BrowserClient) {
        client.chromeOwner = self
        client.popupClientFactory = { [weak self] popupID, request in
            guard let self else { return nil }
            let client = BrowserClient()
            let browser = CefBrowser(raw: nil, client: client, delegate: nil)
            client.attach(browser)
            var options = self.options
            options.nativeTabReservation = nil
            options.isFrameless = true
            options.showsWindowOnCreation = false
            options.initialBounds = CGRect(x: -16000, y: -16000, width: 600, height: 400)
            let popup = CefChromeBrowser(browser: browser, options: options)
            popup.windowOwner = self.windowOwner ?? self
            popup.hostingWindow = self.hostingWindow ?? self.nsWindow
            popup.manualVisible = false
            popup.popupRequest = request
            popup.configurePopupClient(client)
            Self.liveInstances[ObjectIdentifier(popup)] = popup
            self.pendingPopups[popupID] = popup
            if CommandLine.arguments.contains("--engine-acceptance") { NSLog("Acceptance popup client allocated id=%d", popupID) }
            return client
        }
        client.popupAborted = { [weak self] identifier in
            guard let popup = self?.pendingPopups.removeValue(forKey: identifier) else { return }
            Self.liveInstances.removeValue(forKey: ObjectIdentifier(popup))
        }
    }

    fileprivate func attachPopupView(_ view: UnsafeMutablePointer<cef_browser_view_t>) -> Bool {
        guard let rawBrowser = view.pointee.get_browser?(view) else { return false }
        let identifier = rawBrowser.pointee.get_identifier?(rawBrowser) ?? -1
        defer { cefRelease(UnsafeMutableRawPointer(rawBrowser)) }
        var clientOwner: CefChromeBrowser?
        if let host = rawBrowser.pointee.get_host?(rawBrowser) {
            if let client = host.pointee.get_client?(host) {
                clientOwner = BrowserClient.fromNativeClient(UnsafeMutableRawPointer(client))?.chromeOwner
                cefRelease(UnsafeMutableRawPointer(client))
            }
            cefRelease(UnsafeMutableRawPointer(host))
        }
        if CommandLine.arguments.contains("--engine-acceptance") { NSLog("Acceptance popup view native=%d candidates=%@", identifier, pendingPopups.values.map { String($0.browser.id) }.joined(separator: ",")) }
        guard let match = pendingPopups.first(where: { $0.value === clientOwner || $0.value.browser.id == identifier }) else { return false }
        let popup = match.value
        // Chrome announces this view before the lifetime/view delegates in
        // some creation paths. Resolve by the exact native client identity and
        // adopt now, rather than depending on callback ordering.
        if !popup.browser.hasRawBrowser {
            cefAddRef(UnsafeMutableRawPointer(rawBrowser))
            popup.browser.adoptRaw(rawBrowser)
        }
        pendingPopups.removeValue(forKey: match.key)
        cefAddRef(UnsafeMutableRawPointer(view))
        popup.rawBrowserView = view
        let delegate = ChromeWindowDelegate(chrome: popup, options: popup.options)
        popup.windowDelegate = delegate
        popup.rawWindow = cef_window_create_top_level(delegate.makeStruct())
        // The delegate receives on_window_created before rawWindow is assigned.
        popup.applyLayout()
        if let child = popup.nsWindow, let parent = popup.hostingWindow {
            child.isExcludedFromWindowsMenu = true
            child.collectionBehavior.insert(.fullScreenAuxiliary)
            parent.addChildWindow(child, ordered: .above)
        }
        popup.hide()
        popup.windowOwner?.hostedBrowsers.append(popup)
        if let request = popup.popupRequest { onPopupCreated?(popup, request) }
        return true
    }

    /// Creates an independent Chrome runtime surface as a native child window.
    /// CEF permits only one Chrome BrowserView per window; no Alloy substitution.
    public func createPage(
        url: URL?, profile: CefProfile, delegate: CefBrowserDelegate?,
        hostingWindow: NSWindow? = nil, nativeTabReservation: String? = nil
    ) -> CefChromeBrowser {
        precondition(windowOwner == nil && rawWindow != nil)
        var pageOptions = CefChromeBrowserOptions()
        pageOptions.profile = profile
        pageOptions.nativeTabReservation = nativeTabReservation
        pageOptions.isFrameless = true
        pageOptions.showsWindowOnCreation = false
        pageOptions.initialBounds = CGRect(x: -16000, y: -16000, width: 600, height: 400)
        let page = Self.create(url: url, options: pageOptions, delegate: delegate)
        page.windowOwner = self
        page.hostingWindow = hostingWindow ?? nsWindow
        page.hide()
        page.manualVisible = false
        if let child = page.nsWindow, let parent = page.hostingWindow {
            child.isExcludedFromWindowsMenu = true
            child.collectionBehavior.insert(.fullScreenAuxiliary)
            parent.addChildWindow(child, ordered: .above)
        }
        page.hide()
        hostedBrowsers.append(page)
        return page
    }

    /// Bounds use top-left parent window content coordinates in points.
    public func setPageFrame(_ frame: CGRect) {
        guard manualFrame != frame else { return }
        manualFrame = frame
        applyPageFrame()
    }

    /// Clip the actual native document window; a SwiftUI mask cannot clip an
    /// independently composited Chromium child window.
    public func setPageCornerRadius(_ radius: CGFloat) {
        pageCornerRadius = radius.isFinite ? max(0, min(64, radius)) : 0
        applyPageCornerRadius()
    }

    /// Keep geometry anchored to the shell while presenting the page above a
    /// native overlay (for example the Peek tint panel).
    public func setPresentationParent(_ parent: NSWindow?) {
        presentationParent = parent
        guard manualVisible, let window = nsWindow,
              let intended = parent ?? hostingWindow, window.parent !== intended else { return }
        window.parent?.removeChildWindow(window)
        intended.addChildWindow(window, ordered: .above)
    }

    private func applyPageCornerRadius() {
        guard let window = nsWindow, let content = window.contentView else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        content.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.layer?.cornerRadius = pageCornerRadius
        content.layer?.masksToBounds = pageCornerRadius > 0
        content.layer?.cornerCurve = .continuous
        CATransaction.commit()
    }

    public func setPageVisible(_ visible: Bool) {
        guard manualVisible != visible else {
            if !visible, windowOwner != nil { hide() }
            return
        }
        manualVisible = visible
        if windowOwner != nil {
            if visible { show(); applyPageFrame(); nsWindow?.orderFront(nil) } else { hide() }
        } else if let view = rawBrowserView {
            let base = UnsafeMutableRawPointer(view).assumingMemoryBound(to: cef_view_t.self)
            base.pointee.set_visible?(base, visible ? 1 : 0)
        }
    }

    private func applyPageFrame() {
        guard let frame = manualFrame, let parent = hostingWindow ?? windowOwner?.nsWindow,
              let content = parent.contentView, let window = nsWindow else { return }
        let nativeRect = CGRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: max(1,frame.width), height: max(1,frame.height))
        let target = parent.convertToScreen(content.convert(nativeRect, to: nil))
        if window.frame != target {
            if CommandLine.arguments.contains("--engine-acceptance") { NSLog("CEF frame id=%d window=%ld visible=%d frame=%@", browser.id, window.windowNumber, manualVisible ? 1 : 0, String(describing: target)) }
            if let rawWindow {
                var rect = Self.cefScreenRect(from: target)
                withUnsafeMutablePointer(to: &rawWindow.pointee.base.base) { view in
                    view.pointee.set_bounds?(view, &rect)
                }
            }
            window.setFrame(target, display: true)
        }
    }

    /// Chromium owns document/window destruction; release only after didClose.
    public func detachClosedPage() {
        windowOwner?.hostedBrowsers.removeAll { $0 === self }
    }

    fileprivate func handleLayout() {
        for page in hostedBrowsers { page.applyPageFrame() }
        onLayout?()
    }

    // MARK: Window controls

    /// Shows (or re-shows) the window.
    public func show() {
        guard let rawWindow else { return }
        if CommandLine.arguments.contains("--engine-acceptance") { NSLog("CEF show id=%d window=%ld hosted=%d", browser.id, nsWindow?.windowNumber ?? -1, windowOwner == nil ? 0 : 1) }
        if windowOwner != nil, let view = rawBrowserView {
            // Views and its native window maintain independent visibility.
            // A hosted document must restore both after hidden creation or
            // adoption; showing only the window can leave an empty container.
            let base = UnsafeMutableRawPointer(view).assumingMemoryBound(to: cef_view_t.self)
            base.pointee.set_visible?(base, 1)
        }
        if let window = nsWindow, let parent = presentationParent ?? hostingWindow, window.parent !== parent {
            window.parent?.removeChildWindow(window)
            parent.addChildWindow(window, ordered: .above)
        }
        rawWindow.pointee.show?(rawWindow)
        // AppKit caches accessibility children across orderOut/reparent. The
        // live Chromium AX tree is retained; announce the new native hierarchy
        // after Views has shown the document instead of reloading its renderer.
        if windowOwner != nil, let window = nsWindow {
            browser.setAccessibilityEnabled(true)
            NSAccessibility.post(element: window, notification: .layoutChanged)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, self.manualVisible, let window else { return }
                NSAccessibility.post(element: window, notification: .layoutChanged)
                if let content = window.contentView {
                    NSAccessibility.post(element: content, notification: .layoutChanged)
                }
            }
        }
    }

    /// Hides the window without destroying it.
    public func hide() {
        guard let rawWindow else { return }
        rawWindow.pointee.hide?(rawWindow)
        if let window = nsWindow { window.parent?.removeChildWindow(window) }
    }

    /// Closes the window (and its browser). JavaScript `onbeforeunload`
    /// handlers may prompt first; ``onWindowDestroyed`` fires when done.
    public func close() {
        closeRequested = true
        guard let rawWindow else { return }
        rawWindow.pointee.close?(rawWindow)
    }

    /// Reserves border space (in DIPs / points) around the browser view inside
    /// the window, so native content hosted *over* the window (e.g. a SwiftUI
    /// tab strip and omnibox added as an `NSHostingView` subview of
    /// ``rootView``) sits above empty space rather than obscuring the page.
    ///
    /// This insets the **browser view's frame within the window** (using a CEF
    /// `BoxLayout`), it does not cover the page. A `top` inset equal to your
    /// toolbar height produces the standard Arc/Chrome layout: chrome occupies
    /// the top strip, web content fills the rest. Safe to call repeatedly (e.g.
    /// when the toolbar height changes); takes effect immediately if the window
    /// already exists, otherwise on window creation.
    public func setContentInsets(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        insets = cef_insets_t(
            top: Int32(top.rounded()),
            left: Int32(left.rounded()),
            bottom: Int32(bottom.rounded()),
            right: Int32(right.rounded())
        )
        applyLayout()
    }

    /// Applies a vertical `BoxLayout` to the window carrying the current
    /// ``insets`` as `inside_border_insets`, then re-lays-out. The single child
    /// (the browser view) gets the default flex (1) and stretches to fill the
    /// remaining space below/around the insets.
    private func applyLayout() {
        guard let rawWindow else { return }
        var settings = cef_box_layout_settings_t()
        settings.size = MemoryLayout<cef_box_layout_settings_t>.stride
        settings.horizontal = 0
        settings.inside_border_insets = insets
        settings.cross_axis_alignment = CEF_AXIS_ALIGNMENT_STRETCH
        settings.main_axis_alignment = CEF_AXIS_ALIGNMENT_STRETCH
        settings.default_flex = 1
        withUnsafeMutablePointer(to: &rawWindow.pointee.base) { panel in
            if let layout = panel.pointee.set_to_box_layout?(panel, &settings) {
                // set_to_box_layout returns a +1 cef_box_layout_t we own.
                cefRelease(UnsafeMutableRawPointer(layout))
            }
            panel.pointee.layout?(panel)
        }
    }

    // MARK: Callbacks from delegates

    /// The window exists in the views hierarchy: attach the browser view.
    fileprivate func handleWindowCreated(_ window: UnsafeMutablePointer<cef_window_t>) {
        guard let rawBrowserView else { return }
        // add_child_view consumes one reference on the passed view.
        cefAddRef(UnsafeMutableRawPointer(rawBrowserView))
        let view = UnsafeMutableRawPointer(rawBrowserView).assumingMemoryBound(to: cef_view_t.self)
        withUnsafeMutablePointer(to: &window.pointee.base) { panel in
            panel.pointee.add_child_view?(panel, view)
        }
        // Apply a BoxLayout carrying any insets set before window creation
        // (default insets = zero ⇒ browser fills the window, as with the
        // implicit FillLayout). This must run after add_child_view so the
        // browser view participates in the layout.
        applyLayout()
        if options.initialBounds == nil {
            var size = cef_size_t(width: 1100, height: 760)
            window.pointee.center_window?(window, &size)
        }
        if options.showsWindowOnCreation { window.pointee.show?(window) }
    }

    fileprivate func handleBrowserCreated(_ raw: UnsafeMutablePointer<cef_browser_t>) {
        browser.adoptRaw(raw)
        if CommandLine.arguments.contains("--engine-acceptance") { NSLog("CEF view attached id=%d hosted=%d visible=%d", browser.id, windowOwner == nil ? 0 : 1, manualVisible ? 1 : 0) }
        // Chrome's window and compositor can finish attaching after create().
        // Reapply retained geometry after that native turn, without reloading.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.closeRequested { self.close(); return }
            guard self.windowOwner != nil else { return }
            self.applyPageFrame()
            self.applyPageCornerRadius()
            if self.manualVisible { self.browser.setAccessibilityEnabled(true); self.show(); self.nsWindow?.orderFront(nil) }
            else { self.hide() }
        }
    }

    fileprivate func handleCanClose() -> Bool {
        if !closePrepared, let prepare = beforeClose {
            if closePreparation == nil {
                closePreparation = Task { @MainActor [weak self] in
                    let accepted = await prepare()
                    guard let self else { return }
                    self.closePreparation = nil
                    guard accepted else { self.browser.onCloseCancelled?(); return }
                    self.closePrepared = true
                    self.close()
                }
            }
            return false
        }
        let pagesClosed = hostedBrowsers.map { $0.browser.tryCloseFromWindow() }.allSatisfy { $0 }
        return pagesClosed && browser.tryCloseFromWindow()
    }

    public func cancelPreparedClose() { closePrepared = false }

    fileprivate func handleWindowDestroyed() {
        closePreparation?.cancel(); closePreparation = nil
        if !browser.hasRawBrowser { browser.failCreation("The document window closed before creation completed.") }
        // Popup creation can be canceled after OnBeforePopup without producing
        // an attached BrowserView. Do not retain those pending owners forever.
        for popup in pendingPopups.values {
            popup.browser.close(force: true)
            Self.liveInstances.removeValue(forKey: ObjectIdentifier(popup))
        }
        pendingPopups.removeAll()
        if let rawWindow {
            cefRelease(UnsafeMutableRawPointer(rawWindow))
        }
        rawWindow = nil
        if let rawBrowserView {
            cefRelease(UnsafeMutableRawPointer(rawBrowserView))
        }
        rawBrowserView = nil
        viewDelegate = nil
        windowDelegate = nil
        onWindowDestroyed?()
        Self.liveInstances[ObjectIdentifier(self)] = nil
        CefRuntime.shared.chromeWindowDidClose()
    }

    // MARK: Helpers

    /// Converts AppKit screen coordinates (bottom-left origin) to CEF DIP
    /// screen coordinates (top-left origin of the primary display).
    static func cefScreenRect(from appKitRect: CGRect) -> cef_rect_t {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? appKitRect.maxY
        return cef_rect_t(
            x: Int32(appKitRect.origin.x.rounded()),
            y: Int32((primaryHeight - appKitRect.maxY).rounded()),
            width: Int32(appKitRect.width.rounded()),
            height: Int32(appKitRect.height.rounded())
        )
    }

    /// Converts an sRGB NSColor to CEF's ARGB `cef_color_t`.
    private static func cefColor(_ color: NSColor) -> cef_color_t {
        let a = UInt32((color.alphaComponent * 255).rounded()) & 0xFF
        let r = UInt32((color.redComponent * 255).rounded()) & 0xFF
        let g = UInt32((color.greenComponent * 255).rounded()) & 0xFF
        let b = UInt32((color.blueComponent * 255).rounded()) & 0xFF
        return (a << 24) | (r << 16) | (g << 8) | b
    }
}

// MARK: - cef_browser_view_delegate_t bridge

/// Swift owner behind a `cef_browser_view_delegate_t`. One instance per
/// browser view; popup browser views get their own (chrome-less) instance so
/// popup toolbar configuration is inherited without cross-wiring browsers.
@MainActor
final class ChromeBrowserViewDelegate {
    /// nil for popup-view delegates (no CefChromeBrowser to wire back to).
    private weak var chrome: CefChromeBrowser?
    private let options: CefChromeBrowserOptions

    init(chrome: CefChromeBrowser?, options: CefChromeBrowserOptions) {
        self.chrome = chrome
        self.options = options
    }

    private nonisolated static func owner(_ cefSelf: UnsafeMutableRawPointer?) -> ChromeBrowserViewDelegate? {
        cefOwner(ChromeBrowserViewDelegate.self, cefSelf)
    }

    /// Builds the delegate struct. The returned pointer carries one reference
    /// owned by the caller (transferred to CEF at browser view creation).
    func makeStruct() -> UnsafeMutablePointer<cef_browser_view_delegate_t> {
        let d = cefAllocate(cef_browser_view_delegate_t.self, owner: self)

        d.pointee.on_browser_created = { delegateSelf, browserView, rawBrowser in
            cefRelease(browserView.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeBrowserViewDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)),
                let rawBrowser
            else {
                cefRelease(rawBrowser.map(UnsafeMutableRawPointer.init))
                return
            }
            MainActor.assumeIsolated {
                guard let chrome = me.chrome else {
                    // Popup browser views have no wrapper; drop our +1.
                    cefRelease(UnsafeMutableRawPointer(rawBrowser))
                    return
                }
                // Transfers the +1 to the CefBrowser wrapper.
                chrome.handleBrowserCreated(rawBrowser)
            }
        }

        d.pointee.on_browser_destroyed = { _, browserView, rawBrowser in
            cefRelease(browserView.map(UnsafeMutableRawPointer.init))
            cefRelease(rawBrowser.map(UnsafeMutableRawPointer.init))
            // Browser teardown is handled via cef_life_span_handler_t
            // (BrowserClient.on_before_close → CefBrowser.handleBeforeClose).
        }

        d.pointee.get_delegate_for_popup_browser_view = { delegateSelf, browserView, _, popupClient, isDevTools in
            cefRelease(browserView.map(UnsafeMutableRawPointer.init))
            defer { cefRelease(popupClient.map(UnsafeMutableRawPointer.init)) }
            guard let me = ChromeBrowserViewDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else {
                return nil
            }
            // (Pointer return types aren't Sendable, so hop manually.)
            nonisolated(unsafe) var result: UnsafeMutablePointer<cef_browser_view_delegate_t>?
            MainActor.assumeIsolated {
                // Fresh delegate so the popup inherits toolbar config but has
                // no back-reference to the originating CefChromeBrowser.
                let popup = isDevTools == 0 ? BrowserClient.fromNativeClient(popupClient.map(UnsafeMutableRawPointer.init))?.chromeOwner : nil
                if CommandLine.arguments.contains("--engine-acceptance") { NSLog("Acceptance popup view delegate has wrapper=%d devtools=%d", popup == nil ? 0 : 1, isDevTools) }
                let popupDelegate = ChromeBrowserViewDelegate(chrome: popup, options: popup?.options ?? me.options)
                // The struct's initial +1 transfers to CEF via this return.
                result = popupDelegate.makeStruct()
            }
            return result
        }

        d.pointee.on_popup_browser_view_created = { delegateSelf, browserView, popupBrowserView, isDevTools in
            cefRelease(browserView.map(UnsafeMutableRawPointer.init))
            defer { cefRelease(popupBrowserView.map(UnsafeMutableRawPointer.init)) }
            if isDevTools == 0, let popupBrowserView,
                let me = ChromeBrowserViewDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) {
                return MainActor.assumeIsolated { me.chrome?.attachPopupView(popupBrowserView) == true ? 1 : 0 }
            }
            // Return 0: CEF creates a default top-level window for the popup
            // (DevTools windows included), using the popup view delegate above.
            return 0
        }

        d.pointee.get_chrome_toolbar_type = { delegateSelf, browserView in
            cefRelease(browserView.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeBrowserViewDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else {
                return CEF_CTT_NONE
            }
            return MainActor.assumeIsolated {
                me.options.showsChromeToolbar ? CEF_CTT_NORMAL : CEF_CTT_NONE
            }
        }

        d.pointee.get_browser_runtime_style = { _ in
            // The entire point of this hosting mode.
            CEF_RUNTIME_STYLE_CHROME
        }

        return d
    }
}

// MARK: - cef_window_delegate_t bridge

/// Swift owner behind a `cef_window_delegate_t`.
@MainActor
final class ChromeWindowDelegate {
    private weak var chrome: CefChromeBrowser?
    private let options: CefChromeBrowserOptions

    /// `chrome` is optional for testability; in production it is always set.
    init(chrome: CefChromeBrowser?, options: CefChromeBrowserOptions) {
        self.chrome = chrome
        self.options = options
    }

    private nonisolated static func owner(_ cefSelf: UnsafeMutableRawPointer?) -> ChromeWindowDelegate? {
        cefOwner(ChromeWindowDelegate.self, cefSelf)
    }

    /// Builds the delegate struct. The returned pointer carries one reference
    /// owned by the caller (transferred to CEF at window creation).
    func makeStruct() -> UnsafeMutablePointer<cef_window_delegate_t> {
        let d = cefAllocate(cef_window_delegate_t.self, owner: self)

        d.pointee.on_window_created = { delegateSelf, window in
            guard let me = ChromeWindowDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)),
                let window
            else {
                cefRelease(window.map(UnsafeMutableRawPointer.init))
                return
            }
            MainActor.assumeIsolated {
                me.chrome?.handleWindowCreated(window)
            }
            cefRelease(UnsafeMutableRawPointer(window))
        }

        d.pointee.on_window_destroyed = { delegateSelf, window in
            cefRelease(window.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeWindowDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                me.chrome?.handleWindowDestroyed()
            }
        }

        d.pointee.base.base.on_layout_changed = { delegateSelf, view, _ in
            cefRelease(view.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeWindowDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { me.chrome?.handleLayout() }
        }

        d.pointee.can_close = { delegateSelf, window in
            cefRelease(window.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeWindowDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else {
                return 1
            }
            return MainActor.assumeIsolated {
                // Routes through try_close_browser so JS onbeforeunload
                // handlers get their say (mirrors cefsimple's CanClose).
                (me.chrome?.handleCanClose() ?? true) ? 1 : 0
            }
        }

        d.pointee.is_frameless = { delegateSelf, window in
            cefRelease(window.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeWindowDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else {
                return 0
            }
            return MainActor.assumeIsolated { me.options.isFrameless ? 1 : 0 }
        }

        d.pointee.with_standard_window_buttons = { delegateSelf, window in
            cefRelease(window.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeWindowDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else {
                return 1
            }
            return MainActor.assumeIsolated { me.options.isFrameless ? 0 : 1 }
        }

        d.pointee.get_initial_bounds = { delegateSelf, window in
            cefRelease(window.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeWindowDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else {
                return cef_rect_t()
            }
            return MainActor.assumeIsolated {
                guard let bounds = me.options.initialBounds else { return cef_rect_t() }
                return CefChromeBrowser.cefScreenRect(from: bounds)
            }
        }

        d.pointee.get_initial_show_state = { delegateSelf, window in
            cefRelease(window.map(UnsafeMutableRawPointer.init))
            return CEF_SHOW_STATE_NORMAL
        }

        d.pointee.get_window_runtime_style = { _ in
            CEF_RUNTIME_STYLE_CHROME
        }

        return d
    }
}
