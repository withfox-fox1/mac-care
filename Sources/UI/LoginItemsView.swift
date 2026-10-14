import SwiftUI
import AppKit

struct LoginItemsView: View {
    @Environment(AppState.self) private var state
    @State private var target: LoginItem? = nil

    var body: some View {
        let m = state.loginItems
        PaneScaffold(title: "ログイン項目", subtitle: "LaunchAgents / LaunchDaemons を一覧し、前回のスキャンからの変化を検出します。") {
            if m.scanning { ProgressView().controlSize(.small) }
            Button("システム設定を開く") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(u) }
            }
            Button(m.hasScanned ? "再スキャン" : "スキャン") { Task { await m.scan() } }
                .buttonStyle(.borderedProminent).disabled(m.scanning)
        } content: {
            VStack(spacing: 0) {
                if let msg = m.message { Text(msg).foregroundStyle(.orange).padding(.vertical, 6) }
                if let d = m.diff, !d.removed.isEmpty {
                    Text("前回から削除された項目: \(d.removed.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                }
                if !m.hasScanned && !m.scanning {
                    ContentUnavailableView("スキャンを実行してください", systemImage: "person.badge.key",
                                           description: Text("スキャンごとにスナップショットを保存し、新しい項目を強調表示・通知します。"))
                } else {
                    List(m.items) { it in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(it.label).bold()
                                    if it.change == .new { badge("新規", .red) }
                                    if it.change == .changed { badge("変更", .orange) }
                                    badge(it.domain == .user ? "ユーザー" : "システム", .gray)
                                }
                                Text(it.program ?? "実行ファイル不明").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Text("署名: \(it.signer)　RunAtLoad: \(it.runAtLoad ? "はい" : "いいえ")　KeepAlive: \(it.keepAlive ? "はい" : "いいえ")")
                                    .font(.caption).foregroundStyle(it.signer == "未署名" ? .red : .secondary)
                            }
                            Spacer()
                            Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([it.plistURL]) }
                            if it.domain == .user { Button("無効化…", role: .destructive) { target = it } }
                        }
                    }
                }
            }
        }
        .task { if state.consumeAutoScan("loginItems") { await m.scan(); state.markAutoScanDone("loginItems") } }
        .alert("この項目を無効化しますか？", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            Button("無効化してゴミ箱へ", role: .destructive) { if let t = target { Task { await m.disable(t) } }; target = nil }
            Button("キャンセル", role: .cancel) { target = nil }
        } message: { Text("launchctl bootout で停止し、plist をゴミ箱へ移動します。\n\(target?.plistURL.path ?? "")") }
    }

    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
            .background(c.opacity(0.2), in: Capsule()).foregroundStyle(c)
    }
}
