import SwiftUI
import AppKit

struct LargeFilesView: View {
    @Environment(AppState.self) private var state
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\LargeFile.size, order: .reverse)]

    private var selectedFiles: [LargeFile] { state.largeFiles.files.filter { selection.contains($0.id) } }

    var body: some View {
        let m = state.largeFiles
        PaneScaffold(item: .largeFiles, subtitle: "設定の閾値以上のファイルを検索します（システム用のフォルダは除外）。") {
            Button(m.hasScanned ? "再スキャン" : "スキャン") {
                Task { await m.scan(settings: Settings.load()) }
            }.prominentButton(!m.hasScanned).fixedSize().disabled(m.scanning)
                .help(m.scanning ? "スキャン中です" : "")
        } content: {
            VStack(spacing: 0) {
                if m.scanning {
                    ScanActivity(text: "大きなファイルを探しています…")
                } else if m.hasScanned || m.message != nil {
                    StatusStrip(text: [m.info, m.message ?? ""].filter { !$0.isEmpty }.joined(separator: "　"),
                                dismiss: m.message == nil ? nil : { m.message = nil })
                    if m.hasScanned { LastScanNote(date: m.lastScannedAt) }
                }
                if !m.hasScanned && !m.scanning {
                    ScanEmptyState(symbol: "externaldrive.fill", color: Theme.largeFiles,
                                   what: "設定の閾値以上の大きなファイルを探して、一覧にします。",
                                   durationKey: "largeFiles") { Task { await m.scan(settings: Settings.load()) } }
                } else if !m.hasScanned {
                    Color.clear.frame(maxHeight: .infinity)
                } else {
                    Table(m.files.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                        TableColumn("名前", value: \.name) { Text($0.name).lineLimit(1).truncationMode(.middle) }
                        TableColumn("場所", value: \.folder) { Text($0.folder).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary) }
                        TableColumn("サイズ", value: \.size) { Text(formatBytes($0.size)).monospacedDigit() }.width(90)
                        TableColumn("最終使用日", value: \.lastUsed) {
                            Text($0.lastUsed.formatted(date: .abbreviated, time: .omitted))
                        }.width(110)
                        TableColumn("種類", value: \.kind) { Text($0.isHEVC ? "\($0.kind)（圧縮済み）" : $0.kind) }.width(170)
                    }
                    .themedList().alternatingRowBackgrounds(.enabled)
                }
                FooterBar {
                    Text("選択中: \(selection.count) 件 / \(formatBytes(selectedFiles.reduce(0) { $0 + $1.size }))").foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Finderで表示") {
                        NSWorkspace.shared.activateFileViewerSelecting(selectedFiles.map(\.url))
                    }.buttonStyle(.secondary).fixedSize().disabled(selection.isEmpty)
                        .help(selection.isEmpty ? "ファイルを選択してください" : "")
                    // 主ボタンは選択内容で 1 つだけ: 圧縮対象の動画だけを選んでいるときは「圧縮キューへ追加」
                    let compressOnly = !selectedFiles.isEmpty && selectedFiles.allSatisfy(\.needsCompression)
                    Button("圧縮キューへ追加") {
                        let n = state.compressQueue.add(selectedFiles.filter(\.needsCompression).map(\.url))
                        m.message = n > 0 ? "\(n) 件を圧縮キューに追加しました。" : "追加できる動画がありません（圧縮済みの動画は対象外です）。"
                    }.prominentButton(compressOnly, compact: true).fixedSize()
                        .disabled(!selectedFiles.contains(where: \.needsCompression))
                        .help(selection.isEmpty ? "ファイルを選択してください"
                              : !selectedFiles.contains(where: \.needsCompression) ? "圧縮できる動画が選択されていません（圧縮済みの動画は対象外です）" : "")
                    Button("ゴミ箱へ…") {
                        let targets = selectedFiles                              // 確認時点の内容で固定
                        let roots = Settings.load().largeFileRoots.map { URL(fileURLWithPath: $0) }
                        let msg = "\(targets.count) 件 / 合計 \(formatBytes(targets.reduce(0) { $0 + $1.size }))\n"
                            + targets.prefix(8).map { "・" + $0.name }.joined(separator: "\n")
                            + (targets.count > 8 ? "\n…ほか \(targets.count - 8) 件" : "")
                        Task {
                            let done = await Confirm.destructive(title: "選択した \(targets.count) 件をゴミ箱へ移動しますか？", message: msg,
                                                                 button: "ゴミ箱へ移動", snapshot: targets) { await m.trash($0, roots: roots) }
                            if done { selection = [] }
                        }
                    }.buttonStyle(.secondaryDestructive).fixedSize().disabled(selection.isEmpty)
                        .help(selection.isEmpty ? "ファイルを選択してください" : "")
                }
            }
        }
        .task {
            if state.consumeAutoScan("largeFiles") {
                await m.scan(settings: Settings.load()); state.markAutoScanDone("largeFiles")
            }
        }
    }
}
