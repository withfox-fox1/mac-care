import Foundation

// 履歴（history.jsonl）の表示用ロジック。保存形式は変更しない。
//
// 記録の実態（History.append の呼び出し元の調査結果）:
// - SafeTrash.trash は 1 項目ごとに kind=trash を記録する（失敗時は result=failed）。
//   呼び出し元: クリーンアップ、動画圧縮（元ファイル）、アンインストール（アプリ＋関連）、残骸削除、
//   ログイン項目の無効化（plist）、大容量ファイル、セキュリティの検出ファイル隔離。
// - 呼び出し側は、その後に「要約」を 1 件記録する（cleanup「N 件」、uninstall、compress、loginItem）。
//   要約は項目ごとの trash より後ろ（同じ秒、またはその直後）に記録される。
// - スマートケアはセキュリティスキャンを内部で実行するため、「セキュリティスキャン（N 対象）」が
//   スマートケアの直前（0〜3 秒前）に記録される。定期実行ではさらに「定期フルスキャン」（通知結果）が続く。

// MARK: - 結果

enum HistoryOutcome: Equatable {
    case success, failure, partial, threat, info
}

enum HistoryResult {
    /// 保存値（英語）を表示用の日本語にする。未知の値はそのまま返す。
    static func label(_ raw: String) -> String {
        switch raw {
        case "ok": return "成功"
        case "failed": return "失敗"
        case "partial": return "一部失敗"
        case "clean": return "脅威なし"
        case "found": return "脅威を検出"
        case "notified": return "通知済み"
        case "no-notification-permission": return "通知なし（権限未許可）"
        case "ignored": return "無視"
        default: return raw
        }
    }

    static func outcome(_ raw: String) -> HistoryOutcome {
        switch raw {
        case "ok", "clean", "notified": return .success
        case "failed": return .failure
        case "partial": return .partial
        case "found": return .threat
        default: return .info
        }
    }
}

// MARK: - 絞り込み

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, cleanup, compress, scan, delete
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "すべて"
        case .cleanup: "掃除"
        case .compress: "圧縮"
        case .scan: "スキャン"
        case .delete: "削除"
        }
    }
    /// 掃除=クリーンアップ・ゴミ箱、削除=アプリのアンインストール・ログイン項目の無効化
    func matches(_ kind: HistoryKind) -> Bool {
        switch self {
        case .all: true
        case .cleanup: kind == .cleanup || kind == .trash
        case .compress: kind == .compress
        case .scan: kind == .scan
        case .delete: kind == .uninstall || kind == .loginItem
        }
    }
}

// MARK: - 表示用モデル

/// 展開時に表示する内訳 1 件
struct HistoryChild: Equatable {
    var name: String          // パスまたは記録名
    var bytes: Int64?         // nil: サイズを表示しない
    var resultLabel: String
    var outcome: HistoryOutcome
    var detail: String
}

struct HistoryRow: Identifiable, Equatable {
    var id: String            // 入力配列内の代表エントリの位置（履歴は追記専用のため安定）
    var date: Date
    var kind: HistoryKind
    var title: String
    var subtitle: String?
    var result: String        // 保存値
    var resultLabel: String
    var outcome: HistoryOutcome
    /// 右側に出す解放容量（スキャンは nil）。圧縮は削減量。
    var freedBytes: Int64?
    /// 累計・今月の集計に含めるか（ゴミ箱を空にする操作は、先にゴミ箱へ移した分と重複するため除外）
    var countsTowardTotal: Bool
    var countsAsScan: Bool
    var isEmptyTrash: Bool
    /// スキャンの概要（右側に容量の代わりに表示）
    var overview: String?
    var detail: String
    var seconds: Int?
    var outputPath: String?
    var sourcePath: String?
    var children: [HistoryChild]
    var childrenAreItems: Bool   // true: 項目一覧（パス・サイズ・結果）、false: 関連記録
    var itemCount: Int           // まとめた項目数
}

struct HistorySection: Identifiable, Equatable {
    var id: Date              // その日の 0 時
    var title: String
    var rows: [HistoryRow]
}

struct HistoryStats: Equatable {
    var totalFreed: Int64
    var monthFreed: Int64
    var scanCount: Int
    var failureCount: Int
}

// MARK: - 整形

enum HistoryFormat {
    private static let weekdays = ["日", "月", "火", "水", "木", "金", "土"]

    /// 「今日」「昨日」「10月14日（火）」（年が違えば「2025年10月14日（火）」）
    static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "今日" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "昨日" }
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
        let wd = weekdays[max(0, min(6, (c.weekday ?? 1) - 1))]
        let md = "\(c.month ?? 0)月\(c.day ?? 0)日（\(wd)）"
        if c.year != calendar.component(.year, from: now) { return "\(c.year ?? 0)年\(md)" }
        return md
    }

    static func time(_ d: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func dateTime(_ d: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return String(format: "%d/%d/%d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// 解放容量の表示。減った分は「−2.0 GB」、増えた場合（圧縮後が大きい）は「+…」。0 は nil。
    static func freed(_ bytes: Int64?) -> String? {
        guard let b = bytes, b != 0 else { return nil }
        return b > 0 ? "−\(formatBytes(b))" : "+\(formatBytes(-b))"
    }
}

// MARK: - グループ化・集計

enum HistoryGrouping {
    /// 同じ操作の連続した trash を 1 つの束と見なす間隔（秒）。
    /// 実データでは 1 回のクリーンアップ（最大 46 項目）が同一秒内に記録され、時刻は秒単位で切り捨てられる。
    /// 一方、別操作の trash 同士の最短間隔は 165 秒だった。秒の切り上がり・ディスク負荷による遅れを見込み 5 秒とする。
    static let clusterGap: TimeInterval = 5
    /// スマートケアが内部で実行したセキュリティスキャンを同じ操作と見なす間隔（秒）。実データでは 0〜3 秒。
    static let securityGap: TimeInterval = 10
    /// 定期スキャンの通知記録を直前のスマートケアに結びつける最大間隔（秒）。通知の許可待ちで遅れることがある（実データ最大 136 秒）。
    static let notificationGap: TimeInterval = 300
    /// 圧縮・ログイン項目の「元ファイルのゴミ箱移動」を結びつける最大間隔（秒）
    static let pairGap: TimeInterval = 60

    /// entries は History.readAll() の順（古い順・同時刻は記録順）。返り値は新しい順。
    static func rows(from entries: [HistoryEntry]) -> [HistoryRow] {
        // 日時で安定ソート（同時刻は記録順を保つ）
        let e = entries.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
        var claimed = Set<Int>()
        var childrenOf: [Int: [Int]] = [:]   // 要約の位置 → 取り込んだ位置（昇順）

        func norm(_ p: String) -> String {
            var s = (p as NSString).standardizingPath.precomposedStringWithCanonicalMapping
            if s.hasPrefix("/private/") { s.removeFirst(8) }
            return s
        }
        func gap(_ later: Int, _ earlier: Int) -> TimeInterval { e[later].date.timeIntervalSince(e[earlier].date) }

        // 1. 圧縮・ログイン項目: 同じパスの trash を取り込む
        for i in e.indices where e[i].kind == .compress || e[i].kind == .loginItem {
            let t = norm(e[i].target)
            var k = i - 1
            while k >= 0, gap(i, k) <= pairGap {
                if e[k].kind == .trash, !claimed.contains(k), norm(e[k].target) == t {
                    claimed.insert(k); childrenOf[i, default: []].append(k); break
                }
                k -= 1
            }
        }

        // 2. クリーンアップ「N 件」・アンインストール: 直前の連続した trash を件数の範囲で取り込む
        for i in e.indices {
            let cap: Int?
            switch e[i].kind {
            case .cleanup: cap = leadingCount(e[i].target)
            case .uninstall:
                if let n = leadingCount(e[i].target, prefix: "残骸 ") { cap = n }
                else if let rel = intAfter("関連", in: e[i].detail) { cap = 1 + rel + (intAfter("失敗", in: e[i].detail) ?? 0) }
                else { cap = 1 }
            default: cap = nil
            }
            guard let cap, cap > 0 else { continue }
            var taken: [Int] = []
            var last = i
            var k = i - 1
            while k >= 0, taken.count < cap, gap(last, k) <= clusterGap {
                if e[k].kind == .trash, !claimed.contains(k) { taken.append(k); claimed.insert(k); last = k }
                k -= 1
            }
            if !taken.isEmpty { childrenOf[i] = taken.reversed() }
        }

        // 3. 要約のない trash: 間隔が近いものを 1 束にする
        var clusters: [[Int]] = []
        var cur: [Int] = []
        for i in e.indices where e[i].kind == .trash && !claimed.contains(i) {
            if let l = cur.last, gap(i, l) > clusterGap { clusters.append(cur); cur = [] }
            cur.append(i)
        }
        if !cur.isEmpty { clusters.append(cur) }

        // 4. スキャン: スマートケア直前のセキュリティスキャン、定期実行の通知記録
        func isSmartCare(_ x: HistoryEntry) -> Bool { x.kind == .scan && x.target.hasPrefix("スマートケア") }
        func isSecurityScan(_ x: HistoryEntry) -> Bool { x.kind == .scan && x.target.hasPrefix("セキュリティスキャン（") }
        func isNotification(_ x: HistoryEntry) -> Bool { x.kind == .scan && (x.target == "定期フルスキャン" || x.target == "定期スキャン") }
        var related: [Int: [Int]] = [:]
        for i in e.indices where isSmartCare(e[i]) {
            var k = i - 1
            while k >= 0, gap(i, k) <= securityGap {
                if isSecurityScan(e[k]), !claimed.contains(k) { claimed.insert(k); related[i, default: []].append(k); break }
                k -= 1
            }
        }
        for i in e.indices where isNotification(e[i]) {
            var k = i - 1
            while k >= 0, gap(i, k) <= notificationGap {
                if isSmartCare(e[k]), e[k].target.contains("定期"), !(related[k]?.contains { isNotification(e[$0]) } ?? false) {
                    claimed.insert(i); related[k, default: []].append(i); break
                }
                k -= 1
            }
        }

        // 行の生成
        var out: [(idx: Int, row: HistoryRow)] = []
        for i in e.indices where !claimed.contains(i) {
            if e[i].kind == .trash { continue }   // 束ねるものは下で処理
            let kids = (childrenOf[i] ?? []).map { e[$0] }
            out.append((i, makeRow(id: i, e[i], items: kids, related: (related[i] ?? []).map { e[$0] })))
        }
        for c in clusters {
            out.append((c.last!, trashClusterRow(id: c.last!, c.map { e[$0] })))
        }
        out.sort { ($0.row.date, $0.idx) > ($1.row.date, $1.idx) }
        return out.map(\.row)
    }

    static func stats(_ rows: [HistoryRow], now: Date, calendar: Calendar) -> HistoryStats {
        var total: Int64 = 0, month: Int64 = 0, scans = 0, fails = 0
        for r in rows {
            if r.countsTowardTotal, let b = r.freedBytes {
                total += b
                if calendar.isDate(r.date, equalTo: now, toGranularity: .month) { month += b }
            }
            if r.countsAsScan { scans += 1 }
            if r.outcome == .failure || r.outcome == .partial { fails += 1 }
        }
        return HistoryStats(totalFreed: total, monthFreed: month, scanCount: scans, failureCount: fails)
    }

    /// 新しい順の行を、その日（0 時）ごとの見出し付きにまとめる。
    static func sections(_ rows: [HistoryRow], now: Date, calendar: Calendar) -> [HistorySection] {
        var result: [HistorySection] = []
        for r in rows {
            let day = calendar.startOfDay(for: r.date)
            if let last = result.last, last.id == day {
                result[result.count - 1].rows.append(r)
            } else {
                result.append(HistorySection(id: day, title: HistoryFormat.dayTitle(day, now: now, calendar: calendar), rows: [r]))
            }
        }
        return result
    }

    // MARK: 行の組み立て

    private static func fileName(_ p: String) -> String { (p as NSString).lastPathComponent }

    private static func trashChild(_ x: HistoryEntry) -> HistoryChild {
        HistoryChild(name: x.target, bytes: x.bytes, resultLabel: HistoryResult.label(x.result),
                     outcome: HistoryResult.outcome(x.result), detail: x.detail)
    }

    private static func trashClusterRow(id: Int, _ items: [HistoryEntry]) -> HistoryRow {
        let okItems = items.filter { $0.result != "failed" }
        let failed = items.count - okItems.count
        let result = failed == 0 ? "ok" : (okItems.isEmpty ? "failed" : "partial")
        let freed = okItems.reduce(Int64(0)) { $0 + $1.bytes }
        return HistoryRow(
            id: String(id), date: items.last!.date, kind: .trash,
            title: "\(items.count) 項目をゴミ箱へ",
            subtitle: items.count == 1 ? fileName(items[0].target) : "\(fileName(items[0].target)) ほか",
            result: result, resultLabel: HistoryResult.label(result), outcome: HistoryResult.outcome(result),
            freedBytes: freed > 0 ? freed : nil, countsTowardTotal: true, countsAsScan: false, isEmptyTrash: false,
            overview: nil, detail: failed > 0 ? "失敗 \(failed) 件" : "", seconds: nil, outputPath: nil, sourcePath: nil,
            children: items.map(trashChild), childrenAreItems: true, itemCount: items.count)
    }

    private static func makeRow(id: Int, _ x: HistoryEntry, items: [HistoryEntry], related: [HistoryEntry]) -> HistoryRow {
        var row = HistoryRow(
            id: String(id), date: x.date, kind: x.kind, title: x.target, subtitle: nil,
            result: x.result, resultLabel: HistoryResult.label(x.result), outcome: HistoryResult.outcome(x.result),
            freedBytes: nil, countsTowardTotal: false, countsAsScan: false, isEmptyTrash: false,
            overview: nil, detail: x.detail, seconds: firstSeconds(x.detail), outputPath: nil, sourcePath: nil,
            children: items.map(trashChild), childrenAreItems: true, itemCount: max(items.count, 1))
        let failed = x.result == "failed"
        switch x.kind {
        case .cleanup:
            if x.target == "~/.Trash" {
                row.title = "ゴミ箱を空にする"; row.isEmptyTrash = true
                row.subtitle = "完全に削除（累計には含めません）"
            } else {
                let n = leadingCount(x.target) ?? items.count
                row.title = "\(n) 項目をゴミ箱へ"; row.itemCount = n
                row.subtitle = "クリーンアップ"
                row.countsTowardTotal = true
            }
            row.freedBytes = failed ? nil : x.bytes
        case .uninstall:
            if let n = leadingCount(x.target, prefix: "残骸 ") {
                row.title = "アプリの残骸を削除"; row.subtitle = "\(n) 件"; row.itemCount = n
            } else {
                row.title = "アプリを削除"; row.subtitle = fileName(x.target); row.sourcePath = x.target
            }
            row.countsTowardTotal = true
            row.freedBytes = failed ? nil : x.bytes
        case .compress:
            row.title = "動画を圧縮"
            if x.detail.hasPrefix("出力: ") {
                let out = String(x.detail.dropFirst(4))
                row.outputPath = out; row.subtitle = fileName(out)
            } else { row.subtitle = fileName(x.target) }
            row.sourcePath = x.target
            row.countsTowardTotal = true
            row.freedBytes = failed ? nil : x.bytes
            row.children = []   // 元ファイルのゴミ箱移動は出力先・元ファイルとして別表示
        case .loginItem:
            row.title = "ログイン項目を無効化"
            row.subtitle = x.detail.hasPrefix("無効化: ") ? String(x.detail.dropFirst(5)) : fileName(x.target)
            row.sourcePath = x.target
            row.children = []
        case .scan:
            fillScan(&row, x, related: related)
        case .trash:
            break   // 単独の trash は束ねて trashClusterRow で処理する
        }
        return row
    }

    private static func fillScan(_ row: inout HistoryRow, _ x: HistoryEntry, related: [HistoryEntry]) {
        let t = x.target
        row.childrenAreItems = false
        row.children = related.map {
            HistoryChild(name: $0.target, bytes: nil, resultLabel: HistoryResult.label($0.result),
                         outcome: HistoryResult.outcome($0.result), detail: $0.detail)
        }
        let dur = row.seconds.map { "所要 \(ShortDate.duration(TimeInterval($0)))" }
        func join(_ parts: [String?]) -> String? {
            let p = parts.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "・")
        }
        if x.result == "ignored" {
            row.title = "検出を無視"; row.subtitle = fileName(t); row.overview = x.detail; row.sourcePath = t
            return
        }
        row.countsAsScan = true
        if t.hasPrefix("セキュリティスキャン（") {
            row.title = "セキュリティスキャン"
            let n = t.dropFirst("セキュリティスキャン（".count).dropLast()   // 「10 対象」
            row.subtitle = join([String(n), dur])
            row.overview = firstSegment(x.detail)
        } else if t.hasPrefix("スマートケア") {
            row.title = "スマートケア"
            var variant: String? = nil
            if let a = t.firstIndex(of: "（"), let b = t.lastIndex(of: "）"), a < b { variant = String(t[t.index(after: a)..<b]) }
            row.subtitle = join([variant, dur])
            row.overview = smartCareOverview(x.detail)
        } else {
            // 「定期フルスキャン」「定期スキャン」（結びつく直前のスマートケアが無い場合）
            row.title = t
            row.subtitle = dur
            row.overview = smartCareOverview(x.detail)
        }
    }

    // MARK: 文字列の解析

    /// 「46 件」→ 46（prefix 指定可: 「残骸 3 件」）
    static func leadingCount(_ s: String, prefix: String = "") -> Int? {
        guard s.hasPrefix(prefix), s.hasSuffix(" 件") else { return nil }
        return Int(s.dropFirst(prefix.count).dropLast(2))
    }

    /// 「関連 3 件」のようにラベルの直後にある整数
    static func intAfter(_ label: String, in s: String) -> Int? {
        guard let r = s.range(of: label) else { return nil }
        let digits = s[r.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
        return Int(digits)
    }

    /// 最初の「N 秒」
    static func firstSeconds(_ s: String) -> Int? {
        guard let r = s.range(of: " 秒") else { return nil }
        let head = s[..<r.lowerBound]
        let digits = String(head.reversed().prefix { $0.isNumber }.reversed())
        return Int(digits)
    }

    private static func firstSegment(_ s: String) -> String {
        s.components(separatedBy: "、").first ?? s
    }

    /// 「脅威 0 件 / 不要データ 1.84 GB / 新しいログイン項目 0 件、409 秒」→「脅威 0 件」「不要データ 1.84 GB」の2行（項目の途中で折り返さないため）
    private static func smartCareOverview(_ s: String) -> String {
        firstSegment(s).components(separatedBy: " / ").prefix(2).joined(separator: "\n")
    }
}
