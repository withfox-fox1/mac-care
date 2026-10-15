import Foundation

enum RecAction: Equatable {
    case navigate(String)      // サイドバー項目の rawValue
    case openURL(String)
    case runSmartCare
}

struct Recommendation: Equatable, Identifiable {
    enum Kind: String { case threats, videos, cleanMyMac, junk, appUpdate, staleScan, wakeSchedule, notifications, fullDiskAccess }
    var kind: Kind
    var symbol: String
    var title: String
    var detail: String
    var actionLabel: String
    var action: RecAction
    var id: String { kind.rawValue }
}

struct RecommendationInput {
    var videoCount = 0
    var videoBytes: Int64 = 0
    var cleanMyMacItems = 0
    /// nil = 未確認
    var notificationsAuthorized: Bool? = nil
    /// nil = 未確認（ゴミ箱の読み取り結果などから判断）
    var fullDiskAccessMissing: Bool? = nil
    var threats = 0
    var junkBytes: Int64 = 0
    var lastSmartCare: Date? = nil
    var now = Date()
    /// MacCare 自体の更新件数
    var updateAvailable = 0
    /// 「スリープ中でも起こしてスキャン」の提案を出すか
    var wakeSuggested = false
}

enum Recommendations {
    static let junkThreshold: Int64 = 1_000_000_000
    static let notificationsURL = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    static let fullDiskAccessURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// 動画の圧縮で空く量の見積もり（元サイズの 80%）
    static func videoSavings(_ bytes: Int64) -> Int64 { bytes / 10 * 8 }

    /// 優先度順の全候補
    static func all(_ i: RecommendationInput) -> [Recommendation] {
        var out: [Recommendation] = []
        if i.threats > 0 {
            out.append(Recommendation(kind: .threats, symbol: "exclamationmark.shield.fill", title: "脅威を確認",
                                      detail: "\(i.threats) 件の脅威が検出されています", actionLabel: "確認する", action: .navigate("security")))
        }
        if i.videoCount > 0 && i.videoBytes > 0 {
            out.append(Recommendation(kind: .videos, symbol: "film.fill",
                                      title: "動画を圧縮して約\(formatBytes(videoSavings(i.videoBytes)))空ける",
                                      detail: "大容量の動画が \(i.videoCount) 本（合計 \(formatBytes(i.videoBytes))）あります",
                                      actionLabel: "動画圧縮へ", action: .navigate("compress")))
        }
        if i.cleanMyMacItems > 0 {
            out.append(Recommendation(kind: .cleanMyMac, symbol: "power", title: "CleanMyMac の常駐を止める",
                                      detail: "ログイン項目に \(i.cleanMyMacItems) 件残っています", actionLabel: "確認する", action: .navigate("loginItems")))
        }
        if i.junkBytes >= junkThreshold {
            out.append(Recommendation(kind: .junk, symbol: "sparkles", title: "不要データを掃除",
                                      detail: "\(formatBytes(i.junkBytes)) の不要データがあります", actionLabel: "掃除する", action: .navigate("cleanup")))
        }
        if i.updateAvailable > 0 {
            out.append(Recommendation(kind: .appUpdate, symbol: "arrow.down.circle.fill", title: "MacCare のアップデートがあります",
                                      detail: "\(i.updateAvailable) 件の更新を取り込めます", actionLabel: "設定を開く", action: .navigate("settings")))
        }
        let stale = i.lastSmartCare.map { i.now.timeIntervalSince($0) > 7 * 86400 } ?? true
        if stale {
            out.append(Recommendation(kind: .staleScan, symbol: "arrow.triangle.2.circlepath", title: "スマートケアを実行",
                                      detail: i.lastSmartCare == nil ? "まだスマートケアを実行していません" : "前回のスキャンから 7 日以上経っています",
                                      actionLabel: "実行する", action: .runSmartCare))
        }
        if i.wakeSuggested {
            out.append(Recommendation(kind: .wakeSchedule, symbol: "moon.zzz.fill", title: "スリープ中でも起こしてフルスキャン",
                                      detail: "毎日のフルスキャン前に Mac を自動で起こします（管理者パスワードが必要）", actionLabel: "設定を開く", action: .navigate("settings")))
        }
        if i.notificationsAuthorized == false {
            out.append(Recommendation(kind: .notifications, symbol: "bell.fill", title: "通知をオンにする",
                                      detail: "定期スキャンの結果をお知らせします", actionLabel: "設定を開く", action: .openURL(notificationsURL)))
        }
        if i.fullDiskAccessMissing == true {
            out.append(Recommendation(kind: .fullDiskAccess, symbol: "lock.open.fill", title: "フルディスクアクセスを許可（任意）",
                                      detail: "ゴミ箱の中身を確認・空にできるようになります", actionLabel: "設定を開く", action: .openURL(fullDiskAccessURL)))
        }
        return out
    }

    static func top(_ i: RecommendationInput, limit: Int = 3) -> [Recommendation] { Array(all(i).prefix(limit)) }
}
