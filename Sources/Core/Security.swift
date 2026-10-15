import Foundation
import CryptoKit
import Observation

enum ScanEngine: String, Codable { case yara = "YARA", clamav = "ClamAV" }

struct Detection: Identifiable, Hashable {
    let engine: ScanEngine
    let signature: String
    let path: String
    var id: String { engine.rawValue + "|" + signature + "|" + path }
}

enum SecurityError: Error, CustomStringConvertible {
    case compileFailed(String)
    case engineFailed(String)
    var description: String {
        switch self {
        case .compileFailed(let m): return "YARA ルールのコンパイルに失敗: \(m)"
        case .engineFailed(let m): return m
        }
    }
}

enum FileHash {
    static func sha256(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 無視リスト: パス＋ハッシュが一致する間だけ非表示。ハッシュが変われば再び表示。
enum IgnoreList {
    static func isIgnored(path: String, hash: String?, list: [IgnoredDetection]) -> Bool {
        guard let hash else { return false }
        return list.contains { $0.path == path && $0.sha256 == hash }
    }
    static func filter(_ ds: [Detection], list: [IgnoredDetection],
                       hashOf: (String) -> String? = FileHash.sha256) -> (visible: [Detection], hidden: Int) {
        var visible: [Detection] = []
        for d in ds {
            if isIgnored(path: d.path, hash: hashOf(d.path), list: list) { continue }
            visible.append(d)
        }
        return (visible, ds.count - visible.count)
    }
    static func add(path: String, to list: inout [IgnoredDetection]) {
        guard let h = FileHash.sha256(path) else { return }
        list.removeAll { $0.path == path }
        list.append(IgnoredDetection(path: path, sha256: h))
    }
}

struct SystemSecurityStatus {
    var xprotectVersion: String?
    var xprotectUpdated: Date?
    var gatekeeper: String
    var sip: String
}

enum XProtect {
    static let bundle = URL(fileURLWithPath: "/Library/Apple/System/Library/CoreServices/XProtect.bundle")
    static var infoPlist: URL { bundle.appendingPathComponent("Contents/Info.plist") }
    static var yaraRules: URL { bundle.appendingPathComponent("Contents/Resources/XProtect.yara") }

    static func version() -> String? {
        (NSDictionary(contentsOf: infoPlist)?["CFBundleShortVersionString"]) as? String
    }
    static func updated() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: infoPlist.path))?[.modificationDate] as? Date
    }

    static func status() async -> SystemSecurityStatus {
        let gk = (try? await Shell.run("/usr/sbin/spctl", ["--status"]))?.stdout ?? ""
        let sip = (try? await Shell.run("/usr/bin/csrutil", ["status"]))?.stdout ?? ""
        return SystemSecurityStatus(
            xprotectVersion: version(), xprotectUpdated: updated(),
            gatekeeper: gk.contains("enabled") ? "有効" : (gk.isEmpty ? "不明" : "無効"),
            sip: sip.contains("enabled") ? "有効" : (sip.isEmpty ? "不明" : "無効"))
    }
}

enum YaraEngine {
    static var compiledURL: URL { Storage.baseDir.appendingPathComponent("xprotect.yarc") }

    /// 再コンパイルが必要なら実行する（バージョンが変わった場合）。実行したら true。
    @discardableResult
    static func ensureCompiled(rules: URL, version: String, yarac: String,
                               out: URL = compiledURL) async throws -> Bool {
        let vfile = out.appendingPathExtension("version")
        if FileManager.default.fileExists(atPath: out.path),
           (try? String(contentsOf: vfile, encoding: .utf8)) == version { return false }
        try Storage.ensureDir()
        let tmp = out.appendingPathExtension("tmp")
        let r = try await Shell.run(yarac, [rules.path, tmp.path])   // yarac は出力を上書きする
        guard r.exitCode == 0 else { throw SecurityError.compileFailed(r.stderr) }
        if FileManager.default.fileExists(atPath: out.path) {
            _ = try FileManager.default.replaceItemAt(out, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: out)
        }
        try version.write(to: vfile, atomically: true, encoding: .utf8)
        return true
    }

    /// 出力 "RULE PATH" の解析（パスに空白を含み得るので最初の空白で分割）
    static func parse(_ output: String) -> [Detection] {
        output.components(separatedBy: "\n").compactMap { (line: String) -> Detection? in
            guard let sp = line.firstIndex(of: " ") else { return nil }
            let path = String(line[line.index(after: sp)...])
            guard path.hasPrefix("/") else { return nil }
            return Detection(engine: .yara, signature: String(line[..<sp]), path: path)
        }
    }

    static func scan(compiled: URL, target: URL, yara: String) async throws -> [Detection] {
        // 注意: -p（マルチスレッド）は ~/Documents のスキャンで無期限にハングしたため使用しない
        let r = try await Shell.run(yara, ["-C", "-r", "-f", "-w", "--skip-larger=209715200",
                                           compiled.path, target.path])
        // 読み取り不可のファイルなどで 0 以外になることがある。出力があれば採用する。
        if r.exitCode != 0 && r.stdout.isEmpty && !r.stderr.isEmpty && !r.stderr.contains("could not open file") {
            throw SecurityError.engineFailed("yara: \(r.stderr.split(separator: "\n").first ?? "")")
        }
        return parse(r.stdout)
    }
}

enum ClamEngine {
    static func parse(_ output: String) -> [Detection] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasSuffix(" FOUND") else { return nil }
            let body = line.dropLast(6)
            guard let r = body.range(of: ": ", options: .backwards) else { return nil }
            return Detection(engine: .clamav, signature: String(body[r.upperBound...]),
                             path: String(body[..<r.lowerBound]))
        }
    }

    /// 終了コード 0=クリーン, 1=検出, その他=エラー
    static func scan(targets: [URL], clamscan: String, onLine: (@Sendable (String) -> Void)? = nil) async throws -> [Detection] {
        let r = try await Shell.run(clamscan, ["-r", "-i", "--no-summary"] + targets.map(\.path), onLine: onLine)
        switch r.exitCode {
        case 0, 1: return parse(r.stdout)
        default: throw SecurityError.engineFailed("clamscan がエラー終了 (\(r.exitCode)): \(r.stderr.split(separator: "\n").first ?? "")")
        }
    }

    /// freshclam の設定ファイル（Homebrew prefix 配下）
    static func freshclamConf(freshclam: String) -> URL {
        URL(fileURLWithPath: freshclam).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("etc/clamav/freshclam.conf")
    }
}

struct ScanReport {
    var date = Date()
    var duration: TimeInterval = 0
    var yaraHits = 0
    var clamHits = 0
    var hidden = 0
    var targetCount = 0
    var warnings: [String] = []
    var ranYara = false
    var ranClam = false
    var deep = false
    var yaraSeconds: TimeInterval = 0
    var clamSeconds: TimeInterval = 0
    var summary: String {
        "YARA \(ranYara ? "\(yaraHits)" : "未実行") / ClamAV \(ranClam ? "\(clamHits)" : "未実行") 件"
    }
}

enum ScanStep: String { case idle = "待機中", definitions = "定義を更新中", yara = "YARA スキャン中", clam = "ClamAV スキャン中" }

enum SecurityScanner {
    /// 検索対象。設定の対象＋LaunchAgents/Daemons が参照する実行ファイル。
    /// YARA は全対象、ClamAV は deepScan でなければ /Applications を除く（参照先の実行ファイルは個別に含める）。
    static func buildTargets(settings: Settings, loginItems: [LoginItem]) -> (yara: [URL], clam: [URL]) {
        let fm = FileManager.default
        let dirs = settings.scanTargets.map { URL(fileURLWithPath: $0) }.filter { fm.fileExists(atPath: $0.path) }
        let programs = loginItems.compactMap(\.program).map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { fm.fileExists(atPath: $0.path) }
        func assemble(_ ds: [URL]) -> [URL] {
            var urls = ds
            for u in programs where !ds.contains(where: { SafeTrash.isInside(u, of: $0, strict: false) }) && !urls.contains(u) {
                urls.append(u)
            }
            return urls
        }
        let apps = URL(fileURLWithPath: "/Applications")
        let clamDirs = settings.deepScan ? dirs : dirs.filter { !SafeTrash.isInside($0, of: apps, strict: false) }
        return (assemble(dirs), assemble(clamDirs))
    }
}

@MainActor @Observable
final class SecurityModel {
    var status: SystemSecurityStatus? = nil
    var step: ScanStep = .idle
    var running = false
    var detections: [Detection] = []
    var lastReport: ScanReport? = nil
    var message: String? = nil
    var hasScanned = false
    private var task: Task<Void, Never>?

    func refreshStatus() async { status = await XProtect.status() }

    /// スキャン完了まで待つ（スマートケア用）
    func scan(state: AppState) async {
        start(state: state)
        await task?.value
    }

    func start(state: AppState) {
        guard !running else { return }
        running = true; message = nil
        task = Task { [weak self] in
            await self?.run(state: state)
            self?.running = false; self?.step = .idle
        }
    }
    func cancel() { task?.cancel() }

    private func run(state: AppState) async {
        let settings = Settings.load()
        let t0 = Date()
        var report = ScanReport()
        await refreshStatus()
        var found: [Detection] = []
        do {
            let items = LoginItems.scan()
            let targets = SecurityScanner.buildTargets(settings: settings, loginItems: items)
            report.targetCount = targets.yara.count
            report.deep = settings.deepScan

            // 1) ClamAV 定義更新
            if let fresh = Tools.path("freshclam") {
                step = .definitions
                if FileManager.default.fileExists(atPath: ClamEngine.freshclamConf(freshclam: fresh).path) {
                    let r = try await Shell.run(fresh, [])
                    if r.exitCode != 0 { report.warnings.append("定義の更新に失敗しました（既存の定義でスキャンします）: \(r.stderr.split(separator: "\n").last ?? "")") }
                } else {
                    report.warnings.append("freshclam.conf がありません（\(ClamEngine.freshclamConf(freshclam: fresh).path)）。install.sh で設定してください。")
                }
            }
            // 2) YARA
            if let yara = Tools.path("yara"), let yarac = Tools.path("yarac"),
               FileManager.default.fileExists(atPath: XProtect.yaraRules.path) {
                step = .yara
                let ver = XProtect.version() ?? "\(XProtect.updated()?.timeIntervalSince1970 ?? 0)"
                do {
                    try await YaraEngine.ensureCompiled(rules: XProtect.yaraRules, version: ver, yarac: yarac)
                    let ty = Date()
                    var hits: [Detection] = []
                    for t in targets.yara { hits += try await YaraEngine.scan(compiled: YaraEngine.compiledURL, target: t, yara: yara) }
                    report.yaraHits = hits.count; report.ranYara = true
                    report.yaraSeconds = Date().timeIntervalSince(ty)
                    found += hits
                } catch is CancellationError { throw CancellationError() }
                catch { report.warnings.append("\(error)") }
            } else {
                report.warnings.append("YARA を実行できません（yara/yarac 未インストール、または XProtect.yara がありません）。")
            }
            // 3) ClamAV
            if let clam = Tools.path("clamscan") {
                step = .clam
                do {
                    let tc = Date()
                    let hits = try await ClamEngine.scan(targets: targets.clam, clamscan: clam)
                    report.clamHits = hits.count; report.ranClam = true
                    report.clamSeconds = Date().timeIntervalSince(tc)
                    found += hits
                } catch is CancellationError { throw CancellationError() }
                catch { report.warnings.append("\(error)") }
            } else {
                report.warnings.append("ClamAV を実行できません（clamscan 未インストール）。\(Tools.installHint)")
            }
        } catch {
            message = "スキャンを中止しました。"
            return
        }
        let filtered = IgnoreList.filter(found, list: settings.ignoredDetections)
        detections = filtered.visible
        report.hidden = filtered.hidden
        report.duration = Date().timeIntervalSince(t0)
        lastReport = report; hasScanned = true
        let total = filtered.visible.count
        state.lastScanSummary = "セキュリティ: \(total == 0 ? "脅威なし" : "脅威 \(total) 件")（\(report.date.formatted(date: .abbreviated, time: .shortened))）"
        try? History.append(HistoryEntry(date: Date(), kind: .scan, target: "セキュリティスキャン（\(report.targetCount) 対象）",
                                         bytes: 0, result: total == 0 ? "clean" : "found",
                                         detail: "\(report.summary)、\(report.deep ? "じっくり" : "標準")モード、無視 \(report.hidden) 件、\(Int(report.duration)) 秒"))
    }

    /// アプリバンドル内のファイルか（含まれる .app を返す）
    nonisolated static func enclosingApp(of path: String) -> URL? {
        var u = URL(fileURLWithPath: path).deletingLastPathComponent()
        while u.pathComponents.count > 1 {
            if u.pathExtension.lowercased() == "app" { return u }
            u = u.deletingLastPathComponent()
        }
        return nil
    }

    /// 確認済みのスナップショットの検出1件をゴミ箱へ。アプリ内部のファイルは単独では削除しない。
    func trash(_ d: Detection) {
        if SecurityModel.enclosingApp(of: d.path) != nil {
            message = "アプリ内部のファイルは単独で削除できません。アプリ単位で削除してください（アプリケーション画面または Finder）。"
            return
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        do {
            try SafeTrash.trash(URL(fileURLWithPath: d.path), allowedRoots: [home, URL(fileURLWithPath: "/Applications")])
            detections.removeAll { $0.path == d.path }
        } catch { message = "\(error)" }
    }

    func ignore(_ d: Detection) {
        var s = Settings.load()
        IgnoreList.add(path: d.path, to: &s.ignoredDetections)
        try? s.save()
        detections.removeAll { $0.path == d.path }
        try? History.append(HistoryEntry(date: Date(), kind: .scan, target: d.path, bytes: 0,
                                         result: "ignored", detail: "\(d.engine.rawValue): \(d.signature)"))
    }
}
