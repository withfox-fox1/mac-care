import Foundation
import Observation

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    var disk: DiskInfo? = DiskInfo.current()
    var tools: [ToolInfo] = Tools.all()
    var settings: Settings = Settings.load()
    var history: [HistoryEntry] = []
    /// 前回スキャン結果の要約（P3 以降で設定）
    var lastScanSummary: String? = nil

    func refresh() {
        disk = DiskInfo.current()
        tools = Tools.all()
        settings = Settings.load()
        history = History.readAll().reversed()
    }
}
