import Foundation
import Darwin

/// Local task activity only. Scheduled automations, app focus, and the monitor's
/// own RPC traffic are not evidence that Codex is executing a task.
enum OpenCodexSessionFiles {
    static func paths() -> Set<URL> {
        let count = proc_listallpids(nil,0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating:0,count:Int(count)+128)
        let bytes = Int32(pids.count * MemoryLayout<Int32>.stride)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress,bytes) }
        guard actual > 0 else { return [] }
        var paths = Set<URL>()
        for pid in pids.prefix(min(Int(actual),pids.count)) where pid > 0 {
            var name = [CChar](repeating:0,count:256)
            guard proc_name(pid,&name,UInt32(name.count)) > 0 else { continue }
            let processName = name.withUnsafeBufferPointer { String(cString:$0.baseAddress!) }
            guard processName == "codex" || processName == "codex-cli" else { continue }
            var processInfo = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&processInfo,infoSize) == infoSize,
                  processInfo.pbi_uid == getuid() else { continue }
            let needed = proc_pidinfo(pid,PROC_PIDLISTFDS,0,nil,0)
            guard needed > 0 else { continue }
            var descriptors = [proc_fdinfo](repeating:proc_fdinfo(),count:Int(needed)/MemoryLayout<proc_fdinfo>.stride+16)
            let capacity = Int32(descriptors.count * MemoryLayout<proc_fdinfo>.stride)
            let read = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid,PROC_PIDLISTFDS,0,$0.baseAddress,capacity) }
            guard read > 0 else { continue }
            for descriptor in descriptors.prefix(Int(read)/MemoryLayout<proc_fdinfo>.stride)
                where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
                guard proc_pidfdinfo(pid,descriptor.proc_fd,PROC_PIDFDVNODEPATHINFO,&info,size) == size,
                      info.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
                let path = withUnsafePointer(to:&info.pvip.vip_path) {
                    $0.withMemoryRebound(to:CChar.self,capacity:Int(MAXPATHLEN)) { String(cString:$0) }
                }
                let url = URL(fileURLWithPath:path)
                guard path.contains("/sessions/"), url.pathExtension == "jsonl",
                      url.lastPathComponent.hasPrefix("rollout-") else { continue }
                paths.insert(url)
            }
        }
        return paths
    }
}

struct CodexTaskLifecycle: Decodable {
    struct Payload: Decodable { let type: String }
    let type: String
    let payload: Payload

    var isRunning: Bool? {
        guard type == "event_msg" else { return nil }
        switch payload.type {
        case "task_started": return true
        case "task_complete", "turn_aborted", "shutdown": return false
        default: return nil
        }
    }
}

actor CodexActivityReader {
    static let shared = CodexActivityReader()
    private struct Cursor {
        var inode: UInt64
        var offset: UInt64 = 0
        var running = false
        var partial = Data()
        var discardingLongLine = false
    }
    private var cursors: [URL:Cursor] = [:]
    private let openFiles: @Sendable () -> Set<URL>
    private let decoder = JSONDecoder()
    private let eventMarker = Data("\"event_msg\"".utf8)
    private let maximumLineBytes = 4 * 1_024 * 1_024

    init(openFiles: @escaping @Sendable () -> Set<URL> = { OpenCodexSessionFiles.paths() }) {
        self.openFiles = openFiles
    }

    func hasRunningTasks() -> Bool {
        let files = openFiles()
        // Closed files cannot keep a crashed/exited Codex process active.
        cursors = cursors.filter { files.contains($0.key) }
        var running = false
        for url in files { running = read(url) || running }
        return running
    }

    private func read(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath:url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            cursors.removeValue(forKey:url); return false
        }
        var cursor = cursors[url] ?? Cursor(inode:inode)
        if cursor.inode != inode || size < cursor.offset { cursor = Cursor(inode:inode) }
        if size == cursor.offset { return cursor.running }
        guard let handle = try? FileHandle(forReadingFrom:url) else {
            cursors.removeValue(forKey:url); return false
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset:cursor.offset)
            while cursor.offset < size {
                let chunk = try handle.read(upToCount:Int(min(65_536,size-cursor.offset))) ?? Data()
                guard !chunk.isEmpty else { break }
                cursor.offset += UInt64(chunk.count)
                cursor.partial.append(chunk)
                while let newline = cursor.partial.firstIndex(of:0x0a) {
                    let line = Data(cursor.partial[..<newline])
                    cursor.partial.removeSubrange(...newline)
                    if !cursor.discardingLongLine, line.range(of:eventMarker) != nil,
                       let event = try? decoder.decode(CodexTaskLifecycle.self,from:line),
                       let value = event.isRunning { cursor.running = value }
                    cursor.discardingLongLine = false
                }
                if cursor.partial.count > maximumLineBytes {
                    // Do not retain arbitrary message bodies or infer activity
                    // from an event that could not be decoded safely.
                    cursor.partial.removeAll(keepingCapacity:false)
                    cursor.discardingLongLine = true; cursor.running = false
                }
            }
            cursors[url] = cursor
            return cursor.running
        } catch {
            cursors.removeValue(forKey:url); return false
        }
    }
}

struct MonitoringIntervals: Sendable {
    var activityCheck: Duration = .seconds(2)
    var quota: TimeInterval = 30
    var threads: TimeInterval = 60
    var history: TimeInterval = 3_600
}
