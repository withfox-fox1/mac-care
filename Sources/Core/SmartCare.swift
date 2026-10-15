import Foundation
import AppKit
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
    /// now 以前で最も新しい「毎日 hh:mm」の時刻（夏時間でも Calendar に任せる）
    static func lastTarget(now: Date, hour: Int, minute: Int, calendar: Calendar = .current) -> Date {
        let comps = DateComponents(hour: hour, minute: minute, second: 0)
        return calendar.nextDate(after: now.addingTimeInterval(1), matching: comps, matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first, direction: .backward) ?? calendar.startOfDay(for: now)
    }

    /// フルスキャンの実行判定。直近の予定時刻以降に一度もフルスキャンしていなければ実行（取り逃しの補完を含む）。
    /// 予定時刻ごとに 1 回だけ実行されるため、1 日に複数回は走らない。
    static func decide(settings: Settings, now: Date, lastFull: Date?, batteryLow: Bool, busy: Bool,
                       calendar: Calendar = .current) -> ScheduleDecision {
        guard settings.scheduledScanEnabled else { return .disabled }
        let target = lastTarget(now: now, hour: settings.fullScanHour, minute: settings.fullScanMinute, calendar: calendar)
        let last = [lastFull, settings.lastScheduledRun].compactMap { $0 }.max()
        if let last, last >= target { return .notDue }
        if busy { return .skipBusy }
        if batteryLow { return .skipBattery }
        return .run
    }

    /// 復帰・起動後に実行を待つ時間。予定時刻の前後 5 分以内（pmset の起床など）なら短く、それ以外は 5 分。
    static func catchUpDelay(now: Date, hour: Int, minute: Int, calendar: Calendar = .current) -> TimeInterval {
        let last = lastTarget(now: now, hour: hour, minute: minute, calendar: calendar)
        let next = calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                     matchingPolicy: .nextTime) ?? last.addingTimeInterval(86400)
        let near = min(now.timeIntervalSince(last), next.timeIntervalSince(now)) <= 300
        return near ? 30 : 300
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

extension Power {
    /// 直近1分のロードアベレージ（スキャン時間の変動要因の記録用）
    static func loadAverage() -> Double {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) > 0 ? l[0] : 0
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
    var catchUpDelay: TimeInterval = 300
    var pollInterval: UInt64 = 60 * 1_000_000_000
    var retryInterval: TimeInterval = 3600
    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var notBefore = Date.distantPast
    private var retryAt = Date.distantPast

    /// 起動後 5 分、またはスリープ復帰後（5 分、予定時刻付近なら 30 秒）から、毎分「予定時刻を過ぎたか」を確認する。
    /// 起動していない・スリープ中だった場合は、復帰後の確認で取り逃しを補完する。
    func start(state: AppState) {
        loop?.cancel()
        notBefore = now().addingTimeInterval(catchUpDelay)
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let s = Settings.load()
                let n = self.now()
                self.notBefore = n.addingTimeInterval(SchedulerLogic.catchUpDelay(now: n, hour: s.fullScanHour, minute: s.fullScanMinute))
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled, let me = self {
                let n = me.now()
                if n >= me.notBefore && n >= me.retryAt { await me.tick(state: state) }
                try? await Task.sleep(nanoseconds: me.pollInterval)
            }
        }
    }

    func tick(state: AppState, force: Bool = false) async {
        let settings = Settings.load()
        let lastFull = ScanCacheStore.load().lastFullAt
        let decision = force ? ScheduleDecision.run
            : SchedulerLogic.decide(settings: settings, now: now(), lastFull: lastFull, batteryLow: batteryLow(), busy: state.smartCare.running)
        if decision == .skipBattery { retryAt = now().addingTimeInterval(retryInterval) }   // 低バッテリーは 1 時間後に再確認
        guard decision == .run else { return }
        let completed = await state.smartCare.run(state: state, scheduled: true)
        guard completed, let r = state.smartCare.result else { retryAt = now().addingTimeInterval(retryInterval); return }   // 中止された場合は記録しない
        var s = Settings.load()
        s.lastScheduledRun = Date()
        try? s.save()
        state.settings = s
        let ok = await Notifier.post(title: "MacCare フルスキャン完了", body: r.summary)
        NSLog("MacCare scheduler: done, notification requested=\(ok): \(r.summary)")
        try? History.append(HistoryEntry(date: Date(), kind: .scan, target: "定期フルスキャン", bytes: r.junkBytes,
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
    /// 所要時間の保存キー
    var key: String {
        switch self { case .cleanup: "cleanup"; case .security: "security"; case .loginItems: "loginItems"; case .largeFiles: "largeFiles" }
    }
}

/// 各ステップの出力（ステップ完了直後の値を保持する。最後に共有状態を読み直さない）
struct SmartCareSteps {
    var cleanup: @MainActor (AppState, Settings) async -> (junk: Int64, safeJunk: Int64)
    /// 第 2 引数 true = フルスキャン（キャッシュを使わない）
    var security: @MainActor (AppState, Bool) async -> Int
    var loginItems: @MainActor (AppState) async -> (new: Int, changed: Int)
    var largeFiles: @MainActor (AppState, Settings) async -> (count: Int, bytes: Int64)

    static let live = SmartCareSteps(
        cleanup: { st, settings in
            await st.cleanup.scan(settings: settings)
            let cats = st.cleanup.categories   // 完了直後に確定させる
            return (cats.reduce(0) { $0 + $1.size }, SmartCare.safeCategories(cats).reduce(0) { $0 + $1.size })
        },
        security: { st, full in await st.security.scan(state: st, full: full); return st.security.detections.count },
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
    /// 実行中のステップ（読み取り専用の軽い処理はセキュリティスキャンと並行して走る）
    var activeSteps: Set<SmartCareStep> = []
    var doneSteps: Set<SmartCareStep> = []
    var result: SmartCareResult? = SmartCareResult.load()
    var steps = SmartCareSteps.live
    /// 全体の進捗（0...1）と残り時間
    var progress: Double = 0
    var etaText: String = ""
    private var cancelled = false
    private var meter = ProgressMeter()
    private var weights = StepDurations.defaults

    var statusText: String {
        let names = SmartCareStep.allCases.filter { activeSteps.contains($0) }.map(\.rawValue)
        return names.isEmpty ? "" : names.joined(separator: "・") + "中…"
    }

    func cancel(state: AppState) {
        cancelled = true
        state.security.cancel()
    }

    private func tick(state: AppState, now: Date = Date()) {
        let items = SmartCareStep.allCases.map { s -> (weight: Double, fraction: Double) in
            var w = weights[s.key] ?? 10
            // セキュリティは今回の対象量から見積もった時間を使う（キャッシュ有無で所要時間が大きく変わるため）
            if s == .security, let e = state.security.estimatedSeconds { w = max(e, 1) }
            if doneSteps.contains(s) { return (w, 1) }
            return (w, s == .security && activeSteps.contains(s) ? state.security.fraction : 0)
        }
        progress = ProgressMath.weighted(items)
        etaText = ETAFormat.text(meter.update(fraction: progress, now: now))
    }

    private func timed<T>(_ s: SmartCareStep, _ body: () async -> T) async -> (value: T, seconds: Double) {
        activeSteps.insert(s)
        let t = Date()
        let v = await body()
        let sec = Date().timeIntervalSince(t)
        activeSteps.remove(s); doneSteps.insert(s)
        return (v, sec)
    }

    /// 読み取り専用のスキャンのみ（削除はしない）。各ペインと同じスキャナを共有する。
    /// scheduled=true は定期実行（フルスキャン）、false はクイック（設定でフルに変更可）。
    /// 完了したら true、中止されたら false。
    @discardableResult
    func run(state: AppState, scheduled: Bool = false) async -> Bool {
        guard !running else { return false }
        running = true; cancelled = false; doneSteps = []; activeSteps = []
        progress = 0; etaText = ""
        weights = StepDurations.load()
        meter = ProgressMeter()
        defer { running = false; activeSteps = [] }
        let settings = Settings.load()
        let full = scheduled || !settings.quickScan
        let t0 = Date()
        let ticker = Task { [weak self] in
            while !Task.isCancelled { self?.tick(state: state); try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        defer { ticker.cancel() }

        // 値は各ステップの完了直後に確定させる（最後に共有状態を読み直さない）
        let security = Task { await self.timed(.security) { await self.steps.security(state, full) } }
        let junk = await timed(.cleanup) { await steps.cleanup(state, settings) }
        var logins: (value: (new: Int, changed: Int), seconds: Double) = ((0, 0), 0)
        var large: (value: (count: Int, bytes: Int64), seconds: Double) = ((0, 0), 0)
        if !cancelled { logins = await timed(.loginItems) { await steps.loginItems(state) } }
        if !cancelled { large = await timed(.largeFiles) { await steps.largeFiles(state, settings) } }
        let sec = await security.value
        guard !cancelled else { return false }

        StepDurations.save(StepDurations.load().merging([
            "cleanup": junk.seconds, "security": sec.seconds, "loginItems": logins.seconds, "largeFiles": large.seconds,
        ].filter { $0.value > 0.5 }) { _, n in n })
        progress = 1

        let r = SmartCareResult(
            date: Date(), junkBytes: junk.value.junk, safeJunkBytes: junk.value.safeJunk, threats: sec.value,
            newLoginItems: logins.value.new, changedLoginItems: logins.value.changed,
            largeFileCount: large.value.count, largeFileBytes: large.value.bytes,
            deep: settings.deepScan, seconds: Date().timeIntervalSince(t0))
        r.save()
        result = r
        state.lastScanSummary = "前回: \(r.date.formatted(date: .abbreviated, time: .shortened)) / \(r.summary)"
        try? History.append(HistoryEntry(date: Date(), kind: .scan, target: scheduled ? "スマートケア（定期フル）" : (full ? "スマートケア（フル）" : "スマートケア"),
                                         bytes: r.junkBytes, result: r.threats == 0 ? "clean" : "found",
                                         detail: "\(r.summary)、\(Int(r.seconds)) 秒"))
        return true
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
