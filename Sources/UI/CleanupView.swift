import SwiftUI
import AppKit

struct CleanupView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.cleanup
        PaneScaffold(item: .cleanup, subtitle: "不要なキャッシュ・ログ・古い開発用の一時フォルダを確認し、ゴミ箱へ移動します。") {
            if m.scanning || m.cleaning {
                ProgressView().controlSize(.small)
                Text(m.cleaning ? "ゴミ箱へ移動中…" : m.progressText).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(width: 220, alignment: .leading)
            }
            if m.excludedCount > 0 { StatusBadge(kind: .info, "除外 \(m.excludedCount) 件") }
            if let f = m.lastFreed { StatusBadge(kind: .ok, "解放: \(formatBytes(f))") }
            Button(m.hasScanned ? "再スキャン" : "スキャン") {
                Task { await m.scan(settings: Settings.load()) }
            }
            .buttonStyle(.primary)
            .disabled(m.scanning || m.cleaning)
        } content: {
            VStack(spacing: 0) {
                if let msg = m.message { NoticeText(text: msg) }
                if !m.hasScanned && !m.scanning {
                    EmptyStateView(symbol: "sparkles", color: Theme.cleanup, message: "スキャンして、掃除できるものを確認しましょう。\n削除前に内容を確認でき、削除はゴミ箱への移動です。") {
                        Button("スキャン") { Task { await m.scan(settings: Settings.load()) } }.buttonStyle(.primary)
                    }
                } else {
                    List {
                        Section("不要データ") {
                            ForEach(m.categories) { CategoryRow(category: $0, model: m) }
                            if m.categories.isEmpty && !m.scanning { Text("掃除できる項目はありません").foregroundStyle(.secondary) }
                        }
                        Section("ゴミ箱") { trashSection(m) }
                    }
                    .themedList()
                }
                FooterBar {
                    Text("選択中: \(m.selectedCount) 件 / \(formatBytes(m.selectedSize))").foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("選択した項目をゴミ箱へ…") {
                        let jobs = m.snapshotSelected()   // 確認時点の内容で固定
                        let msg = CleanupModel.summary(of: jobs, categories: m.categories)
                        Task {
                            await Confirm.destructive(title: "選択した項目をゴミ箱へ移動しますか？", message: msg,
                                                      button: "ゴミ箱へ移動", snapshot: jobs) {
                                await m.cleanItems($0, settings: Settings.load())
                            }
                        }
                    }
                        .buttonStyle(.primaryCompact)
                        .disabled(m.selectedCount == 0 || m.scanning || m.cleaning)
                }
            }
        }
        .task {
            if state.consumeAutoScan("cleanup") {
                await m.scan(settings: Settings.load()); state.markAutoScanDone("cleanup")
            }
        }
    }

    @ViewBuilder private func trashSection(_ m: CleanupModel) -> some View {
        if m.trashReadable {
            HStack {
                Text("ゴミ箱の中身: \(formatBytes(m.trashSize))")
                Spacer()
                Button("ゴミ箱を空にする") {
                    let size = m.trashSize
                    Task {
                        await Confirm.destructive(title: "ゴミ箱を空にしますか？",
                                                  message: "この操作は取り消せません。ゴミ箱内の \(formatBytes(size)) が完全に削除されます。",
                                                  button: "完全に削除", snapshot: size, undoable: false) { _ in
                            await m.emptyTrash(settings: Settings.load())
                        }
                    }
                }.buttonStyle(.secondary).disabled(m.trashSize == 0)
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
                }.buttonStyle(.secondary)
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
                Text("消すと: \(category.effect)").foregroundStyle(Theme.secondary)
                if !category.excluded.isEmpty {
                    DisclosureGroup("除外した項目 \(category.excluded.count) 件") {
                        ForEach(category.excluded, id: \.self) { e in
                            HStack {
                                Text(e.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(e.reason).foregroundStyle(.secondary)
                            }.font(.caption)
                        }
                    }.font(.caption)
                }
                if category.skipped > 0 {
                    Text("読み取れず除外: \(category.skipped) 件").font(.caption).foregroundStyle(Theme.warn)
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
