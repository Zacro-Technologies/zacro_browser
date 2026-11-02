import Foundation
import Darwin

/// Only Zacro-owned processes use these transports. No shell, personal CLI home, or inherited secrets.
enum ProviderProcessPolicy {
  static func stopAndWait(_ process: Process?) async {
    guard let process else { return }
    if process.isRunning { process.terminate() }
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        if process.processIdentifier > 0 { process.waitUntilExit() }
        continuation.resume()
      }
    }
  }
  static func environment(home: URL, provider: NativeAIProvider) -> [String: String] {
    let allowed = Set(["TMPDIR", "TMP", "TEMP", "LANG", "LC_ALL", "LC_CTYPE", "TZ"])
    var result = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
    result["HOME"] = home.path
    result["PATH"] = "/usr/bin:/bin"
    if provider == .codex { result["CODEX_HOME"] = home.path }
    else {
      result["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent("config").path
      result["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] = "1"
      result["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    }
    return result
  }
  static func prepare(_ home: URL) throws -> URL {
    let cwd = home.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return cwd
  }
  static func nativeExecutable(_ url: URL) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: url.path),
      let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let bytes = (try? handle.read(upToCount: 4)) ?? Data()
    return [Data([0xcf,0xfa,0xed,0xfe]),Data([0xfe,0xed,0xfa,0xcf]),Data([0xca,0xfe,0xba,0xbe]),Data([0xbe,0xba,0xfe,0xca])].contains(bytes)
  }
}

final class OwnedProviderCommand: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false
  private var timedOut = false
  private var exceededMemory = false
  private let running = DispatchGroup()
  func cancel() {
    let child = lock.withLock { cancelled = true; return process }
    Self.terminate(child)
  }
  func shutdown() async {
    cancel()
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async { [self] in running.wait(); continuation.resume() }
    }
  }
  private func expire() {
    lock.withLock { timedOut = true }; cancel()
  }
  private func checkMemory(_ process: Process, maximum: UInt64) {
    guard process.isRunning else { return }
    var info = rusage_info_v2()
    let status = withUnsafeMutablePointer(to:&info) { pointer in
      pointer.withMemoryRebound(to:rusage_info_t?.self,capacity:1) { proc_pid_rusage(process.processIdentifier,RUSAGE_INFO_V2,$0) }
    }
    if status == 0 && info.ri_resident_size > maximum { lock.withLock { exceededMemory = true }; cancel() }
  }
  private static func terminate(_ child: Process?) {
    guard let child, child.isRunning else { return }
    child.terminate()
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
      if child.isRunning { kill(child.processIdentifier,SIGKILL) }
    }
  }
  func run(executable: URL, arguments: [String], home: URL, provider: NativeAIProvider,
           input: String? = nil, timeout: TimeInterval = 120, maximum: Int = 2 * 1024 * 1024,
           maximumResidentBytes: UInt64? = nil) async throws -> (Int32, Data) {
    try Task.checkCancellation()
    running.enter(); defer { running.leave() }
    return try await withTaskCancellationHandler {
      try await Task.detached(priority: .userInitiated) { [self] in
        let process = Process(), output = Pipe(), stdin = Pipe()
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = try ProviderProcessPolicy.prepare(home)
        process.environment = ProviderProcessPolicy.environment(home: home, provider: provider)
        process.standardOutput = output; process.standardInput = stdin; process.standardError = FileHandle.nullDevice
        let stopped = lock.withLock { self.process = process; return cancelled }
        guard !stopped else { throw ServiceError("CANCELLED", "Request stopped.") }
        do { try process.run() } catch { throw ServiceError("UNAVAILABLE", "The official provider executable could not start.") }
        if lock.withLock({ cancelled }) { Self.terminate(process) }
        let expired = DispatchWorkItem { [weak self] in self?.expire() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expired)
        let memoryTimer: DispatchSourceTimer?
        if let maximumResidentBytes {
          let monitor = DispatchSource.makeTimerSource(queue:.global(qos:.utility))
          monitor.schedule(deadline:.now() + .milliseconds(100),repeating:.milliseconds(100))
          monitor.setEventHandler { [weak self,weak process] in if let process { self?.checkMemory(process,maximum:maximumResidentBytes) } }
          monitor.resume(); memoryTimer = monitor
        } else { memoryTimer = nil }
        defer {
          if process.isRunning { Self.terminate(process); process.waitUntilExit() }
          memoryTimer?.cancel()
          expired.cancel(); try? stdin.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
          lock.withLock { self.process = nil }
        }
        if let input { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        if input != nil || !arguments.contains("login") { try stdin.fileHandleForWriting.close() }
        var bytes = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
          guard bytes.count + chunk.count <= maximum else { Self.terminate(process); throw ServiceError("RESPONSE_SIZE", "The provider returned an oversized response.") }
          bytes.append(chunk)
        }
        process.waitUntilExit()
        let state = lock.withLock { (cancelled,timedOut,exceededMemory) }
        if state.2 { throw ServiceError("MEMORY", "The process exceeded its supported memory limit.") }
        if state.1 { throw ServiceError("TIMEOUT", "The provider request exceeded its deadline.") }
        if state.0 { throw ServiceError("CANCELLED", "The provider request stopped.") }
        return (process.terminationStatus, bytes)
      }.value
    } onCancel: { cancel() }
  }
}

/// Private newline JSON-RPC transport. Server requests are always denied, never executed.
actor ProviderRPC {
  private var process: Process?
  private var input: FileHandle?
  private var buffer = Data()
  private var nextID = 1
  private var pending: [Int: CheckedContinuation<ServiceJSON, Error>] = [:]
  private var deadlines: [Int: Task<Void, Never>] = [:]
  private let notification: @Sendable (ServiceJSON) async -> Void
  private let inputQueue = DispatchQueue(label: "tech.zacro.provider-rpc-input", qos: .userInitiated)
  init(notification: @escaping @Sendable (ServiceJSON) async -> Void) { self.notification = notification }
  func start(executable: URL, arguments: [String], home: URL) throws {
    guard process == nil else { return }
    let child = Process(), stdin = Pipe(), stdout = Pipe()
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    child.executableURL = executable; child.arguments = arguments
    child.currentDirectoryURL = try ProviderProcessPolicy.prepare(home)
    child.environment = ProviderProcessPolicy.environment(home: home, provider: .codex)
    child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      if chunk.isEmpty { handle.readabilityHandler = nil }
      Task { await self?.receive(chunk) }
    }
    child.terminationHandler = { [weak self] _ in Task { await self?.ended() } }
    do { try child.run() } catch { throw ServiceError("UNAVAILABLE", "The bundled Codex runtime could not start.") }
    process = child; input = stdin.fileHandleForWriting
  }
  func call(_ method: String, _ params: ServiceJSON = [:], timeout: TimeInterval = 20) async throws -> ServiceJSON {
    try Task.checkCancellation()
    let id = nextID; nextID += 1
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[id] = continuation
        deadlines[id] = Task { [weak self] in
          try? await Task.sleep(for: .seconds(timeout))
          if !Task.isCancelled { await self?.fail(id, ServiceError("TIMEOUT", "Codex took too long to respond.")) }
        }
        Task { [self] in
          do { try await send(["id":.number(Double(id)),"method":.string(method),"params":params]) }
          catch { fail(id, error) }
        }
      }
    } onCancel: { Task { await self.fail(id, ServiceError("CANCELLED", "Request stopped.")) } }
  }
  func notify(_ method: String, _ params: ServiceJSON = [:]) async throws { try await send(["method":.string(method),"params":params]) }
  private func send(_ message: ServiceJSON) async throws {
    guard process?.isRunning == true, let input else { throw ServiceError("UNAVAILABLE", "The Codex connection is not running.") }
    let data = try message.encoded() + Data([10])
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      inputQueue.async {
        do { try input.write(contentsOf: data); continuation.resume() }
        catch { continuation.resume(throwing: ServiceError("UNAVAILABLE", "The provider input connection closed.")) }
      }
    }
  }
  private func receive(_ data: Data) async {
    guard process != nil, !data.isEmpty else { return }
    buffer.append(data)
    guard buffer.count <= 4 * 1024 * 1024 else { await stop(error: ServiceError("PROTOCOL", "Codex returned an oversized message.")); return }
    while let end = buffer.firstIndex(of: 10) {
      let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
      if line.isEmpty { continue }
      guard let message = try? ServiceJSON.decode(line) else { await stop(error: ServiceError("PROTOCOL", "Codex returned invalid JSON.")); return }
      if message.contains("method") && message.contains("id") {
        Task { [self] in try? await send(["id":message["id"],"error":["code":-32601,"message":"Zacro does not permit local tools or approval requests."]]) }
        await notification(["method":"zacro/tool-policy","params":[:]])
        await stop(error: ServiceError("TOOL_POLICY", "Codex requested a tool that Zacro does not permit.")); return
      }
      if message.contains("id") {
        let id = message["id"].int
        deadlines.removeValue(forKey: id)?.cancel()
        guard let continuation = pending.removeValue(forKey: id) else { continue }
        if message.contains("error") { continuation.resume(throwing: CodexSubscription.safeError(message["error"])) }
        else { continuation.resume(returning: message["result"]) }
      } else { await notification(message) }
    }
  }
  private func fail(_ id: Int, _ error: Error) {
    deadlines.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: error)
  }
  private func ended() async {
    await stop(error: ServiceError("UNAVAILABLE", "The Codex connection stopped. Please reconnect."))
    await notification(["method":"zacro/ended","params":[:]])
  }
  func stop(error: Error = ServiceError("CLOSED", "The Codex connection closed.")) async {
    let child = process; process = nil
    let writer = input; input = nil; buffer = Data()
    for id in Array(pending.keys) { fail(id, error) }
    await ProviderProcessPolicy.stopAndWait(child)
    // Keep the descriptor owned until previously enqueued writes have drained.
    // Killing a non-reading child unblocks its full pipe without blocking this actor.
    await withCheckedContinuation { continuation in
      inputQueue.async { try? writer?.close(); continuation.resume() }
    }
  }
}
