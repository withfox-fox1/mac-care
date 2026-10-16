import Foundation

/// 設定画面の選択肢と表示用の整形（UI から分離してテスト可能にする）
enum SettingsChoices {
    static let thresholdMB = [100, 500, 1_000, 5_000]
    static let staleDays = [30, 60, 90, 180, 365]

    /// 選択肢に現在値が無ければ加える（昇順）。保存済みの任意の値を失わないため。
    static func options(_ base: [Int], including current: Int) -> [Int] {
        base.contains(current) ? base : (base + [current]).sorted()
    }

    static func sizeLabel(mb: Int) -> String {
        if mb >= 1_000 && mb % 1_000 == 0 { return "\(mb / 1_000) GB" }
        return "\(mb) MB"
    }

    static func daysLabel(_ d: Int) -> String { "\(d) 日" }

    /// ホームフォルダは「ホーム」と表示する。それ以外はパスそのまま。
    static func displayPath(_ p: String, home: String = NSHomeDirectory()) -> String {
        p == home ? "ホーム" : p
    }

    /// 機能ごとの必須ツール。いずれかが無いと、その機能が使えない。
    static let toolGroups: [(feature: String, tools: [String])] = [
        ("セキュリティ検査", ["yara", "yarac", "clamscan", "freshclam"]),
        ("動画の圧縮", ["ffmpeg", "ffprobe"]),
    ]

    /// 必須ツールが欠けている機能と、欠けているツール名
    static func missingTools(_ tools: [ToolInfo]) -> [(feature: String, missing: [String])] {
        toolGroups.compactMap { g in
            let miss = g.tools.filter { n in !(tools.first { $0.name == n }?.isAvailable ?? false) }
            return miss.isEmpty ? nil : (g.feature, miss)
        }
    }
}
