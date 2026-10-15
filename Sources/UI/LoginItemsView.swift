import SwiftUI
import AppKit

struct LoginItemsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.loginItems
        PaneScaffold(item: .loginItems, subtitle: "LaunchAgents / LaunchDaemons を一覧し、前回のスキャンからの変化を検出します。") {
            if m.scanning { ProgressView().controlSize(.small) }
            Button("システム設定を開く") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(u) }
            }.buttonStyle(.secondary)
            Button(m.hasScanned ? "再スキャン" : "スキャン") { Task { await m.scan() } }
                .buttonStyle(.primary).disabled(m.scanning)
        } content: {
            VStack(spacing: 0) {
                if let msg = m.message { NoticeText(text: msg) }
                if let d = m.diff, !d.removed.isEmpty {
                    Text("前回から削除された項目: \(d.removed.joined(separator: ", "))").font(.caption).foregroundStyle(Theme.secondary).padding(.vertical, 4)
                }
                if !m.hasScanned && !m.scanning {
                    EmptyStateView(symbol: "power", color: Theme.loginItems, message: "ログイン項目をスキャンします。\nスキャンごとにスナップショットを保存し、新しい項目を強調表示・通知します。") {
                        Button("スキャン") { Task { await m.scan() } }.buttonStyle(.primary)
                    }
                } else {
                    List(m.items) { it in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(it.label).bold()
                                    if it.change == .new { badge("新規", Theme.danger) }
                                    if it.change == .changed { badge("変更", Theme.warn) }
                                    badge(it.domain == .user ? "ユーザー" : "システム", Theme.secondary)
                                }
                                Text(it.program ?? "実行ファイル不明").font(.caption).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                                Text("署名: \(it.signer)　RunAtLoad: \(it.runAtLoad ? "はい" : "いいえ")　KeepAlive: \(it.keepAlive ? "はい" : "いいえ")")
                                    .font(.caption).foregroundStyle(it.signer == "未署名" ? Theme.danger : Theme.secondary)
                            }
                            Spacer()
                            Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([it.plistURL]) }.buttonStyle(.secondary)
                            if it.domain == .user {
                                Button("無効化…") {
                                    let snap = it   // 確認時点の内容で固定
                                    Task {
                                        await Confirm.destructive(title: "この項目を無効化しますか？",
                                                                  message: "launchctl bootout で停止し、plist をゴミ箱へ移動します。\n\(snap.plistURL.path)",
                                                                  button: "無効化してゴミ箱へ", snapshot: snap) { await m.disable($0) }
                                    }
                                }.buttonStyle(.secondaryDestructive)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .themedList()
                }
            }
        }
        .task { if state.consumeAutoScan("loginItems") { await m.scan(); state.markAutoScanDone("loginItems") } }
    }

    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
            .background(c.opacity(0.2), in: Capsule()).foregroundStyle(c)
    }
}
