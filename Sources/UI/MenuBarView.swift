import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let sc = state.smartCare
        VStack(alignment: .leading, spacing: 10) {
            if let d = state.disk {
                Text("空き容量: \(formatBytes(d.available)) / \(formatBytes(d.total))")
                    .font(.system(.body, design: .rounded))
            } else {
                Text("ディスク情報を取得できません").foregroundStyle(.secondary)
            }
            if sc.running {
                HStack { ProgressView().controlSize(.small); Text(sc.statusText).font(.caption) }
            } else if let r = sc.result {
                VStack(alignment: .leading, spacing: 2) {
                    Text("前回のスキャン: \(r.date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    Text("脅威 \(r.threats) 件 / 不要データ \(formatBytes(r.junkBytes))")
                        .font(.caption).foregroundStyle(r.threats > 0 ? .red : .secondary)
                    if r.newLoginItems > 0 {
                        Text("新しいログイン項目 \(r.newLoginItems) 件").font(.caption).foregroundStyle(.orange)
                    }
                }
            } else {
                Text("前回のスキャン: なし").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Button("スマートケアを実行") {
                Task {
                    await sc.run(state: state)
                    state.requestedSection = "smartCare"
                    WindowOpener.open()
                }
            }.disabled(sc.running)
            Button("ウィンドウを開く") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                WindowOpener.bringToFront()
            }
            Divider()
            Button("終了") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .onAppear { state.refresh() }
    }
}
