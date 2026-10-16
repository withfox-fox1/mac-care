import SwiftUI
import AppKit

struct LoginItemsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.loginItems
        PaneScaffold(item: .loginItems, subtitle: "Mac の起動時やログイン時に自動で動くプログラムを確認します。前回から増えたものをお知らせします。") {
            Button("システム設定を開く") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(u) }
            }.buttonStyle(.secondary)
            Button(m.hasScanned ? "再スキャン" : "スキャン") { Task { await m.scan() } }
                .prominentButton(!m.hasScanned).fixedSize().disabled(m.scanning)
                .help(m.scanning ? "スキャン中です" : "")
        } content: {
            VStack(spacing: 0) {
                if let msg = m.message { NoticeText(text: msg) { m.message = nil } }
                if m.scanning {
                    ScanActivity(text: "ログイン項目を確認しています…")
                } else if m.hasScanned {
                    LastScanNote(date: m.lastScannedAt)
                }
                if let d = m.diff, !d.removed.isEmpty {
                    StatusStrip(symbol: "minus.circle.fill", text: "前回から削除された項目: \(d.removed.joined(separator: ", "))")
                }
                if !m.hasScanned && !m.scanning {
                    ScanEmptyState(symbol: "power", color: Theme.loginItems,
                                   what: "Mac の起動時に自動で動くプログラムを確認し、前回から増えたものをお知らせします。",
                                   durationKey: "loginItems") { Task { await m.scan() } }
                } else if !m.hasScanned {
                    Color.clear.frame(maxHeight: .infinity)
                } else {
                    List(m.items) { it in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(it.label).bold().lineLimit(1).truncationMode(.middle)
                                    if it.change == .new { badge("新規", Theme.danger) }
                                    if it.change == .changed { badge("変更", Theme.warn) }
                                    badge(it.domain == .user ? "このアカウント" : "Mac 全体", Theme.secondary)
                                }
                                HStack(spacing: 8) {
                                    Text("提供元: \(it.signer.isEmpty ? "不明" : it.signer)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                        .lineLimit(1).truncationMode(.tail)
                                    if it.signer == "未署名" {
                                        Label("署名なし", systemImage: "exclamationmark.triangle.fill")
                                            .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.danger).fixedSize()
                                            .help("開発元の署名がないプログラムです。心当たりがなければ確認してください。")
                                    }
                                }
                                DisclosureGroup("詳細") {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("プログラム: \(it.program ?? "実行ファイル不明")").textSelection(.enabled)
                                        Text("RunAtLoad（起動時に自動実行）: \(it.runAtLoad ? "はい" : "いいえ")　KeepAlive（終了しても再起動）: \(it.keepAlive ? "はい" : "いいえ")")
                                    }.font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(.top, 2)
                                }.font(.system(size: 11))
                            }
                            Spacer()
                            Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([it.plistURL]) }.buttonStyle(.secondary).fixedSize()
                            if it.domain == .user {
                                Button("無効化…") {
                                    let snap = it   // 確認時点の内容で固定
                                    Task {
                                        await Confirm.destructive(title: "この項目を無効化しますか？",
                                                                  message: "この項目を停止し、設定ファイル（plist）をゴミ箱へ移動します。\n\(snap.plistURL.path)",
                                                                  button: "無効化してゴミ箱へ", snapshot: snap) { await m.disable($0) }
                                    }
                                }
                                // 行内の赤ボタンをやめて通常の副ボタンにする（確認ダイアログで内容を確認してから実行）
                                .buttonStyle(.secondary).fixedSize()
                                .help("この項目を停止し、設定ファイルをゴミ箱へ移動します（確認画面が出ます）")
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
        Text(t).font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 1)
            .background(c.opacity(0.2), in: Capsule()).foregroundStyle(c).fixedSize()
    }
}
