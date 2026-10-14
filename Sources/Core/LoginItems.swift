import Foundation
import CryptoKit

enum LoginDomain: String, Codable { case user, system }

enum ItemChange: String { case unchanged, new, changed }

struct LoginItem: Identifiable, Hashable {
    let label: String
    let plistURL: URL
    let program: String?
    let runAtLoad: Bool
    let keepAlive: Bool
    let domain: LoginDomain
    let plistSHA256: String
    var signer: String = ""
    var change: ItemChange = .unchanged
    var id: String { plistURL.path }
}

struct SnapshotItem: Codable, Equatable {
    var label: String
    var program: String
    var sha256: String
}

struct SnapshotDiff: Equatable {
    var new: [String]       // label
    var changed: [String]
    var removed: [String]
}

enum LoginItems {
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }
    static func directories() -> [(URL, LoginDomain)] {
        [(home.appendingPathComponent("Library/LaunchAgents"), .user),
         (URL(fileURLWithPath: "/Library/LaunchAgents"), .system),
         (URL(fileURLWithPath: "/Library/LaunchDaemons"), .system)]
    }

    /// plist から実行ファイルのパスを取り出す（Program 優先、無ければ ProgramArguments[0]）
    static func programPath(of dict: [String: Any]) -> String? {
        if let p = dict["Program"] as? String, !p.isEmpty { return p }
        if let a = dict["ProgramArguments"] as? [String], let f = a.first, !f.isEmpty { return f }
        return nil
    }

    static func parse(plist url: URL, domain: LoginDomain) -> LoginItem? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let d = obj as? [String: Any] else { return nil }
        let keep: Bool
        if let b = d["KeepAlive"] as? Bool { keep = b } else if let kd = d["KeepAlive"] as? [String: Any] { keep = !kd.isEmpty } else { keep = false }
        return LoginItem(label: d["Label"] as? String ?? url.deletingPathExtension().lastPathComponent,
                         plistURL: url, program: programPath(of: d),
                         runAtLoad: d["RunAtLoad"] as? Bool ?? false, keepAlive: keep, domain: domain,
                         plistSHA256: FileHash.sha256(url.path) ?? "")
    }

    static func scan(dirs: [(URL, LoginDomain)] = directories()) -> [LoginItem] {
        var out: [LoginItem] = []
        for (dir, dom) in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "plist" {
                if let i = parse(plist: f, domain: dom) { out.append(i) }
            }
        }
        return out.sorted { $0.label.lowercased() < $1.label.lowercased() }
    }

    /// 署名者。codesign -dv の出力から Authority（最初の行）と TeamIdentifier を取る。
    static func signer(of program: String?) async -> String {
        guard let program else { return "実行ファイルなし" }
        guard FileManager.default.fileExists(atPath: program) else { return "実行ファイルなし" }
        guard let r = try? await Shell.run("/usr/bin/codesign", ["-dv", "--verbose=2", program]),
              r.exitCode == 0 else { return "未署名" }
        return parseSigner(r.stderr)
    }

    static func parseSigner(_ text: String) -> String {
        var authority: String? = nil, team: String? = nil
        for l in text.split(separator: "\n") {
            if authority == nil, l.hasPrefix("Authority=") { authority = String(l.dropFirst(10)) }
            if l.hasPrefix("TeamIdentifier="), !l.hasSuffix("not set") { team = String(l.dropFirst(15)) }
        }
        if let a = authority {
            // Authority に既にチームIDが含まれていれば重複表示しない
            if let t = team, !a.contains(t) { return "\(a) [\(t)]" }
            return a
        }
        return text.contains("Signature=adhoc") ? "アドホック署名" : "署名情報なし"
    }

    static func snapshot(of items: [LoginItem]) -> [SnapshotItem] {
        items.map { SnapshotItem(label: $0.label, program: $0.program ?? "", sha256: $0.plistSHA256) }
    }

    /// 前回との差分。label 単位で比較し、program か plist のハッシュが違えば「変更」。
    static func diff(previous: [SnapshotItem], current: [SnapshotItem]) -> SnapshotDiff {
        let prev = Dictionary(previous.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        let cur = Dictionary(current.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        let new = cur.keys.filter { prev[$0] == nil }.sorted()
        let changed = cur.keys.filter { prev[$0] != nil && prev[$0] != cur[$0] }.sorted()
        let removed = prev.keys.filter { cur[$0] == nil }.sorted()
        return SnapshotDiff(new: new, changed: changed, removed: removed)
    }

    static var snapshotURL: URL { Storage.baseDir.appendingPathComponent("loginitems-snapshot.json") }

    static func loadSnapshot() -> [SnapshotItem]? {
        guard let d = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode([SnapshotItem].self, from: d)
    }
    static func saveSnapshot(_ s: [SnapshotItem]) {
        try? Storage.ensureDir()
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: snapshotURL, options: .atomic) }
    }

    /// 完全なスキャン: 一覧取得 → 署名者 → 前回との差分 → スナップショット保存
    static func fullScan(dirs: [(URL, LoginDomain)] = directories(), save: Bool = true) async -> (items: [LoginItem], diff: SnapshotDiff?, removed: [String]) {
        var items = scan(dirs: dirs)
        await withTaskGroup(of: (Int, String).self) { g in
            for (i, it) in items.enumerated() { g.addTask { (i, await signer(of: it.program)) } }
            for await (i, s) in g { items[i].signer = s }
        }
        var diffResult: SnapshotDiff? = nil
        if let prev = loadSnapshot() {
            let d = diff(previous: prev, current: snapshot(of: items))
            diffResult = d
            for i in items.indices {
                if d.new.contains(items[i].label) { items[i].change = .new }
                else if d.changed.contains(items[i].label) { items[i].change = .changed }
            }
        }
        if save { saveSnapshot(snapshot(of: items)) }
        return (items, diffResult, diffResult?.removed ?? [])
    }

    /// ユーザー領域の項目を無効化: launchctl bootout（未ロードのエラーは無視）→ plist をゴミ箱へ
    static func disable(_ item: LoginItem) async throws {
        guard item.domain == .user else { throw SafeTrashError.denied(item.plistURL.path) }
        _ = try? await Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", item.plistURL.path])
        try SafeTrash.trash(item.plistURL, allowedRoots: [home.appendingPathComponent("Library/LaunchAgents")])
        try? History.append(HistoryEntry(date: Date(), kind: .loginItem, target: item.plistURL.path, bytes: 0,
                                         result: "ok", detail: "無効化: \(item.label)"))
    }
}
