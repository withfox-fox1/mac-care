import SwiftUI

/// ダッシュボード（旧スマートケア）。スキャンロジックは SmartCareModel を共有する。
struct DashboardView: View {
    @Environment(AppState.self) private var state

    private func go(_ section: String) { state.requestedSection = section }

    private var ringTint: Color? {
        switch HealthScore.level(state.healthScore) { case .good: nil; case .caution: Theme.warn; case .critical: Theme.danger }
    }

    var body: some View {
        let m = state.smartCare
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                top(m)
                cards(m)
                HStack(alignment: .top, spacing: 12) {
                    recommendationsCard.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    recentCard.frame(minWidth: 280, idealWidth: 330, maxWidth: 360, maxHeight: .infinity, alignment: .top)
                }.fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 24)
        }
        .task {
            await state.refreshNotificationStatus()
            await state.security.refreshStatus()
            if state.consumeAutoScan("smartCare") {
                await m.run(state: state); state.markAutoScanDone("smartCare")
            }
            // おすすめ（動画圧縮）の判定用に、読み取り専用の大容量ファイル検索を一度だけ行う
            if !state.largeFiles.hasScanned && !state.largeFiles.scanning && !m.running {
                await state.largeFiles.scan(settings: Settings.load())
            }
        }
        .onAppear { state.refresh() }
        .onChange(of: m.running) { _, now in if !now { state.refresh() } }
    }

    // MARK: 上部（スコア・見出し・実行ボタン）

    private func top(_ m: SmartCareModel) -> some View {
        let score = state.healthScore
        let ran = state.hasHealthScore
        let ringScore: Int? = ran ? score : nil
        let heading = VStack(alignment: .leading, spacing: 6) {
            Text(ran ? HealthScore.headline(score) : "まずはスマートケアを実行しましょう").font(.system(size: 26, weight: .heavy))
            Text(summary).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // 右側（実行ボタン／進捗）。縮めず、収まらないときは見出しの下へ回す
        let trailing = { (align: HorizontalAlignment) in
            VStack(alignment: align, spacing: 8) {
                if m.running {
                    HStack(alignment: .bottom, spacing: 12) {
                        ScanProgressBlock(fraction: m.progress, etaText: m.etaText, stepText: m.statusText,
                                          detailText: m.activeSteps.contains(.security) ? state.security.detail : "", width: 250)
                        Button("中止") { m.cancel(state: state) }.buttonStyle(.secondary).fixedSize()
                    }
                } else {
                    let run = Button { Task { await m.run(state: state) } } label: {
                        Label("スマートケアを実行", systemImage: "arrow.triangle.2.circlepath")
                    }
                    // 未実行のときは大きく目立たせる（実行後は通常サイズ）
                    if ran { run.buttonStyle(.primary).fixedSize() } else { run.buttonStyle(.primaryLarge).fixedSize() }
                }
                Text(meta(m)).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                Text(FullScanLabel.text(state.security.lastFullAt)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            .fixedSize()
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 22) {
                ScoreRing(score: ringScore, tint: ran ? ringTint : nil)
                heading
                Spacer(minLength: 12)
                trailing(.trailing)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 22) {
                    ScoreRing(score: ringScore, tint: ran ? ringTint : nil)
                    heading
                }
                trailing(.leading)
            }
        }
    }

    private func meta(_ m: SmartCareModel) -> String {
        guard let r = m.result else { return "まだ実行していません" }
        return "前回 \(ShortDate.format(r.date)) ・ \(ShortDate.duration(r.seconds))"
    }

    private var summary: String {
        guard let r = state.smartCare.result else { return "スマートケアを実行すると、Mac の状態をまとめて確認できます。\nスキャンでは何も削除しません。" }
        let login = r.newLoginItems + r.changedLoginItems
        let l1 = (r.threats == 0 ? "脅威なし" : "脅威 \(r.threats) 件") + "・" + (login == 0 ? "ログイン項目の変化なし。" : "ログイン項目に変化が \(login) 件。")
        let l2: String
        if let v = state.recommendations.first(where: { $0.kind == .videos }) {
            let vb = state.recommendationInput.videoBytes
            _ = v
            l2 = "大容量の動画を圧縮すると、さらに約\(formatBytes(Recommendations.videoSavings(vb)))空けられます。"
        } else if let d = state.disk {
            l2 = "空き容量は \(formatBytes(d.available)) / \(formatBytes(d.total)) です。"
        } else { l2 = "" }
        return [l1, l2].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: 4 枚のカード

        private func stepState(_ s: SmartCareStep, _ m: SmartCareModel) -> CardStepState? {
        guard m.running else { return nil }
        if m.doneSteps.contains(s) { return .done }
        return m.activeSteps.contains(s) ? .checking : .waiting
    }

    private func cards(_ m: SmartCareModel) -> some View {
        let r = m.result
        let login = (r?.newLoginItems ?? 0) + (r?.changedLoginItems ?? 0)
        let videos = state.largeFiles.files.filter(\.needsCompression).count
        let junk = r?.junkBytes ?? 0
        let notRun = r == nil && !m.running
        return HStack(alignment: .top, spacing: 12) {
            StatusCard(title: "不要データ", symbol: "sparkles", color: Theme.cleanup, step: stepState(.cleanup, m),
                       value: r.map { formatBytes($0.junkBytes) },
                       detail: r.map { "すぐ掃除できるもの \(formatBytes($0.safeJunkBytes))" },
                       badge: r == nil ? (.info, "未実行") : junk < 1_000_000_000 ? (.ok, "きれい") : (.warn, "掃除できます"),
                       tap: { go("cleanup") }) {
                if let r, r.safeJunkBytes > 0 {
                    Button("すぐ掃除（\(formatBytes(r.safeJunkBytes))）…") { trashSafe(r) }.buttonStyle(.secondary)
                        .disabled(state.cleanup.cleaning || m.running)
                        .help(m.running ? "スマートケアの実行中は掃除できません" : state.cleanup.cleaning ? "掃除中です" : "")
                }
            }
            StatusCard(title: "脅威", symbol: "checkmark.shield.fill", color: Theme.security, step: stepState(.security, m),
                       stepDetail: m.running ? state.security.detail : nil,
                       value: r.map { "\($0.threats) 件" },
                       detail: r.map { "最終確認 \(ShortDate.format($0.date))" },
                       badge: r == nil ? (.info, "未実行") : r!.threats == 0 ? (.ok, "保護中") : (.danger, "要対応"),
                       tap: { go("security") }) { EmptyView() }
            StatusCard(title: "ログイン項目", symbol: "power", color: Theme.loginItems, step: stepState(.loginItems, m),
                       value: r.map { _ in state.loginItems.hasScanned ? "\(state.loginItems.items.count) 件" : "変化 \(login) 件" },
                       detail: r.map { "新規 \($0.newLoginItems)・変更 \($0.changedLoginItems)" },
                       badge: r == nil ? (.info, "未実行") : login == 0 ? (.ok, "変化なし") : (.warn, "要確認"),
                       tap: { go("loginItems") }) { EmptyView() }
            StatusCard(title: "大容量ファイル", symbol: "externaldrive.fill", color: Theme.largeFiles, step: stepState(.largeFiles, m),
                       value: r.map { formatBytes($0.largeFileBytes) },
                       detail: r.map { "\($0.largeFileCount) 件" + (state.largeFiles.hasScanned ? "・うち動画 \(videos) 本" : "") },
                       badge: r == nil ? (.info, "未実行") : r!.largeFileCount == 0 ? (.ok, "なし") : (.warn, "要確認"),
                       tap: { go("largeFiles") }) { EmptyView() }
        }
        .fixedSize(horizontal: false, vertical: true)
        .opacity(notRun ? 0.55 : 1)   // 未実行のカードは薄く表示する
    }

    /// 不要データの掃除（Confirm.destructive 経由。確認時点の内容で固定）
    private func trashSafe(_ r: SmartCareResult) {
        let m = state.smartCare
        let jobs = SmartCare.safeJobs(state.cleanup.categories)
        let msg = CleanupModel.summary(of: jobs, categories: SmartCare.safeCategories(state.cleanup.categories))
        Task {
            await Confirm.destructive(title: "不要データをゴミ箱へ移動しますか？", message: msg,
                                      button: "ゴミ箱へ移動", snapshot: jobs) {
                await m.trashSafe($0, state: state)
            }
        }
    }

    // MARK: おすすめ・最近の操作

    private var recommendationsCard: some View {
        let recs = Array(state.recommendations.prefix(3))
        return CardView(padding: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("おすすめ").font(.system(size: 13, weight: .heavy)).foregroundStyle(Color(hex: "dff3f6")).padding(.bottom, 6)
                if recs.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).font(.system(size: 22))
                        Text("いまのところ対応が必要な項目はありません").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }.padding(.vertical, 8)
                }
                ForEach(Array(recs.enumerated()), id: \.element.id) { i, rec in
                    if i > 0 { ThemedDivider() }
                    RecommendationRow(rec: rec) { state.perform(rec.action) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// 履歴画面と同じグループ化で、同種の操作をまとめた直近 5 件
    private var recentRows: [HistoryRow] {
        // state.history は新しい順。グループ化は記録順（古い順）で受け取るため戻す。直近分だけ使う
        Array(HistoryGrouping.rows(from: Array(state.history.prefix(200).reversed())).prefix(5))
    }

    private var recentCard: some View {
        let items = recentRows
        return CardView(padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text("最近の操作").font(.system(size: 13, weight: .heavy)).foregroundStyle(Color(hex: "dff3f6")).padding(.bottom, 6)
                ForEach(Array(items.enumerated()), id: \.element.id) { i, row in
                    logRow(row, first: i == 0)
                }
                if items.isEmpty { simpleRow("履歴はまだありません", "", first: true) }
                if let d = state.disk {
                    simpleRow("空き容量", "\(formatBytes(d.available)) / \(formatBytes(d.total))", first: items.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// 「動画を圧縮・−1.84 GB」「14 項目をゴミ箱へ」の形。ファイル名は 2 行目に中央省略で出す
    private func logRow(_ row: HistoryRow, first: Bool) -> some View {
        let freed = HistoryFormat.freed(row.freedBytes).map { "・" + $0 } ?? ""
        return VStack(spacing: 0) {
            if !first { ThemedDivider() }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title + freed).font(.system(size: 12)).foregroundStyle(Color(hex: "cfe6ec"))
                        .lineLimit(1).truncationMode(.middle)
                    if let s = row.subtitle {
                        Text(s).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Text(ShortDate.format(row.date)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).fixedSize().layoutPriority(1)
            }
            .padding(.vertical, 7)
        }
    }

    private func simpleRow(_ l: String, _ r: String, first: Bool) -> some View {
        VStack(spacing: 0) {
            if !first { ThemedDivider() }
            HStack(spacing: 8) {
                Text(l).lineLimit(1).truncationMode(.middle).foregroundStyle(Color(hex: "cfe6ec"))
                Spacer(minLength: 8)
                Text(r).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize().layoutPriority(1)
            }
            .font(.system(size: 12)).padding(.vertical, 7)
        }
    }
}

/// おすすめ 1 行（ダッシュボード・パネル共通）
struct RecommendationRow: View {
    let rec: Recommendation
    let perform: () -> Void

    static func gradient(_ k: Recommendation.Kind) -> [Color] {
        switch k {
        case .videos: [Color(hex: "f59e0b"), Color(hex: "f97316")]
        case .cleanMyMac: [Color(hex: "ef4444"), Color(hex: "f97316")]
        case .threats: [Color(hex: "ef4444"), Color(hex: "dc2626")]
        case .junk: [Color(hex: "0ea5e9"), Color(hex: "3b82f6")]
        case .staleScan: [Color(hex: "14b8a6"), Color(hex: "3b82f6")]
        case .appUpdate: [Color(hex: "3b82f6"), Color(hex: "6366f1")]
        case .wakeSchedule: [Color(hex: "6366f1"), Color(hex: "8b5cf6")]
        case .notifications, .fullDiskAccess: [Color(hex: "10b981"), Color(hex: "14b8a6")]
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: Self.gradient(rec.kind), startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: rec.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.title).font(.system(size: 13, weight: .bold)).lineLimit(2)
                Text(rec.detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(rec.actionLabel, action: perform).buttonStyle(.secondary).fixedSize()
        }
        .padding(.vertical, 8)
    }
}

/// スキャン中の各ステップ状態
enum CardStepState { case waiting, checking, done }

/// ダッシュボードの状態カード（タップで該当ペインへ）
struct StatusCard<Extra: View>: View {
    let title: String
    let symbol: String
    let color: Color
    let step: CardStepState?
    var stepDetail: String? = nil
    let value: String?
    let detail: String?
    let badge: (BadgeKind, String)
    let tap: () -> Void
    @ViewBuilder var extra: Extra
    @State private var hovering = false

    private var accessibilityText: String {
        if let step { return step == .waiting ? "待機中" : step == .checking ? "チェック中" : "完了" }
        return [value ?? "未実行", detail ?? "", badge.1].filter { !$0.isEmpty }.joined(separator: "、")
    }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    IconTile(symbol: symbol, color: color, size: 24, filled: false)
                    Text(title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color(hex: "cfe6ec")).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    // カード全体を押せることを示す
                    Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(hovering ? Theme.accentText : Theme.secondary).accessibilityHidden(true)
                }
                if let step {
                    HStack(spacing: 8) {
                        if step == .checking { ProgressView().controlSize(.small) }
                        Text(step == .waiting ? "待機中" : step == .checking ? "チェック中" : "完了")
                            .font(.system(size: 20, weight: .heavy))
                            .foregroundStyle(step == .done ? Theme.ok : step == .checking ? Theme.text : Theme.secondary)
                    }.padding(.top, 10)
                    Text(step == .checking ? (stepDetail ?? " ") : " ").font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1).padding(.top, 4)
                    Color.clear.frame(height: 22).padding(.top, 10)
                } else {
                    Text(value ?? "—").font(.system(size: 26, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7).padding(.top, 10)
                    Text(detail ?? "スマートケアで表示されます").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                        .lineLimit(2, reservesSpace: true).padding(.top, 4)
                    // バッジとボタンは縮めない。横に収まらないときは縦に並べる
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            StatusBadge(kind: badge.0, badge.1).fixedSize()
                            Spacer(minLength: 4)
                            extra.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            StatusBadge(kind: badge.0, badge.1).fixedSize()
                            extra.fixedSize()
                        }
                    }.padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.teal.opacity(hovering ? 0.8 : 0), lineWidth: 1.5).allowsHitTesting(false))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onHover { hovering = $0 }
        .onTapGesture(perform: tap)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityText)
    }
}
