import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let d = state.disk {
                Text("空き容量: \(formatBytes(d.available)) / \(formatBytes(d.total))")
                    .font(.system(.body, design: .rounded))
            } else {
                Text("ディスク情報を取得できません").foregroundStyle(.secondary)
            }
            Text(state.lastScanSummary ?? "前回のスキャン: なし")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("ウィンドウを開く") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("スマートケアを実行") {}.disabled(true)
            Divider()
            Button("終了") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .onAppear { state.refresh() }
    }
}
