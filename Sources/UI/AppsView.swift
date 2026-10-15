import SwiftUI
import AppKit

struct AppsView: View {
    @Environment(AppState.self) private var state
    @State private var tab = 0
    @State private var selectedApp: String? = nil
    @State private var selectedLeftovers = Set<String>()

    private var app: InstalledApp? { state.apps.apps.first { $0.id == selectedApp } }

    var body: some View {
        let m = state.apps
        PaneScaffold(item: .apps, subtitle: "アプリと関連ファイルをまとめてゴミ箱へ移動します。Apple 製・実行中のアプリは対象外です。") {
            if m.scanning { ProgressView().controlSize(.small) }
            Picker("", selection: $tab) { Text("アプリ").tag(0); Text("残骸").tag(1) }
                .pickerStyle(.segmented).frame(width: 140).labelsHidden()
            Button(m.hasScanned ? "再スキャン" : "スキャン") { Task { await m.scan() } }
                .buttonStyle(.primary).disabled(m.scanning)
        } content: {
            VStack(spacing: 0) {
                if let msg = m.message { NoticeText(text: msg) }
                if !m.hasScanned && !m.scanning {
                    EmptyStateView(symbol: "command", color: Theme.apps, message: "/Applications と ~/Applications のアプリを調べます。") {
                        Button("スキャン") { Task { await m.scan() } }.buttonStyle(.primary)
                    }
                } else if tab == 0 { appsTab(m) } else { leftoversTab(m) }
            }
        }
        .task {
            if state.consumeAutoScan("apps") {
                await m.scan()
                if CommandLine.arguments.contains("--leftovers") { tab = 1 }   // 検証用: 残骸タブを開く
                state.markAutoScanDone("apps")
            }
        }
    }

    @ViewBuilder private func appsTab(_ m: AppsModel) -> some View {
        VStack(spacing: 0) {
            Table(m.apps, selection: $selectedApp) {
                TableColumn("名前") { a in
                    HStack { Text(a.name); if m.isRunning(a) { StatusBadge(kind: .warn, "実行中") } }
                }
                TableColumn("バージョン") { Text($0.version) }.width(90)
                TableColumn("サイズ") { Text($0.size == 0 ? "計算中…" : formatBytes($0.size)).monospacedDigit() }.width(80)
                TableColumn("最終使用日") { Text($0.lastUsed?.formatted(date: .abbreviated, time: .omitted) ?? "—") }.width(130)
                TableColumn("入手元") { Text($0.isAppStore ? "App Store" : "その他") }.width(80)
            }
            .themedList().alternatingRowBackgrounds(.enabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ThemedDivider()
            VStack(alignment: .leading, spacing: 6) {
                if let a = app {
                    HStack {
                        Text("\(a.name) の関連ファイル").bold()
                        Spacer()
                        Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([a.url]) }.buttonStyle(.secondary)
                        Button("アンインストール…") {
                            let plan = m.plan(for: a)   // 確認時点の内容で固定
                            let total = plan.related.reduce(0) { $0 + $1.size } + a.size
                            let msg = "アプリ本体と関連ファイル \(plan.related.count) 件（\(formatBytes(total))）をゴミ箱へ移動します。\n"
                                + plan.related.prefix(8).map { "・" + $0.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: "\n")
                            Task {
                                await Confirm.destructive(title: "「\(a.name)」をアンインストールしますか？", message: msg,
                                                          button: "ゴミ箱へ移動", snapshot: plan) { await m.uninstall($0); selectedApp = nil }
                            }
                        }
                            .buttonStyle(.secondaryDestructive).disabled(a.isApple || m.isRunning(a))
                    }
                    if a.isApple { Text("Apple 製アプリは削除できません。").font(.caption).foregroundStyle(Theme.secondary) }
                    else if m.isRunning(a) { Text("実行中のため削除できません。終了してから再度スキャンしてください。").font(.caption).foregroundStyle(Theme.warn) }
                    List(m.related) { r in
                        HStack {
                            if r.isProtected {
                                Image(systemName: "lock").foregroundStyle(Theme.secondary)
                            } else {
                                Toggle("", isOn: Binding(get: { m.selectedRelated.contains(r.id) },
                                                         set: { if $0 { m.selectedRelated.insert(r.id) } else { m.selectedRelated.remove(r.id) } }))
                                    .labelsHidden()
                            }
                            VStack(alignment: .leading) {
                                Text(r.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                                if r.isSystem { Text("管理者権限が必要なため表示のみ（Finder で開いて手動で削除）").font(.caption).foregroundStyle(Theme.secondary) }
                                else if r.kind == .bundlePrefix { Text("ID の前方一致のみ（既定では未選択。内容を確認してください）").font(.caption).foregroundStyle(Theme.warn) }
                                else if r.kind == .nameOnly { Text("名前のみ一致（既定では未選択）").font(.caption).foregroundStyle(Theme.warn) }
                            }
                            Spacer()
                            Text(formatBytes(r.size)).monospacedDigit().foregroundStyle(Theme.secondary)
                            if r.isSystem {
                                Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }.buttonStyle(.secondary)
                            }
                        }
                    }
                    .themedList()
                } else {
                    Text("アプリを選択すると関連ファイルを表示します。").foregroundStyle(Theme.secondary).padding()
                }
            }
            .padding(.horizontal).padding(.top, 8).frame(maxWidth: .infinity, minHeight: 200, maxHeight: 240, alignment: .topLeading)
        }
        .onChange(of: selectedApp) { _, _ in
            if let a = app { Task { await m.loadRelated(for: a) } } else { m.related = [] }
        }
    }

    @ViewBuilder private func leftoversTab(_ m: AppsModel) -> some View {
        VStack(spacing: 0) {
            List(m.leftovers, selection: $selectedLeftovers) { r in
                HStack {
                    VStack(alignment: .leading) {
                        Text(r.url.lastPathComponent)
                        Text(r.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption).foregroundStyle(Theme.secondary)
                        if r.displayOnly { Text("書類を含む可能性があるため表示のみ（Finder で確認してください）").font(.caption).foregroundStyle(Theme.warn) }
                    }
                    Spacer()
                    Text(formatBytes(r.size)).monospacedDigit().foregroundStyle(Theme.secondary)
                }
            }
            .themedList().alternatingRowBackgrounds(.enabled)
            FooterBar {
                Text("アンインストール済みアプリの残骸候補: \(m.leftovers.count) 件。内容を確認して選択してください。")
                    .font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                Button("選択した項目をゴミ箱へ…") {
                    let snap = Leftovers.deletable(m.leftovers.filter { selectedLeftovers.contains($0.id) })   // 確認時点の内容で固定
                    let msg = snap.prefix(10).map { "・" + $0.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: "\n")
                    Task {
                        let done = await Confirm.destructive(title: "選択した \(snap.count) 件をゴミ箱へ移動しますか？", message: msg,
                                                             button: "ゴミ箱へ移動", snapshot: snap) { await m.trashLeftovers($0) }
                        if done { selectedLeftovers = [] }
                    }
                }.buttonStyle(.secondaryDestructive).disabled(selectedLeftovers.isEmpty)
            }
        }
    }
}
