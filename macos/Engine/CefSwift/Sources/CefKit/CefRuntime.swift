import AppKit
import CCef
import CCefAppKit
import Foundation

// MARK: - Settings mapping (inlined from CefSettingsMapping.swift)

/// Owns a fully-populated `cef_settings_t` whose string members are released
/// on deinit. Kept alive for the duration of `cef_initialize` (CEF copies
/// what it needs).
final class MappedCefSettings {
    var raw = cef_settings_t()

    /// - Parameters:
    ///   - configuration: the user configuration.
    ///   - frameworkDirectory: resolved `.framework` directory (maps to
    ///     `framework_dir_path`), or nil to let CEF use defaults.
    init(configuration: CefConfiguration, frameworkDirectory: URL?) {
        raw.size = MemoryLayout<cef_settings_t>.stride
        raw.no_sandbox = configuration.noSandbox ? 1 : 0
        raw.external_message_pump = configuration.externalMessagePump ? 1 : 0
        raw.multi_threaded_message_loop = 0  // unsupported on macOS
        raw.log_severity = configuration.logSeverity.cefValue
        raw.persist_session_cookies = configuration.persistSessionCookies ? 1 : 0
        raw.remote_debugging_port = Int32(configuration.remoteDebuggingPort ?? 0)
        raw.windowless_rendering_enabled = configuration.windowlessRenderingEnabled ? 1 : 0

        // CEF requires cache_path to equal or live under root_cache_path. When only
        // cachePath is given, derive the root from it so the pair is always valid.
        let rootCache: URL
        if let explicitRoot = configuration.rootCachePath {
            rootCache = explicitRoot
        } else if let cache = configuration.cachePath {
            rootCache = cache.deletingLastPathComponent()
        } else {
            rootCache = Self.defaultRootCachePath()
        }
        try? FileManager.default.createDirectory(at: rootCache, withIntermediateDirectories: true)
        CefStringUtil.set(rootCache.path, into: &raw.root_cache_path)
        CefStringUtil.set((configuration.cachePath ?? rootCache).path, into: &raw.cache_path)

        CefStringUtil.set(configuration.locale, into: &raw.locale)
        CefStringUtil.set(configuration.userAgentProduct, into: &raw.user_agent_product)
        CefStringUtil.set(configuration.logFile?.path, into: &raw.log_file)
        CefStringUtil.set(frameworkDirectory?.path, into: &raw.framework_dir_path)
        CefStringUtil.set(configuration.browserSubprocessPath?.path, into: &raw.browser_subprocess_path)
    }

    /// Default per-app CEF data directory:
    /// `~/Library/Application Support/<bundle id | "CefSwift">/CefSwift`.
    static func defaultRootCachePath() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier
            ?? ProcessInfo.processInfo.processName
        return appSupport.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("CefSwift", isDirectory: true)
    }

    deinit {
        ccef_string_clear(&raw.root_cache_path)
        ccef_string_clear(&raw.cache_path)
        ccef_string_clear(&raw.locale)
        ccef_string_clear(&raw.user_agent_product)
        ccef_string_clear(&raw.log_file)
        ccef_string_clear(&raw.framework_dir_path)
        ccef_string_clear(&raw.browser_subprocess_path)
    }
}

// MARK: -

/// Routes CEFApplication's terminate: through the runtime so quitting closes
/// CEF browsers cleanly first. Returns true when termination may proceed.
private let cefTerminateHandler: CEFApplicationTerminateHandler = { () -> ObjCBool in
    ObjCBool(
        MainActor.assumeIsolated {
            CefRuntime.shared.handleTerminationRequest()
        }
    )
}

/// Process-wide CEF lifecycle: framework loading, `cef_initialize`,
/// the external message pump, and shutdown.
///
/// ```swift
/// try CefRuntime.shared.initialize()
/// ```
///
/// `initialize` must be called on the main thread before any browser is
/// created and before SwiftUI/AppKit start delivering events. It installs
/// ``CEFApplication`` automatically when no NSApplication exists yet.
@MainActor
public final class CefRuntime {
    /// The shared runtime.
    public static let shared = CefRuntime()

    /// Whether `cef_initialize` has completed successfully.
    public private(set) var isInitialized = false

    /// The configuration passed to ``initialize(configuration:)``; `nil`
    /// before initialization.
    public private(set) var configuration: CefConfiguration?

    /// The JS ↔ Swift function bridge. Register functions any time; pages
    /// call them via `window.cefSwift.invoke(name, params)`. See ``CefBridge``.
    public let bridge = CefBridge()

    /// Hosts that own NSApplication.run() use this to stop their event loop.
    /// It fires after all browsers and Views windows close. Release remaining
    /// CEF objects and call shutdown() only after the event loop has returned.
    public var onReadyToTerminate: (() -> Void)?
    public var onTerminationChanged: ((Bool) -> Void)?
    /// Snapshot native documents before asking any of them to close. A false
    /// result cancels this quit attempt without unloading a document.
    public var beforeClosingDocuments: (() async -> Bool)?

    var messagePump: CefMessagePump?
    private var appContext: CefAppContext?
    private var settings: MappedCefSettings?
    private var browsers: [Int32: CefBrowser] = [:]
    private var auxiliaryBrowserIDs: Set<Int32> = []
    private final class AuxiliaryWindow {
        weak var window: NSWindow?
        let context: CefExistingRequestContext?
        var observer: NSObjectProtocol?
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        init(window: NSWindow, context: CefExistingRequestContext?) {
            self.window = window; self.context = context
        }
    }
    private var auxiliaryWindows: [ObjectIdentifier: AuxiliaryWindow] = [:]
    private var closedAuxiliaryWindows: [ObjectIdentifier: AuxiliaryWindow] = [:]
    private var auxiliaryWindowIDs: [Int32: ObjectIdentifier] = [:]
    private var isTerminationRequested = false
    private var scheduledTerminationAttemptID: UUID?
    private var isPreparingTermination = false
    private var terminationAttemptID: UUID?
    public var onAuxiliaryAdmissionFailure: ((Error) -> Void)?
    private var auxiliaryAdmission: CefAuxiliaryAdmissionLease?
    private var auxiliaryDrainTask: Task<Void, Never>?
    private var auxiliaryDrainAttemptID: UUID?
    private var auxiliaryAdmissionFailureAttemptID: UUID?
    private var auxiliaryFinalCleanupStarted = false
    private var finalTerminationAttemptID: UUID?
    private var finalTerminationCompletion: (attempt: UUID, run: () -> Void)?

    private init() {}

    /// Initializes CEF in the browser (main) process.
    ///
    /// Call exactly once, on the main thread, before creating browsers.
    /// If `NSApp` does not exist yet, ``CEFApplication`` is installed first;
    /// if another NSApplication subclass was already instantiated this is a
    /// fatal programmer error (CEF requires the NSApplication to conform to
    /// CefAppProtocol from the very first event).
    public func initialize(configuration: CefConfiguration = .default) throws(CefError) {
        precondition(Thread.isMainThread, "CefRuntime.initialize must run on the main thread.")
        guard !isInitialized else { throw CefError.alreadyInitialized }

        // CEFApplication must exist before cef_initialize.
        if NSApp == nil {
            CEFApplication.install()
        } else {
            precondition(
                NSApp is CEFApplication,
                """
                NSApp is \(type(of: NSApp!)), not CEFApplication. Call \
                CefRuntime.initialize() (or CEFApplication.install()) before \
                anything else touches NSApp — i.e. before NSApplicationMain \
                or SwiftUI's App.main().
                """
            )
        }

        let frameworkBinary = try Self.resolveFrameworkBinary(override: configuration.frameworkDirectory)
        guard ccef_load_framework(frameworkBinary.path) != 0 else {
            throw CefError.loadFailed(String(cString: ccef_loader_error()))
        }

        // Configure the API version and verify ABI compatibility before any
        // other CEF call.
        do {
            try Self.verifyAPIHash()
        } catch {
            ccef_unload_framework()
            throw error
        }

        // Custom schemes must be registered identically in every process;
        // the reserved bridge scheme is always present so CefBridge works
        // without configuration.
        var customSchemes = configuration.customSchemes
        if !customSchemes.contains(where: { $0.name == CefBridge.schemeName }) {
            customSchemes.append(CefBridge.customScheme)
        }

        let pump = CefMessagePump()
        let context = CefAppContext(
            extraSwitches: configuration.extraCommandLineSwitches,
            useMockKeychain: configuration.safeStorage.resolved() == .mockKeychain,
            userCommandLineHook: configuration.onBeforeCommandLineProcessing,
            customSchemes: customSchemes,
            pump: pump
        )
        let app = context.makeApp()
        let mapped = MappedCefSettings(
            configuration: configuration,
            frameworkDirectory: frameworkBinary.deletingLastPathComponent()
        )

        var mainArgs = cef_main_args_t(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
        // cef_initialize consumes our +1 reference on `app`.
        let result = cef_initialize(&mainArgs, &mapped.raw, app, nil)
        guard result != 0 else {
            let exitCode = cef_get_exit_code()
            ccef_unload_framework()
            throw CefError.initializationFailed(exitCode: exitCode)
        }

        appContext = context
        settings = mapped
        self.configuration = configuration
        messagePump = pump
        pump.start()
        CEFApplication.setTerminateHandler(cefTerminateHandler)
        isInitialized = true

        // Route cefswift://bridge/* to the bridge dispatcher.
        registerSchemeHandler(scheme: CefBridge.schemeName, handler: CefBridgeSchemeHandler(bridge: bridge))
    }

    // MARK: Custom scheme handlers

    /// Registers `handler` as the content source for `scheme` (optionally
    /// restricted to `domain` for standard schemes). Call after
    /// ``initialize(configuration:)``; for custom (non-built-in) schemes the
    /// scheme must also be declared in ``CefConfiguration/customSchemes``.
    /// Registering again for the same scheme/domain replaces the handler.
    public func registerSchemeHandler(scheme: String, domain: String? = nil, handler: some CefSchemeHandler) {
        precondition(
            isInitialized,
            "CefRuntime.registerSchemeHandler requires initialize() to have succeeded first."
        )
        let factory = SchemeHandlerFactory(handler: handler)
        // cef_register_scheme_handler_factory consumes our +1 factory ref.
        let factoryPointer = factory.makeFactory()
        let registered = CefStringUtil.withCefString(scheme) { cefScheme in
            if let domain {
                return CefStringUtil.withCefString(domain) { cefDomain in
                    cef_register_scheme_handler_factory(cefScheme, cefDomain, factoryPointer)
                }
            }
            return cef_register_scheme_handler_factory(cefScheme, nil, factoryPointer)
        }
        if registered == 0 {
            FileHandle.standardError.write(
                Data("CefSwift: cef_register_scheme_handler_factory failed for scheme '\(scheme)'.\n".utf8))
        }
    }

    /// Shuts CEF down and unloads the framework. All browsers and pending
    /// authorization operations must already be drained. Call once, at exit.
    public func shutdown() {
        guard isInitialized else { return }
        precondition(browsers.isEmpty && !CefChromeBrowser.hasLiveWindows && !hasLiveAuxiliaryWindows,
                     "Close all Chromium browsers and windows before shutdown")
        if CefAuxiliaryAdmissionLease.isSupported {
            do {
                // Direct SDK shutdown cannot bypass the pre-Browser auth
                // barrier. Acquire synchronously and keep it through shutdown.
                if auxiliaryAdmission == nil { auxiliaryAdmission = try CefAuxiliaryAdmissionLease.acquireProcess() }
                guard let lease = auxiliaryAdmission, try lease.status().isQuiescent else {
                    preconditionFailure("Drain native authorization operations before shutdown")
                }
            } catch {
                preconditionFailure("Native authorization cleanup is unavailable: \(error.localizedDescription)")
            }
        }
        messagePump?.stop()
        messagePump = nil
        CEFApplication.setTerminateHandler(nil)
        onReadyToTerminate = nil
        auxiliaryFinalCleanupStarted = false
        onTerminationChanged = nil
        beforeClosingDocuments = nil
        terminationAttemptID = nil
        finalTerminationAttemptID = nil
        finalTerminationCompletion = nil
        scheduledTerminationAttemptID = nil
        isPreparingTermination = false
        isTerminationRequested = false
        // Keep admission closed through native shutdown. The optional export
        // must never be called after unloading its framework.
        auxiliaryDrainTask?.cancel(); auxiliaryDrainTask = nil
        auxiliaryDrainAttemptID = nil
        cef_shutdown()
        auxiliaryAdmission = nil
        onAuxiliaryAdmissionFailure = nil
        ccef_unload_framework()
        appContext = nil
        settings = nil
        configuration = nil
        isInitialized = false
    }

    // MARK: Helper process

    /// Entry point for helper executables (`cef-helper`'s main.swift calls
    /// only this). Seals the macOS sandbox when requested (i.e. unless CEF
    /// passed `--no-sandbox`), loads the framework from the helper-relative
    /// bundle location (or `CEF_FRAMEWORK_PATH`), mirrors any custom scheme
    /// registration forwarded on the command line, runs
    /// `cef_execute_process`, and exits with its return code. Never returns.
    public static func helperMain() -> Never {
        let arguments = CommandLine.arguments

        // Sandbox: when the browser process runs with no_sandbox=0, CEF stops
        // passing --no-sandbox to subprocesses; each helper must then load
        // libcef_sandbox.dylib and seal itself BEFORE the framework loads.
        if !arguments.contains("--no-sandbox") {
            guard ccef_sandbox_initialize(CommandLine.argc, CommandLine.unsafeArgv) != 0 else {
                let message = String(cString: ccef_sandbox_error())
                FileHandle.standardError.write(Data("cef-helper: sandbox initialization failed: \(message)\n".utf8))
                exit(125)
            }
        }

        let binary: URL
        do {
            binary = try resolveHelperFrameworkBinary()
        } catch {
            FileHandle.standardError.write(Data("cef-helper: \(error)\n".utf8))
            exit(125)
        }
        guard ccef_load_framework(binary.path) != 0 else {
            let message = String(cString: ccef_loader_error())
            FileHandle.standardError.write(Data("cef-helper: \(message)\n".utf8))
            exit(125)
        }
        do {
            try verifyAPIHash()
        } catch {
            FileHandle.standardError.write(Data("cef-helper: \(error)\n".utf8))
            exit(125)
        }

        // Custom schemes must be registered in every process: the browser
        // forwarded its list via --cefswift-schemes (see CefAppContext).
        let customSchemes = CefCustomScheme.parse(fromArguments: arguments)
        var helperApp: UnsafeMutablePointer<cef_app_t>?
        if !customSchemes.isEmpty {
            // cef_execute_process consumes our +1 reference on the app.
            helperApp = CefHelperAppContext(customSchemes: customSchemes).makeApp()
        }

        var mainArgs = cef_main_args_t(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
        let code = cef_execute_process(&mainArgs, helperApp, nil)
        exit(code)
    }

    // MARK: Framework resolution

    nonisolated static let frameworkBinaryName = "Chromium Embedded Framework"
    nonisolated static let frameworkBundleName = "Chromium Embedded Framework.framework"

    /// Resolves the framework binary for the browser process:
    /// explicit override → app bundle Frameworks dir → CEF_FRAMEWORK_PATH.
    nonisolated static func resolveFrameworkBinary(override: URL?) throws(CefError) -> URL {
        var searched: [String] = []

        if let override {
            let candidate = binaryURL(for: override)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            searched.append("frameworkDirectory override: \(candidate.path)")
        }

        if let frameworks = Bundle.main.privateFrameworksURL {
            let candidate = frameworks
                .appendingPathComponent(frameworkBundleName)
                .appendingPathComponent(frameworkBinaryName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            searched.append("app bundle: \(candidate.path)")
        }

        if let env = ProcessInfo.processInfo.environment["CEF_FRAMEWORK_PATH"], !env.isEmpty {
            let candidate = binaryURL(for: URL(fileURLWithPath: env))
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            searched.append("CEF_FRAMEWORK_PATH: \(candidate.path)")
        } else {
            searched.append("CEF_FRAMEWORK_PATH: (not set)")
        }

        throw CefError.frameworkNotFound("Searched: \(searched.joined(separator: "; ")).")
    }

    /// Helper-process resolution: CEF_FRAMEWORK_PATH override, then the
    /// standard helper-relative location
    /// `<exe>/../../../Chromium Embedded Framework.framework/...`
    /// (helpers live in `Contents/Frameworks/` of the main app).
    nonisolated static func resolveHelperFrameworkBinary() throws(CefError) -> URL {
        if let env = ProcessInfo.processInfo.environment["CEF_FRAMEWORK_PATH"], !env.isEmpty {
            let candidate = binaryURL(for: URL(fileURLWithPath: env))
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidate = executable
            .deletingLastPathComponent()  // MacOS/
            .deletingLastPathComponent()  // Contents/
            .deletingLastPathComponent()  // <Helper>.app/  -> Contents/Frameworks/
            .deletingLastPathComponent()
            .appendingPathComponent(frameworkBundleName)
            .appendingPathComponent(frameworkBinaryName)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw CefError.frameworkNotFound("Helper searched: \(candidate.path).")
    }

    /// Accepts either a `.framework` directory or a direct binary path.
    nonisolated private static func binaryURL(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return url.appendingPathComponent(frameworkBinaryName)
        }
        return url
    }

    /// Configures the API version (first CEF call in every process) and
    /// verifies the platform API hash against the vendored headers.
    nonisolated static func verifyAPIHash() throws(CefError) {
        guard let hash = cef_api_hash(CCEF_API_VERSION_VALUE, 0) else {
            throw CefError.loadFailed("cef_api_hash returned NULL for API version \(CCEF_API_VERSION_VALUE).")
        }
        let actual = String(cString: hash)
        let expected = CCEF_EXPECTED_API_HASH_PLATFORM
        guard actual == expected else {
            throw CefError.apiHashMismatch(expected: expected, actual: actual)
        }
    }

    // MARK: Browser registry / termination

    func registerBrowser(_ browser: CefBrowser) {
        guard browser.id >= 0 else { return }
        browsers[browser.id] = browser
        if isTerminationRequested, let attempt = terminationAttemptID {
            // A profile may finish initializing after Quit was requested.
            // Wait until creation attaches the child to its parent, then apply
            // the same child-before-root close ordering to the new browser.
            DispatchQueue.main.async { [self] in
                guard isInitialized, isTerminationRequested, !isPreparingTermination,
                      terminationAttemptID == attempt else { return }
                _ = handleTerminationRequest()
            }
        }
    }

    /// All live browsers registered with the runtime. Used by ``CefBridge``
    /// to broadcast events to every page.
    var activeBrowsers: [CefBrowser] { browsers.values.filter { !auxiliaryBrowserIDs.contains($0.id) } }

    /// Chrome-created auth, developer and other native windows. They participate
    /// in lifecycle/termination, without becoming application document tabs.
    public var auxiliaryBrowsers: [CefBrowser] {
        auxiliaryBrowserIDs.compactMap { browsers[$0] }
    }

    /// Closes only this exact registered Chrome-created browser. Ordinary
    /// beforeunload remains authoritative; callers await closure before releasing
    /// its request context or committing a profile deletion.
    public func closeAuxiliaryBrowser(_ browser: CefBrowser) async throws {
        guard auxiliaryBrowserIDs.contains(browser.id), browsers[browser.id] === browser else {
            if browser.isClosed { return }
            throw CefDevToolsError.rejected("The native auxiliary browser is no longer owned by this runtime.")
        }
        observeAuxiliaryWindow(browser)
        try await browser.closeAndWait()
    }

    public func hasAuxiliaryWindows(in profile: CefProfile) -> Bool {
        pruneReleasedAuxiliaryWindows()
        return auxiliaryBrowsers.contains { $0.belongs(to: profile) }
            || auxiliaryWindows.values.contains { $0.window != nil && $0.context?.belongs(to: profile) == true }
    }

    public func closeAuxiliaryBrowsers(in profile: CefProfile) async throws {
        // A site can open another window during close. Reconcile that native
        // identity, but fail safely rather than running an unbounded close loop.
        for _ in 0..<128 {
            try Task.checkCancellation()
            guard let browser = auxiliaryBrowsers.first(where: { $0.belongs(to: profile) }) else {
                let windows = auxiliaryWindows.compactMap { key, value in
                    value.context?.belongs(to: profile) == true ? key : nil
                }
                for window in windows { try await waitForAuxiliaryWindow(window) }
                if !hasAuxiliaryWindows(in: profile) { return }
                continue
            }
            try await closeAuxiliaryBrowser(browser)
        }
        throw CefDevToolsError.rejected("The profile keeps opening native windows. Close them before deleting its data.")
    }

    private var hasLiveAuxiliaryWindows: Bool {
        pruneReleasedAuxiliaryWindows()
        return !auxiliaryWindows.isEmpty
    }

    private func pruneReleasedAuxiliaryWindows() {
        for id in auxiliaryWindows.keys.filter({ auxiliaryWindows[$0]?.window == nil }) {
            auxiliaryWindowDidClose(id)
        }
        closedAuxiliaryWindows = closedAuxiliaryWindows.filter { $0.value.window != nil }
    }

    func observeAuxiliaryWindow(_ browser: CefBrowser) {
        guard auxiliaryBrowserIDs.contains(browser.id), let window = browser.nativeView?.window else { return }
        let id = ObjectIdentifier(window)
        closedAuxiliaryWindows = closedAuxiliaryWindows.filter { $0.value.window != nil }
        guard closedAuxiliaryWindows[id]?.window !== window else { return }
        auxiliaryWindowIDs[browser.id] = id
        guard auxiliaryWindows[id] == nil else { return }
        let entry = AuxiliaryWindow(window: window, context: browser.existingRequestContext())
        auxiliaryWindows[id] = entry
        entry.observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: nil, queue: nil) { [weak self] notification in
            guard let window = notification.object as? NSWindow, ObjectIdentifier(window) == id else { return }
            MainActor.assumeIsolated { self?.auxiliaryWindowDidClose(id) }
        }
    }

    private func auxiliaryWindowDidClose(_ id: ObjectIdentifier) {
        guard let entry = auxiliaryWindows.removeValue(forKey: id) else { return }
        if let observer = entry.observer { NotificationCenter.default.removeObserver(observer) }
        // A later browser-close callback can still expose the same NSWindow.
        // Remember it weakly without retaining its native request context.
        if let window = entry.window {
            closedAuxiliaryWindows[id] = AuxiliaryWindow(window: window, context: nil)
        }
        auxiliaryWindowIDs = auxiliaryWindowIDs.filter { $0.value != id }
        for waiter in entry.waiters.values { waiter.resume() }
        scheduleTerminationIfReady()
    }

    private func waitForAuxiliaryWindow(_ id: ObjectIdentifier) async throws {
        guard let entry = auxiliaryWindows[id] else { return }
        if entry.window == nil { auxiliaryWindowDidClose(id); return }
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { entry.waiters[token] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.auxiliaryWindows[id]?.waiters.removeValue(forKey: token)?.resume(throwing: CancellationError())
            }
        }
    }

    func registerAuxiliaryBrowser(_ browser: CefBrowser) {
        guard browser.id >= 0 else { return }
        auxiliaryBrowserIDs.insert(browser.id)
        registerBrowser(browser)
        observeAuxiliaryWindow(browser)
        // CEF calls OnAfterCreated before SetBrowser/TabStripModel insertion.
        // Read the resulting exact window after that native stack completes.
        DispatchQueue.main.async { [weak self, weak browser] in
            guard let browser, !browser.isClosed else { return }
            self?.observeAuxiliaryWindow(browser)
        }
    }

    func unregisterBrowser(id: Int32) {
        auxiliaryBrowserIDs.remove(id)
        browsers[id] = nil
        scheduleTerminationIfReady()
    }

    func chromeWindowDidClose() {
        // Keep the native shell alive until every child document accepts its
        // close. A beforeunload "Stay" must leave a usable parent window.
        if isTerminationRequested, !isPreparingTermination, let attempt = terminationAttemptID,
           !CefChromeBrowser.hasHostedWindows {
            DispatchQueue.main.async { [self] in
                guard isInitialized, isTerminationRequested, !isPreparingTermination,
                      terminationAttemptID == attempt, !CefChromeBrowser.hasHostedWindows else { return }
                let roots = CefChromeBrowser.rootBrowserIDs
                for browser in Array(browsers.values)
                    where roots.contains(browser.id) && !browser.closingForTermination {
                    guard isTerminationRequested, !isPreparingTermination,
                          terminationAttemptID == attempt else { return }
                    browser.closingForTermination = true
                    browser.close(force: false)
                }
                scheduleTerminationIfReady()
            }
        }
        scheduleTerminationIfReady()
    }

    private func scheduleTerminationIfReady() {
        guard isTerminationRequested, !isPreparingTermination, let attempt = terminationAttemptID,
              browsers.isEmpty, !CefChromeBrowser.hasLiveWindows, !hasLiveAuxiliaryWindows,
              scheduledTerminationAttemptID == nil else { return }
        guard auxiliaryAdmissionIsQuiescent(attempt: attempt) else { return }
        // on_before_close is still on CEF's message-loop stack. Calling
        // cef_shutdown synchronously here destroys objects that the enclosing
        // close callback still needs. Let that callback and work slice return
        // before re-entering AppKit termination.
        scheduledTerminationAttemptID = attempt
        DispatchQueue.main.async { [self] in
            // An older queued callback cannot clear a replacement attempt's
            // scheduled flag, even if cancellation and retry share one turn.
            guard scheduledTerminationAttemptID == attempt else { return }
            scheduledTerminationAttemptID = nil
            guard isInitialized, isTerminationRequested, !isPreparingTermination,
                  terminationAttemptID == attempt, browsers.isEmpty,
                  !CefChromeBrowser.hasLiveWindows, !hasLiveAuxiliaryWindows else { return }
            guard auxiliaryAdmissionIsQuiescent(attempt: attempt) else { return }
            if let final = finalTerminationCompletion, final.attempt == attempt {
                finalTerminationCompletion = nil
                // This final check and the event-loop stop are synchronous on
                // the native UI actor. No late browser can enter between them.
                final.run()
            } else if finalTerminationAttemptID == attempt {
                return // The exact final completion already ran.
            } else if let onReadyToTerminate {
                auxiliaryFinalCleanupStarted = true
                onReadyToTerminate()
            } else {
                shutdown()
                NSApp.terminate(nil)
            }
        }
    }

    /// Capture this exact Quit attempt before awaiting application cleanup.
    /// Invoke the returned closure afterward: it drains any Chrome-created
    /// browsers/windows admitted during that await before calling completion.
    /// Cancellation or a replacement Quit makes the old closure a no-op.
    public func deferredTerminationCompletion(_ completion: @escaping () -> Void) -> (() -> Void)? {
        guard isInitialized, isTerminationRequested, !isPreparingTermination,
              let attempt = terminationAttemptID else { return nil }
        return { [weak self] in self?.completeTermination(attempt: attempt, completion: completion) }
    }

    private func completeTermination(attempt: UUID, completion: @escaping () -> Void) {
        guard isInitialized, isTerminationRequested, !isPreparingTermination,
              terminationAttemptID == attempt, finalTerminationAttemptID != attempt else { return }
        finalTerminationAttemptID = attempt
        finalTerminationCompletion = (attempt, completion)
        // registerBrowser normally queues this close. Reconcile here too so a
        // completion cannot depend on the relative order of the two callbacks.
        _ = handleTerminationRequest()
        scheduleTerminationIfReady()
    }

    /// Called from CEFApplication's terminate:. Returns true when the app
    /// may terminate immediately.
    private func auxiliaryAdmissionIsQuiescent(attempt: UUID) -> Bool {
        guard let lease = auxiliaryAdmission else { return true }
        // A broken native lease cannot be repaired by repeatedly scheduling
        // termination. Keep the context and report once for this attempt.
        guard auxiliaryAdmissionFailureAttemptID != attempt else { return false }
        do {
            if try lease.status().isQuiescent { return true }
        } catch {
            reportAuxiliaryAdmissionFailure(error, attempt: attempt)
            return false
        }
        guard auxiliaryDrainAttemptID != attempt else { return false }
        auxiliaryDrainAttemptID = attempt
        auxiliaryDrainTask = Task { @MainActor [weak self] in
            do {
                try await lease.waitForQuiescence()
                guard let self, self.terminationAttemptID == attempt,
                      self.auxiliaryDrainAttemptID == attempt,
                      self.isTerminationRequested else { return }
                self.auxiliaryDrainTask = nil
                self.auxiliaryDrainAttemptID = nil
                self.scheduleTerminationIfReady()
            } catch is CancellationError {
                // Only the matching attempt owns its task/lease. Cancellation
                // clears fields synchronously before a replacement can start.
            } catch {
                guard let self, self.terminationAttemptID == attempt,
                      self.auxiliaryDrainAttemptID == attempt else { return }
                self.auxiliaryDrainTask = nil
                self.auxiliaryDrainAttemptID = nil
                self.reportAuxiliaryAdmissionFailure(error, attempt: attempt)
            }
        }
        return false
    }

    private func reportAuxiliaryAdmissionFailure(_ error: Error, attempt: UUID) {
        guard terminationAttemptID == attempt,
              auxiliaryAdmissionFailureAttemptID != attempt else { return }
        auxiliaryAdmissionFailureAttemptID = attempt
        onAuxiliaryAdmissionFailure?(error)
    }

    @discardableResult
    private func releaseAuxiliaryAdmissionForCancelledAttempt(attempt: UUID) -> Bool {
        guard terminationAttemptID == attempt else { return false }
        auxiliaryDrainAttemptID = nil
        let pending = auxiliaryDrainTask; auxiliaryDrainTask = nil
        pending?.cancel()
        do { try auxiliaryAdmission?.release() }
        catch {
            // A native fence which could not be released still owns the Quit
            // attempt. Do not publish a usable cancellation with admission shut.
            reportAuxiliaryAdmissionFailure(error, attempt: attempt)
            return false
        }
        auxiliaryAdmission = nil
        auxiliaryAdmissionFailureAttemptID = nil
        return true
    }

    /// Opaque authority to act on one failed Quit attempt. A delayed sheet
    /// cannot cancel or retry a replacement attempt.
    public struct AuxiliaryTerminationFailure {
        fileprivate let attempt: UUID
        public let canCancelQuit: Bool
    }

    public var auxiliaryTerminationFailure: AuxiliaryTerminationFailure? {
        guard isInitialized, isTerminationRequested, let attempt = terminationAttemptID,
              auxiliaryAdmissionFailureAttemptID == attempt else { return nil }
        return AuxiliaryTerminationFailure(attempt: attempt,
            canCancelQuit: !auxiliaryFinalCleanupStarted)
    }

    @discardableResult
    public func retryAuxiliaryTermination(_ failure: AuxiliaryTerminationFailure) -> Bool {
        guard isInitialized, isTerminationRequested,
              terminationAttemptID == failure.attempt,
              auxiliaryAdmissionFailureAttemptID == failure.attempt else { return false }
        // Only this explicit host action clears the error latch. A scheduler
        // callback cannot create a repeated alert or spin on a failing ABI.
        auxiliaryAdmissionFailureAttemptID = nil
        _ = handleTerminationRequest()
        return true
    }

    @discardableResult
    public func cancelAuxiliaryTermination(_ failure: AuxiliaryTerminationFailure) throws -> Bool {
        guard isInitialized, isTerminationRequested, !auxiliaryFinalCleanupStarted,
              failure.canCancelQuit, terminationAttemptID == failure.attempt,
              auxiliaryAdmissionFailureAttemptID == failure.attempt else { return false }
        // Release must succeed before cancellation is published. On failure,
        // retain both the lease and the original failed-attempt authority.
        try auxiliaryAdmission?.release()
        auxiliaryAdmission = nil
        auxiliaryAdmissionFailureAttemptID = nil
        auxiliaryDrainAttemptID = nil
        let pending = auxiliaryDrainTask; auxiliaryDrainTask = nil
        pending?.cancel()
        terminationAttemptID = nil
        finalTerminationAttemptID = nil
        finalTerminationCompletion = nil
        scheduledTerminationAttemptID = nil
        isPreparingTermination = false
        isTerminationRequested = false
        onTerminationChanged?(false)
        return true
    }

    func handleTerminationRequest() -> Bool {
        guard isInitialized else { return true }
        if !isTerminationRequested {
            // Synchronous native admission precedes every async preparation.
            // This authority outlives the last browser/DevTools transport.
            do {
                if auxiliaryAdmission == nil { auxiliaryAdmission = try CefAuxiliaryAdmissionLease.acquireProcess() }
            } catch { onAuxiliaryAdmissionFailure?(error); return false }
            let attempt = UUID()
            let prepare = beforeClosingDocuments
            terminationAttemptID = attempt
            isTerminationRequested = true
            // Publish the preparation gate before invoking client callbacks:
            // a reentrant Quit must not start unloading ahead of this barrier.
            isPreparingTermination = prepare != nil
            onTerminationChanged?(true)
            guard isInitialized, isTerminationRequested, terminationAttemptID == attempt else { return false }
            if let prepare {
                Task { @MainActor [weak self] in
                    guard let self, self.isInitialized, self.isTerminationRequested,
                          self.terminationAttemptID == attempt else { return }
                    let accepted = await prepare()
                    // Cancellation can be followed by another Quit while a
                    // native snapshot drains. Its predecessor may not clear
                    // either flag or veto the replacement attempt.
                    guard self.isInitialized, self.isTerminationRequested,
                          self.terminationAttemptID == attempt else { return }
                    self.isPreparingTermination = false
                    if accepted { _ = self.handleTerminationRequest() }
                    else {
                        guard self.releaseAuxiliaryAdmissionForCancelledAttempt(attempt: attempt) else { return }
                        self.terminationAttemptID = nil
                        self.isTerminationRequested = false
                        self.onTerminationChanged?(false)
                    }
                }
            }
        }
        guard !isPreparingTermination, let attempt = terminationAttemptID else { return false }
        let roots = CefChromeBrowser.rootBrowserIDs
        let hasChildren = CefChromeBrowser.hasHostedWindows
        for browser in Array(browsers.values)
            where !browser.closingForTermination && (!hasChildren || !roots.contains(browser.id)) {
            guard isTerminationRequested, !isPreparingTermination,
                  terminationAttemptID == attempt else { return false }
            browser.closingForTermination = true
            browser.close(force: false)
        }
        scheduleTerminationIfReady()
        return false
    }

    func cancelTerminationRequest(for browser: CefBrowser) {
        browser.closingForTermination = false
        guard isTerminationRequested, let attempt = terminationAttemptID else { return }
        guard releaseAuxiliaryAdmissionForCancelledAttempt(attempt: attempt) else { return }
        terminationAttemptID = nil
        finalTerminationAttemptID = nil
        finalTerminationCompletion = nil
        scheduledTerminationAttemptID = nil
        isPreparingTermination = false
        isTerminationRequested = false
        onTerminationChanged?(false)
    }
}
