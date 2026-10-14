import SwiftUI
import AppKit

struct CleanupView: View {
    @Environment(AppState.self) private var state
    @State private var confirmClean = false
    @State private var confirmEmpty = false

    var body: some View {
        let m = state.cleanup
        PaneScaffold(title: "クリーンアップ", subtitle: "不要なキャッシュ・ログ・古い node_modules を確認し、ゴミ箱へ移動します。") {
            if m.scanning || m.cleaning {
                ProgressView().controlSize(.small)
                Text(m.cleaning ? "ゴミ箱へ移動中…" : m.progressText).foregroundStyle(.secondary)
            }
            if let f = m.lastFreed { Text("解放: \(formatBytes(f))").foregroundStyle(.green).bold() }
            Button(m.hasScanned ? "再スキャン" : "スキャン") {
                Task { await m.scan(settings: Settings.load()) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(m.scanning || m.cleaning)
        } content: {
            VStack(spacing: 0) {
                if let msg = m.message { Text(msg).foregroundStyle(.orange).padding(.horizontal).padding(.top, 8) }
                if !m.hasScanned && !m.scanning {
                    ContentUnavailableView("スキャンを実行してください", systemImage: "trash",
                                           description: Text("削除前に必ず内容を確認できます。削除はゴミ箱への移動です。"))
                } else {
                    List {
                        Section("不要データ") {
                            ForEach(m.categories) { CategoryRow(category: $0, model: m) }
                            if m.categories.isEmpty && !m.scanning { Text("掃除できる項目はありません").foregroundStyle(.secondary) }
                        }
                        Section("ゴミ箱") { trashSection(m) }
                    }
                }
                Divider()
                HStack {
                    Text("選択中: \(m.selectedCount) 件 / \(formatBytes(m.selectedSize))")
                    Spacer()
                    Button("選択した項目をゴミ箱へ") { confirmClean = true }
                        .disabled(m.selectedCount == 0 || m.scanning || m.cleaning)
                }
                .padding()
            }
        }
        .task {
            if state.consumeAutoScan("cleanup") {
                await m.scan(settings: Settings.load()); state.markAutoScanDone("cleanup")
            }
        }
        .alert("選択した項目をゴミ箱へ移動しますか？", isPresented: $confirmClean) {
            Button("ゴミ箱へ移動", role: .destructive) { Task { await m.cleanSelected(settings: Settings.load()) } }
            Button("キャンセル", role: .cancel) {}
        } message: { Text(m.confirmationSummary) }
        .alert("ゴミ箱を空にしますか？", isPresented: $confirmEmpty) {
            Button("完全に削除", role: .destructive) { Task { await m.emptyTrash(settings: Settings.load()) } }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("この操作は取り消せません。ゴミ箱内の \(formatBytes(m.trashSize)) が完全に削除されます。") }
    }

    @ViewBuilder private func trashSection(_ m: CleanupModel) -> some View {
        if m.trashReadable {
            HStack {
                Text("ゴミ箱の中身: \(formatBytes(m.trashSize))")
                Spacer()
                Button("ゴミ箱を空にする") { confirmEmpty = true }.disabled(m.trashSize == 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("ゴミ箱の内容を読み取るには、フルディスクアクセスの許可が必要です。")
                Text("システム設定 › プライバシーとセキュリティ › フルディスクアクセス で MacCare を許可してください（任意）。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("設定を開く") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(u)
                    }
                }
            }
        }
    }
}

private struct CategoryRow: View {
    let category: CleanupCategory
    let model: CleanupModel

    private func itemBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.selected.contains(id) },
                set: { if $0 { model.selected.insert(id) } else { model.selected.remove(id) } })
    }
    private var allBinding: Binding<Bool> {
        Binding(get: { !category.items.isEmpty && category.items.allSatisfy { model.selected.contains($0.id) } },
                set: { on in
                    for i in category.items { if on { model.selected.insert(i.id) } else { model.selected.remove(i.id) } }
                })
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                Text(category.summary)
                Text("消すと: \(category.effect)").foregroundStyle(.secondary)
                if category.skipped > 0 {
                    Text("読み取れず除外: \(category.skipped) 件").font(.caption).foregroundStyle(.orange)
                }
                ForEach(category.items.prefix(100)) { item in
                    Toggle(isOn: itemBinding(item.id)) {
                        HStack {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(formatBytes(item.size)).foregroundStyle(.secondary)
                        }
                    }
                }
                if category.items.count > 100 {
                    Text("他 \(category.items.count - 100) 件（上位100件のみ個別表示。分類のチェックで全件選択）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Toggle(isOn: allBinding) {
                HStack {
                    Text(category.name).bold()
                    Spacer()
                    Text("\(category.items.count) 件").foregroundStyle(.secondary)
                    Text(formatBytes(category.size)).monospacedDigit()
                }
            }
        }
    }
}
