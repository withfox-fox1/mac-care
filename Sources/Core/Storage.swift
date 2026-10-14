import Foundation

/// アプリデータの保存先。テストでは baseDir を差し替える。
enum Storage {
    static var baseDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacCare", isDirectory: true)

    static func ensureDir() throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }
    static var settingsURL: URL { baseDir.appendingPathComponent("settings.json") }
    static var historyURL: URL { baseDir.appendingPathComponent("history.jsonl") }
}

struct Settings: Codable, Equatable {
    var largeFileThresholdMB: Int = 500
    var largeFileRoots: [String] = [NSHomeDirectory()]
    var nodeModulesStaleDays: Int = 90
    var scheduledScanEnabled: Bool = true
    var scanIntervalDays: Int = 7
    var lastScheduledRun: Date? = nil

    init() {}

    // 項目追加に備え、欠けているキーは既定値で補う
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        largeFileThresholdMB = try c.decodeIfPresent(Int.self, forKey: .largeFileThresholdMB) ?? d.largeFileThresholdMB
        largeFileRoots = try c.decodeIfPresent([String].self, forKey: .largeFileRoots) ?? d.largeFileRoots
        nodeModulesStaleDays = try c.decodeIfPresent(Int.self, forKey: .nodeModulesStaleDays) ?? d.nodeModulesStaleDays
        scheduledScanEnabled = try c.decodeIfPresent(Bool.self, forKey: .scheduledScanEnabled) ?? d.scheduledScanEnabled
        scanIntervalDays = try c.decodeIfPresent(Int.self, forKey: .scanIntervalDays) ?? d.scanIntervalDays
        lastScheduledRun = try c.decodeIfPresent(Date.self, forKey: .lastScheduledRun)
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: Storage.settingsURL),
              let s = try? decoder.decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    func save() throws {
        try Storage.ensureDir()
        try Settings.encoder.encode(self).write(to: Storage.settingsURL, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

enum HistoryKind: String, Codable, CaseIterable {
    case cleanup, trash, compress, scan, uninstall, loginItem
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var date: Date
    var kind: HistoryKind
    var target: String
    var bytes: Int64
    var result: String
    var detail: String
    var id: String { "\(date.timeIntervalSince1970)|\(kind.rawValue)|\(target)" }
}

/// 追記専用の JSON Lines 履歴
enum History {
    private static let lock = NSLock()

    static func append(_ entry: HistoryEntry) throws {
        lock.lock(); defer { lock.unlock() }
        try Storage.ensureDir()
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        var line = try e.encode(entry)
        line.append(UInt8(ascii: "\n"))
        let url = Storage.historyURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try line.write(to: url, options: .atomic)
            return
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: line)
    }

    /// 破損行は読み飛ばす。古い順。
    static func readAll() -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: Storage.historyURL, encoding: .utf8) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap {
            try? d.decode(HistoryEntry.self, from: Data($0.utf8))
        }
    }
}
