import Foundation
import AppKit
import Observation

struct CleanupItem: Identifiable, Hashable {
    let url: URL
    let size: Int64
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// 集計から除外した項目と、その理由
struct ExcludedItem: Hashable {
    let name: String
    let reason: String
}

/// 削除対象のスナップショット（確認ダイアログで見せた内容と実行内容を一致させる）
struct CleanupJob: Hashable {
    let item: CleanupItem
    let roots: [URL]
}

struct CleanupCategory: Identifiable {
    let id: String
    let name: String
    let summary: String
    let effect: String
    /// この分類の削除を許可するルート（SafeTrash の allowedRoots）
    let roots: [URL]
    var items: [CleanupItem]
    var skipped: Int
    var excluded: [ExcludedItem] = []
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

private final class Counter { var n = 0 }

enum CleanupScanner {
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// ディレクトリの割り当てサイズ合計。読めないものは skipped に数える。
    static func size(of url: URL) -> (bytes: Int64, skipped: Int) {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return (0, 1) }
        if v.isDirectory != true || v.isSymbolicLink == true {
            return (Int64(v.totalFileAllocatedSize ?? 0), 0)
        }
        let c = Counter()
        var total: Int64 = Int64(v.totalFileAllocatedSize ?? 0)
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                      options: [], errorHandler: { _, _ in c.n += 1; return true })
        else { return (0, 1) }
        for case let f as URL in en {
            if let r = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) {
                total += Int64(r.totalFileAllocatedSize ?? 0)
            } else { c.n += 1 }
        }
        return (total, c.n)
    }

    /// 直下の項目（.DS_Store などドットで始まるものは除く）
    static func children(of dir: URL) -> [URL]? {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: []))?
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    static func makeCategory(id: String, name: String, summary: String, effect: String,
                             roots: [URL], urls: [URL], excluded: [ExcludedItem] = []) -> CleanupCategory {
        var skipped = 0
        var items: [CleanupItem] = []
        for u in urls {
            let r = size(of: u)
            skipped += r.skipped
            if r.bytes > 0 { items.append(CleanupItem(url: u, size: r.bytes)) }
        }
        items.sort { $0.size > $1.size }
        return CleanupCategory(id: id, name: name, summary: summary, effect: effect,
                               roots: roots, items: items, skipped: skipped, excluded: excluded)
    }

    /// 実行中のアプリ・プロセスの識別情報（キャッシュ名との照合用）
    struct RunningInfo {
        var ids: Set<String> = []        // バンドルID（小文字）
        var names: Set<String> = []      // 実行ファイル名・表示名・プロセス名（小文字）
        var vendors: Set<String> = []    // バンドルIDの提供元（com.google.* → google）

        /// 名前が実行中のものに該当すれば理由を返す
        func match(_ rawName: String) -> String? {
            let n = rawName.lowercased()
            if ids.contains(n) { return "実行中のアプリ(\(rawName))のキャッシュ" }
            if ids.contains(where: { n.hasPrefix($0 + ".") }) { return "実行中のアプリのキャッシュ" }
            if vendors.contains(n) { return "実行中のアプリの提供元(\(rawName))" }
            for k in names where k.count >= 4 {
                if n == k || n.hasPrefix(k + "-") || n.hasPrefix(k + " ") || n.hasPrefix(k + ".") || n.hasPrefix(k + "_") {
                    return "実行中のプロセス(\(k))に関連"
                }
            }
            return nil
        }

        static func current(extraProcessNames: [String] = []) -> RunningInfo {
            var r = RunningInfo()
            for a in NSWorkspace.shared.runningApplications {
                if let b = a.bundleIdentifier?.lowercased() {
                    r.ids.insert(b)
                    let parts = b.split(separator: ".")
                    if parts.count >= 2 { r.vendors.insert(String(parts[1])) }
                }
                if let e = a.executableURL?.lastPathComponent { r.names.insert(e.lowercased()) }
                if let n = a.localizedName { r.names.insert(n.lowercased()) }
                if let u = a.bundleURL { r.names.insert(u.deletingPathExtension().lastPathComponent.lowercased()) }
            }
            for p in extraProcessNames { r.names.insert(p.lowercased()) }
            return r
        }
    }

    /// 再取得に時間がかかる・システムが管理するため掃除しないキャッシュ名（小文字）
    static let neverCleanCaches: [String: String] = [
        "ms-playwright": "ブラウザの再ダウンロードが必要になるため",
        "cloudkit": "iCloud 同期の管理データのため",
        "geoservices": "システムの位置情報キャッシュのため",
        "passkit": "Wallet 関連のため",
        "gamekit": "Game Center 関連のため",
        "familycircle": "ファミリー共有関連のため",
        "maccaretests": "MacCare 自身のテスト領域のため",
    ]

    /// ~/Library/Caches 直下から、除外すべきものを理由つきで取り除く
    static func userCacheItems(root: URL, otherCategoryNames: Set<String>, running: RunningInfo)
        -> (keep: [URL], excluded: [ExcludedItem]) {
        var keep: [URL] = [], ex: [ExcludedItem] = []
        for u in children(of: root) ?? [] {
            let n = u.lastPathComponent, l = n.lowercased()
            if l.hasPrefix("com.apple.") { ex.append(ExcludedItem(name: n, reason: "Apple 製のため")); continue }
            if let why = neverCleanCaches[l] { ex.append(ExcludedItem(name: n, reason: why)); continue }
            if otherCategoryNames.contains(n) { ex.append(ExcludedItem(name: n, reason: "別の分類で集計")); continue }
            if let why = running.match(n) { ex.append(ExcludedItem(name: n, reason: why)); continue }
            keep.append(u)
        }
        return (keep, ex)
    }

    /// 検索範囲から未更新の node_modules を探す
    static func staleNodeModules(roots: [URL], staleDays: Int, now: Date = Date(),
                                 maxDepth: Int = 5, library: URL? = nil) -> [URL] {
        let lib = (library ?? home.appendingPathComponent("Library")).standardizedFileURL.path
        let limit = TimeInterval(staleDays) * 86400
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]

        func walk(_ dir: URL, depth: Int) {
            guard let kids = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: []) else { return }
            var newest: Date? = nil
            var nm: URL? = nil
            for k in kids {
                let v = try? k.resourceValues(forKeys: Set(keys))
                if k.lastPathComponent == "node_modules" { nm = k; continue }
                if let d = v?.contentModificationDate, newest == nil || d > newest! { newest = d }
            }
            if let nm {
                let ref = newest ?? (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let ref, now.timeIntervalSince(ref) > limit { found.append(nm) }
            }
            guard depth < maxDepth else { return }
            for k in kids {
                let n = k.lastPathComponent
                guard n != "node_modules", !n.hasPrefix(".") else { continue }
                guard let v = try? k.resourceValues(forKeys: Set(keys)),
                      v.isDirectory == true, v.isSymbolicLink != true else { continue }
                if k.standardizedFileURL.path == lib { continue }
                if ["app", "photoslibrary"].contains(k.pathExtension.lowercased()) { continue }
                walk(k, depth: depth + 1)
            }
        }
        for r in roots { walk(r, depth: 0) }
        return found
    }

    static func scanAll(settings: Settings, brewCache: URL?, running: RunningInfo,
                        progress: (String) -> Void) -> [CleanupCategory] {
        let fm = FileManager.default
        let caches = home.appendingPathComponent("Library/Caches")
        let pip = caches.appendingPathComponent("pip")
        var out: [CleanupCategory] = []

        func dirCategory(_ id: String, _ name: String, _ summary: String, _ effect: String, _ root: URL) {
            guard fm.fileExists(atPath: root.path) else { return }
            progress(name)
            out.append(makeCategory(id: id, name: name, summary: summary, effect: effect,
                                    roots: [root], urls: children(of: root) ?? []))
        }

        var excluded: Set<String> = ["pip"]
        if let b = brewCache, b.deletingLastPathComponent().standardizedFileURL.path == caches.path {
            excluded.insert(b.lastPathComponent)
        }
        progress("ユーザーキャッシュ")
        let uc = userCacheItems(root: caches, otherCategoryNames: excluded, running: running)
        out.append(makeCategory(
            id: "caches", name: "ユーザーキャッシュ",
            summary: "~/Library/Caches 内のアプリのキャッシュ（Apple 製・実行中のアプリを除く）。",
            effect: "次回起動時にキャッシュが再生成されます。初回のみ動作が遅くなることがあります。",
            roots: [caches], urls: uc.keep, excluded: uc.excluded))
        dirCategory("logs", "ユーザーログ", "~/Library/Logs 内のログファイル。",
                    "過去のログが失われます。アプリの動作には影響しません。",
                    home.appendingPathComponent("Library/Logs"))
        dirCategory("npm", "npm キャッシュ", "~/.npm/_cacache のダウンロードキャッシュ。",
                    "次回の npm install で再ダウンロードされます。",
                    home.appendingPathComponent(".npm/_cacache"))
        if let b = brewCache {
            dirCategory("brew", "Homebrew キャッシュ", "brew --cache のダウンロード済みパッケージ。",
                        "次回の brew install / upgrade で再ダウンロードされます。", b)
        }
        dirCategory("pip", "pip キャッシュ", "~/Library/Caches/pip のダウンロードキャッシュ。",
                    "次回の pip install で再ダウンロードされます。", pip)
        let xcode = home.appendingPathComponent("Library/Developer/Xcode")
        dirCategory("xcode-derived", "Xcode DerivedData", "Xcode のビルド成果物とインデックス。",
                    "次回のビルドで再生成されます（時間がかかります）。", xcode.appendingPathComponent("DerivedData"))
        dirCategory("xcode-archives", "Xcode Archives", "Xcode でアーカイブしたビルド。",
                    "配布用アーカイブが失われます。再提出に必要な場合は残してください。",
                    xcode.appendingPathComponent("Archives"))
        dirCategory("xcode-devsupport", "iOS DeviceSupport", "実機デバッグ用のシンボルキャッシュ。",
                    "実機を接続すると再作成されます（初回は時間がかかります）。",
                    xcode.appendingPathComponent("iOS DeviceSupport"))

        progress("古い node_modules")
        let nmRoots = settings.largeFileRoots.map { URL(fileURLWithPath: $0) }
        out.append(makeCategory(
            id: "node_modules", name: "古い node_modules",
            summary: "\(settings.nodeModulesStaleDays) 日以上更新のないプロジェクトの node_modules。",
            effect: "npm install で復元できます。",
            roots: nmRoots, urls: staleNodeModules(roots: nmRoots, staleDays: settings.nodeModulesStaleDays)))
        return out.filter { !$0.items.isEmpty || $0.skipped > 0 || !$0.excluded.isEmpty }
    }
}

enum TrashBin {
    static var url: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash") }
    /// フルディスクアクセスがないと読めない
    static func isReadable() -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }
    static func size() -> Int64 { CleanupScanner.size(of: url).bytes }
}

@MainActor @Observable
final class CleanupModel {
    var categories: [CleanupCategory] = []
    var selected: Set<String> = []
    var scanning = false
    var cleaning = false
    var progressText = ""
    var lastFreed: Int64? = nil
    var message: String? = nil
    var hasScanned = false
    var trashReadable = false
    var trashSize: Int64 = 0
    private var scanTask: Task<Void, Never>?

    var excludedCount: Int { categories.reduce(0) { $0 + $1.excluded.count } }

    /// 現在の選択内容のスナップショット（確認ダイアログ表示時点の内容で固定する）
    func snapshotSelected() -> [CleanupJob] {
        categories.flatMap { c in c.items.filter { selected.contains($0.id) }.map { CleanupJob(item: $0, roots: c.roots) } }
    }

    static func summary(of jobs: [CleanupJob], categories: [CleanupCategory]) -> String {
        let ids = Set(jobs.map(\.item.id))
        let lines = categories.compactMap { c -> String? in
            let hit = c.items.filter { ids.contains($0.id) }
            guard !hit.isEmpty else { return nil }
            return "\(c.name): \(hit.count) 件 / \(formatBytes(hit.reduce(0) { $0 + $1.size }))"
        }
        return lines.joined(separator: "\n") + "\n\n合計 \(jobs.count) 件 / \(formatBytes(jobs.reduce(0) { $0 + $1.item.size }))"
    }

    var selectedSize: Int64 { snapshotSelected().reduce(0) { $0 + $1.item.size } }
    var selectedCount: Int { selected.count }

    /// 実行中のスキャンがあればその完了を待つ（呼び出し側が古い状態を読まないようにする）
    func scan(settings: Settings) async {
        if let t = scanTask { await t.value; return }
        let t = Task { await self.performScan(settings: settings) }
        scanTask = t
        await t.value
        scanTask = nil
    }

    private func performScan(settings: Settings) async {
        scanning = true; message = nil; lastFreed = nil
        var brewURL: URL? = nil
        if let brew = Tools.path("brew"),
           let r = try? await Shell.run(brew, ["--cache"]), r.exitCode == 0 {
            let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let u = URL(fileURLWithPath: p).standardizedFileURL
            // ホーム配下のパスのみ採用
            if !p.isEmpty, SafeTrash.isInside(u, of: CleanupScanner.home) { brewURL = u }
        }
        // GUI アプリ以外（node / claude など）の実行中プロセス名も取得
        var procs: [String] = []
        if let r = try? await Shell.run("/bin/ps", ["-axco", "comm"]) {
            procs = r.stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        let running = CleanupScanner.RunningInfo.current(extraProcessNames: procs)
        let cats = await Task.detached(priority: .userInitiated) { [weak self] () -> [CleanupCategory] in
            CleanupScanner.scanAll(settings: settings, brewCache: brewURL, running: running) { t in
                Task { @MainActor in self?.progressText = t + " を集計中…" }
            }
        }.value
        let readable = TrashBin.isReadable()
        let tsize = readable ? await Task.detached { TrashBin.size() }.value : 0
        categories = cats
        selected = selected.intersection(Set(cats.flatMap { $0.items.map(\.id) }))
        trashReadable = readable; trashSize = tsize
        hasScanned = true; scanning = false; progressText = ""
    }

    /// スナップショットされた項目のみをゴミ箱へ（SafeTrash 経由）。共有の選択状態は読まない・変更しない。
    func cleanItems(_ jobs: [CleanupJob], settings: Settings, rescan: Bool = true) async {
        guard !cleaning else { message = "別の掃除が実行中のため、何も削除しませんでした。"; return }
        cleaning = true
        let result = await Task.detached(priority: .userInitiated) { () -> (Int64, Int) in
            var freed: Int64 = 0, failed = 0
            for j in jobs {
                do { try SafeTrash.trash(j.item.url, allowedRoots: j.roots); freed += j.item.size }
                catch { failed += 1 }
            }
            return (freed, failed)
        }.value
        try? History.append(HistoryEntry(date: Date(), kind: .cleanup, target: "\(jobs.count) 件",
                                         bytes: result.0, result: result.1 == 0 ? "ok" : "partial",
                                         detail: "失敗 \(result.1) 件"))
        let done = Set(jobs.map(\.item.id))
        selected.subtract(done)
        cleaning = false
        if rescan { await scan(settings: settings) }
        lastFreed = result.0
        if result.1 > 0 { message = "\(result.1) 件を移動できませんでした。" }
        TrashNotice.post(TrashOutcome(moved: jobs.count - result.1, failed: result.1, bytes: result.0))
    }

    /// ゴミ箱を空にする（完全削除）。Finder 経由。AppleScript はメインスレッド外で実行する。
    func emptyTrash(settings: Settings) async {
        let before = trashSize
        let err: String? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var e: NSDictionary?
                NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&e)
                cont.resume(returning: e.map { "\($0)" })
            }
        }
        let ok = (err == nil)
        try? History.append(HistoryEntry(date: Date(), kind: .cleanup, target: "~/.Trash", bytes: ok ? before : 0,
                                         result: ok ? "ok" : "failed",
                                         detail: ok ? "ゴミ箱を空にしました" : (err ?? "")))
        message = ok ? nil : "ゴミ箱を空にできませんでした（Finder の自動操作が許可されているか確認してください）。"
        await scan(settings: settings)
        if ok { lastFreed = before }
    }
}
