import Foundation

enum SafeTrashError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case outsideAllowedRoots(String)
    case isAllowedRoot(String)
    case symlinkEscapes(String)
    case denied(String)
    case trashFailed(String)

    var description: String {
        switch self {
        case .notFound(let p): return "存在しません: \(p)"
        case .outsideAllowedRoots(let p): return "許可範囲外のため拒否: \(p)"
        case .isAllowedRoot(let p): return "許可ルート自体は削除できません: \(p)"
        case .symlinkEscapes(let p): return "シンボリックリンクの実体が許可範囲外: \(p)"
        case .denied(let p): return "保護対象のため拒否: \(p)"
        case .trashFailed(let m): return "ゴミ箱への移動に失敗: \(m)"
        }
    }
}

/// アプリ内のすべての削除はここを通す。removeItem は使わない。
enum SafeTrash {
    private static var home: String { NSHomeDirectory() }

    /// ちょうどその場所だけ拒否
    private static func denyExact() -> [String] {
        ["/", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private",
         home, home + "/Library"]
    }
    /// その配下すべてと、それを含む祖先を拒否
    private static func denyTrees() -> [String] {
        [home + "/Library/Application Support/Claude/vm_bundles", home + "/voicevox_engine"]
    }

    private static func comps(_ url: URL) -> [String] { url.pathComponents }

    /// コンポーネント単位の包含判定（strict: 同一パスは含めない）
    static func isInside(_ child: URL, of root: URL, strict: Bool = true) -> Bool {
        let c = comps(child), r = comps(root)
        guard c.count >= r.count, Array(c.prefix(r.count)) == r else { return false }
        return strict ? c.count > r.count : true
    }

    private static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isDenied(_ url: URL) -> Bool {
        let u = resolved(url)
        for p in denyExact() where comps(resolved(URL(fileURLWithPath: p))) == comps(u) { return true }
        for p in denyTrees() {
            let t = resolved(URL(fileURLWithPath: p))
            if isInside(u, of: t, strict: false) || isInside(t, of: u) { return true }
        }
        return false
    }

    static func trash(_ url: URL, allowedRoots: [URL]) throws {
        // 末端がリンクの場合に備え、親ディレクトリだけ解決してリンク自体を対象にする
        let std = url.standardizedFileURL
        let candidate = resolved(std.deletingLastPathComponent()).appendingPathComponent(std.lastPathComponent)
        let target = resolved(candidate)   // リンクの実体

        let roots = allowedRoots.map { resolved($0) }
        if roots.contains(where: { comps($0) == comps(candidate) || comps($0) == comps(target) }) {
            throw SafeTrashError.isAllowedRoot(url.path)
        }
        guard roots.contains(where: { isInside(candidate, of: $0) }) else {
            throw SafeTrashError.outsideAllowedRoots(url.path)
        }
        guard roots.contains(where: { isInside(target, of: $0) }) else {
            throw SafeTrashError.symlinkEscapes(url.path)
        }
        if isDenied(candidate) || isDenied(target) { throw SafeTrashError.denied(url.path) }

        guard FileManager.default.fileExists(atPath: candidate.path)
                || (try? candidate.checkResourceIsReachable()) == true
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil
        else { throw SafeTrashError.notFound(url.path) }
        let size = byteSize(candidate)
        do {
            try FileManager.default.trashItem(at: candidate, resultingItemURL: nil)
        } catch {
            try? History.append(HistoryEntry(date: Date(), kind: .trash, target: candidate.path,
                                             bytes: size, result: "failed", detail: error.localizedDescription))
            throw SafeTrashError.trashFailed(error.localizedDescription)
        }
        try? History.append(HistoryEntry(date: Date(), kind: .trash, target: candidate.path,
                                         bytes: size, result: "ok", detail: ""))
    }

    /// 履歴用の概算サイズ（リンクは辿らない）
    static func byteSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isDirectory != true || v.isSymbolicLink == true { return Int64(v.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let f as URL in en {
                total += Int64((try? f.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
