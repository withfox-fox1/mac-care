import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct VideoView: View {
    @Environment(AppState.self) private var state

    private func statusText(_ j: CompressQueue.Job) -> String {
        switch j.status {
        case .waiting: return "待機中"
        case .running, .paused:
            let pct = Int(j.progress * 100)
            let eta = j.eta.map { " / 残り約 \(Self.fmt($0))" } ?? ""
            return (j.status == .paused ? "一時停止中 " : "変換中 ") + "\(pct)%" + eta
        case .done(let s): return "完了（\(formatBytes(s)) 削減）"
        case .skipped(let r): return "スキップ: \(r)"
        case .failed(let r): return "失敗: \(r)"
        case .cancelled: return "中止"
        }
    }
    static func fmt(_ t: TimeInterval) -> String {
        let s = Int(t); return s >= 3600 ? "\(s / 3600)時間\(s % 3600 / 60)分" : s >= 60 ? "\(s / 60)分\(s % 60)秒" : "\(s)秒"
    }

    var body: some View {
        @Bindable var q = state.compressQueue
        PaneScaffold(item: .compress, subtitle: "HEVC に変換し、検証後に元ファイルをゴミ箱へ移動します。") {
            Picker("画質", selection: $q.preset) {
                ForEach(VideoPreset.allCases) { Text($0.label).tag($0) }
            }.frame(width: 240).disabled(q.isRunning)
            Button("追加…") { addVideos(q) }.buttonStyle(.secondary)
            Button("完了を消去") { q.clearFinished() }.buttonStyle(.secondary)
            Button(q.isPaused ? "再開" : "一時停止") { q.togglePause() }.buttonStyle(.secondary).disabled(!q.isRunning)
            Button("中止") { q.abort() }.buttonStyle(.secondary).disabled(!q.isRunning)
            Button("開始") { q.start() }.buttonStyle(.primary)
                .disabled(q.isRunning || !q.jobs.contains { $0.status == .waiting })
        } content: {
            VStack(spacing: 0) {
                if let msg = q.message { NoticeText(text: msg) }
                if q.jobs.isEmpty {
                    EmptyStateView(symbol: "film.fill", color: Theme.video, message: "キューは空です。\n「大容量ファイル」から動画を追加するか、動画を選択してください。") {
                        Button("動画を追加…") { addVideos(q) }.buttonStyle(.primary)
                    }
                } else {
                    List(q.jobs) { j in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(j.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(j.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.head)
                            if j.status == .running || j.status == .paused { ProgressView(value: j.progress) }
                            Text(statusText(j)).font(.caption)
                                .foregroundStyle({ if case .failed = j.status { return Theme.danger }; return Theme.secondary }())
                        }.padding(.vertical, 2)
                    }
                    .themedList()
                }
            }
        }
    }

    private func addVideos(_ q: CompressQueue) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie, UTType(filenameExtension: "m4v") ?? .movie]
        if p.runModal() == .OK { q.add(p.urls) }
    }
}
