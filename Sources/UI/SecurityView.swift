import SwiftUI
import AppKit

struct SecurityView: View {
    @Environment(AppState.self) private var state
    @State private var confirmTrash: Detection? = nil

    var body: some View {
        let m = state.security
        PaneScaffold(title: "セキュリティ", subtitle: "常時保護は macOS 標準（XProtect / Gatekeeper）が担当します。ここでは追加のスキャンを行います。") {
            if m.running { ProgressView().controlSize(.small); Text(m.step.rawValue).foregroundStyle(.secondary) }
            if m.running {
                Button("キャンセル") { m.cancel() }
            } else {
                Button(m.hasScanned ? "再スキャン" : "スキャン開始") { m.start(state: state) }.buttonStyle(.borderedProminent)
            }
        } content: {
            List {
                Section("システムの保護状態") {
                    if let s = m.status {
                        LabeledContent("XProtect", value: s.xprotectVersion.map { "バージョン \($0)" } ?? "不明")
                        LabeledContent("XProtect 更新日", value: s.xprotectUpdated?.formatted(date: .abbreviated, time: .shortened) ?? "不明")
                        LabeledContent("Gatekeeper", value: s.gatekeeper)
                        LabeledContent("SIP", value: s.sip)
                    } else { Text("取得中…").foregroundStyle(.secondary) }
                }
                Section { Text("現在のモード: \(state.settings.deepScan ? "じっくりスキャン" : "標準スキャン")（設定で変更できます）").font(.caption).foregroundStyle(.secondary) }
                if let msg = m.message { Section { Text(msg).foregroundStyle(.orange) } }
                if let r = m.lastReport {
                    Section("前回のスキャン") {
                        LabeledContent("結果", value: r.summary)
                        LabeledContent("モード", value: r.deep ? "じっくり（ClamAV も /Applications を対象）" : "標準（ClamAV は /Applications を除外）")
                        LabeledContent("対象 / 所要時間 / 無視", value: "\(r.targetCount) 件 / \(Int(r.duration)) 秒（YARA \(Int(r.yaraSeconds)) 秒・ClamAV \(Int(r.clamSeconds)) 秒）/ \(r.hidden) 件")
                        ForEach(r.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    }
                    Section("検出結果") {
                        if m.detections.isEmpty { Label("脅威は検出されませんでした", systemImage: "checkmark.shield").foregroundStyle(.green) }
                        ForEach(m.detections) { d in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(d.engine.rawValue): \(d.signature)").bold().foregroundStyle(.red)
                                    Spacer()
                                    Button("Finderで表示") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d.path)])
                                    }
                                    Button("無視") { m.ignore(d) }
                                    Button("ゴミ箱へ", role: .destructive) { confirmTrash = d }
                                }
                                Text(d.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                } else if !m.running {
                    Section { Text("スキャンを開始すると、定義更新 → YARA → ClamAV の順に実行します。").foregroundStyle(.secondary) }
                }
            }
        }
        .task {
            state.settings = Settings.load()
            await m.refreshStatus()
            if state.consumeAutoScan("security") { m.start(state: state) }
        }
        .onChange(of: m.running) { _, now in if !now { state.markAutoScanDone("security") } }
        .alert("このファイルをゴミ箱へ移動しますか？", isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("ゴミ箱へ移動", role: .destructive) { if let d = confirmTrash { m.trash(d) }; confirmTrash = nil }
            Button("キャンセル", role: .cancel) { confirmTrash = nil }
        } message: { Text(confirmTrash?.path ?? "") }
    }
}
