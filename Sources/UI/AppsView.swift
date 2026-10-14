import SwiftUI
import AppKit

struct AppsView: View {
    @Environment(AppState.self) private var state
    @State private var tab = 0
    @State private var selectedApp: String? = nil
    @State private var confirmUninstall = false
    @State private var selectedLeftovers = Set<String>()
    @State private var confirmLeftovers = false

    private var app: InstalledApp? { state.apps.apps.first { $0.id == selectedApp } }

    var body: some View {
        let m = state.apps
        PaneScaffold(title: "アプリケーション", subtitle: "アプリと関連ファイルをまとめてゴミ箱へ移動します。Apple 製・実行中のアプリは対象外です。") {
            if m.scanning { ProgressView().controlSize(.small) }
            Picker("", selection: $tab) { Text("アプリ").tag(0); Text("残骸").tag(1) }
                .pickerStyle(.segmented).frame(width: 140).labelsHidden()
            Button(m.hasScanned ? "再スキャン" : "スキャン") { Task { await m.scan() } }
                .buttonStyle(.borderedProminent).disabled(m.scanning)
        } content: {
            VStack(spacing: 0) {
                if let msg = m.message { Text(msg).foregroundStyle(.orange).padding(.vertical, 6) }
                if !m.hasScanned && !m.scanning {
                    ContentUnavailableView("スキャンを実行してください", systemImage: "square.grid.2x2",
                                           description: Text("/Applications と ~/Applications を調べます。"))
                } else if tab == 0 { appsTab(m) } else { leftoversTab(m) }
            }
        }
        .task { if state.consumeAutoScan("apps") { await m.scan(); state.markAutoScanDone("apps") } }
    }

    @ViewBuilder private func appsTab(_ m: AppsModel) -> some View {
        VStack(spacing: 0) {
            Table(m.apps, selection: $selectedApp) {
                TableColumn("名前") { a in
                    HStack { Text(a.name); if m.isRunning(a) { Text("実行中").font(.caption).foregroundStyle(.orange) } }
                }
                TableColumn("バージョン") { Text($0.version) }.width(90)
                TableColumn("サイズ") { Text(formatBytes($0.size)).monospacedDigit() }.width(80)
                TableColumn("最終使用日") { Text($0.lastUsed?.formatted(date: .abbreviated, time: .omitted) ?? "—") }.width(130)
                TableColumn("入手元") { Text($0.isAppStore ? "App Store" : "その他") }.width(80)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let a = app {
                    HStack {
                        Text("\(a.name) の関連ファイル").bold()
                        Spacer()
                        Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([a.url]) }
                        Button("アンインストール…", role: .destructive) { confirmUninstall = true }
                            .disabled(a.isApple || m.isRunning(a))
                    }
                    if a.isApple { Text("Apple 製アプリは削除できません。").font(.caption).foregroundStyle(.secondary) }
                    else if m.isRunning(a) { Text("実行中のため削除できません。終了してから再度スキャンしてください。").font(.caption).foregroundStyle(.orange) }
                    List(m.related) { r in
                        HStack {
                            if r.isSystem {
                                Image(systemName: "lock").foregroundStyle(.secondary)
                            } else {
                                Toggle("", isOn: Binding(get: { m.selectedRelated.contains(r.id) },
                                                         set: { if $0 { m.selectedRelated.insert(r.id) } else { m.selectedRelated.remove(r.id) } }))
                                    .labelsHidden()
                            }
                            VStack(alignment: .leading) {
                                Text(r.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                                if r.isSystem { Text("管理者権限が必要なため表示のみ（Finder で開いて手動で削除）").font(.caption).foregroundStyle(.secondary) }
                                else if r.kind == .nameOnly { Text("名前のみ一致（既定では未選択）").font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer()
                            Text(formatBytes(r.size)).monospacedDigit().foregroundStyle(.secondary)
                            if r.isSystem {
                                Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
                            }
                        }
                    }
                } else {
                    Text("アプリを選択すると関連ファイルを表示します。").foregroundStyle(.secondary).padding()
                }
            }
            .padding(.horizontal).padding(.top, 8).frame(maxWidth: .infinity, minHeight: 200, maxHeight: 240, alignment: .topLeading)
        }
        .onChange(of: selectedApp) { _, _ in
            if let a = app { Task { await m.loadRelated(for: a) } } else { m.related = [] }
        }
        .alert("「\(app?.name ?? "")」をアンインストールしますか？", isPresented: $confirmUninstall) {
            Button("ゴミ箱へ移動", role: .destructive) { if let a = app { Task { await m.uninstall(a); selectedApp = nil } } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            let sel = m.related.filter { m.selectedRelated.contains($0.id) }
            Text("アプリ本体と関連ファイル \(sel.count) 件（\(formatBytes(sel.reduce(0) { $0 + $1.size } + (app?.size ?? 0)))）をゴミ箱へ移動します。")
        }
    }

    @ViewBuilder private func leftoversTab(_ m: AppsModel) -> some View {
        VStack(spacing: 0) {
            List(m.leftovers, selection: $selectedLeftovers) { r in
                HStack {
                    VStack(alignment: .leading) {
                        Text(r.url.lastPathComponent)
                        Text(r.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatBytes(r.size)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("アンインストール済みアプリの残骸候補: \(m.leftovers.count) 件。内容を確認して選択してください。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("選択した項目をゴミ箱へ…") { confirmLeftovers = true }.disabled(selectedLeftovers.isEmpty)
            }.padding()
        }
        .alert("選択した \(selectedLeftovers.count) 件をゴミ箱へ移動しますか？", isPresented: $confirmLeftovers) {
            Button("ゴミ箱へ移動", role: .destructive) {
                let t = m.leftovers.filter { selectedLeftovers.contains($0.id) }
                Task { await m.trashLeftovers(t); selectedLeftovers = [] }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }
}
