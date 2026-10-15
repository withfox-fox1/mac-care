import SwiftUI
import AppKit

struct SecurityView: View {
    @Environment(AppState.self) private var state

    /// 検査済み / 前回から変更なし の内訳
    private func engineLine(_ ran: Bool, _ total: Int, _ cached: Int, _ date: Date) -> String {
        guard ran else { return "未実行" }
        let scanned = total - cached
        if cached == 0 { return "検査済み \(scanned) 件" }
        return "検査済み \(scanned) 件 / 前回から変更なし \(cached) 件（前回までに検査済み）"
    }

    private func coverageNote(_ last: Date?) -> String {
        guard let last else { return "。クイックは変更分のみのため、フルスキャンを一度実行してください" }
        let days = Int(Date().timeIntervalSince(last) / 86400)
        return days >= 2 ? "（\(days) 日前。未変更ファイルはその時点の検査結果です）" : ""
    }

    var body: some View {
        @Bindable var st = state
        let m = state.security
        PaneScaffold(item: .security, subtitle: "常時保護は macOS 標準（XProtect / Gatekeeper）が担当します。ここでは追加のスキャンを行います。") {
            if m.running {
                ScanProgressBlock(fraction: m.fraction, etaText: m.etaText,
                                  stepText: m.step == .scanning ? "\(m.runningFull ? "フル" : "クイック")スキャン中" : m.step.rawValue,
                                  detailText: m.detail, width: 230)
                Button("キャンセル") { m.cancel() }.buttonStyle(.secondary)
            } else {
                Picker("方式", selection: $st.settings.quickScan) {
                    Text("クイック（変更分のみ）").tag(true)
                    Text("フル（すべて）").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 270)
                Button(m.hasScanned ? "再スキャン" : "スキャン開始") { m.start(state: state) }.buttonStyle(.primary)
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
                Section {
                    Text("現在のモード: \(state.settings.deepScan ? "じっくりスキャン" : "標準スキャン")（設定で変更できます）").font(.caption).foregroundStyle(Theme.secondary)
                    Text(FullScanLabel.text(m.lastFullAt) + coverageNote(m.lastFullAt)).font(.caption).foregroundStyle(Theme.secondary)
                    Text("クイック: 前回から変更のないファイルは再検査せず、新規・変更分のみ検査します。フル: すべてのファイルを両エンジンで検査します（毎日の定期スキャンがフルです）。").font(.caption).foregroundStyle(Theme.secondary)
                }
                if let msg = m.message { Section { Text(msg).foregroundStyle(Theme.warn) } }
                if let r = m.lastReport {
                    Section("前回のスキャン") {
                        LabeledContent("結果", value: r.summary)
                        LabeledContent("モード", value: r.deep ? "じっくり（ClamAV も /Applications を対象）" : "標準（ClamAV は /Applications を除外）")
                        LabeledContent("方式", value: r.quick ? "クイック（変更分のみ）" : "フル（すべて検査）")
                        LabeledContent("YARA", value: engineLine(r.ranYara, r.yaraTotal, r.yaraCached, r.date))
                        LabeledContent("ClamAV", value: engineLine(r.ranClam, r.clamTotal, r.clamCached, r.date))
                        if r.quick, r.yaraCached + r.clamCached > 0 {
                            LabeledContent("キャッシュ命中率", value: "\(Int((r.hitRate * 100).rounded()))%（最も古い検査: \(r.oldestCached.map { ShortDate.format($0) } ?? "—")）")
                        }
                        if r.clamOverLimit > 0 {
                            LabeledContent("ClamAV の上限超（YARA のみで検査）", value: "\(r.clamOverLimit) 件")
                        }
                        if r.dataless > 0 { LabeledContent("iCloud 未ダウンロード（未検査）", value: "\(r.dataless) 件") }
                        if r.unreadable > 0 { LabeledContent("読み取れず未検査", value: "\(r.unreadable) 件") }
                        LabeledContent("対象 / 所要時間 / 無視", value: "\(r.targetCount) 件 / \(Int(r.duration)) 秒（YARA \(Int(r.yaraSeconds)) 秒・ClamAV \(Int(r.clamSeconds)) 秒）/ \(r.hidden) 件")
                        ForEach(r.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.warn) }
                    }
                    Section("検出結果") {
                        if m.detections.isEmpty { Label("脅威は検出されませんでした", systemImage: "checkmark.shield.fill").foregroundStyle(Theme.ok) }
                        ForEach(m.detections) { d in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(d.engine.rawValue): \(d.signature)").bold().foregroundStyle(Theme.danger)
                                    Spacer()
                                    Button("Finderで表示") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d.path)])
                                    }.buttonStyle(.secondary)
                                    Button("無視") { m.ignore(d) }.buttonStyle(.secondary)
                                    if SecurityModel.enclosingApp(of: d.path) != nil {
                                        Button("アプリ単位で削除…") { state.requestedSection = "apps" }.buttonStyle(.secondary)
                                    } else {
                                        Button("ゴミ箱へ") {
                                            let snap = d   // 確認時点の内容で固定
                                            Task {
                                                await Confirm.destructive(title: "このファイルをゴミ箱へ移動しますか？", message: snap.path,
                                                                          button: "ゴミ箱へ移動", snapshot: snap) { m.trash($0) }
                                            }
                                        }.buttonStyle(.secondaryDestructive)
                                    }
                                }
                                if SecurityModel.enclosingApp(of: d.path) != nil {
                                    Text("アプリ内部のファイルのため、単独では削除できません（アプリ単位で削除してください）。").font(.caption).foregroundStyle(Theme.warn)
                                }
                                Text(d.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                } else if !m.running {
                    Section { Text("スキャンを開始すると、定義更新 → YARA → ClamAV の順に実行します。").foregroundStyle(Theme.secondary) }
                }
            }
            .themedList()
        }
        .task {
            state.settings = Settings.load()
            await m.refreshStatus()
            if state.consumeAutoScan("security") { m.start(state: state) }
        }
        .onChange(of: m.running) { _, now in if !now { state.markAutoScanDone("security") } }
        .onChange(of: state.settings.quickScan) { _, v in var d = Settings.load(); d.quickScan = v; try? d.save() }
    }
}
