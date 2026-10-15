import Foundation
import IOKit.ps
import Observation
import ServiceManagement
@preconcurrency import UserNotifications

struct SmartCareResult: Codable, Equatable {
    var date: Date
    var junkBytes: Int64
    var safeJunkBytes: Int64
    var threats: Int
    var newLoginItems: Int
    var changedLoginItems: Int
    var largeFileCount: Int
    var largeFileBytes: Int64
    var deep: Bool
    var seconds: Double

    var summary: String {
        "脅威 \(threats) 件 / 不要データ \(formatBytes(junkBytes)) / 新しいログイン項目 \(newLoginItems) 件"
    }
    var needsAttention: Bool { threats > 0 || newLoginItems > 0 }

    static var fileURL: URL { Storage.baseDir.appendingPathComponent("last-smartcare.json") }
    static func load() -> SmartCareResult? {
        guard let d = try? Data(contentsOf: fileURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SmartCareResult.self, from: d)
    }
    func save() {
        try? Storage.ensureDir()
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        if let d = try? e.encode(self) { try? d.write(to: SmartCareResult.fileURL, options: .atomic) }
    }
}

enum SmartCare {
    /// スマートケアから削除してよい分類（既定で安全なもののみ）。node_modules / Xcode / ゴミ箱は含めない。
    static let safeCategoryIDs: Set<String> = ["caches", "logs", "npm", "brew", "pip"]

    static func safeCategories(_ cats: [CleanupCategory]) -> [CleanupCategory] {
        cats.filter { safeCategoryIDs.contains($0.id) }
    }
    static func safeItemIDs(_ cats: [CleanupCategory]) -> Set<String> {
        Set(safeCategories(cats).flatMap { $0.items.map(\.id) })
    }
    /// 安全な分類の削除対象スナップショット（共有の選択状態は使わない）
    static func safeJobs(_ cats: [CleanupCategory]) -> [CleanupJob] {
        safeCategories(cats).flatMap { c in c.items.map { CleanupJob(item: $0, roots: c.roots) } }
    }
}

// MARK: - スケジューラ

enum ScheduleDecision: Equatable { case run, disabled, notDue, skipBusy, skipBattery }

enum SchedulerLogic {
    static func decide(settings: Settings, now: Date, batteryLow: Bool, busy: Bool) -> ScheduleDecision {
        guard settings.scheduledScanEnabled else { return .disabled }
        if let last = settings.lastScheduledRun,
           now.timeIntervalSince(last) < TimeInterval(max(1, settings.scanIntervalDays)) * 86400 { return .notDue }
        if busy { return .skipBusy }
        if batteryLow { return .skipBattery }
        return .run
    }
}

enum Power {
    /// バッテリー駆動で残量 20% 未満
    static func isBatteryLow(threshold: Int = 20) -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue else { continue }
            if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0,
               cur * 100 / max < threshold { return true }
        }
        return false
    }
}

enum Notifier {
    /// 通知を送る。権限は初回に要求する。戻り値は「送信を依頼できたか」
    @discardableResult
    static func post(title: String, body: String) async -> Bool {
        let c = UNUserNotificationCenter.current()
        guard (try? await c.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        do { try await c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)); return true }
        catch { return false }
    }
}

@MainActor
final class Scheduler {
    var batteryLow: () -> Bool = { Power.isBatteryLow() }
    var now: () -> Date = { Date() }
    var catchUpDelay: UInt64 = 300 * 1_000_000_000
    var interval: UInt64 = 3600 * 1_000_000_000
    private var loop: Task<Void, Never>?

    /// 起動時の遅延実行（5 分後）→ 以後 1 時間ごとに確認
    func start(state: AppState) {
        loop?.cancel()
        loop = Task { [weak self] in
            guard let first = self?.catchUpDelay else { return }
            try? await Task.sleep(nanoseconds: first)
            while !Task.isCancelled, let me = self {
                await me.tick(state: state)
                try? await Task.sleep(nanoseconds: me.interval)
            }
        }
    }

    func tick(state: AppState, force: Bool = false) async {
        let settings = Settings.load()
        let decision = force ? ScheduleDecision.run
            : SchedulerLogic.decide(settings: settings, now: now(), batteryLow: batteryLow(), busy: state.smartCare.running)
        guard decision == .run else { NSLog("MacCare scheduler: skip (\(decision))"); return }
        await state.smartCare.run(state: state, scheduled: true)
        guard let r = state.smartCare.result else { return }   // 中止された場合は記録しない
        var s = Settings.load()
        s.lastScheduledRun = Date()
        try? s.save()
        state.settings = s
        let ok = await Notifier.post(title: "MacCare 定期スキャン完了", body: r.summary)
        NSLog("MacCare scheduler: done, notification requested=\(ok): \(r.summary)")
        try? History.append(HistoryEntry(date: Date(), kind: .scan, target: "定期スキャン", bytes: r.junkBytes,
                                         result: ok ? "notified" : "no-notification-permission", detail: r.summary))
    }
}

// MARK: - ログイン時起動

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
    /// 初回起動時のみ既定で登録する
    static func initializeIfNeeded() {
        var s = Settings.load()
        guard !s.launchAtLoginInitialized else { return }
        try? set(true)
        s.launchAtLoginInitialized = true
        try? s.save()
    }
}

// MARK: - スマートケア本体

enum SmartCareStep: String, CaseIterable {
    case cleanup = "不要データの集計", security = "セキュリティスキャン", loginItems = "ログイン項目の確認", largeFiles = "大容量ファイルの集計"
}

/// 各ステップの出力（ステップ完了直後の値を保持する。最後に共有状態を読み直さない）
struct SmartCareSteps {
    var cleanup: @MainActor (AppState, Settings) async -> (junk: Int64, safeJunk: Int64)
    var security: @MainActor (AppState) async -> Int
    var loginItems: @MainActor (AppState) async -> (new: Int, changed: Int)
    var largeFiles: @MainActor (AppState, Settings) async -> (count: Int, bytes: Int64)

    static let live = SmartCareSteps(
        cleanup: { st, settings in
            await st.cleanup.scan(settings: settings)
            let cats = st.cleanup.categories   // 完了直後に確定させる
            return (cats.reduce(0) { $0 + $1.size }, SmartCare.safeCategories(cats).reduce(0) { $0 + $1.size })
        },
        security: { st in await st.security.scan(state: st); return st.security.detections.count },
        loginItems: { st in
            await st.loginItems.scan()
            return (st.loginItems.diff?.new.count ?? 0, st.loginItems.diff?.changed.count ?? 0)
        },
        largeFiles: { st, settings in
            await st.largeFiles.scan(settings: settings)
            return (st.largeFiles.files.count, st.largeFiles.files.reduce(0) { $0 + $1.size })
        })
}

@MainActor @Observable
final class SmartCareModel {
    var running = false
    var currentStep: SmartCareStep? = nil
    var doneSteps: Set<SmartCareStep> = []
    var result: SmartCareResult? = SmartCareResult.load()
    var steps = SmartCareSteps.live
    private var cancelled = false

    var statusText: String { currentStep.map { "\($0.rawValue)中…" } ?? "" }

    func cancel(state: AppState) {
        cancelled = true
        state.security.cancel()
    }

    /// 読み取り専用のスキャンのみ（削除はしない）。各ペインと同じスキャナを共有する。
    func run(state: AppState, scheduled: Bool = false) async {
        guard !running else { return }
        running = true; cancelled = false; doneSteps = []
        defer { running = false; currentStep = nil }
        let settings = Settings.load()
        let t0 = Date()

        currentStep = .cleanup
        let junk = await steps.cleanup(state, settings)
        doneSteps.insert(.cleanup)
        guard !cancelled else { return }

        currentStep = .security
        let threats = await steps.security(state)
        guard !cancelled else { return }
        doneSteps.insert(.security)

        currentStep = .loginItems
        let logins = await steps.loginItems(state)
        doneSteps.insert(.loginItems)
        guard !cancelled else { return }

        currentStep = .largeFiles
        let large = await steps.largeFiles(state, settings)
        doneSteps.insert(.largeFiles)

        let r = SmartCareResult(
            date: Date(), junkBytes: junk.junk, safeJunkBytes: junk.safeJunk, threats: threats,
            newLoginItems: logins.new, changedLoginItems: logins.changed,
            largeFileCount: large.count, largeFileBytes: large.bytes,
            deep: settings.deepScan, seconds: Date().timeIntervalSince(t0))
        r.save()
        result = r
        state.lastScanSummary = "前回: \(r.date.formatted(date: .abbreviated, time: .shortened)) / \(r.summary)"
        try? History.append(HistoryEntry(date: Date(), kind: .scan, target: scheduled ? "スマートケア（定期）" : "スマートケア",
                                         bytes: r.junkBytes, result: r.threats == 0 ? "clean" : "found",
                                         detail: "\(r.summary)、\(Int(r.seconds)) 秒"))
    }

    /// 確認済みのスナップショットのみをゴミ箱へ。CleanupModel.selected は変更しない。
    func trashSafe(_ jobs: [CleanupJob], state: AppState) async {
        await state.cleanup.cleanItems(jobs, settings: Settings.load())
        // 解放後の集計を反映（クリーンアップ画面の最新状態から）
        if var r = result {
            let cats = state.cleanup.categories
            r.junkBytes = cats.reduce(0) { $0 + $1.size }
            r.safeJunkBytes = SmartCare.safeCategories(cats).reduce(0) { $0 + $1.size }
            r.save(); result = r
        }
    }
}
