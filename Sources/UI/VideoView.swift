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
        PaneScaffold(item: .compress, subtitle: "画質を保ったまま動画を小さくします。元の動画は、変換結果を確認してからゴミ箱へ移します。") {
            Picker("画質", selection: $q.preset) {
                ForEach(VideoPreset.allCases) { Text($0.label).tag($0) }
            }.frame(width: 240).disabled(q.isRunning).help(q.preset.detail)
            Button("動画を追加…") { addVideos(q) }.buttonStyle(.secondary).fixedSize()
        } content: {
            VStack(spacing: 0) {
                if let msg = q.message { NoticeText(text: msg) }
                CompressCandidatesCard()
                if !q.jobs.isEmpty {
                    QueueSummaryCard(queue: q, startIsPrimary: CompressCandidatesCard.picked(state).isEmpty)
                }
                if q.jobs.isEmpty {
                    EmptyStateView(symbol: "film.fill", color: Theme.video, message: "上の候補から選ぶか、［動画を追加…］で動画を選んでください。") {
                        EmptyView()
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

/// キュー全体の進み具合（何本中何本・全体の%・残り時間・終了予定）と、キューの操作ボタン
struct QueueSummaryCard: View {
    let queue: CompressQueue
    /// 「圧縮を開始」を主ボタンにするか（候補を選択中は候補カード側が主ボタン）
    var startIsPrimary = true

    private var summary: QueueSummary { queue.summary }
    private var running: Bool { queue.isRunning }
    private var paused: Bool { queue.isPaused }

    private var finishText: String {
        guard let f = summary.finishAt else { return "" }
        let cal = Calendar.current
        let day = cal.isDateInToday(f) ? "" : cal.isDateInTomorrow(f) ? "明日 " : f.formatted(.dateTime.month().day()) + " "
        return "終了予定 \(day)\(f.formatted(.dateTime.hour().minute()))"
    }

    /// 完了した分の合計削減量
    private var totalSaved: Int64 {
        queue.jobs.reduce(0) { if case .done(let s) = $1.status { return $0 + s } else { return $0 } }
    }
    private var hasWaiting: Bool { queue.jobs.contains { $0.status == .waiting } }
    private var hasFinished: Bool {
        queue.jobs.contains { switch $0.status { case .waiting, .running, .paused: return false; default: return true } }
    }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 10) {
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
                if !running && summary.done > 0 {
                    Text("\(summary.done) 本完了・合計 \(formatBytes(totalSaved)) 削減。元の動画はゴミ箱にあります")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 8) {
                    if running {
                        Button(paused ? "再開" : "一時停止") { queue.togglePause() }.buttonStyle(.secondary).fixedSize()
                        Button("中止") { queue.abort() }.buttonStyle(.secondary).fixedSize()
                    } else if hasWaiting {
                        if startIsPrimary {
                            Button("圧縮を開始") { queue.start() }.buttonStyle(.primaryCompact).fixedSize()
                        } else {
                            Button("圧縮を開始") { queue.start() }.buttonStyle(.secondary).fixedSize()
                        }
                    }
                    if hasFinished && !running {
                        Button("完了を消去") { queue.clearFinished() }.buttonStyle(.secondary).fixedSize()
                    }
                    Spacer(minLength: 0)
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

    /// 現在チェックされている候補（VideoView が主ボタンの出し分けに使う）
    static func picked(_ state: AppState) -> [CompressCandidate] {
        let paths = Set(state.compressQueue.jobs.compactMap { j -> String? in
            switch j.status { case .waiting, .running, .paused, .done: return j.url.path; default: return nil }
        })
        let m = state.compressCandidates
        return CompressEstimator.visible(m.candidates, excludingPaths: paths).filter { m.selected.contains($0.id) }
    }

    private func headline(_ list: [CompressCandidate], _ picked: [CompressCandidate]) -> String {
        guard !picked.isEmpty else { return "圧縮候補（\(list.count) 本）" }
        let saving = CompressEstimator.totalSaving(picked)
        return "圧縮候補（\(list.count) 本・" + (saving > 0 ? "\(CompressEstimator.savingText(saving)) 空く見込み" : "削減はわずか") + "）"
    }

    /// 「すべて」チェックボックスの状態（全選択・一部選択・未選択）
    private func allSymbol(_ list: [CompressCandidate], _ picked: [CompressCandidate]) -> String {
        picked.isEmpty ? "square" : picked.count == list.count ? "checkmark.square.fill" : "minus.square.fill"
    }

    var body: some View {
        let list = visible, picked = chosen
        CardView(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        if picked.count == list.count { m.selected = [] } else { m.selected = Set(list.map(\.id)) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: allSymbol(list, picked)).font(.system(size: 15))
                                .foregroundStyle(picked.isEmpty ? Theme.secondary : Theme.accentText)
                            Text("すべて").font(.system(size: 12.5, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain).fixedSize().disabled(list.isEmpty)
                    .accessibilityLabel("すべて選択").accessibilityValue(picked.isEmpty ? "未選択" : picked.count == list.count ? "全選択" : "一部選択")
                    Text(headline(list, picked))
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    Button("再スキャン") { Task { await m.scan(settings: state.settings) } }
                        .buttonStyle(.secondary).fixedSize().disabled(m.scanning)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("見込みは目安です。動画の内容により変わります。")
                        .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("選択した動画を圧縮（\(picked.count) 本）") { compress(picked) }
                        .buttonStyle(.primaryCompact).fixedSize().disabled(picked.isEmpty)
                }
                if m.scanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("候補をスキャンしています…").font(.callout).foregroundStyle(Theme.secondary)
                    }.padding(.vertical, 6)
                } else if !m.hasScanned {
                    Text("まだスキャンしていません。「再スキャン」で候補を探します。").font(.callout).foregroundStyle(Theme.secondary).padding(.vertical, 6)
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
            Toggle("", isOn: on).labelsHidden().toggleStyle(.checkbox).fixedSize().accessibilityLabel(c.name)
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
            + "見込み: \(CompressEstimator.savingText(CompressEstimator.totalSaving(targets))) 削減（目安）\n"
            + "元の動画は、変換結果を確認してからゴミ箱へ移します（ゴミ箱から元に戻せます）。"
            + (running ? "\n実行中のキューの末尾に追加します。" : "")
            + "\n" + targets.prefix(6).map { "・" + $0.name }.joined(separator: "\n")
            + (targets.count > 6 ? "\n…ほか \(targets.count - 6) 本" : "")
        Task {
            await Confirm.destructive(title: "選択した \(targets.count) 本を圧縮しますか？", message: msg,
                                      button: running ? "キューに追加" : "圧縮を開始", snapshot: urls, undoable: false) { urls in
                q.add(urls)
                m.remove(paths: Set(urls.map(\.path)))
                if !q.isRunning { q.start() }
            }
        }
    }
}
