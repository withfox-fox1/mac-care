import Foundation
import AppKit
import Observation
import UserNotifications

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
    let compressCandidates = CompressCandidatesModel()
    let security = SecurityModel()
    let apps = AppsModel()
    let loginItems = LoginItemsModel()
    let smartCare = SmartCareModel()
    let scheduler = Scheduler()
    let update = UpdateModel()
    let metrics = MetricsModel()
    /// 通知の許可状態（nil = 未確認）
    var notificationsAuthorized: Bool? = nil
    /// 起動引数 --scan が未消費か（最初のセクション表示でのみ自動スキャンする）
    var launchScanPending = CommandLine.arguments.contains("--scan")
    private var backgroundStarted = false

    /// メニューバーアイコンを警告表示にするか
    /// ゴミ箱を開くボタンを付けるお知らせの本文（update.notice と同じ本文のときだけ有効）
    var trashNoticeText: String? = nil

    var needsAttention: Bool { smartCare.result?.needsAttention ?? false }

    /// 常駐用の処理を一度だけ開始（ログイン時起動の初期登録・定期スキャン）
    func startBackgroundServices() {
        guard !backgroundStarted else { return }
        backgroundStarted = true
        LaunchAtLogin.initializeIfNeeded()
        scheduler.start(state: self)
        update.resolvePending()
        update.startDailyCheck()
        if let r = smartCare.result {
            lastScanSummary = "前回: \(r.date.formatted(date: .abbreviated, time: .shortened)) / \(r.summary)"
        }
    }
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
    /// 表示中のサイドバー項目（rawValue）。ウィンドウのビューが作り直されても選択を保つため AppState に置く
    var currentSection: String = "dashboard"
    /// 前回スキャン結果の要約（P3 以降で設定）
    var lastScanSummary: String? = nil

    func refresh() {
        disk = DiskInfo.current()
        tools = Tools.all()
        settings = Settings.load()
        history = History.readAll().reversed()
    }

    // MARK: ダッシュボード・パネル用の導出値

    var healthInput: HealthInput {
        let r = smartCare.result
        return HealthInput(threats: r?.threats ?? 0, newOrChangedLoginItems: (r?.newLoginItems ?? 0) + (r?.changedLoginItems ?? 0),
                           freeBytes: disk?.available, totalBytes: disk?.total, junkBytes: r?.junkBytes ?? 0,
                           lastSmartCare: r?.date, now: Date())
    }
    var healthScore: Int { HealthScore.score(healthInput) }

    var recommendationInput: RecommendationInput {
        let r = smartCare.result
        let videos = largeFiles.files.filter(\.needsCompression)
        return RecommendationInput(
            videoCount: videos.count, videoBytes: videos.reduce(0) { $0 + $1.size },
            cleanMyMacItems: loginItems.items.filter { $0.label.lowercased().contains("com.macpaw") }.count,
            notificationsAuthorized: notificationsAuthorized,
            fullDiskAccessMissing: cleanup.hasScanned ? !cleanup.trashReadable : nil,
            threats: r?.threats ?? 0, junkBytes: r?.junkBytes ?? 0, lastSmartCare: r?.date, now: Date(),
            updateAvailable: update.availableCount,
            wakeSuggested: settings.scheduledScanEnabled && !settings.wakeForScan && !settings.wakeSuggestionDismissed)
    }
    var recommendations: [Recommendation] { Recommendations.all(recommendationInput) }

    func refreshNotificationStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notificationsAuthorized = true
        case .denied: notificationsAuthorized = false
        default: notificationsAuthorized = false   // 未決定も「オンにする」対象
        }
    }

    func perform(_ action: RecAction) {
        switch action {
        case .navigate(let s): requestedSection = s
        case .openURL(let u): if let url = URL(string: u) { NSWorkspace.shared.open(url) }
        case .runSmartCare: Task { await smartCare.run(state: self) }
        }
    }
}

// MARK: - ゴミ箱移動後のお知らせ

/// ゴミ箱への移動結果（お知らせ文言の生成元）
struct TrashOutcome: Equatable {
    var moved: Int
    var failed: Int
    var bytes: Int64

    var isError: Bool { failed > 0 }

    var message: String {
        let size = bytes > 0 ? "（\(formatBytes(bytes))）" : ""
        if failed == 0 { return "\(moved) 項目\(size)をゴミ箱へ移動しました。" }
        if moved == 0 { return "\(failed) 件は移動できませんでした。" }
        return "\(moved) 件\(size)を移動しました。\(failed) 件は移動できませんでした。"
    }
}

enum TrashNotice {
    /// テスト用に差し替え可能。既定は AppState のお知らせ表示
    @MainActor static var sink: (_ text: String, _ isError: Bool) -> Void = { text, isError in
        AppState.shared.postTrashNotice(text, isError: isError)
    }
    @MainActor static func post(_ o: TrashOutcome) {
        guard o.moved + o.failed > 0 else { return }
        sink(o.message, o.isError)
    }
    @MainActor static func post(text: String, isError: Bool = false) { sink(text, isError) }
}

extension AppState {
    /// ゴミ箱移動のお知らせ。MainWindow が表示する update.notice に載せ、［ゴミ箱を開く］は NoticeBanner が付ける。
    func postTrashNotice(_ text: String, isError: Bool) {
        trashNoticeText = text
        update.notice = (text, isError)
    }
}
