import Foundation
import Observation

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    var disk: DiskInfo? = DiskInfo.current()
    var tools: [ToolInfo] = Tools.all()
    var settings: Settings = Settings.load()
    var history: [HistoryEntry] = []
    let cleanup = CleanupModel()
    let largeFiles = LargeFilesModel()
    let compressQueue = CompressQueue()
    let security = SecurityModel()
    let apps = AppsModel()
    let loginItems = LoginItemsModel()
    /// `--scan` 指定時に、その項目表示で自動スキャンする対象（読み取り専用のスキャンのみ）
    var autoScanSection: String? = nil

    /// 自動スキャン対象なら true を返して消費する
    func consumeAutoScan(_ key: String) -> Bool {
        guard autoScanSection == key else { return false }
        autoScanSection = nil
        return true
    }
    /// 検証用: 自動スキャンの完了を示すマーカーファイルを書く
    func markAutoScanDone(_ key: String) {
        guard CommandLine.arguments.contains("--scan") else { return }
        try? Storage.ensureDir()
        try? "done".write(to: Storage.baseDir.appendingPathComponent("autoscan-\(key).done"), atomically: true, encoding: .utf8)
    }
    /// 起動引数などで指定されたサイドバー項目
    var requestedSection: String? = nil
    /// 前回スキャン結果の要約（P3 以降で設定）
    var lastScanSummary: String? = nil

    func refresh() {
        disk = DiskInfo.current()
        tools = Tools.all()
        settings = Settings.load()
        history = History.readAll().reversed()
    }
}
