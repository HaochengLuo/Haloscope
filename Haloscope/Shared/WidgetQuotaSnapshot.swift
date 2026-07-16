import Foundation
import OSLog
import Security

struct WidgetQuotaSnapshot: Codable, Equatable, Sendable {
    enum Availability: String, Codable, Sendable { case available, unavailable }

    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var remainingPercent: Double?
    var windowDurationMins: Int?
    var resetsAt: Date?
    var availableResetCredits: Int?
    var planType: String?
    var updatedAt: Date
    var availability: Availability
    var errorMessage: String?

    var normalizedRemainingPercent: Double? {
        remainingPercent.map { min(100, max(0, $0)) }
    }

    var roundedRemainingPercent: Int? {
        normalizedRemainingPercent.map { Int($0.rounded()) }
    }

    func isStale(at date: Date = .now, maxAge: TimeInterval = 10 * 60) -> Bool {
        date.timeIntervalSince(updatedAt) > maxAge
    }

    func materiallyDiffers(from other: WidgetQuotaSnapshot?) -> Bool {
        guard let other else { return true }
        return roundedRemainingPercent != other.roundedRemainingPercent
            || windowDurationMins != other.windowDurationMins
            || resetsAt != other.resetsAt
            || availableResetCredits != other.availableResetCredits
            || planType != other.planType
            || availability != other.availability
    }

    static func unavailable(_ message: String, at date: Date = .now) -> WidgetQuotaSnapshot {
        .init(
            remainingPercent: nil,
            windowDurationMins: nil,
            resetsAt: nil,
            availableResetCredits: nil,
            planType: nil,
            updatedAt: date,
            availability: .unavailable,
            errorMessage: message
        )
    }
}

struct WidgetTimelineSchedule: Sendable {
    static let maximumEntryCount = 256
    static let fineWindow: TimeInterval = 24 * 60 * 60
    static let fineInterval: TimeInterval = 15 * 60
    static let minimumCoarseInterval: TimeInterval = 60 * 60

    static func entryDates(now: Date, resetAt: Date?) -> [Date] {
        guard let resetAt, resetAt > now else { return [now] }

        let totalDuration = resetAt.timeIntervalSince(now)
        let fineDuration = min(fineWindow, totalDuration)
        let coarseDuration = totalDuration - fineDuration
        let fineStepCount = Int(ceil(fineDuration / fineInterval))
        let coarseSlotCount = max(1, maximumEntryCount - 1 - fineStepCount)
        let coarseInterval = max(
            minimumCoarseInterval,
            ceil(coarseDuration / Double(coarseSlotCount))
        )
        let fineStart = resetAt.addingTimeInterval(-fineDuration)

        var dates = [now]
        var cursor = now
        while cursor < fineStart, dates.count < maximumEntryCount {
            cursor = min(fineStart, cursor.addingTimeInterval(coarseInterval))
            dates.append(cursor)
        }
        while cursor < resetAt, dates.count < maximumEntryCount {
            cursor = min(resetAt, cursor.addingTimeInterval(fineInterval))
            dates.append(cursor)
        }
        return dates
    }
}

enum WidgetQuotaStoreError: LocalizedError {
    case appGroupUnavailable(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        let language = SharedLanguagePreference.widgetLanguage()
        return switch self {
        case .appGroupUnavailable(let identifier):
            L10n.format("store.app_group",language:language,identifier)
        case .keychain(let status):
            L10n.format("store.keychain",language:language,Int(status))
        }
    }
}

struct WidgetQuotaSnapshotStore: Sendable {
    static let defaultAppGroupIdentifier = "group.com.lamluo.haloscope"
    static let fileName = "quota-snapshot.json"
    static let defaultsKey = "widgetQuotaSnapshot.v1"
    static let keychainService = "com.lamluo.haloscope.widget-quota"
    static let keychainAccount = "snapshot-v1"

    static var configuredAppGroupIdentifier: String {
        expandedInfoValue(for:"HaloscopeAppGroupIdentifier") ?? defaultAppGroupIdentifier
    }

    static var keychainAccessGroup: String? {
        expandedInfoValue(for:"HaloscopeKeychainAccessGroup")
    }

    private let explicitDirectoryURL: URL?
    private let appGroupIdentifier: String
    private let logger = Logger(subsystem: "com.lamluo.haloscope", category: "WidgetQuotaSnapshotStore")

    init(directoryURL: URL? = nil, appGroupIdentifier: String? = nil) {
        explicitDirectoryURL = directoryURL
        self.appGroupIdentifier = appGroupIdentifier ?? Self.configuredAppGroupIdentifier
    }

    func read() throws -> WidgetQuotaSnapshot? {
        if explicitDirectoryURL != nil {
            let fileURL = try snapshotURL()
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return try decoder().decode(WidgetQuotaSnapshot.self, from: Data(contentsOf: fileURL))
        }

        var candidates: [(source: String, snapshot: WidgetQuotaSnapshot)] = []
        var firstError: Error?
        do {
            let fileURL = try snapshotURL()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    let snapshot = try decoder().decode(WidgetQuotaSnapshot.self, from: Data(contentsOf: fileURL))
                    candidates.append(("shared container", snapshot))
                } catch {
                    firstError = error
                    logger.error("Shared container snapshot read failed: \(String(describing:error), privacy: .public)")
                }
            }
        } catch {
            firstError = error
            logger.error("Shared container lookup failed: \(String(describing:error), privacy: .public)")
        }

        if let data = sharedDefaults?.data(forKey: Self.defaultsKey) {
            do {
                candidates.append(("shared defaults", try decoder().decode(WidgetQuotaSnapshot.self, from: data)))
            } catch {
                firstError = firstError ?? error
                logger.error("Shared defaults snapshot decode failed: \(String(describing:error), privacy: .public)")
            }
        }
        do {
            if let data = try readKeychain() {
                candidates.append(("shared keychain", try decoder().decode(WidgetQuotaSnapshot.self, from: data)))
            }
        } catch {
            firstError = firstError ?? error
        }

        if let candidate = candidates.max(by: { $0.snapshot.updatedAt < $1.snapshot.updatedAt }) {
            logger.notice("Loaded widget snapshot from \(candidate.source, privacy: .public); remaining=\(candidate.snapshot.remainingPercent ?? -1, privacy: .public)")
            return candidate.snapshot
        }
        if let firstError { throw firstError }
        return nil
    }

    func write(_ snapshot: WidgetQuotaSnapshot) throws {
        let data = try encoder().encode(snapshot)
        if explicitDirectoryURL != nil {
            let fileURL = try snapshotURL(createDirectory: true)
            try data.write(to: fileURL, options: .atomic)
            logger.notice("Wrote widget snapshot to \(fileURL.path, privacy: .public); remaining=\(snapshot.remainingPercent ?? -1, privacy: .public)")
            return
        }

        var firstError: Error?
        var didWrite = false
        do {
            let fileURL = try snapshotURL(createDirectory: true)
            try data.write(to: fileURL, options: .atomic)
            sharedDefaults?.set(data, forKey: Self.defaultsKey)
            didWrite = true
            logger.notice("Wrote widget snapshot to shared container; remaining=\(snapshot.remainingPercent ?? -1, privacy: .public)")
        } catch {
            firstError = error
            logger.error("Shared container snapshot write failed")
        }

        do {
            try writeKeychain(data)
            didWrite = true
            logger.notice("Mirrored widget snapshot to shared keychain")
        } catch {
            firstError = firstError ?? error
            logger.error("Shared keychain snapshot write failed")
        }
        if !didWrite, let firstError { throw firstError }
    }

    private var sharedDefaults: UserDefaults? {
        guard explicitDirectoryURL == nil else { return nil }
        return UserDefaults(suiteName: appGroupIdentifier)
    }

    private func readKeychain() throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(keychainQuery(returnData:true) as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            logger.error("Shared keychain read failed with OSStatus \(status, privacy: .public)")
            throw WidgetQuotaStoreError.keychain(status)
        }
        return result as? Data
    }

    private func writeKeychain(_ data: Data) throws {
        let query = keychainQuery(returnData:false)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData:data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            logger.error("Shared keychain update failed with OSStatus \(updateStatus, privacy: .public)")
            throw WidgetQuotaStoreError.keychain(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary,nil)
        guard addStatus == errSecSuccess else {
            logger.error("Shared keychain insert failed with OSStatus \(addStatus, privacy: .public)")
            throw WidgetQuotaStoreError.keychain(addStatus)
        }
    }

    private func keychainQuery(returnData: Bool) -> [String:Any] {
        var query: [String:Any] = [
            kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:Self.keychainService,
            kSecAttrAccount as String:Self.keychainAccount,
            kSecUseDataProtectionKeychain as String:true
        ]
        if let accessGroup = Self.keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    private static func expandedInfoValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey:key) as? String,
              !value.isEmpty,
              !value.contains("$(") else { return nil }
        return value
    }

    private func snapshotURL(createDirectory: Bool = false) throws -> URL {
        let directory: URL
        if let explicitDirectoryURL {
            directory = explicitDirectoryURL
        } else if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            directory = groupURL.appendingPathComponent("Library/Application Support/Haloscope", isDirectory: true)
        } else {
            throw WidgetQuotaStoreError.appGroupUnavailable(appGroupIdentifier)
        }
        if createDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    private func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys]
        return value
    }

    private func decoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}
