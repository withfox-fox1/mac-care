import AppKit

/// 破壊的操作の確認ダイアログ。
/// - 既定ボタン（Return）は「キャンセル」。実行ボタンはキー割り当てなしで、明示的なクリックが必要。
/// - 表示時点のスナップショットをそのまま action に渡すため、確認内容と実行内容が一致する。
@MainActor
enum Confirm {
    /// テスト用に差し替え可能。(title, message, 実行ボタン名) → 実行が選ばれたか
    static var presenter: (String, String, String) -> Bool = { title, message, button in
        makeAlert(title: title, message: message, button: button).runModal() == .alertSecondButtonReturn
    }

    static func makeAlert(title: String, message: String, button: String) -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = message
        let cancel = a.addButton(withTitle: "キャンセル")   // 先頭 = 既定（Return）
        cancel.keyEquivalent = "\r"
        let go = a.addButton(withTitle: button)
        go.keyEquivalent = ""
        go.hasDestructiveAction = true
        return a
    }

    /// 確認が取れた場合のみ action(snapshot) を実行する。戻り値は実行したか。
    @discardableResult
    static func destructive<S>(title: String, message: String, button: String, snapshot: S,
                               action: (S) async -> Void) async -> Bool {
        guard presenter(title, message, button) else { return false }
        await action(snapshot)
        return true
    }
}
