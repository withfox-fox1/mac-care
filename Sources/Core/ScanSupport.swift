import Foundation

// MARK: - ファイル一覧

struct ScanFile: Equatable, Sendable {
    var path: String
    var size: Int64
    var mtime: Int64      // ナノ秒
    var inode: UInt64
}

/// スキャン対象の一覧（YARA は全ファイル、ClamAV は対象フォルダ分＋上限以下）
struct ScanInventory: Sendable {
    var yara: [ScanFile] = []
    var clam: [ScanFile] = []
    /// ClamAV が扱えない大きさ（2 GiB 以上）のファイル。YARA のみで検査する
    var clamOverLimit: [ScanFile] = []
    /// iCloud 未ダウンロードなどで中身が手元にないファイル（読むとダウンロードが走るため対象外）
    var dataless = 0
    /// 改行を含む名前で一覧に載せられないファイル
    var unlistable = 0
}

enum ScanFileList {
    /// ClamAV が扱える最大サイズ（libclamav の上限 2 GiB - 1）
    static let clamMaxBytes: Int64 = 2_147_483_647
    private static let sfDataless: UInt32 = 0x4000_0000

    private static func stat(_ path: String) -> (ScanFile, dataless: Bool)? {
        var st = Darwin.stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let m = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        return (ScanFile(path: path, size: Int64(st.st_size), mtime: m, inode: UInt64(st.st_ino)),
                (st.st_flags & sfDataless) != 0)
    }

    /// 1 つの対象（フォルダまたはファイル）を列挙する。シンボリックリンクは辿らない。
    static func enumerate(_ target: URL, isCancelled: () -> Bool = { false }) -> (files: [ScanFile], dataless: Int, unlistable: Int) {
        var files: [ScanFile] = [], dataless = 0, unlistable = 0
        func add(_ path: String) {
            guard let (f, dl) = stat(path) else { return }
            if dl { dataless += 1; return }
            if path.contains("\n") { unlistable += 1; return }
            files.append(f)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else { return ([], 0, 0) }
        if !isDir.boolValue { add(target.path); return (files, dataless, unlistable) }
        guard let e = FileManager.default.enumerator(at: target, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }) else {
            return ([], 0, 0)
        }
        var n = 0
        for case let u as URL in e {
            n += 1
            if n % 2000 == 0, isCancelled() { break }
            add(u.path)
        }
        return (files, dataless, unlistable)
    }

    static func build(yaraTargets: [URL], clamTargets: [URL], clamMax: Int64 = clamMaxBytes,
                      isCancelled: () -> Bool = { false }) -> ScanInventory {
        var inv = ScanInventory()
        var seen = Set<String>()
        var perTarget: [String: [ScanFile]] = [:]
        for t in yaraTargets {
            let r = enumerate(t, isCancelled: isCancelled)
            inv.dataless += r.dataless; inv.unlistable += r.unlistable
            perTarget[t.path] = r.files
            for f in r.files where seen.insert(f.path).inserted { inv.yara.append(f) }
        }
        var seenClam = Set<String>()
        for t in clamTargets {
            for f in perTarget[t.path] ?? enumerate(t, isCancelled: isCancelled).files where seenClam.insert(f.path).inserted {
                if f.size > clamMax { inv.clamOverLimit.append(f) } else { inv.clam.append(f) }
            }
        }
        return inv
    }

    /// 1 回の yara 実行に渡す塊（進捗を細かく出すため分割する）
    static func chunks(_ files: [ScanFile], maxBytes: Int64 = 1_500_000_000, maxCount: Int = 4000) -> [[ScanFile]] {
        var out: [[ScanFile]] = [], cur: [ScanFile] = [], bytes: Int64 = 0
        for f in files {
            if !cur.isEmpty, bytes + f.size > maxBytes || cur.count >= maxCount { out.append(cur); cur = []; bytes = 0 }
            cur.append(f); bytes += f.size
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

// MARK: - 差分キャッシュ

/// 「問題なし」と判定したファイルの記録（サイズ・更新時刻・inode が同じなら未変更とみなす）
struct CacheEntry: Codable, Equatable {
    var size: Int64, mtime: Int64, inode: UInt64
    var scannedAt: Int64   // 検査した時刻（epoch 秒）

    init(file: ScanFile, at: Date) { size = file.size; mtime = file.mtime; inode = file.inode; scannedAt = Int64(at.timeIntervalSince1970) }
    func matches(_ f: ScanFile) -> Bool { size == f.size && mtime == f.mtime && inode == f.inode }

    // ファイルが大きくなりすぎないよう配列で保存する
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        size = try c.decode(Int64.self); mtime = try c.decode(Int64.self)
        inode = try c.decode(UInt64.self); scannedAt = try c.decode(Int64.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(size); try c.encode(mtime); try c.encode(inode); try c.encode(scannedAt)
    }
}

struct ScanPlan {
    var toScan: [ScanFile] = []
    var hits = 0
    var hitBytes: Int64 = 0
    var oldestHit: Date? = nil
    var quick = false
    var total: Int { toScan.count + hits }
    var hitRate: Double { total == 0 ? 0 : Double(hits) / Double(total) }
}

struct ScanCacheStore: Codable, Equatable {
    var clam: [String: CacheEntry] = [:]
    var yara: [String: CacheEntry] = [:]
    /// 全ファイル・全エンジンのフルスキャンが最後に完了した時刻
    var lastFullAt: Date? = nil
    var lastFullClamDefs: String? = nil
    var lastFullYaraDefs: String? = nil

    static var url: URL { Storage.baseDir.appendingPathComponent("scancache.json") }
    static func load() -> ScanCacheStore {
        guard let d = try? Data(contentsOf: url) else { return ScanCacheStore() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(ScanCacheStore.self, from: d)) ?? ScanCacheStore()
    }
    func save() {
        try? Storage.ensureDir()
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        if let d = try? e.encode(self) { try? d.write(to: ScanCacheStore.url, options: .atomic) }
    }
}

enum ScanCache {
    /// クイック: キャッシュと一致しないファイル（新規・変更分）だけ検査する。フル: すべて検査する。
    static func plan(files: [ScanFile], cache: [String: CacheEntry], quick: Bool) -> ScanPlan {
        var p = ScanPlan(quick: quick)
        guard quick else { p.toScan = files; return p }
        var oldest: Int64? = nil
        for f in files {
            if let e = cache[f.path], e.matches(f) {
                p.hits += 1; p.hitBytes += f.size
                oldest = min(oldest ?? e.scannedAt, e.scannedAt)
            } else { p.toScan.append(f) }
        }
        p.oldestHit = oldest.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return p
    }

    /// 今回問題なしだったファイルを記録し、未変更で引き続き有効なエントリは維持する。消えたファイルは落とす。
    static func merge(files: [ScanFile], previous: [String: CacheEntry], quick: Bool,
                      clean: Set<String>, now: Date) -> [String: CacheEntry] {
        var out: [String: CacheEntry] = [:]
        for f in files {
            if clean.contains(f.path) { out[f.path] = CacheEntry(file: f, at: now) }
            else if quick, let e = previous[f.path], e.matches(f) { out[f.path] = e }
        }
        return out
    }
}

// MARK: - 出力の解析

enum ClamLine: Equatable {
    case ok(String)
    case found(path: String, signature: String)
    case error(path: String, message: String)
    case other

    /// `--no-summary` の 1 行。パスに ": " が含まれていても末尾側の区切りで分割する。
    static func parse(_ line: String) -> ClamLine {
        if line.hasSuffix(": OK") { return .ok(String(line.dropLast(4))) }
        if line.hasSuffix(" FOUND") {
            let body = line.dropLast(6)
            guard let r = body.range(of: ": ", options: .backwards) else { return .other }
            return .found(path: String(body[..<r.lowerBound]), signature: String(body[r.upperBound...]))
        }
        if line.hasSuffix(" ERROR") {
            let body = line.dropLast(6)
            guard let r = body.range(of: ": ", options: .backwards) else { return .other }
            return .error(path: String(body[..<r.lowerBound]), message: String(body[r.upperBound...]))
        }
        return .other
    }
}

enum YaraErrors {
    /// "error scanning PATH: could not open file" などの標準エラーから、検査できなかったパスを集める
    static func unreadable(_ stderr: String) -> Set<String> {
        var out = Set<String>()
        let prefix = "error scanning "
        for line in stderr.split(separator: "\n") where line.hasPrefix(prefix) {
            let body = line.dropFirst(prefix.count)
            if let r = body.range(of: ": ", options: .backwards) { out.insert(String(body[..<r.lowerBound])) }
        }
        return out
    }
}

// MARK: - 進捗・残り時間

/// スレッド間で共有するバイト数カウンタ（読み取り側は UI のタイマー）
final class ByteProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _total: Int64 = 0, _done: Int64 = 0, _finished = false
    func reset(total: Int64) { lock.lock(); _total = total; _done = 0; _finished = false; lock.unlock() }
    func add(_ n: Int64) { lock.lock(); _done += n; lock.unlock() }
    func finish() { lock.lock(); _finished = true; lock.unlock() }
    var snapshot: (total: Int64, done: Int64, finished: Bool) { lock.lock(); defer { lock.unlock() }; return (_total, _done, _finished) }
    var fraction: Double {
        let s = snapshot
        if s.finished || s.total <= 0 { return s.finished ? 1 : 0 }
        return min(1, Double(s.done) / Double(s.total))
    }
}

enum ProgressMath {
    /// 重み付き平均（重みの合計が 0 なら 0）
    static func weighted(_ items: [(weight: Double, fraction: Double)]) -> Double {
        let w = items.reduce(0) { $0 + max(0, $1.weight) }
        guard w > 0 else { return 0 }
        return min(1, max(0, items.reduce(0) { $0 + max(0, $1.weight) * min(1, max(0, $1.fraction)) } / w))
    }
}

/// 残り時間の推定: 経過 / 進捗 から求め、指数移動平均でならす
struct ProgressMeter {
    var startedAt: Date
    var warmup: TimeInterval = 5
    var minFraction = 0.02
    var alpha = 0.3
    private(set) var smoothed: Double? = nil

    init(startedAt: Date = Date()) { self.startedAt = startedAt }

    /// 残り秒数。開始直後（warmup 未満）や進捗がほぼ 0 のときは nil（「計算中…」）
    mutating func update(fraction: Double, now: Date) -> TimeInterval? {
        let elapsed = now.timeIntervalSince(startedAt)
        if fraction >= 1 { smoothed = 0; return 0 }
        guard elapsed >= warmup, fraction >= minFraction else { return nil }
        let raw = elapsed * (1 - fraction) / fraction
        smoothed = smoothed.map { $0 * (1 - alpha) + raw * alpha } ?? raw
        return smoothed
    }
}

enum ETAFormat {
    /// 「残り 約3分」「残り 40秒」。nil は「計算中…」
    static func text(_ remaining: TimeInterval?) -> String {
        guard let r = remaining else { return "残り時間を計算中…" }
        if r < 5 { return "まもなく完了" }
        if r < 60 { return "残り \(Int((r / 5).rounded()) * 5)秒" }
        let m = Int((r / 60).rounded())
        if m < 60 { return "残り 約\(m)分" }
        return "残り 約\(m / 60)時間\(m % 60 == 0 ? "" : "\(m % 60)分")"
    }
    static func percent(_ f: Double) -> String { "\(Int((min(1, max(0, f)) * 100).rounded()))%" }
}

/// 前回実行時の各ステップの所要時間（進捗の重み。初回は既定値）
enum StepDurations {
    static let defaults: [String: Double] = ["cleanup": 20, "security": 120, "loginItems": 3, "largeFiles": 60]
    static var url: URL { Storage.baseDir.appendingPathComponent("step-durations.json") }
    static func load() -> [String: Double] {
        guard let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([String: Double].self, from: d) else { return defaults }
        return defaults.merging(m.filter { $0.value > 0 }) { _, new in new }
    }
    static func save(_ m: [String: Double]) {
        try? Storage.ensureDir()
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: url, options: .atomic) }
    }
}

/// フルスキャンの前回時刻の表示（「前回のフルスキャン: 今日 0:03」）
enum FullScanLabel {
    static func text(_ last: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let last else { return "前回のフルスキャン: 未実施" }
        return "前回のフルスキャン: " + ShortDate.format(last, now: now, calendar: calendar)
    }
}
