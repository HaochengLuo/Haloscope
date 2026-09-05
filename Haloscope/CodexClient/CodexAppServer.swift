import Foundation
import OSLog

enum MonitoringServerConfiguration {
    // These overrides apply only to our child. Never change the user's Codex
    // configuration or retry without them if a CLI version rejects a flag.
    static let arguments = ["app-server", "--stdio",
                            "--disable", "plugins", "--disable", "remote_plugin",
                            "--disable", "apps", "--disable", "workspace_dependencies"]
}

actor CodexAppServerProcess {
    private var process: Process?; private var input: FileHandle?
    private var output: FileHandle?; private var errorOutput: FileHandle?
    private var outputBuffer = Data()
    private var generation = 0
    private var stoppingTask: Task<Void,Never>?
    var onLine: (@Sendable (Data) async -> Void)?
    var onTermination: (@Sendable () async -> Void)?
    func start(path: String) throws {
        guard process == nil, stoppingTask == nil else { throw RPCError.disconnected }
        generation += 1; let currentGeneration = generation
        let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = MonitoringServerConfiguration.arguments
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        try p.run(); process = p; input = stdin.fileHandleForWriting; outputBuffer.removeAll(keepingCapacity:true)
        let stdoutHandle = stdout.fileHandleForReading, stderrHandle = stderr.fileHandleForReading
        output = stdoutHandle; errorOutput = stderrHandle
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                guard let self else { return }
                if data.isEmpty { await self.didExit(generation:currentGeneration) }
                else { await self.consume(data,generation:currentGeneration) }
            }
        }
        stderrHandle.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
    }
    private func consume(_ data: Data, generation incomingGeneration: Int) async {
        guard incomingGeneration == generation else { return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of:0x0a) {
            let line = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            await onLine?(line)
        }
    }
    private func didExit(generation exitedGeneration: Int) async {
        guard exitedGeneration == generation else { return }
        // stdout EOF alone does not prove that the child has exited.
        let handler = onTermination
        await stop()
        await handler?()
    }
    func send(_ data: Data) throws { guard let input else { throw RPCError.disconnected }; try input.write(contentsOf: data + Data([0x0a])) }
    func stop() async {
        if let stoppingTask, let child = process {
            await stoppingTask.value
            finishStopping(child)
            return
        }
        generation += 1
        output?.readabilityHandler = nil; errorOutput?.readabilityHandler = nil
        let child = process
        try? input?.close()
        input = nil; output = nil; errorOutput = nil; outputBuffer.removeAll()
        guard let child else { return }
        let task = Task.detached {
            if child.isRunning { child.terminate() }
            let deadline = ContinuousClock.now.advanced(by:.seconds(2))
            while child.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for:.milliseconds(25))
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            // waitUntilExit() can stall its run loop on a Swift cooperative
            // worker even after the child has gone. Observe Foundation's
            // reaped-process state asynchronously and bound this final wait.
            let killDeadline = ContinuousClock.now.advanced(by:.seconds(2))
            while child.isRunning, ContinuousClock.now < killDeadline {
                try? await Task.sleep(for:.milliseconds(25))
            }
        }
        stoppingTask = task
        await task.value
        finishStopping(child)
    }
    private func finishStopping(_ child: Process) {
        guard process === child else { return }
        // If termination could not be confirmed, retain the slot so start()
        // cannot launch a second child over the first one.
        if !child.isRunning { process = nil }
        stoppingTask = nil
    }
}

actor JSONRPCClient {
    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        var timeoutTask: Task<Void,Never>?
    }

    private let server = CodexAppServerProcess()
    private let requestTimeout: Duration
    private let logger = Logger(subsystem:"com.lamluo.haloscope",category:"JSONRPCClient")
    private var nextID = 1
    private var pending: [Int:PendingRequest] = [:]
    private var generation = 0
    private var notificationHandler: (@Sendable (RPCResponse) async -> Void)?
    private var disconnectHandler: (@Sendable () async -> Void)?

    init(requestTimeout: Duration = .seconds(45)) { self.requestTimeout = requestTimeout }
    func setNotificationHandler(_ handler: @escaping @Sendable (RPCResponse) async -> Void) { notificationHandler = handler }
    func setDisconnectHandler(_ handler: @escaping @Sendable () async -> Void) { disconnectHandler = handler }
    func connect(path: String, experimental: Bool) async throws {
        generation += 1; let session = generation
        cancelPending(with:RPCError.disconnected)
        await server.stop()
        try checkSession(session)
        await server.setHandler { [weak self] data in await self?.receive(data,session:session) }
        await server.setTerminationHandler { [weak self] in await self?.serverExited(session:session) }
        try checkSession(session)
        try await server.start(path: path)
        do {
            try checkSession(session)
            _ = try await request("initialize", params: .object(["clientInfo":.object(["name":.string("haloscope"),"title":.string("Haloscope"),"version":.string("0.2.0")]),"capabilities":.object(["experimentalApi":.bool(experimental)])]))
            try checkSession(session)
            try await notify("initialized", params: .object([:]))
        } catch {
            if generation == session { await disconnect() }
            throw error
        }
    }
    private func checkSession(_ session: Int) throws {
        try Task.checkCancellation()
        guard generation == session else { throw CancellationError() }
    }
    func request(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        let id = nextID; nextID += 1
        let payload = try JSONEncoder().encode(["jsonrpc":JSONValue.string("2.0"),"id":.number(Double(id)),"method":.string(method),"params":params])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = PendingRequest(method:method,continuation:continuation,timeoutTask:nil)
            Task { [weak self] in await self?.sendAndArmTimeout(id:id,payload:payload) }
        }
    }
    func notify(_ method: String, params: JSONValue) async throws { try await server.send(JSONEncoder().encode(["jsonrpc":JSONValue.string("2.0"),"method":.string(method),"params":params])) }
    private func sendAndArmTimeout(id: Int, payload: Data) async {
        guard pending[id] != nil else { return }
        do { try await server.send(payload) }
        catch { fail(id:id,error:error); return }
        guard pending[id] != nil else { return }
        let duration = requestTimeout
        pending[id]?.timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for:duration) } catch { return }
            await self?.timeOut(id:id)
        }
    }
    private func receive(_ data: Data, session: Int) async {
        guard generation == session else { return }
        guard let response = try? JSONDecoder().decode(RPCResponse.self, from: data) else { return }
        if let id = response.id, let request = pending.removeValue(forKey:id) {
            request.timeoutTask?.cancel()
            if let error = response.error { request.continuation.resume(throwing:RPCError.server(error)) }
            else if let result = response.result { request.continuation.resume(returning:result) }
            else { request.continuation.resume(throwing:RPCError.malformed) }
        } else if response.method != nil { await notificationHandler?(response) }
    }
    private func timeOut(id: Int) {
        guard let method = pending[id]?.method else { return }
        logger.error("RPC request timed out: \(method, privacy:.public)")
        fail(id:id,error:RPCError.timeout)
    }
    private func fail(id: Int, error: Error) {
        guard let request = pending.removeValue(forKey:id) else { return }
        request.timeoutTask?.cancel()
        request.continuation.resume(throwing:error)
    }
    private func cancelPending(with error: Error) {
        let requests = Array(pending.values); pending.removeAll()
        requests.forEach { request in request.timeoutTask?.cancel(); request.continuation.resume(throwing:error) }
    }
    private func serverExited(session: Int) async {
        guard generation == session else { return }
        cancelPending(with:RPCError.disconnected)
        await disconnectHandler?()
    }
    func disconnect() async {
        generation += 1
        cancelPending(with:RPCError.disconnected)
        await server.stop()
    }
}

private extension CodexAppServerProcess {
    func setHandler(_ handler: @escaping @Sendable (Data) async -> Void) { onLine = handler }
    func setTerminationHandler(_ handler: @escaping @Sendable () async -> Void) { onTermination = handler }
}
