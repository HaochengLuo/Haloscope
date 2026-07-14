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

enum WidgetQuotaStoreError: LocalizedError {
    case appGroupUnavailable(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable(let identifier):
            "无法访问共享容器 \(identifier)。请确认宿主和小组件使用同一签名团队。"
        case .keychain(let status):
            "无法访问共享钥匙串（OSStatus \(status)）。"
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
        if explicitDirectoryURL == nil, let data = try readKeychain() {
            let snapshot = try decoder().decode(WidgetQuotaSnapshot.self, from: data)
            logger.notice("Loaded widget snapshot from shared keychain; remaining=\(snapshot.remainingPercent ?? -1, privacy: .public)")
            return snapshot
        }
        if let data = sharedDefaults?.data(forKey: Self.defaultsKey) {
            let snapshot = try decoder().decode(WidgetQuotaSnapshot.self, from: data)
            logger.notice("Loaded widget snapshot from shared defaults; remaining=\(snapshot.remainingPercent ?? -1, privacy: .public)")
            return snapshot
        }
        let fileURL = try snapshotURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.error("Snapshot is missing at \(fileURL.path, privacy: .public)")
            return nil
        }
        let snapshot = try decoder().decode(WidgetQuotaSnapshot.self, from: Data(contentsOf: fileURL))
        logger.notice("Loaded widget snapshot from \(fileURL.path, privacy: .public); remaining=\(snapshot.remainingPercent ?? -1, privacy: .public)")
        return snapshot
    }

    func write(_ snapshot: WidgetQuotaSnapshot) throws {
        let data = try encoder().encode(snapshot)
        if explicitDirectoryURL == nil {
            try writeKeychain(data)
        }
        let fileURL = try snapshotURL(createDirectory: true)
        try data.write(to: fileURL, options: .atomic)
        sharedDefaults?.set(data, forKey: Self.defaultsKey)
        logger.notice("Wrote widget snapshot to \(fileURL.path, privacy: .public); remaining=\(snapshot.remainingPercent ?? -1, privacy: .public)")
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
