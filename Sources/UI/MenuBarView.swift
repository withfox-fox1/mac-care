import SwiftUI
import AppKit

/// ウィンドウの表示/非表示を検知する（MenuBarExtra の .window スタイルは onAppear/onDisappear が当てにならないため）
struct WindowVisibilityObserver: NSViewRepresentable {
    var onChange: (Bool) -> Void

    final class V: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var tokens: [NSObjectProtocol] = []
        private var last: Bool? = nil

        private func report() {
            guard let w = window else { return }
            let v = w.isVisible && w.occlusionState.contains(.visible)
            guard v != last else { return }
            last = v; onChange(v)
        }
        override func viewDidMoveToWindow() {
            tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
            guard let w = window else { return }
            for n in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                      NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] note in
                    // willClose の時点ではまだ isVisible が true のため、閉じる通知は即座に非表示扱いにする
                    if note.name == NSWindow.willCloseNotification || note.name == NSWindow.didMiniaturizeNotification {
                        self?.last = false; self?.onChange(false)
                    } else { self?.report() }
                })
            }
            DispatchQueue.main.async { self.report() }
        }
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.onChange = onChange; return v }
    func updateNSView(_ v: V, context: Context) { v.onChange = onChange }
}

/// メニューバーのパネル（--show-panel では通常ウィンドウにも同じ内容を出す）
struct MenuBarView: View {
    @Environment(AppState.self) private var state

    private func openMain(_ section: String? = nil) {
        if let section { state.requestedSection = section }
        WindowOpener.open()
    }

    private var score: Int { state.healthScore }
    private var warn: Bool { score < 80 }
    private var tint: Color? {
        switch HealthScore.level(score) { case .good: nil; case .caution: Theme.warn; case .critical: Theme.danger }
    }

    var body: some View {
        let mx = state.metrics
        VStack(spacing: 10) {
            header
            securityCard
            grid(mx)
            VStack(alignment: .leading, spacing: 8) {
                Text("おすすめ").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.secondary).padding(.leading, 4)
                recommendationCard
            }.padding(.top, 6)
            footer
        }
        .padding(18)
        .frame(width: 400)
        .background(ThemedBackground())
        .oceanScheme()
        .background(WindowVisibilityObserver { visible in
            if visible { state.refresh(); Task { await state.security.refreshStatus() }; state.metrics.start() }
            else { state.metrics.stop() }
        })
    }

    // MARK: ヘッダー

    private var header: some View {
        HStack(spacing: 14) {
            ScoreRing(score: state.hasHealthScore ? score : nil, size: 62, lineWidth: 6,
                      symbol: warn ? "exclamationmark.triangle.fill" : "checkmark.shield.fill", tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text("Mac の状態：").foregroundStyle(Theme.text)
                    if !state.hasHealthScore { Text("未チェック").foregroundStyle(Theme.secondary) }
                    else if let tint { Text(HealthScore.word(score)).foregroundStyle(tint) }
                    else { Text(HealthScore.word(score)).foregroundStyle(Theme.ringGradient) }
                }
                .font(.system(size: 20, weight: .bold))
                HStack(spacing: 0) {
                    Text(state.metrics.modelName).lineLimit(1).truncationMode(.tail)
                    Text(" ・ 最終チェック \(state.smartCare.result.map { ShortDate.format($0.date) } ?? "なし")")
                        .lineLimit(1).fixedSize()
                }
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }

    /// スキャン中は進捗（%・残り時間・現在の処理）を表示する
    private var progressCard: some View {
        let sc = state.smartCare, sec = state.security
        let care = sc.running
        return CardView(padding: 12) {
            HStack(alignment: .top, spacing: 10) {
                IconTile(symbol: "checkmark.shield.fill", color: Theme.security, size: 30, filled: false)
                ScanProgressBlock(fraction: care ? sc.progress : sec.fraction, etaText: care ? sc.etaText : sec.etaText,
                                  stepText: care ? sc.statusText : sec.step.rawValue, detailText: sec.detail)
            }
        }
        .contentShape(Rectangle()).onTapGesture { openMain(care ? "dashboard" : "security") }
    }

    @ViewBuilder private var securityCard: some View {
        if state.smartCare.running || state.security.running { progressCard } else { idleSecurityCard }
    }

    private var idleSecurityCard: some View {
        let r = state.smartCare.result
        let threats = r?.threats ?? 0
        return CardView(padding: 12) {
            HStack(spacing: 10) {
                IconTile(symbol: threats > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill",
                         color: threats > 0 ? Theme.danger : Theme.ok, size: 30, filled: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("セキュリティ").font(.system(size: 13.5, weight: .bold))
                    Text("XProtect \(state.security.status?.xprotectVersion ?? "—")・前回スキャン " + (r.map { "脅威 \($0.threats)件" } ?? "なし"))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if threats > 0 { StatusBadge(kind: .danger, "要対応") } else { StatusBadge(kind: .ok, "保護中") }
            }
        }
        .contentShape(Rectangle()).onTapGesture { openMain("security") }
    }

    // MARK: 2 列グリッド

    private func grid(_ mx: MetricsModel) -> some View {
        var cards: [AnyView] = [AnyView(diskCard), AnyView(memoryCard(mx)), AnyView(cpuCard(mx))]
        if mx.hasBattery { cards.append(AnyView(batteryCard(mx))) }
        cards.append(AnyView(networkCard(mx)))
        cards.append(AnyView(devicesCard(mx)))
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: cards.count, by: 2)), id: \.self) { i in
                GridRow {
                    cards[i].frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if i + 1 < cards.count { cards[i + 1].frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                    else { Color.clear }
                }
            }
        }
    }

    private func title(_ symbol: String, _ color: Color, _ t: String, _ sub: String, subLines: Int = 1) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, color: color, size: 30, filled: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(t).font(.system(size: 13.5, weight: .bold)).lineLimit(1)
                Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(subLines).minimumScaleFactor(0.75).monospacedDigit()
            }
        }
    }

    private func bar(_ fraction: Double, _ colors: [Color]) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, g.size.width * CGFloat(max(0, min(1, fraction)))))
            }
        }.frame(height: 6).padding(.top, 8)
    }

    private func note(_ t: String) -> some View {
        Text(t).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1).minimumScaleFactor(0.8).padding(.top, 8)
    }

    /// 「最大: 名前 値」。名前だけを中央省略し、値は常に表示する
    private func topNote(_ name: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text("最大: \(name)").lineLimit(1).truncationMode(.middle)
            Text(value).lineLimit(1).fixedSize()
        }
        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).padding(.top, 8)
    }

    private func linkText(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accentText)
            .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 8)
    }

    private var diskCard: some View {
        let d = state.disk
        let used = d.map { Double($0.total - $0.available) / Double(max(1, $0.total)) } ?? 0
        let junk = state.smartCare.result?.junkBytes
        return CardView(padding: 12) {
            VStack(alignment: .leading, spacing: 0) {
                title("internaldrive.fill", Color(hex: "67e8f9"), DiskInfo.volumeName, d.map { "空き \(formatBytes($0.available))" } ?? "取得できません")
                bar(used, [Theme.accentText, Theme.info])
                Button { openMain("cleanup") } label: {
                    linkText(junk.map { "掃除できる \(formatBytes($0)) ›" } ?? "クリーンアップを開く ›")
                }.buttonStyle(.plain)
            }
        }
    }

    private func memoryCard(_ mx: MetricsModel) -> some View {
        let p = mx.memoryPressure
        let colors: [Color] = (p ?? 0) >= 80 ? [Theme.warn, Theme.danger] : (p ?? 0) >= 60 ? [Theme.ok, Theme.warn] : [Theme.ok, Color(hex: "a3e635")]
        return CardView(padding: 12) {
            VStack(alignment: .leading, spacing: 0) {
                title("memorychip.fill", Color(hex: "c084fc"), "メモリ", p.map { "プレッシャー \($0)%" } ?? "取得中…")
                bar(Double(p ?? 0) / 100, colors)
                if let t = mx.topMemory { topNote(t.name, formatBytes(t.memoryBytes)) } else { note(" ") }
            }
        }
    }

    private func cpuCard(_ mx: MetricsModel) -> some View {
        CardView(padding: 12) {
            VStack(alignment: .leading, spacing: 0) {
                title("bolt.fill", Theme.warn, "CPU", mx.cpuLoad.map { "負荷 \(Int($0.rounded()))%" } ?? "取得中…")
                Sparkline(values: mx.cpuHistory).frame(height: 26).padding(.top, 8)
                if let t = mx.topCPU { topNote(t.name, "\(Int(t.cpu.rounded()))%") } else { note(" ") }
            }
        }
    }

    private func batteryCard(_ mx: MetricsModel) -> some View {
        let b = mx.battery
        let sub: String = {
            guard let b else { return "取得中…" }
            if b.isCharging { return b.minutes.map { "充電中・あと \(MetricsMath.minutes($0))" } ?? "充電中" }
            if b.onAC { return "電源に接続中" }
            return b.minutes.map { "残り \(MetricsMath.minutes($0))" } ?? "残り時間を計算中"
        }()
        let low = (b?.percent ?? 100) < 20 && !(b?.onAC ?? false)
        return CardView(padding: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    IconTile(symbol: b?.isCharging == true ? "battery.100.bolt" : "battery.75", color: Theme.ok, size: 30, filled: false)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("バッテリー").font(.system(size: 13.5, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 2)
                            if let b { Text("\(b.percent)%").font(.system(size: 13.5, weight: .bold)) }
                        }
                        Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                bar(Double(b?.percent ?? 0) / 100, low ? [Theme.danger, Theme.warn] : [Theme.ok, Theme.ok])
                note([b?.condition.map { "状態: \($0)" }, b?.cycleCount.map { "充電回数 \($0)" }].compactMap { $0 }.joined(separator: "・"))
            }
        }
    }

    private func networkCard(_ mx: MetricsModel) -> some View {
        CardView(padding: 12) {
            VStack(alignment: .leading, spacing: 0) {
                title(mx.wifi.isWiFi ? "wifi" : "cable.connector", Color(hex: "67e8f9"),
                      mx.wifi.isWiFi ? (mx.wifi.ssid ?? "Wi-Fi") : "有線",
                      "↑\(MetricsMath.rate(mx.netUp))  ↓\(MetricsMath.rate(mx.netDown))")
                if mx.speedTesting {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("測定中…").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 8)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let r = mx.speedResult {
                            Text("↓\(Int(r.down.rounded())) ↑\(Int(r.up.rounded())) Mbps").font(.system(size: 11.5, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        } else if mx.speedFailed {
                            Text("測定できませんでした").font(.system(size: 11.5)).foregroundStyle(Theme.warn)
                        }
                        Button { mx.runSpeedTest() } label: {
                            Text(mx.speedResult == nil ? "スピードテスト ›" : "再測定 ›").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accentText)
                        }.buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 8)
                }
            }
        }
    }

    private func devicesCard(_ mx: MetricsModel) -> some View {
        CardView(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("接続中のデバイス").font(.system(size: 13.5, weight: .bold)).lineLimit(1)
                if mx.devices.isEmpty {
                    Text("なし").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                ForEach(mx.devices.prefix(4)) { d in
                    HStack(spacing: 6) {
                        Image(systemName: d.symbol).font(.system(size: 11)).frame(width: 14)
                        Text(d.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(d.battery.map { "\($0)%" } ?? "—").foregroundStyle(d.battery == nil ? Theme.secondary : Theme.text)
                    }.font(.system(size: 12))
                }
            }
        }
    }

    // MARK: おすすめ・フッター

    @ViewBuilder private var recommendationCard: some View {
        if let rec = state.recommendations.first {
            CardView(padding: 12) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(LinearGradient(colors: RecommendationRow.gradient(rec.kind), startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 38, height: 38)
                            .overlay(Image(systemName: rec.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rec.title).font(.system(size: 13.5, weight: .bold)).lineLimit(2)
                            Text(rec.detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    Button(rec.actionLabel) { perform(rec.action) }.buttonStyle(.primaryCompact)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        } else {
            CardView(padding: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).font(.system(size: 20))
                    Text("いまのところ対応が必要な項目はありません").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func perform(_ a: RecAction) {
        switch a {
        case .navigate(let s): openMain(s)
        case .runSmartCare: runSmartCare()
        case .openURL: state.perform(a)
        }
    }

    private func runSmartCare() {
        openMain("dashboard")
        Task { await state.smartCare.run(state: state) }
    }

    private var footer: some View {
        let sc = state.smartCare
        return VStack(spacing: 12) {
            ThemedDivider()
            HStack(spacing: 6) {
                Menu {
                    Button("設定を開く") { openMain("settings") }
                    Divider()
                    Button("MacCare を終了") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("設定とその他")
                Spacer(minLength: 0)
                if sc.running {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(sc.statusText).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1) }
                        .layoutPriority(-1)
                    Button("中止") { sc.cancel(state: state) }.buttonStyle(.secondary).fixedSize()
                } else {
                    Button { runSmartCare() } label: { Text("スマートケアを実行") }
                        .buttonStyle(PrimaryButtonStyle(compact: false)).fixedSize()
                }
                Spacer(minLength: 0)
                Button("MacCare を開く") { openMain() }.buttonStyle(.secondary).fixedSize()
            }
        }
        .padding(.top, 4)
    }
}

/// CPU 負荷の折れ線（0–100% を縦軸に、低負荷でも見えるよう最大値を下限 25 で切る）
struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            let top = max(25, values.max() ?? 25)
            Path { p in
                guard values.count > 1 else { return }
                for (i, v) in values.enumerated() {
                    let x = g.size.width * CGFloat(i) / CGFloat(max(1, 29))   // 30 点で全幅
                    let y = g.size.height * (1 - CGFloat(v / top))
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Theme.warn, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
