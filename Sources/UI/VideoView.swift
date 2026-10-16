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
                CompressCandidatesCard()
                if !q.jobs.isEmpty { QueueSummaryCard(summary: q.summary, running: q.isRunning, paused: q.isPaused) }
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

/// キュー全体の進み具合（何本中何本・全体の%・残り時間・終了予定）
struct QueueSummaryCard: View {
    let summary: QueueSummary
    let running: Bool
    let paused: Bool

    private var finishText: String {
        guard let f = summary.finishAt else { return "" }
        let cal = Calendar.current
        let day = cal.isDateInToday(f) ? "" : cal.isDateInTomorrow(f) ? "明日 " : f.formatted(.dateTime.month().day()) + " "
        return "終了予定 \(day)\(f.formatted(.dateTime.hour().minute()))"
    }

    var body: some View {
        CardView {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(summary.done) / \(summary.total) 本完了")
                        .font(.system(size: 20, weight: .heavy)).monospacedDigit()
                    if summary.failedOrSkipped > 0 {
                        Text("失敗・スキップ \(summary.failedOrSkipped) 本").font(.caption).foregroundStyle(Theme.warn)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(summary.fraction.map { ETAFormat.percent($0) } ?? "—")
                            .font(.system(size: 16, weight: .bold)).monospacedDigit()
                        Text(paused ? "一時停止中" : running ? ETAFormat.text(summary.remaining) : "停止中")
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                        Spacer()
                        if running && !paused && !finishText.isEmpty {
                            Text(finishText).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.accentText)
                        }
                    }
                    ScanProgressBar(fraction: summary.fraction ?? 0)
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
    }
}

/// 圧縮候補（HEVC 以外の 100MB 以上の動画）。チェックしたものをまとめてキューへ追加する。
struct CompressCandidatesCard: View {
    @Environment(AppState.self) private var state

    private var m: CompressCandidatesModel { state.compressCandidates }
    private var q: CompressQueue { state.compressQueue }

    /// キュー内（待機・実行中・一時停止・完了）のファイルは候補から外す
    private var queuedPaths: Set<String> {
        Set(q.jobs.compactMap { j -> String? in
            switch j.status {
            case .waiting, .running, .paused, .done: return j.url.path
            default: return nil
            }
        })
    }
    private var visible: [CompressCandidate] { CompressEstimator.visible(m.candidates, excludingPaths: queuedPaths) }
    private var chosen: [CompressCandidate] { visible.filter { m.selected.contains($0.id) } }

    var body: some View {
        let list = visible, picked = chosen
        CardView(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("圧縮候補（\(list.count) 本・約 \(formatBytes(CompressEstimator.totalSaving(picked))) 空く見込み）")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    Button("再検索") { Task { await m.scan(settings: state.settings) } }
                        .buttonStyle(.secondary).fixedSize().disabled(m.scanning)
                    Button("すべて選択") { m.selected = Set(list.map(\.id)) }
                        .buttonStyle(.secondary).fixedSize().disabled(list.isEmpty)
                    Button("選択解除") { m.selected = [] }
                        .buttonStyle(.secondary).fixedSize().disabled(picked.isEmpty)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("見込みは目安です（HEVC 変換後は概ね 1.8〜3.4 Mbps。実際の削減量は動画の内容で変わります）。")
                        .font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                    Spacer(minLength: 8)
                    Button("選択した動画を圧縮（\(picked.count) 本）") { compress(picked) }
                        .buttonStyle(.primaryCompact).fixedSize().disabled(picked.isEmpty)
                }
                if m.scanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("候補を検索しています…").font(.callout).foregroundStyle(Theme.secondary)
                    }.padding(.vertical, 6)
                } else if !m.hasScanned {
                    Text("まだ検索していません。「再検索」で候補を探します。").font(.callout).foregroundStyle(Theme.secondary).padding(.vertical, 6)
                } else if list.isEmpty {
                    Text("圧縮候補はありません（100MB 以上の HEVC 以外の動画が見つかりませんでした）。")
                        .font(.callout).foregroundStyle(Theme.secondary).padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(list) { c in row(c) }
                        }
                    }
                    .frame(maxHeight: 190)
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
        .task { if !m.hasScanned && !m.scanning { await m.scan(settings: state.settings) } }
    }

    private func row(_ c: CompressCandidate) -> some View {
        let on = Binding(get: { m.selected.contains(c.id) },
                         set: { if $0 { m.selected.insert(c.id) } else { m.selected.remove(c.id) } })
        return HStack(spacing: 10) {
            Toggle("", isOn: on).labelsHidden().toggleStyle(.checkbox).fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).lineLimit(1).truncationMode(.middle)
                Text(c.folder).font(.system(size: 10.5)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.head)
                if c.isLowBitrate {
                    Text("ビットレートが低く、圧縮効果は小さめです").font(.system(size: 10.5)).foregroundStyle(Theme.warn).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if c.isLowBitrate { StatusBadge(kind: .warn, "低ビットレート").fixedSize() }
            Text(CompressEstimator.bitrateText(c.bitrate))
                .font(.caption).monospacedDigit().foregroundStyle(Theme.secondary).fixedSize()
            Text("\(formatBytes(c.size)) → 約 \(c.estimatedOutput.map { formatBytes($0) } ?? "不明")")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit().fixedSize()
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func compress(_ targets: [CompressCandidate]) {
        let urls = targets.map(\.url)   // 確認時点の選択で固定
        let running = q.isRunning
        let msg = "\(targets.count) 本 / 合計 \(formatBytes(CompressEstimator.totalSize(targets)))\n"
            + "見込み: 約 \(formatBytes(CompressEstimator.totalSaving(targets))) 削減（目安）\n"
            + "検証に合格した元ファイルはゴミ箱へ移動します。"
            + (running ? "\n実行中のキューの末尾に追加します。" : "")
            + "\n" + targets.prefix(6).map { "・" + $0.name }.joined(separator: "\n")
            + (targets.count > 6 ? "\n…ほか \(targets.count - 6) 本" : "")
        Task {
            await Confirm.destructive(title: "選択した \(targets.count) 本を圧縮しますか？", message: msg,
                                      button: running ? "キューに追加" : "圧縮を開始", snapshot: urls) { urls in
                q.add(urls)
                m.remove(paths: Set(urls.map(\.path)))
                if !q.isRunning { q.start() }
            }
        }
    }
}
