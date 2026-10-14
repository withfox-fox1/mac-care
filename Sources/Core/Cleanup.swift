import Foundation
import AppKit
import Observation

struct CleanupItem: Identifiable, Hashable {
    let url: URL
    let size: Int64
    var id: String { url.path }
    var name: String { url.lastPathComponent }
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

    static func children(of dir: URL) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])
    }

    static func makeCategory(id: String, name: String, summary: String, effect: String,
                             roots: [URL], urls: [URL]) -> CleanupCategory {
        var skipped = 0
        var items: [CleanupItem] = []
        for u in urls {
            let r = size(of: u)
            skipped += r.skipped
            if r.bytes > 0 { items.append(CleanupItem(url: u, size: r.bytes)) }
        }
        items.sort { $0.size > $1.size }
        return CleanupCategory(id: id, name: name, summary: summary, effect: effect,
                               roots: roots, items: items, skipped: skipped)
    }

    /// ~/Library/Caches 直下から、Apple 製・実行中アプリ・他分類で扱うものを除外
    static func userCacheItems(root: URL, excludedNames: Set<String>, runningIDs: Set<String>) -> [URL] {
        (children(of: root) ?? []).filter { u in
            let n = u.lastPathComponent
            return !n.hasPrefix("com.apple.") && !excludedNames.contains(n)
                && !runningIDs.contains(n.lowercased())
        }
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

    static func scanAll(settings: Settings, brewCache: URL?, runningIDs: Set<String>,
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

        var excluded: Set<String> = ["pip", "MacCareTests"]
        if let b = brewCache, b.deletingLastPathComponent().standardizedFileURL.path == caches.path {
            excluded.insert(b.lastPathComponent)
        }
        progress("ユーザーキャッシュ")
        out.append(makeCategory(
            id: "caches", name: "ユーザーキャッシュ",
            summary: "~/Library/Caches 内のアプリのキャッシュ（Apple 製・実行中のアプリを除く）。",
            effect: "次回起動時にキャッシュが再生成されます。初回のみ動作が遅くなることがあります。",
            roots: [caches],
            urls: userCacheItems(root: caches, excludedNames: excluded, runningIDs: runningIDs)))
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
        return out.filter { !$0.items.isEmpty || $0.skipped > 0 }
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

    var selectedSize: Int64 {
        categories.flatMap { $0.items }.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
    }
    var selectedCount: Int { selected.count }

    var confirmationSummary: String {
        let lines = categories.compactMap { c -> String? in
            let ids = c.items.filter { selected.contains($0.id) }
            guard !ids.isEmpty else { return nil }
            return "\(c.name): \(ids.count) 件 / \(formatBytes(ids.reduce(0) { $0 + $1.size }))"
        }
        return lines.joined(separator: "\n") + "\n\n合計 \(selectedCount) 件 / \(formatBytes(selectedSize))"
    }

    func scan(settings: Settings) async {
        guard !scanning else { return }
        scanning = true; message = nil; lastFreed = nil
        var brewURL: URL? = nil
        if let brew = Tools.path("brew"),
           let r = try? await Shell.run(brew, ["--cache"]), r.exitCode == 0 {
            let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let u = URL(fileURLWithPath: p).standardizedFileURL
            // ホーム配下のパスのみ採用
            if !p.isEmpty, SafeTrash.isInside(u, of: CleanupScanner.home) { brewURL = u }
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        let cats = await Task.detached(priority: .userInitiated) { [weak self] () -> [CleanupCategory] in
            CleanupScanner.scanAll(settings: settings, brewCache: brewURL, runningIDs: running) { t in
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

    /// 選択項目をゴミ箱へ。各項目は SafeTrash を通す。
    func cleanSelected(settings: Settings) async {
        guard !cleaning else { return }
        cleaning = true
        let jobs: [(CleanupItem, [URL])] = categories.flatMap { c in
            c.items.filter { selected.contains($0.id) }.map { ($0, c.roots) }
        }
        let result = await Task.detached(priority: .userInitiated) { () -> (Int64, Int) in
            var freed: Int64 = 0, failed = 0
            for (item, roots) in jobs {
                do { try SafeTrash.trash(item.url, allowedRoots: roots); freed += item.size }
                catch { failed += 1 }
            }
            return (freed, failed)
        }.value
        try? History.append(HistoryEntry(date: Date(), kind: .cleanup, target: "\(jobs.count) 件",
                                         bytes: result.0, result: result.1 == 0 ? "ok" : "partial",
                                         detail: "失敗 \(result.1) 件"))
        selected = []
        cleaning = false
        await scan(settings: settings)
        lastFreed = result.0
        if result.1 > 0 { message = "\(result.1) 件を移動できませんでした。" }
    }

    /// ゴミ箱を空にする（完全削除）。Finder 経由。
    func emptyTrash(settings: Settings) async {
        let before = trashSize
        var err: NSDictionary?
        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        script?.executeAndReturnError(&err)
        let ok = (err == nil)
        try? History.append(HistoryEntry(date: Date(), kind: .cleanup, target: "~/.Trash", bytes: ok ? before : 0,
                                         result: ok ? "ok" : "failed",
                                         detail: ok ? "ゴミ箱を空にしました" : "\(err ?? [:])"))
        message = ok ? nil : "ゴミ箱を空にできませんでした（Finder の自動操作が許可されているか確認してください）。"
        await scan(settings: settings)
        if ok { lastFreed = before }
    }
}
