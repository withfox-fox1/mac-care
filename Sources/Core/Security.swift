import Foundation
import CryptoKit
import Observation

enum ScanEngine: String, Codable { case yara = "YARA", clamav = "ClamAV" }

struct Detection: Identifiable, Hashable, Codable {
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

    /// 保護機能の判定結果（出力文字列 → 有効 / 無効 / 確認不可）
    enum Protection: Equatable {
        case enabled, disabled, unknown
        var label: String {
            switch self {
            case .enabled: return "有効"
            case .disabled: return "無効"
            case .unknown: return "確認できませんでした"
            }
        }
    }

    /// `spctl --status` の出力（"assessments enabled" / "assessments disabled"）
    static func parseGatekeeper(_ output: String) -> Protection {
        let t = output.lowercased()
        if t.contains("assessments enabled") { return .enabled }
        if t.contains("assessments disabled") { return .disabled }
        return .unknown
    }

    /// `csrutil status` の出力（"System Integrity Protection status: enabled." など）
    static func parseSIP(_ output: String) -> Protection {
        let t = output.lowercased()
        guard let r = t.range(of: "system integrity protection status:") else { return .unknown }
        let rest = t[r.upperBound...]
        let first = rest.prefix { $0 != "\n" }
        if first.contains("disabled") { return .disabled }
        if first.contains("enabled") { return .enabled }
        return .unknown
    }

    /// コマンドを実行して標準出力＋標準エラーを返す。失敗（キャンセル以外）は 1 回だけ再試行する。
    /// キャンセルされた場合は nil（前回値を保つために呼び出し側で扱う）。
    private static func output(_ exe: String, _ args: [String]) async -> String? {
        for attempt in 0..<2 {
            do {
                let r = try await Shell.run(exe, args)
                let text = r.stdout + "\n" + r.stderr
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attempt == 1 { return text }
            } catch is CancellationError {
                return nil
            } catch {
                if attempt == 1 { return "" }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return ""
    }

    /// 取得できなかった項目は nil。呼び出し側が直前の値を保持する。
    static func status(previous: SystemSecurityStatus? = nil) async -> SystemSecurityStatus? {
        // 並行実行を避け、順番に取得する
        let gkOut = await output("/usr/sbin/spctl", ["--status"])
        let sipOut = await output("/usr/bin/csrutil", ["status"])
        if gkOut == nil || sipOut == nil { return previous }   // スキャンのキャンセル等。表示を「確認不可」に落とさない
        return SystemSecurityStatus(
            xprotectVersion: version(), xprotectUpdated: updated(),
            gatekeeper: parseGatekeeper(gkOut ?? "").label,
            sip: parseSIP(sipOut ?? "").label)
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

    /// 失敗とみなす条件: 出力がなく、読み取り不可以外のエラーがある
    static func isFailure(_ r: ShellResult) -> Bool {
        r.exitCode != 0 && r.stdout.isEmpty && !r.stderr.isEmpty && !r.stderr.contains("could not open file")
    }

    static func scan(compiled: URL, target: URL, yara: String) async throws -> [Detection] {
        // 注意: -p（マルチスレッド）は ~/Documents のスキャンで無期限にハングしたため使用しない
        // サイズ上限は設けない（大きなファイルも検査する）
        let r = try await Shell.run(yara, ["-C", "-r", "-f", "-w", compiled.path, target.path])
        // 読み取り不可のファイルなどで 0 以外になることがある。出力があれば採用する。
        if isFailure(r) {
            throw SecurityError.engineFailed("yara: \(r.stderr.split(separator: "\n").first ?? "")")
        }
        return parse(r.stdout)
    }

    /// ファイル一覧を渡して検査する。戻り値: 検出と、読み取れなかったパス
    static func scan(compiled: URL, files: [ScanFile], yara: String) async throws -> (hits: [Detection], unreadable: Set<String>) {
        try Storage.ensureDir()
        let list = Storage.baseDir.appendingPathComponent("yara-list-\(UUID().uuidString).txt")
        try files.map(\.path).joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }
        let r = try await Shell.run(yara, ["-C", "-f", "-w", "--scan-list", compiled.path, list.path])
        if isFailure(r) { throw SecurityError.engineFailed("yara: \(r.stderr.split(separator: "\n").first ?? "")") }
        return (parse(r.stdout), YaraErrors.unreadable(r.stderr))
    }
}

enum ClamEngine {
    /// libclamav が扱える最大サイズまで引き上げる（既定の 100MB/400MB を超えるファイルが
    /// 「スキップして問題なし扱い」にならないようにする）
    static let limitArgs = ["--max-filesize=2147483647", "--max-scansize=2147483647", "--pcre-max-filesize=2147483647"]

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
        let r = try await Shell.run(clamscan, ["-r", "-i", "--no-summary"] + limitArgs + targets.map(\.path), onLine: onLine)
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

    /// `sigtool --info` の "Version: N"
    static func parseSigtoolVersion(_ output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("Version:") {
            let v = line.dropFirst("Version:".count).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        return nil
    }

    /// ウイルス定義(daily)のバージョン
    static func definitionsVersion(freshclam: String?) async -> String? {
        guard let freshclam, let sigtool = Tools.locate("sigtool") else { return nil }
        let prefix = URL(fileURLWithPath: freshclam).deletingLastPathComponent().deletingLastPathComponent()
        let db = prefix.appendingPathComponent("var/lib/clamav")
        for name in ["daily.cld", "daily.cvd"] {
            let p = db.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: p) else { continue }
            if let r = try? await Shell.run(sigtool, ["--info", p]), let v = parseSigtoolVersion(r.stdout) { return v }
        }
        return nil
    }

    /// ファイル一覧を渡して検査する（--file-list）。1 ファイルごとに結果行が出るので進捗に使える。
    static func scan(files: [ScanFile], clamscan: String, progress: ByteProgress) async throws -> ClamOutcome {
        try Storage.ensureDir()
        let list = Storage.baseDir.appendingPathComponent("clam-list-\(UUID().uuidString).txt")
        try files.map(\.path).joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }
        let col = ClamCollector(sizes: Dictionary(files.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a }), progress: progress)
        let r = try await Shell.run(clamscan, ["--file-list=\(list.path)", "--no-summary"] + limitArgs, onLine: { col.handle($0) })
        let o = col.outcome
        switch r.exitCode {
        case 0, 1: break
        default:
            // 一部のファイルが読めなくてもエラー終了になる。結果行が 1 件でもあれば採用する。
            if o.clean.isEmpty && o.hits.isEmpty {
                throw SecurityError.engineFailed("clamscan がエラー終了 (\(r.exitCode)): \(r.stderr.split(separator: "\n").first ?? "")")
            }
        }
        return o
    }
}

struct ClamOutcome {
    var clean = Set<String>()
    var hits: [Detection] = []
    var errors = 0
}

/// clamscan の出力行を集計する（バックグラウンドスレッドから呼ばれる）
final class ClamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var o = ClamOutcome()
    private let sizes: [String: Int64]
    private let progress: ByteProgress
    init(sizes: [String: Int64], progress: ByteProgress) { self.sizes = sizes; self.progress = progress }

    func handle(_ line: String) {
        let parsed = ClamLine.parse(line)
        var path: String?
        lock.lock()
        switch parsed {
        case .ok(let p): o.clean.insert(p); path = p
        case .found(let p, let sig): o.hits.append(Detection(engine: .clamav, signature: sig, path: p)); path = p
        case .error(let p, _): o.errors += 1; path = p
        case .other: break
        }
        lock.unlock()
        if let path, let s = sizes[path] { progress.add(s) }
    }
    var outcome: ClamOutcome { lock.lock(); defer { lock.unlock() }; return o }
}

struct ScanReport: Codable {
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
    var freshclamSeconds: TimeInterval = 0
    /// クイック（変更分のみ）で実行したか
    var quick = false
    var yaraTotal = 0, yaraCached = 0
    var clamTotal = 0, clamCached = 0
    /// キャッシュで省略したファイルのうち最も古い検査時刻
    var oldestCached: Date? = nil
    /// ClamAV の上限(2GiB)超で YARA のみで検査したファイル数
    var clamOverLimit = 0
    /// iCloud 未ダウンロードなどで検査できなかった件数
    var dataless = 0
    /// 読み取れず検査できなかった件数
    var unreadable = 0
    var unlistable = 0
    var lastFullAt: Date? = nil
    var summary: String {
        "YARA \(ranYara ? "\(yaraHits)" : "未実行") / ClamAV \(ranClam ? "\(clamHits)" : "未実行") 件"
    }
    var yaraScanned: Int { yaraTotal - yaraCached }
    var clamScanned: Int { clamTotal - clamCached }
    /// キャッシュ命中率（両エンジン合計）
    var hitRate: Double {
        let t = yaraTotal + clamTotal
        return t == 0 ? 0 : Double(yaraCached + clamCached) / Double(t)
    }
}

/// 前回のスキャン結果（再起動後も表示するための保存形式）
struct StoredScan: Codable {
    var report: ScanReport
    var detections: [Detection]
}

enum ScanReportStore {
    static var fileURL: URL { Storage.baseDir.appendingPathComponent("last-security-scan.json") }
    static func save(_ v: StoredScan, to url: URL = fileURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        if let d = try? e.encode(v) { try? d.write(to: url, options: .atomic) }
    }
    static func load(from url: URL = fileURL) -> StoredScan? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(StoredScan.self, from: d)
    }
}

enum ScanStep: String { case idle = "待機中", definitions = "定義を更新中", listing = "検査対象を列挙中", scanning = "スキャン中" }

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


/// 実行中のキャンセルを列挙などの同期処理へ伝える
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
    func reset() { lock.lock(); v = false; lock.unlock() }
}

/// 1 エンジンの実行結果
struct EngineOutcome {
    var hits: [Detection] = []
    var clean = Set<String>()
    var ran = false
    var seconds: TimeInterval = 0
    var unreadable = 0
    var warnings: [String] = []
}

@MainActor @Observable
final class SecurityModel {
    var status: SystemSecurityStatus? = nil
    var step: ScanStep = .idle
    var running = false
    var detections: [Detection] = []
    var lastReport: ScanReport? = nil

    init() {
        if let st = ScanReportStore.load() { lastReport = st.report; detections = st.detections }
    }
    var message: String? = nil
    var hasScanned = false
    /// 実行中の全体進捗（0...1）・残り時間・エンジン別の内訳
    var fraction: Double = 0
    var etaText: String = ""
    var detail: String = ""
    /// 実行中の方式（クイック/フル）
    var runningFull = false
    /// 実行開始時点の所要時間の見積り（バイト数 ÷ 前回の処理速度。両エンジンは並行なので長い方）
    var estimatedSeconds: Double? = nil
    /// 前回のフルスキャン完了時刻（キャッシュ記録から）
    var lastFullAt: Date? = ScanCacheStore.load().lastFullAt
    @ObservationIgnored private var task: Task<Void, Never>?
    private let cancelFlag = CancelFlag()
    private let clamP = ByteProgress(), yaraP = ByteProgress()
    @ObservationIgnored private var useClam = false
    @ObservationIgnored private var useYara = false
    @ObservationIgnored private var meter = ProgressMeter()
    @ObservationIgnored private var bps: [String: Double] = [:]

    func refreshStatus() async { if let st = await XProtect.status(previous: status) { status = st } }

    /// スキャン完了まで待つ（スマートケア用）。full=nil なら設定（クイック/フル）に従う
    func scan(state: AppState, full: Bool? = nil) async {
        start(state: state, full: full)
        await task?.value
    }

    func start(state: AppState, full: Bool? = nil) {
        guard !running else { return }
        running = true; message = nil
        fraction = 0; etaText = ""; detail = ""; estimatedSeconds = nil
        let wantFull = full ?? !Settings.load().quickScan
        runningFull = wantFull
        task = Task { [weak self] in
            await self?.run(state: state, full: wantFull)
            self?.running = false; self?.step = .idle
        }
    }
    func cancel() { cancelFlag.set(); task?.cancel() }

    /// タイマーから呼ぶ。進捗と残り時間を更新する
    private func tick(now: Date = Date()) {
        guard step == .scanning else { return }
        let bc = max(bps["clamBPS"] ?? 60e6, 1e6), by = max(bps["yaraBPS"] ?? 150e6, 1e6)
        let c = clamP.snapshot, y = yaraP.snapshot
        var items: [(Double, Double)] = []
        var parts: [String] = []
        if useYara { items.append((Double(y.total) / by, yaraP.fraction)); parts.append("YARA \(ETAFormat.percent(yaraP.fraction))") }
        if useClam { items.append((Double(c.total) / bc, clamP.fraction)); parts.append("ClamAV \(ETAFormat.percent(clamP.fraction))") }
        let totalW = items.reduce(0) { $0 + $1.0 }
        if estimatedSeconds == nil { estimatedSeconds = items.map(\.0).max() ?? 0 }
        let f = totalW <= 0 ? ((useYara ? y.finished : true) && (useClam ? c.finished : true) ? 1 : 0)
            : ProgressMath.weighted(items.map { (weight: $0.0, fraction: $0.1) })
        fraction = f
        detail = parts.joined(separator: "・")
        etaText = ETAFormat.text(meter.update(fraction: f, now: now))
    }

    private func run(state: AppState, full: Bool) async {
        let settings = Settings.load()
        let t0 = Date()
        var report = ScanReport()
        report.quick = !full
        bps = StepDurations.load()
        // フルスキャン中はスリープさせない（AC 接続時に有効。バッテリー駆動では保証されない）
        let sleepGuard = full ? SleepGuard(reason: "MacCare フルスキャン") : nil
        defer { sleepGuard?.release() }
        cancelFlag.reset()
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { ticker.cancel() }
        await refreshStatus()
        var found: [Detection] = []
        do {
            let items = LoginItems.scan()
            let targets = SecurityScanner.buildTargets(settings: settings, loginItems: items)
            report.targetCount = targets.yara.count
            report.deep = settings.deepScan

            // 1) ClamAV 定義更新
            let freshclam = Tools.path("freshclam")
            if let fresh = freshclam {
                step = .definitions
                if FileManager.default.fileExists(atPath: ClamEngine.freshclamConf(freshclam: fresh).path) {
                    let tf = Date()
                    let r = try await Shell.run(fresh, [])
                    report.freshclamSeconds = Date().timeIntervalSince(tf)
                    if r.exitCode != 0 { report.warnings.append("定義の更新に失敗しました（既存の定義でスキャンします）: \(r.stderr.split(separator: "\n").last ?? "")") }
                } else {
                    report.warnings.append("freshclam.conf がありません（\(ClamEngine.freshclamConf(freshclam: fresh).path)）。install.sh で設定してください。")
                }
            }

            // 2) 使えるエンジンの確認
            var yaraPath: String? = nil
            if let yara = Tools.path("yara"), let yarac = Tools.path("yarac"),
               FileManager.default.fileExists(atPath: XProtect.yaraRules.path) {
                let ver = XProtect.version() ?? "\(XProtect.updated()?.timeIntervalSince1970 ?? 0)"
                do {
                    try await YaraEngine.ensureCompiled(rules: XProtect.yaraRules, version: ver, yarac: yarac)
                    yaraPath = yara
                } catch is CancellationError { throw CancellationError() }
                catch { report.warnings.append("\(error)") }
            } else {
                report.warnings.append("YARA を実行できません（yara/yarac 未インストール、または XProtect.yara がありません）。")
            }
            let clamPath = Tools.path("clamscan")
            if clamPath == nil { report.warnings.append("ClamAV を実行できません（clamscan 未インストール）。\(Tools.installHint)") }
            useYara = yaraPath != nil; useClam = clamPath != nil

            // 3) 検査対象の列挙（1 回だけ。両エンジンで共有）
            step = .listing
            let flag = cancelFlag
            let inv = await Task.detached(priority: .userInitiated) {
                ScanFileList.build(yaraTargets: targets.yara, clamTargets: targets.clam, isCancelled: { flag.isSet })
            }.value
            try Task.checkCancellation()
            report.clamOverLimit = inv.clamOverLimit.count
            report.dataless = inv.dataless; report.unlistable = inv.unlistable

            // 4) 差分キャッシュ（クイック時のみ参照）
            var store = ScanCacheStore.load()
            let yPlan = ScanCache.plan(files: inv.yara, cache: store.yara, quick: !full)
            let cPlan = ScanCache.plan(files: inv.clam, cache: store.clam, quick: !full)
            report.yaraTotal = useYara ? yPlan.total : 0; report.yaraCached = useYara ? yPlan.hits : 0
            report.clamTotal = useClam ? cPlan.total : 0; report.clamCached = useClam ? cPlan.hits : 0
            report.oldestCached = [useYara ? yPlan.oldestHit : nil, useClam ? cPlan.oldestHit : nil].compactMap { $0 }.min()
            yaraP.reset(total: yPlan.toScan.reduce(0) { $0 + $1.size })
            clamP.reset(total: cPlan.toScan.reduce(0) { $0 + $1.size })
            meter = ProgressMeter(startedAt: Date())
            step = .scanning

            // 5) YARA と ClamAV を同時に実行
            let compiled = YaraEngine.compiledURL
            let yFiles = yPlan.toScan, cFiles = cPlan.toScan
            let yP = yaraP, cP = clamP
            let yp = yaraPath, cp = clamPath
            async let yRes = Self.runYara(files: yFiles, yara: yp, compiled: compiled, progress: yP)
            async let cRes = Self.runClam(files: cFiles, clam: cp, progress: cP)
            let (yo, co) = try await (yRes, cRes)

            report.ranYara = yo.ran; report.yaraHits = yo.hits.count; report.yaraSeconds = yo.seconds
            report.ranClam = co.ran; report.clamHits = co.hits.count; report.clamSeconds = co.seconds
            report.unreadable = yo.unreadable + co.unreadable
            report.warnings += yo.warnings + co.warnings
            found = yo.hits + co.hits

            // 6) キャッシュ更新（完了した場合のみ）
            let now = Date()
            if yo.ran { store.yara = ScanCache.merge(files: inv.yara, previous: store.yara, quick: !full, clean: yo.clean, now: now) }
            if co.ran { store.clam = ScanCache.merge(files: inv.clam, previous: store.clam, quick: !full, clean: co.clean, now: now) }
            if full, (useYara || useClam), (!useYara || yo.ran), (!useClam || co.ran) {
                store.lastFullAt = now
                store.lastFullClamDefs = await ClamEngine.definitionsVersion(freshclam: freshclam)
                store.lastFullYaraDefs = XProtect.version()
                report.lastFullAt = now
            }
            store.save()
            lastFullAt = store.lastFullAt
            // 次回の進捗見積り用に処理速度を保存
            var upd: [String: Double] = [:]
            let cb = Double(cFiles.reduce(0) { $0 + $1.size }), yb = Double(yFiles.reduce(0) { $0 + $1.size })
            if co.seconds > 3, cb > 100e6 { upd["clamBPS"] = cb / co.seconds }
            if yo.seconds > 3, yb > 100e6 { upd["yaraBPS"] = yb / yo.seconds }
            if !upd.isEmpty { StepDurations.save(StepDurations.load().merging(upd) { _, n in n }) }
        } catch {
            message = "スキャンを中止しました。"
            return
        }
        report.lastFullAt = report.lastFullAt ?? lastFullAt
        fraction = 1; etaText = ""
        let filtered = IgnoreList.filter(found, list: settings.ignoredDetections)
        detections = filtered.visible
        report.hidden = filtered.hidden
        report.duration = Date().timeIntervalSince(t0)
        lastReport = report; hasScanned = true
        ScanReportStore.save(StoredScan(report: report, detections: filtered.visible))
        let total = filtered.visible.count
        state.lastScanSummary = "セキュリティ: \(total == 0 ? "脅威なし" : "脅威 \(total) 件")（\(report.date.formatted(date: .abbreviated, time: .shortened))）"
        let cache = report.quick ? "クイック（キャッシュ命中 \(Int((report.hitRate * 100).rounded()))%・\(report.yaraCached + report.clamCached) 件省略）" : "フル"
        try? History.append(HistoryEntry(date: Date(), kind: .scan, target: "セキュリティスキャン（\(report.targetCount) 対象）",
                                         bytes: 0, result: total == 0 ? "clean" : "found",
                                         detail: "\(report.summary)、\(report.deep ? "じっくり" : "標準")モード・\(cache)、無視 \(report.hidden) 件、ClamAV上限超 \(report.clamOverLimit) 件、読取不可 \(report.unreadable) 件、\(Int(report.duration)) 秒（定義更新 \(Int(report.freshclamSeconds)) 秒・YARA \(Int(report.yaraSeconds)) 秒・ClamAV \(Int(report.clamSeconds)) 秒、負荷 \(String(format: "%.1f", Power.loadAverage()))）"))
    }

    nonisolated static func runYara(files: [ScanFile], yara: String?, compiled: URL, progress: ByteProgress) async throws -> EngineOutcome {
        var o = EngineOutcome()
        guard let yara else { progress.finish(); return o }
        let t = Date()
        var failed = false
        for chunk in ScanFileList.chunks(files) {
            try Task.checkCancellation()
            do {
                let r = try await YaraEngine.scan(compiled: compiled, files: chunk, yara: yara)
                let hitPaths = Set(r.hits.map(\.path))
                o.hits += r.hits
                o.unreadable += r.unreadable.count
                for f in chunk where !hitPaths.contains(f.path) && !r.unreadable.contains(f.path) { o.clean.insert(f.path) }
            } catch is CancellationError { throw CancellationError() }
            catch { o.warnings.append("\(error)"); failed = true; break }
            progress.add(chunk.reduce(0) { $0 + $1.size })
        }
        o.ran = !failed
        o.seconds = Date().timeIntervalSince(t)
        progress.finish()
        return o
    }

    nonisolated static func runClam(files: [ScanFile], clam: String?, progress: ByteProgress) async throws -> EngineOutcome {
        var o = EngineOutcome()
        guard let clam else { progress.finish(); return o }
        let t = Date()
        if !files.isEmpty {
            do {
                let r = try await ClamEngine.scan(files: files, clamscan: clam, progress: progress)
                o.hits = r.hits; o.clean = r.clean; o.unreadable = r.errors
                o.ran = true
            } catch is CancellationError { throw CancellationError() }
            catch { o.warnings.append("\(error)") }
        } else { o.ran = true }
        o.seconds = Date().timeIntervalSince(t)
        progress.finish()
        return o
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
            persistDetections()
            TrashNotice.post(TrashOutcome(moved: 1, failed: 0, bytes: 0))
        } catch { message = "\(error)" }
    }

    func ignore(_ d: Detection) {
        var s = Settings.load()
        IgnoreList.add(path: d.path, to: &s.ignoredDetections)
        try? s.save()
        detections.removeAll { $0.path == d.path }
        persistDetections()
        try? History.append(HistoryEntry(date: Date(), kind: .scan, target: d.path, bytes: 0,
                                         result: "ignored", detail: "\(d.engine.rawValue): \(d.signature)"))
    }

    private func persistDetections() {
        if let r = lastReport { ScanReportStore.save(StoredScan(report: r, detections: detections)) }
    }
}
