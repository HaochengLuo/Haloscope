import Foundation
import OSLog

actor CodexAppServerProcess {
    private var process: Process?; private var input: FileHandle?
    private var output: FileHandle?; private var errorOutput: FileHandle?
    private var outputBuffer = Data()
    private var generation = 0
    var onLine: (@Sendable (Data) async -> Void)?
    var onTermination: (@Sendable () async -> Void)?
    func start(path: String) throws {
        guard process == nil else { return }
        generation += 1; let currentGeneration = generation
        let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = ["app-server", "--stdio"]
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
        output?.readabilityHandler = nil; errorOutput?.readabilityHandler = nil
        process = nil; input = nil; output = nil; errorOutput = nil; outputBuffer.removeAll()
        await onTermination?()
    }
    func send(_ data: Data) throws { guard let input else { throw RPCError.disconnected }; try input.write(contentsOf: data + Data([0x0a])) }
    func stop() {
        generation += 1
        output?.readabilityHandler = nil; errorOutput?.readabilityHandler = nil
        process?.terminate(); process = nil; input = nil; output = nil; errorOutput = nil; outputBuffer.removeAll()
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
    private var notificationHandler: (@Sendable (RPCResponse) async -> Void)?
    private var disconnectHandler: (@Sendable () async -> Void)?

    init(requestTimeout: Duration = .seconds(15)) { self.requestTimeout = requestTimeout }
    func setNotificationHandler(_ handler: @escaping @Sendable (RPCResponse) async -> Void) { notificationHandler = handler }
    func setDisconnectHandler(_ handler: @escaping @Sendable () async -> Void) { disconnectHandler = handler }
    func connect(path: String, experimental: Bool) async throws {
        cancelPending(with:RPCError.disconnected)
        await server.stop()
        await server.setHandler { [weak self] data in await self?.receive(data) }
        await server.setTerminationHandler { [weak self] in await self?.serverExited() }
        try await server.start(path: path)
        _ = try await request("initialize", params: .object(["clientInfo":.object(["name":.string("haloscope"),"title":.string("Haloscope"),"version":.string("0.2.0")]),"capabilities":.object(["experimentalApi":.bool(experimental)])]))
        try await notify("initialized", params: .object([:]))
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
        do { try await server.send(payload) }
        catch { fail(id:id,error:error); return }
        guard pending[id] != nil else { return }
        let duration = requestTimeout
        pending[id]?.timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for:duration) } catch { return }
            await self?.timeOut(id:id)
        }
    }
    private func receive(_ data: Data) async {
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
    private func serverExited() async {
        cancelPending(with:RPCError.disconnected)
        await disconnectHandler?()
    }
    func disconnect() async {
        cancelPending(with:RPCError.disconnected)
        await server.stop()
    }
}

private extension CodexAppServerProcess {
    func setHandler(_ handler: @escaping @Sendable (Data) async -> Void) { onLine = handler }
    func setTerminationHandler(_ handler: @escaping @Sendable () async -> Void) { onTermination = handler }
}
