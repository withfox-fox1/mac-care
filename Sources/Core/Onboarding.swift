import Foundation

/// 初回起動時だけ表示するあいさつ（1 枚のみ）
enum Onboarding {
    static let defaultsKey = "MacCare.onboardingShown"

    /// 表示すべきか。検証用の起動引数（--open-window / --show-panel）のときは出さない
    static func shouldShow(defaults: UserDefaults = .standard, arguments: [String] = CommandLine.arguments) -> Bool {
        if arguments.contains("--open-window") || arguments.contains("--show-panel") { return false }
        return !defaults.bool(forKey: defaultsKey)
    }
    static func markShown(defaults: UserDefaults = .standard) { defaults.set(true, forKey: defaultsKey) }
}
