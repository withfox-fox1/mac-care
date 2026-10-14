import SwiftUI
import AppKit

struct LargeFilesView: View {
    @Environment(AppState.self) private var state
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\LargeFile.size, order: .reverse)]
    @State private var confirmTrash = false

    private var selectedFiles: [LargeFile] { state.largeFiles.files.filter { selection.contains($0.id) } }

    var body: some View {
        let m = state.largeFiles
        VStack(spacing: 0) {
            HStack {
                Button(m.hasScanned ? "再スキャン" : "スキャン") {
                    Task { await m.scan(settings: Settings.load()) }
                }.disabled(m.scanning)
                if m.scanning { ProgressView().controlSize(.small); Text("検索中…").foregroundStyle(.secondary) }
                else if m.hasScanned { Text(m.info).foregroundStyle(.secondary) }
                Spacer()
                Button("Finderで表示") {
                    NSWorkspace.shared.activateFileViewerSelecting(selectedFiles.map(\.url))
                }.disabled(selection.isEmpty)
                Button("圧縮キューへ追加") {
                    let n = state.compressQueue.add(selectedFiles.filter(\.isVideo).map(\.url))
                    m.message = n > 0 ? "\(n) 件を圧縮キューに追加しました。" : "追加できる動画がありません。"
                }.disabled(!selectedFiles.contains(where: \.isVideo))
                Button("ゴミ箱へ") { confirmTrash = true }.disabled(selection.isEmpty)
            }
            .padding()
            if let msg = m.message { Text(msg).font(.caption).foregroundStyle(.secondary).padding(.bottom, 6) }
            Divider()
            if !m.hasScanned && !m.scanning {
                ContentUnavailableView("スキャンを実行してください", systemImage: "externaldrive",
                                       description: Text("設定の閾値以上のファイルを検索します（~/Library・隠しフォルダは除外）。"))
            } else {
                Table(m.files.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("名前", value: \.name) { Text($0.name).lineLimit(1).truncationMode(.middle) }
                    TableColumn("場所", value: \.folder) { Text($0.folder).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary) }
                    TableColumn("サイズ", value: \.size) { Text(formatBytes($0.size)).monospacedDigit() }.width(90)
                    TableColumn("最終使用日", value: \.lastUsed) {
                        Text($0.lastUsed.formatted(date: .abbreviated, time: .omitted))
                    }.width(110)
                    TableColumn("種類", value: \.kind) { Text($0.kind) }.width(130)
                }
            }
        }
        .navigationTitle("大容量ファイル")
        .alert("選択した \(selection.count) 件をゴミ箱へ移動しますか？", isPresented: $confirmTrash) {
            Button("ゴミ箱へ移動", role: .destructive) {
                let t = selectedFiles
                Task { await m.trash(t); selection = [] }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("合計 \(formatBytes(selectedFiles.reduce(0) { $0 + $1.size }))")
        }
    }
}
