import Foundation
import AppKit
import Observation
@preconcurrency import UserNotifications

struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    var size: Int64            // 0 = 未計算
    let lastUsed: Date?
    let isAppStore: Bool
    var id: String { url.path }
    var isApple: Bool { bundleID.lowercased().hasPrefix("com.apple.") }
}

struct RelatedFile: Identifiable, Hashable {
    /// bundleID: ID と完全一致 / bundlePrefix: ID で始まる別名（既定は未選択）/ nameOnly: 名前のみ一致（既定は未選択）
    enum Kind { case bundleID, bundlePrefix, nameOnly }
    let url: URL
    let size: Int64
    let kind: Kind
    /// /Library 配下（管理者権限が必要なため表示のみ）
    let isSystem: Bool
    /// 誤削除の恐れがあるため表示のみ（Containers など）
    var displayOnly: Bool = false
    var id: String { url.path }
    var isProtected: Bool { isSystem || displayOnly }
}

enum AppCatalog {
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }
    static func defaultDirs() -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    /// 直下の .app と、フォルダ1階層下の .app を列挙
    static func appURLs(in dirs: [URL] = defaultDirs()) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for d in dirs {
            for c in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                if c.pathExtension == "app" { out.append(c); continue }
                if (try? c.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                   !c.lastPathComponent.hasPrefix(".") {
                    for n in (try? fm.contentsOfDirectory(at: c, includingPropertiesForKeys: nil)) ?? []
                    where n.pathExtension == "app" { out.append(n) }
                }
            }
        }
        return out
    }

    /// Info.plist の場所。macOS アプリは Contents/Info.plist、iOS/iPadOS アプリは Wrapper/*.app/Info.plist
    static func infoPlist(for url: URL) -> URL? {
        let fm = FileManager.default
        let mac = url.appendingPathComponent("Contents/Info.plist")
        if fm.fileExists(atPath: mac.path) { return mac }
        let wrapper = url.appendingPathComponent("Wrapper")
        for w in (try? fm.contentsOfDirectory(at: wrapper, includingPropertiesForKeys: nil)) ?? []
        where w.pathExtension == "app" {
            let p = w.appendingPathComponent("Info.plist")
            if fm.fileExists(atPath: p.path) { return p }
        }
        let flat = url.appendingPathComponent("Info.plist")
        return fm.fileExists(atPath: flat.path) ? flat : nil
    }

    static func info(for url: URL, withSize: Bool = true) -> InstalledApp? {
        guard let plist = infoPlist(for: url),
              let d = NSDictionary(contentsOf: plist) as? [String: Any],
              let bid = d["CFBundleIdentifier"] as? String else { return nil }
        let name = (d["CFBundleDisplayName"] as? String) ?? (d["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let ver = (d["CFBundleShortVersionString"] as? String) ?? (d["CFBundleVersion"] as? String) ?? ""
        let mas = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt").path)
            || FileManager.default.fileExists(atPath: url.appendingPathComponent("Wrapper/iTunesMetadata.plist").path)
        return InstalledApp(url: url, name: name, bundleID: bid, version: ver,
                            size: withSize ? CleanupScanner.size(of: url).bytes : 0,
                            lastUsed: LargeFileScanner.lastUsed(url), isAppStore: mas)
    }

    /// 一覧の取得（サイズは重いので計算しない。必要になったとき computeSize を使う）
    static func scan(dirs: [URL] = defaultDirs(), withSize: Bool = false) -> [InstalledApp] {
        let urls = appURLs(in: dirs)
        var result = [InstalledApp?](repeating: nil, count: urls.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            let a = info(for: urls[i], withSize: withSize)
            lock.lock(); result[i] = a; lock.unlock()
        }
        return result.compactMap { $0 }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

enum RelatedFinder {
    static let userSubdirs = ["Application Support", "Caches", "Containers", "Group Containers", "Preferences",
                              "Saved Application State", "HTTPStorages", "WebKit", "Logs", "LaunchAgents"]
    static let systemSubdirs = ["Application Support", "Caches", "Preferences", "LaunchAgents", "LaunchDaemons"]

    /// 名前が Bundle ID に該当するか（境界は「.」。com.foo.app は com.foo.app2 に一致しない）
    static func matchesBundleID(_ name: String, _ bid: String) -> Bool {
        let n = name.lowercased(), b = bid.lowercased()
        return n == b || n.hasPrefix(b + ".") || n.hasSuffix("." + b) || n.contains("." + b + ".")
    }

    /// ID そのもの（拡張子 plist/savedState 等を除いて一致）か、前方一致のみか
    static func isExactMatch(_ name: String, _ bid: String) -> Bool {
        var n = name.lowercased()
        for ext in [".plist", ".savedstate", ".binarycookies", ".lockfile"] where n.hasSuffix(ext) { n = String(n.dropLast(ext.count)) }
        let b = bid.lowercased()
        return n == b || n.hasSuffix("." + b)   // Group Containers の「TEAMID.<bundle id>」も ID 一致とみなす
    }

    /// 削除時に許可するルート（検索した各サブフォルダのみ。~/Library 全体は許可しない）
    static func allowedRoots(library: URL) -> [URL] { userSubdirs.map { library.appendingPathComponent($0) } }

    static func find(bundleID: String, appName: String, library: URL, systemLibrary: URL? = nil,
                     otherInstalledIDs: Set<String> = []) -> [RelatedFile] {
        let fm = FileManager.default
        var out: [RelatedFile] = []
        // 自分より具体的な（長い）別アプリのIDに属するものは除く（Chrome と Chrome.canary など）
        let moreSpecific = otherInstalledIDs.map { $0.lowercased() }.filter { $0.count > bundleID.count && $0 != bundleID.lowercased() }
        func scanDir(_ root: URL, _ subs: [String], system: Bool) {
            for sub in subs {
                let dir = root.appendingPathComponent(sub)
                for c in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                    let n = c.lastPathComponent
                    if n.hasPrefix(".") { continue }
                    let kind: RelatedFile.Kind?
                    if matchesBundleID(n, bundleID) {
                        if moreSpecific.contains(where: { matchesBundleID(n, $0) }) { continue }
                        kind = isExactMatch(n, bundleID) ? .bundleID : .bundlePrefix
                    }
                    else if !system, !appName.isEmpty, n == appName,
                            (try? c.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { kind = .nameOnly }
                    else { kind = nil }
                    guard let kind else { continue }
                    out.append(RelatedFile(url: c, size: CleanupScanner.size(of: c).bytes, kind: kind, isSystem: system))
                }
            }
        }
        scanDir(library, userSubdirs, system: false)
        if let sys = systemLibrary { scanDir(sys, systemSubdirs, system: true) }
        return out.sorted { $0.size > $1.size }
    }
}

enum Leftovers {
    /// リバースDNS形式（ドット2つ以上、各要素は英数・-・_）
    static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let f = parts.first?.first, f.isLetter else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    }

    /// macOS 自身が管理するため残骸扱いしない名前（前方一致、小文字）
    static let systemOwnedPrefixes = ["org.cups.", "com.apple.", "group.com.apple.", "systemgroup.", "com.openssh.", "org.openssh.",
                                      "org.x.", "org.freedesktop."]
    static func isSystemOwned(_ lowercasedName: String) -> Bool {
        lowercasedName.contains("com.apple.") || systemOwnedPrefixes.contains { lowercasedName.hasPrefix($0) }
    }

    /// LaunchServices がアプリとして認識している ID か
    static func systemKnowsApp(_ id: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    /// 残骸候補。Containers / Group Containers は書類を含み得るため「表示のみ」で返す。
    static func find(library: URL, installedIDs: Set<String>, runningIDs: Set<String>,
                     isInstalled: (String) -> Bool = Leftovers.systemKnowsApp) -> [RelatedFile] {
        let fm = FileManager.default
        let known = installedIDs.union(runningIDs).map { $0.lowercased() }
        // 同じ提供元（先頭2要素）のアプリが入っている場合は拡張機能等の可能性があるため除外（誤検出より見逃しを優先）
        func vendor(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".") }
        let vendors = Set(known.map(vendor))
        var out: [RelatedFile] = []
        for sub in ["Application Support", "Caches", "Preferences", "Containers", "Group Containers"] {
            let displayOnly = (sub == "Containers" || sub == "Group Containers")
            let dir = library.appendingPathComponent(sub)
            for c in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                var n = c.lastPathComponent
                if n.hasPrefix(".") { continue }
                if sub == "Preferences" { guard n.hasSuffix(".plist") else { continue }; n = String(n.dropLast(6)) }
                let l = n.lowercased()
                guard looksLikeBundleID(n), !isSystemOwned(l) else { continue }
                if vendors.contains(vendor(l)) { continue }
                if known.contains(where: { l == $0 || l.hasPrefix($0 + ".") || $0.hasPrefix(l + ".") }) { continue }
                // Group Containers は「TEAMID.<bundle id>」「group.<bundle id>」形式。先頭要素を除いた ID も確認する
                var candidates = [n]
                if sub == "Group Containers", let dot = n.firstIndex(of: ".") { candidates.append(String(n[n.index(after: dot)...])) }
                if candidates.contains(where: { isInstalled($0) }) { continue }
                out.append(RelatedFile(url: c, size: CleanupScanner.size(of: c).bytes, kind: .bundleID,
                                       isSystem: false, displayOnly: displayOnly))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// 削除可能なものだけ（表示のみの項目は含めない）
    static func deletable(_ items: [RelatedFile]) -> [RelatedFile] { items.filter { !$0.isProtected } }
}

enum UninstallError: Error, CustomStringConvertible {
    case appleApp, running
    case appTrashFailed(String)
    var description: String {
        switch self {
        case .appleApp: return "Apple 製アプリは削除できません。"
        case .running: return "実行中のアプリは削除できません。終了してからやり直してください。"
        case .appTrashFailed(let m): return "アプリ本体をゴミ箱へ移動できませんでした（管理者権限が必要な可能性があります）: \(m)"
        }
    }
}

enum AppUninstaller {
    /// アプリ本体 → 関連ファイルの順。本体が失敗したら関連ファイルには触れない。
    /// isRunning は削除の直前に評価する。戻り値: (成功数, 失敗した関連ファイルのパス)
    static func uninstall(app: InstalledApp, related: [RelatedFile], isRunning: () -> Bool,
                          library: URL = AppCatalog.home.appendingPathComponent("Library"),
                          appRoots: [URL] = AppCatalog.defaultDirs()) throws -> (trashed: Int, failed: [String]) {
        if app.isApple { throw UninstallError.appleApp }
        if isRunning() { throw UninstallError.running }
        do { try SafeTrash.trash(app.url, allowedRoots: appRoots) }
        catch { throw UninstallError.appTrashFailed("\(error)") }
        var ok = 1
        var failed: [String] = []
        var bytes = app.size
        let roots = RelatedFinder.allowedRoots(library: library)
        for r in related where !r.isProtected {
            do { try SafeTrash.trash(r.url, allowedRoots: roots); ok += 1; bytes += r.size }
            catch { failed.append(r.url.path) }
        }
        try? History.append(HistoryEntry(date: Date(), kind: .uninstall, target: app.url.path, bytes: bytes,
                                         result: failed.isEmpty ? "ok" : "partial",
                                         detail: "\(app.bundleID)、関連 \(ok - 1) 件、失敗 \(failed.count) 件"))
        return (ok, failed)
    }

    /// 残骸のゴミ箱移動。表示のみの項目は無視する。戻り値は失敗数。
    static func trashLeftovers(_ items: [RelatedFile],
                               library: URL = AppCatalog.home.appendingPathComponent("Library")) -> Int {
        let roots = ["Application Support", "Caches", "Preferences"].map { library.appendingPathComponent($0) }
        var f = 0
        for i in Leftovers.deletable(items) { do { try SafeTrash.trash(i.url, allowedRoots: roots) } catch { f += 1 } }
        return f
    }
}

/// 確認ダイアログで見せた内容そのままのアンインストール計画
struct UninstallPlan {
    let app: InstalledApp
    let related: [RelatedFile]
}

@MainActor @Observable
final class AppsModel {
    var apps: [InstalledApp] = []
    var leftovers: [RelatedFile] = []
    var related: [RelatedFile] = []
    var selectedRelated: Set<String> = []
    var scanning = false
    var hasScanned = false
    var lastScannedAt: Date? = nil
    var message: String? = nil
    var runningIDs: Set<String> = []
    private var scanTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?

    /// 実行中のスキャンがあれば完了を待つ
    func scan() async {
        if let t = scanTask { await t.value; return }
        let t = Task { await self.performScan() }
        scanTask = t
        await t.value
        scanTask = nil
    }

    private func performScan() async {
        scanning = true; message = nil
        sizeTask?.cancel()
        runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        let running = runningIDs
        let (a, l) = await Task.detached(priority: .userInitiated) { () -> ([InstalledApp], [RelatedFile]) in
            let apps = AppCatalog.scan()
            let left = Leftovers.find(library: AppCatalog.home.appendingPathComponent("Library"),
                                      installedIDs: Set(apps.map(\.bundleID)), runningIDs: running)
            return (apps, left)
        }.value
        apps = a; leftovers = l; hasScanned = true; lastScannedAt = Date(); scanning = false
        computeSizesInBackground()
    }

    /// サイズは一覧表示後に順次計算する（一覧をブロックしない）
    private func computeSizesInBackground() {
        let urls = apps.map(\.url)
        sizeTask = Task { [weak self] in
            for u in urls {
                if Task.isCancelled { return }
                let sz = await Task.detached(priority: .utility) { CleanupScanner.size(of: u).bytes }.value
                guard let self, let i = self.apps.firstIndex(where: { $0.url == u }) else { continue }
                self.apps[i].size = sz
            }
        }
    }

    func isRunning(_ app: InstalledApp) -> Bool { runningIDs.contains(app.bundleID.lowercased()) }

    func loadRelated(for app: InstalledApp) async {
        related = []; selectedRelated = []
        let others = Set(apps.map(\.bundleID))
        let r = await Task.detached { () -> [RelatedFile] in
            RelatedFinder.find(bundleID: app.bundleID, appName: app.url.deletingPathExtension().lastPathComponent,
                               library: AppCatalog.home.appendingPathComponent("Library"),
                               systemLibrary: URL(fileURLWithPath: "/Library"), otherInstalledIDs: others)
        }.value
        related = r
        // 既定で選択するのは ID 完全一致のみ（前方一致・名前のみ一致は未選択）
        selectedRelated = Set(r.filter { $0.kind == .bundleID && !$0.isProtected }.map(\.id))
    }

    /// 現在の選択からアンインストール計画を作る（確認ダイアログ表示時に呼ぶ）
    func plan(for app: InstalledApp) -> UninstallPlan {
        UninstallPlan(app: app, related: related.filter { selectedRelated.contains($0.id) && !$0.isProtected })
    }

    func uninstall(_ plan: UninstallPlan) async {
        let app = plan.app
        do {
            // 実行中かどうかは削除の直前に NSRunningApplication で再確認する
            let r = try await Task.detached { try AppUninstaller.uninstall(
                app: app, related: plan.related,
                isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty }) }.value
            message = r.failed.isEmpty ? "「\(app.name)」と関連ファイル \(r.trashed - 1) 件をゴミ箱へ移動しました。"
                : "「\(app.name)」を移動しました。関連ファイル \(r.failed.count) 件は移動できませんでした。"
            apps.removeAll { $0.id == app.id }
            related = []
            let failedSet = Set(r.failed)
            let bytes = app.size + plan.related.filter { !$0.isProtected && !failedSet.contains($0.url.path) }.reduce(0) { $0 + $1.size }
            TrashNotice.post(TrashOutcome(moved: r.trashed, failed: r.failed.count, bytes: bytes))
        } catch { message = "\(error)" }
    }

    func trashLeftovers(_ items: [RelatedFile]) async {
        let deletable = Leftovers.deletable(items)
        let failed = await Task.detached { AppUninstaller.trashLeftovers(deletable) }.value
        try? History.append(HistoryEntry(date: Date(), kind: .uninstall, target: "残骸 \(deletable.count) 件",
                                         bytes: deletable.reduce(0) { $0 + $1.size }, result: failed == 0 ? "ok" : "partial", detail: ""))
        let gone = Set(deletable.map(\.id))
        leftovers.removeAll { gone.contains($0.id) && !FileManager.default.fileExists(atPath: $0.url.path) }
        message = failed > 0 ? "\(failed) 件を移動できませんでした。" : nil
        TrashNotice.post(TrashOutcome(moved: deletable.count - failed, failed: failed,
                                      bytes: deletable.reduce(0) { $0 + $1.size }))
    }
}

@MainActor @Observable
final class LoginItemsModel {
    var items: [LoginItem] = []
    var scanning = false
    var hasScanned = false
    var lastScannedAt: Date? = nil
    var message: String? = nil
    var diff: SnapshotDiff? = nil

    func scan() async {
        guard !scanning else { return }
        scanning = true; message = nil
        let r = await LoginItems.fullScan()
        items = r.items; diff = r.diff
        hasScanned = true; lastScannedAt = Date(); scanning = false
        if let d = r.diff, !d.new.isEmpty { notify(newLabels: d.new) }
    }

    func disable(_ item: LoginItem) async {
        do {
            try await LoginItems.disable(item)
            items.removeAll { $0.id == item.id }
            TrashNotice.post(text: "ログイン項目「\(item.label)」を無効化し、設定ファイルをゴミ箱へ移動しました。")
        } catch { message = "\(error)" }
    }

    private func notify(newLabels: [String]) { notifyNewLoginItems(newLabels) }
}


/// 新しいログイン項目の通知（権限は初回に要求）
@MainActor private func notifyNewLoginItems(_ labels: [String]) {
    let c = UNUserNotificationCenter.current()
    c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = "MacCare: 新しいログイン項目"
        content.body = labels.prefix(3).joined(separator: ", ") + (labels.count > 3 ? " ほか \(labels.count) 件" : "")
        c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
