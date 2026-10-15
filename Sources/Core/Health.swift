import Foundation

/// 健康スコアの入力（スマートケア結果と空き容量から作る）
struct HealthInput {
    var threats: Int
    var newOrChangedLoginItems: Int
    var freeBytes: Int64?
    var totalBytes: Int64?
    var junkBytes: Int64
    var lastSmartCare: Date?
    var now: Date
}

enum HealthScore {
    static let junkThreshold: Int64 = 5_000_000_000

    /// 100 点から減点方式で 0...100 に丸める
    static func score(_ i: HealthInput) -> Int {
        var s = 100
        s -= min(60, 30 * max(0, i.threats))
        s -= min(20, 10 * max(0, i.newOrChangedLoginItems))
        if let f = i.freeBytes, let t = i.totalBytes, t > 0, Double(f) / Double(t) < 0.10 { s -= 20 }
        if i.junkBytes >= junkThreshold { s -= 5 }
        if let last = i.lastSmartCare {
            if i.now.timeIntervalSince(last) > 14 * 86400 { s -= 10 }
        } else {
            s -= 10
        }
        return max(0, min(100, s))
    }

    enum Level { case good, caution, critical }

    static func level(_ score: Int) -> Level { score >= 80 ? .good : score >= 50 ? .caution : .critical }

    static func headline(_ score: Int) -> String {
        switch level(score) {
        case .good: "Mac は良好です"
        case .caution: "注意が必要です"
        case .critical: "対処が必要です"
        }
    }
    /// メニューバーパネル用の短い状態語
    static func word(_ score: Int) -> String {
        switch level(score) { case .good: "良好"; case .caution: "注意"; case .critical: "要対処" }
    }
}

/// 日時の短い表記（今日 11:42 / 昨日 18:13 / 10/3 09:05）
enum ShortDate {
    static func format(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP"); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        let t = f.string(from: d)
        if calendar.isDate(d, inSameDayAs: now) { return "今日 \(t)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "昨日 \(t)" }
        f.dateFormat = "M/d HH:mm"
        return f.string(from: d)
    }
    /// 所要時間（7分 / 42秒）
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? "\(s / 60)分" : "\(s)秒"
    }
}
