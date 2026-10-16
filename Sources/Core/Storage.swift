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

struct IgnoredDetection: Codable, Equatable {
    var path: String
    var sha256: String
}

struct Settings: Codable, Equatable {
    var largeFileThresholdMB: Int = 500
    var largeFileRoots: [String] = [NSHomeDirectory()]
    var nodeModulesStaleDays: Int = 90
    var scheduledScanEnabled: Bool = true
    var lastScheduledRun: Date? = nil
    /// フルスキャンの実行時刻（毎日）。既定 0:00
    var fullScanHour: Int = 0
    var fullScanMinute: Int = 0
    /// セキュリティスキャンの方式: true=クイック（変更分のみ）、false=フル
    var quickScan: Bool = true
    /// フルスキャン前にスリープから復帰させる pmset スケジュールを設定済みか
    var wakeForScan: Bool = false
    /// 設定済みの起床時刻（"HH:MM:SS"）。解除・uninstall 判定用
    var wakeScheduleTime: String? = nil
    /// 起床スケジュールの提案（おすすめ）を閉じたか
    var wakeSuggestionDismissed: Bool = false
    var scanTargets: [String] = {
        let h = NSHomeDirectory()
        return [h + "/Downloads", h + "/Desktop", h + "/Documents", "/Applications"]
    }()
    var ignoredDetections: [IgnoredDetection] = []
    /// じっくりスキャン: ClamAV の対象に /Applications を含める（既定は含めない）
    var deepScan: Bool = false
    /// ログイン時起動の初期登録を済ませたか
    var launchAtLoginInitialized: Bool = false

    init() {}

    /// 設定画面で編集する項目だけを取り込む（スキャン結果由来の項目は上書きしない）
    mutating func mergeEditable(from o: Settings) {
        largeFileThresholdMB = o.largeFileThresholdMB
        largeFileRoots = o.largeFileRoots
        nodeModulesStaleDays = o.nodeModulesStaleDays
        scheduledScanEnabled = o.scheduledScanEnabled
        fullScanHour = o.fullScanHour
        fullScanMinute = o.fullScanMinute
        quickScan = o.quickScan
        scanTargets = o.scanTargets
        deepScan = o.deepScan
    }

    /// 設定画面の「既定値に戻す」。編集可能な項目（mergeEditable の対象）だけを既定値にする。
    /// 無視リスト・起床スケジュール・内部状態（初回登録済み・前回実行日時など）は変えない。
    mutating func resetEditableToDefaults() {
        mergeEditable(from: Settings())
    }

    /// 無視リストから 1 件解除する（パスとハッシュが一致するもの）
    mutating func removeIgnored(_ item: IgnoredDetection) {
        ignoredDetections.removeAll { $0 == item }
    }

    // 項目追加に備え、欠けているキーは既定値で補う
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        largeFileThresholdMB = try c.decodeIfPresent(Int.self, forKey: .largeFileThresholdMB) ?? d.largeFileThresholdMB
        largeFileRoots = try c.decodeIfPresent([String].self, forKey: .largeFileRoots) ?? d.largeFileRoots
        nodeModulesStaleDays = try c.decodeIfPresent(Int.self, forKey: .nodeModulesStaleDays) ?? d.nodeModulesStaleDays
        scheduledScanEnabled = try c.decodeIfPresent(Bool.self, forKey: .scheduledScanEnabled) ?? d.scheduledScanEnabled
        fullScanHour = try c.decodeIfPresent(Int.self, forKey: .fullScanHour) ?? d.fullScanHour
        fullScanMinute = try c.decodeIfPresent(Int.self, forKey: .fullScanMinute) ?? d.fullScanMinute
        quickScan = try c.decodeIfPresent(Bool.self, forKey: .quickScan) ?? d.quickScan
        wakeForScan = try c.decodeIfPresent(Bool.self, forKey: .wakeForScan) ?? d.wakeForScan
        wakeScheduleTime = try c.decodeIfPresent(String.self, forKey: .wakeScheduleTime)
        wakeSuggestionDismissed = try c.decodeIfPresent(Bool.self, forKey: .wakeSuggestionDismissed) ?? d.wakeSuggestionDismissed
        lastScheduledRun = try c.decodeIfPresent(Date.self, forKey: .lastScheduledRun)
        scanTargets = try c.decodeIfPresent([String].self, forKey: .scanTargets) ?? d.scanTargets
        ignoredDetections = try c.decodeIfPresent([IgnoredDetection].self, forKey: .ignoredDetections) ?? d.ignoredDetections
        deepScan = try c.decodeIfPresent(Bool.self, forKey: .deepScan) ?? d.deepScan
        launchAtLoginInitialized = try c.decodeIfPresent(Bool.self, forKey: .launchAtLoginInitialized) ?? d.launchAtLoginInitialized
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
