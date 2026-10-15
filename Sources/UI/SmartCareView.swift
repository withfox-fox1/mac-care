import SwiftUI

struct SmartCareView: View {
    @Environment(AppState.self) private var state
    @State private var confirmTrash = false

    private func go(_ section: String) { state.requestedSection = section }

    var body: some View {
        let m = state.smartCare
        PaneScaffold(title: "スマートケア", subtitle: "不要データ・セキュリティ・ログイン項目・大容量ファイルをまとめて確認します。スキャンでは何も削除しません。") {
            if m.running {
                ProgressView().controlSize(.small)
                Text(m.statusText).foregroundStyle(.secondary)
                Button("キャンセル") { m.cancel(state: state) }
            } else {
                Button(m.result == nil ? "スキャン" : "再スキャン") { Task { await m.run(state: state) } }
                    .buttonStyle(.borderedProminent)
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if m.running || !m.doneSteps.isEmpty && m.result == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(SmartCareStep.allCases, id: \.self) { s in
                                HStack {
                                    Image(systemName: m.doneSteps.contains(s) ? "checkmark.circle.fill" : (m.currentStep == s ? "circle.dotted" : "circle"))
                                        .foregroundStyle(m.doneSteps.contains(s) ? .green : .secondary)
                                    Text(s.rawValue)
                                }
                            }
                        }
                    }
                    if let r = m.result {
                        Text("前回のスキャン: \(r.date.formatted(date: .abbreviated, time: .shortened))（\(Int(r.seconds)) 秒・\(r.deep ? "じっくり" : "標準")モード）")
                            .font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                            card("不要データ", "trash", formatBytes(r.junkBytes),
                                 "うち既定で安全なもの \(formatBytes(r.safeJunkBytes))", .blue, "確認する") { go("cleanup") }
                            card("脅威", "shield", "\(r.threats) 件",
                                 r.threats == 0 ? "脅威は検出されませんでした" : "内容を確認してください", r.threats == 0 ? .green : .red, "確認する") { go("security") }
                            card("ログイン項目の変化", "person.badge.key", "新規 \(r.newLoginItems) / 変更 \(r.changedLoginItems)",
                                 "前回のスナップショットとの比較", r.newLoginItems + r.changedLoginItems == 0 ? .green : .orange, "確認する") { go("loginItems") }
                            card("大容量ファイル", "externaldrive", "\(r.largeFileCount) 件",
                                 "合計 \(formatBytes(r.largeFileBytes))", .purple, "確認する") { go("largeFiles") }
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("不要データをまとめて掃除").bold()
                                Text("ユーザーキャッシュ・ログ・npm・Homebrew・pip のみ（\(formatBytes(r.safeJunkBytes))）。node_modules・Xcode・ゴミ箱は対象外です。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let f = state.cleanup.lastFreed { Text("解放: \(formatBytes(f))").foregroundStyle(.green).bold() }
                            Button("不要データをゴミ箱へ…") { confirmTrash = true }
                                .disabled(r.safeJunkBytes == 0 || state.cleanup.cleaning || m.running)
                        }
                        .padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    } else if !m.running {
                        ContentUnavailableView("スキャンを実行してください", systemImage: "sparkles",
                                               description: Text("結果は 4 つのカードにまとめて表示します。"))
                    }
                }
                .padding(20)
            }
        }
        .task {
            if state.consumeAutoScan("smartCare") {
                await m.run(state: state); state.markAutoScanDone("smartCare")
            }
        }
        .alert("不要データをゴミ箱へ移動しますか？", isPresented: $confirmTrash) {
            Button("ゴミ箱へ移動", role: .destructive) { Task { await m.trashSafe(state: state) } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            let safe = SmartCare.safeCategories(state.cleanup.categories)
            Text(safe.map { "\($0.name): \(formatBytes($0.size))" }.joined(separator: "\n")
                 + "\n\n合計 \(formatBytes(safe.reduce(0) { $0 + $1.size }))（ゴミ箱へ移動します）")
        }
    }

    private func card(_ title: String, _ symbol: String, _ value: String, _ note: String, _ color: Color,
                      _ action: String, _ tap: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(color)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(note).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action, action: tap)
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
