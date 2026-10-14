import Foundation
import AppKit
import Observation
@preconcurrency import UserNotifications

struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    var size: Int64
    let lastUsed: Date?
    let isAppStore: Bool
    var id: String { url.path }
    var isApple: Bool { bundleID.lowercased().hasPrefix("com.apple.") }
}

struct RelatedFile: Identifiable, Hashable {
    enum Kind { case bundleID, nameOnly }
    let url: URL
    let size: Int64
    let kind: Kind
    /// /Library 配下（管理者権限が必要なため表示のみ）
    let isSystem: Bool
    var id: String { url.path }
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

    static func info(for url: URL, withSize: Bool = true) -> InstalledApp? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: plist) as? [String: Any],
              let bid = d["CFBundleIdentifier"] as? String else { return nil }
        let name = (d["CFBundleDisplayName"] as? String) ?? (d["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let ver = (d["CFBundleShortVersionString"] as? String) ?? (d["CFBundleVersion"] as? String) ?? ""
        let mas = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt").path)
        return InstalledApp(url: url, name: name, bundleID: bid, version: ver,
                            size: withSize ? CleanupScanner.size(of: url).bytes : 0,
                            lastUsed: LargeFileScanner.lastUsed(url), isAppStore: mas)
    }

    static func scan(dirs: [URL] = defaultDirs()) -> [InstalledApp] {
        let urls = appURLs(in: dirs)
        var result = [InstalledApp?](repeating: nil, count: urls.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            let a = info(for: urls[i])
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

    static func find(bundleID: String, appName: String, library: URL, systemLibrary: URL? = nil) -> [RelatedFile] {
        let fm = FileManager.default
        var out: [RelatedFile] = []
        func scanDir(_ root: URL, _ subs: [String], system: Bool) {
            for sub in subs {
                let dir = root.appendingPathComponent(sub)
                for c in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                    let n = c.lastPathComponent
                    let kind: RelatedFile.Kind?
                    if matchesBundleID(n, bundleID) { kind = .bundleID }
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

    static func find(library: URL, installedIDs: Set<String>, runningIDs: Set<String>) -> [RelatedFile] {
        let fm = FileManager.default
        let known = installedIDs.union(runningIDs).map { $0.lowercased() }
        // 同じ提供元（先頭2要素）のアプリが入っている場合は拡張機能等の可能性があるため除外（誤検出より見逃しを優先）
        func vendor(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".") }
        let vendors = Set(known.map(vendor))
        var out: [RelatedFile] = []
        for sub in ["Application Support", "Containers", "Caches", "Preferences"] {
            let dir = library.appendingPathComponent(sub)
            for c in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                var n = c.lastPathComponent
                if sub == "Preferences" { guard n.hasSuffix(".plist") else { continue }; n = String(n.dropLast(6)) }
                let l = n.lowercased()
                guard looksLikeBundleID(n), !l.contains("com.apple.") else { continue }
                // インストール済み・実行中アプリのIDと一致、または前方一致の関係なら残骸ではない
                if vendors.contains(vendor(l)) { continue }
                if known.contains(where: { l == $0 || l.hasPrefix($0 + ".") || $0.hasPrefix(l + ".") }) { continue }
                out.append(RelatedFile(url: c, size: CleanupScanner.size(of: c).bytes, kind: .bundleID, isSystem: false))
            }
        }
        return out.sorted { $0.size > $1.size }
    }
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
    /// 戻り値: (成功数, 失敗した関連ファイルのパス)
    static func uninstall(app: InstalledApp, related: [RelatedFile], isRunning: Bool,
                          library: URL = AppCatalog.home.appendingPathComponent("Library"),
                          appRoots: [URL] = AppCatalog.defaultDirs()) throws -> (trashed: Int, failed: [String]) {
        if app.isApple { throw UninstallError.appleApp }
        if isRunning { throw UninstallError.running }
        do { try SafeTrash.trash(app.url, allowedRoots: appRoots) }
        catch { throw UninstallError.appTrashFailed("\(error)") }
        var ok = 1
        var failed: [String] = []
        var bytes = app.size
        for r in related where !r.isSystem {
            do { try SafeTrash.trash(r.url, allowedRoots: [library]); ok += 1; bytes += r.size }
            catch { failed.append(r.url.path) }
        }
        try? History.append(HistoryEntry(date: Date(), kind: .uninstall, target: app.url.path, bytes: bytes,
                                         result: failed.isEmpty ? "ok" : "partial",
                                         detail: "\(app.bundleID)、関連 \(ok - 1) 件、失敗 \(failed.count) 件"))
        return (ok, failed)
    }
}

@MainActor @Observable
final class AppsModel {
    var apps: [InstalledApp] = []
    var leftovers: [RelatedFile] = []
    var related: [RelatedFile] = []
    var selectedRelated: Set<String> = []
    var scanning = false
    var hasScanned = false
    var message: String? = nil
    var runningIDs: Set<String> = []

    func scan() async {
        guard !scanning else { return }
        scanning = true; message = nil
        runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        let running = runningIDs
        let (a, l) = await Task.detached(priority: .userInitiated) { () -> ([InstalledApp], [RelatedFile]) in
            let apps = AppCatalog.scan()
            let left = Leftovers.find(library: AppCatalog.home.appendingPathComponent("Library"),
                                      installedIDs: Set(apps.map(\.bundleID)), runningIDs: running)
            return (apps, left)
        }.value
        apps = a; leftovers = l; hasScanned = true; scanning = false
    }

    func isRunning(_ app: InstalledApp) -> Bool { runningIDs.contains(app.bundleID.lowercased()) }

    func loadRelated(for app: InstalledApp) async {
        related = []; selectedRelated = []
        let r = await Task.detached { () -> [RelatedFile] in
            RelatedFinder.find(bundleID: app.bundleID, appName: app.url.deletingPathExtension().lastPathComponent,
                               library: AppCatalog.home.appendingPathComponent("Library"),
                               systemLibrary: URL(fileURLWithPath: "/Library"))
        }.value
        related = r
        selectedRelated = Set(r.filter { $0.kind == .bundleID && !$0.isSystem }.map(\.id))
    }

    func uninstall(_ app: InstalledApp) async {
        let sel = related.filter { selectedRelated.contains($0.id) }
        let running = isRunning(app)
        do {
            let r = try await Task.detached { try AppUninstaller.uninstall(app: app, related: sel, isRunning: running) }.value
            message = r.failed.isEmpty ? "「\(app.name)」と関連ファイル \(r.trashed - 1) 件をゴミ箱へ移動しました。"
                : "「\(app.name)」を移動しました。関連ファイル \(r.failed.count) 件は移動できませんでした。"
            apps.removeAll { $0.id == app.id }
            related = []
        } catch { message = "\(error)" }
    }

    func trashLeftovers(_ items: [RelatedFile]) async {
        let lib = AppCatalog.home.appendingPathComponent("Library")
        let failed = await Task.detached { () -> Int in
            var f = 0
            for i in items { do { try SafeTrash.trash(i.url, allowedRoots: [lib]) } catch { f += 1 } }
            return f
        }.value
        try? History.append(HistoryEntry(date: Date(), kind: .uninstall, target: "残骸 \(items.count) 件",
                                         bytes: items.reduce(0) { $0 + $1.size }, result: failed == 0 ? "ok" : "partial", detail: ""))
        let gone = Set(items.map(\.id))
        leftovers.removeAll { gone.contains($0.id) && !FileManager.default.fileExists(atPath: $0.url.path) }
        message = failed > 0 ? "\(failed) 件を移動できませんでした。" : nil
    }
}

@MainActor @Observable
final class LoginItemsModel {
    var items: [LoginItem] = []
    var scanning = false
    var hasScanned = false
    var message: String? = nil
    var diff: SnapshotDiff? = nil

    func scan() async {
        guard !scanning else { return }
        scanning = true; message = nil
        let r = await LoginItems.fullScan()
        items = r.items; diff = r.diff
        hasScanned = true; scanning = false
        if let d = r.diff, !d.new.isEmpty { notify(newLabels: d.new) }
    }

    func disable(_ item: LoginItem) async {
        do {
            try await LoginItems.disable(item)
            items.removeAll { $0.id == item.id }
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
