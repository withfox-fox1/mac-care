import SwiftUI
import AppKit

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard, cleanup, largeFiles, compress, security, loginItems, apps, history, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "ダッシュボード"
        case .cleanup: "クリーンアップ"
        case .largeFiles: "大容量ファイル"
        case .compress: "動画圧縮"
        case .apps: "アプリケーション"
        case .loginItems: "ログイン項目"
        case .security: "セキュリティ"
        case .history: "履歴"
        case .settings: "設定"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .cleanup: "sparkles"
        case .largeFiles: "externaldrive.fill"
        case .compress: "film.fill"
        case .apps: "command"
        case .loginItems: "power"
        case .security: "checkmark.shield.fill"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape.fill"
        }
    }
    var color: Color {
        switch self {
        case .dashboard: Theme.teal
        case .cleanup: Theme.cleanup
        case .largeFiles: Theme.largeFiles
        case .compress: Theme.video
        case .security: Theme.security
        case .loginItems: Theme.loginItems
        case .apps: Theme.apps
        case .history, .settings: Theme.neutral
        }
    }
    /// 起動引数用の名前（rawValue のほか別名も受け付ける）
    static func from(_ name: String) -> SidebarItem? {
        let n = name.lowercased()
        if n == "video" { return .compress }
        if n == "smartcare" { return .dashboard }   // 旧名の別名
        return allCases.first { $0.rawValue.lowercased() == n }
    }

    static let groups: [(title: String?, items: [SidebarItem])] = [
        (nil, [.dashboard]),
        ("容量", [.cleanup, .largeFiles, .compress]),
        ("保護", [.security, .loginItems, .apps]),
        ("その他", [.history, .settings]),
    ]
}

struct MainWindow: View {
    @Environment(AppState.self) private var state
    private var selection: SidebarItem { SidebarItem(rawValue: state.currentSection) ?? .dashboard }

    var body: some View {
        ZStack {
            ThemedBackground()
            HStack(spacing: 0) {
                sidebar
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        if let n = state.update.notice {
                            NoticeBanner(text: n.text, isError: n.isError) { state.update.notice = nil }
                                .padding(.horizontal, 30).padding(.top, 12)
                        }
                    }
            }
        }
        .oceanScheme()
        .frame(minWidth: 960, minHeight: 620)
        .background(WindowConfigurator())
        .onAppear { applyRequest(); WindowOpener.bringToFront() }
        .onChange(of: state.requestedSection) { applyRequest() }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(SidebarItem.groups.enumerated()), id: \.offset) { _, g in
                    if let t = g.title {
                        Text(t).font(.system(size: 10.5, weight: .bold)).tracking(0.8)
                            .foregroundStyle(Color(hex: "6f98a6")).padding(.leading, 12).padding(.top, 14).padding(.bottom, 6)
                    }
                    ForEach(g.items) { row($0) }
                }
            }
            .padding(.horizontal, 12).padding(.top, 44).padding(.bottom, 16)
        }
        .frame(width: 224)
        .background(Color(hex: "020a12", opacity: 0.40))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1) }
    }

    private func row(_ item: SidebarItem) -> some View {
        let on = selection == item
        return Button { state.currentSection = item.rawValue } label: {
            HStack(spacing: 11) {
                if item == .dashboard {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.accentText, Theme.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                        .overlay(Image(systemName: item.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
                } else {
                    IconTile(symbol: item.symbol, color: item.color)
                }
                Text(item.title).font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Color(hex: "cfe6ec"))
                Spacer(minLength: 0)
                if item == .settings, state.update.availableCount > 0 {
                    Text("\(state.update.availableCount)").font(.system(size: 10.5, weight: .heavy)).foregroundStyle(Color(hex: "1b1200"))
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.warn, in: Capsule())
                        .accessibilityLabel("アップデートあり")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(on ? Theme.accentText.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(on ? Theme.accentText.opacity(0.25) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .dashboard: DashboardView()
        case .cleanup: CleanupView()
        case .security: SecurityView()
        case .apps: AppsView()
        case .loginItems: LoginItemsView()
        case .largeFiles: LargeFilesView()
        case .compress: VideoView()
        case .history: HistoryView()
        case .settings: SettingsView()
        }
    }

    private func applyRequest() {
        guard let name = state.requestedSection else { return }
        if let item = SidebarItem.from(name) {
            state.currentSection = item.rawValue
            // --scan 指定時のみ、表示後に読み取り専用スキャンを自動開始する（ダッシュボードは従来のキー smartCare を使う）
            if state.launchScanPending {
                state.autoScanSection = item == .dashboard ? "smartCare" : item.rawValue
                state.launchScanPending = false
            }
        }
        state.requestedSection = nil
    }
}

struct HistoryView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        PaneScaffold(item: .history, subtitle: "実行した掃除・スキャン・削除の記録です。") { EmptyView() } content: {
            if state.history.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath", color: Theme.secondary, message: "履歴はまだありません") { EmptyView() }
            } else {
                Table(state.history) {
                    TableColumn("日時") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }
                        .width(min: 120, ideal: 150)
                    TableColumn("種類") { Text($0.kind.rawValue) }.width(80)
                    TableColumn("対象") { Text($0.target).lineLimit(1).truncationMode(.middle) }
                    TableColumn("サイズ") { Text(formatBytes($0.bytes)) }.width(80)
                    TableColumn("結果") { Text($0.result) }.width(70)
                }
                .themedList().alternatingRowBackgrounds(.enabled)
            }
        }
        .onAppear { state.refresh() }
    }
}

/// ウィンドウをタイトルバーなし風にする（信号ボタンだけ残し、背景色を揃える）
struct WindowConfigurator: NSViewRepresentable {
    final class V: NSView {
        var obs: NSKeyValueObservation?
        override func viewDidMoveToWindow() {
            guard let w = window else { return }
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(srgbRed: 0.024, green: 0.075, blue: 0.122, alpha: 1)
            // タイトルの変更で戻されないよう、変更のたびに隠し直す
            obs = w.observe(\.title) { w, _ in w.titleVisibility = .hidden }
        }
    }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ v: NSView, context: Context) {}
}

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String? = nil
    @State private var wakeBusy = false
    @State private var wakeError: String? = nil

    private var fullScanTime: Binding<Date> {
        Binding(get: { Calendar.current.date(from: DateComponents(hour: state.settings.fullScanHour, minute: state.settings.fullScanMinute)) ?? Date() },
                set: { d in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                    state.settings.fullScanHour = c.hour ?? 0; state.settings.fullScanMinute = c.minute ?? 0
                })
    }

    /// pmset の起床スケジュールを設定/解除する（明示操作時のみ。管理者パスワードのプロンプトが出る）
    private func setWake(_ on: Bool) async {
        wakeBusy = true; defer { wakeBusy = false }
        wakeError = nil
        var s = Settings.load()
        let events = await WakeScheduler.currentEvents()
        let existing = WakeSchedule.classify(events, ourTime: s.wakeScheduleTime)
        if on {
            if case .foreign(let ev) = existing {
                let a = NSAlert()
                a.messageText = "既存の起床スケジュールを上書きしますか？"
                a.informativeText = "pmset の繰り返しスケジュールは 1 つしか持てません。現在の設定（\(ev.map { "\($0.kind) \($0.time) \($0.days)" }.joined(separator: ", "))）は上書きされます。"
                a.addButton(withTitle: "上書きする"); a.addButton(withTitle: "キャンセル")
                guard a.runModal() == .alertFirstButtonReturn else { return }
            }
            s.fullScanHour = state.settings.fullScanHour; s.fullScanMinute = state.settings.fullScanMinute
            if let err = await WakeScheduler.run(arguments: WakeSchedule.applyArguments(hour: s.fullScanHour, minute: s.fullScanMinute)) {
                wakeError = "起床スケジュールを設定できませんでした: \(err)"; return
            }
            s.wakeForScan = true
            s.wakeScheduleTime = WakeSchedule.wakeTime(hour: s.fullScanHour, minute: s.fullScanMinute)
        } else {
            // MacCare 以外の繰り返しスケジュールは解除しない
            if case .foreign = existing {
                wakeError = "MacCare 以外の起床スケジュールがあるため、pmset は変更せず MacCare 側の設定のみ解除しました。"
            } else if let err = await WakeScheduler.run(arguments: WakeSchedule.cancelArguments) {
                wakeError = "起床スケジュールを解除できませんでした: \(err)"; return
            }
            s.wakeForScan = false; s.wakeScheduleTime = nil
        }
        s.wakeSuggestionDismissed = true
        try? s.save()
        state.settings.wakeForScan = s.wakeForScan
        state.settings.wakeScheduleTime = s.wakeScheduleTime
        state.settings.wakeSuggestionDismissed = true
    }

    private var updateCard: some View {
        let u = state.update
        return card("アップデート") {
            labeled("現在のバージョン", BuildInfo.display)
            labeled("最終確認", u.lastCheck.map { ShortDate.format($0) } ?? "未確認")
            HStack(spacing: 10) {
                Button("アップデートを確認") { Task { await u.check() } }.buttonStyle(.secondary).disabled(u.checking)
                if u.checking { ProgressView().controlSize(.small); Text("確認中…").font(.caption).foregroundStyle(Theme.secondary) }
                Spacer()
                if case .available = u.state {
                    Button("アップデートする") { u.confirmAndStart() }.buttonStyle(.primary)
                }
            }
            switch u.state {
            case .unknown: EmptyView()
            case .upToDate:
                StatusBadge(kind: .ok, "最新です")
            case .available(let n, let commits):
                StatusBadge(kind: .warn, "更新あり（\(n) 件）")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(commits, id: \.hash) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(c.hash).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.accentText)
                            Text(c.subject).font(.system(size: 12)).lineLimit(2)
                        }
                    }
                    if n > commits.count { Text("ほか \(n - commits.count) 件").font(.caption).foregroundStyle(Theme.secondary) }
                }
            case .blocked(let m):
                StatusBadge(kind: .warn, "更新できません")
                Text(m).font(.caption).foregroundStyle(Theme.warn)
            case .unavailable(let m):
                StatusBadge(kind: .info, "確認できません")
                Text(m).font(.caption).foregroundStyle(Theme.secondary)
            }
            Text("更新は GitHub の origin/main を取り込み、アプリを再ビルドして再起動します。1 日 1 回、自動で確認だけ行います（自動インストールはしません）。ログ: \(SelfUpdate.logURL.path)")
                .font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    private func pickFolder(_ add: @escaping (String) -> Void) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        if p.runModal() == .OK { p.urls.forEach { add($0.path) } }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        CardView(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 13, weight: .heavy)).foregroundStyle(Color(hex: "dff3f6"))
                body()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(Theme.secondary).textSelection(.enabled) }
    }

    @ViewBuilder private func pathList(_ title: String, _ binding: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("追加…") { pickFolder { p in if !binding.wrappedValue.contains(p) { binding.wrappedValue.append(p) } } }
                    .buttonStyle(.secondary)
            }
            ForEach(binding.wrappedValue, id: \.self) { p in
                HStack {
                    Text(p).font(.callout).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { binding.wrappedValue.removeAll { $0 == p } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("削除")
                }
            }
        }
    }

    var body: some View {
        @Bindable var st = state
        PaneScaffold(item: .settings, subtitle: "変更は自動で保存されます。", framed: false) { EmptyView() } content: {
            ScrollView {
                VStack(spacing: 14) {
                    updateCard
                    card("外部ツール") {
                        ForEach(state.tools) { t in
                            HStack {
                                Text(t.name); Spacer()
                                if let p = t.path { Text(p).foregroundStyle(Theme.secondary).textSelection(.enabled) }
                                else { StatusBadge(kind: .warn, "未インストール") }
                            }
                        }
                        if state.tools.contains(where: { !$0.isAvailable }) {
                            Text("導入コマンド: \(Tools.installHint)").font(.caption).foregroundStyle(Theme.secondary).textSelection(.enabled)
                        }
                    }
                    card("一般") {
                        Toggle("ログイン時に MacCare を起動", isOn: Binding(get: { launchAtLogin }, set: { on in
                            do { try LaunchAtLogin.set(on); launchError = nil } catch { launchError = "\(error.localizedDescription)" }
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }))
                        if let e = launchError { Text(e).font(.caption).foregroundStyle(Theme.warn) }
                    }
                    card("フルスキャン（定期実行）") {
                        Toggle("毎日フルスキャンを実行する（スマートケアを含む全ファイル・両エンジン）", isOn: $st.settings.scheduledScanEnabled)
                        DatePicker("実行時刻", selection: fullScanTime, displayedComponents: .hourAndMinute)
                        Text("フルスキャン: 毎日 \(String(format: "%d:%02d", st.settings.fullScanHour, st.settings.fullScanMinute))。Mac がスリープ中・停止中で逃した場合は、起動・復帰の数分後に実行します（1 日 1 回）。")
                            .font(.caption).foregroundStyle(Theme.secondary)
                        labeled("前回のフルスキャン", state.security.lastFullAt.map { ShortDate.format($0) } ?? "未実施")
                        labeled("前回の定期実行", st.settings.lastScheduledRun?.formatted(date: .abbreviated, time: .shortened) ?? "なし")
                        Toggle("スリープ中でも起こしてスキャン", isOn: Binding(get: { state.settings.wakeForScan }, set: { on in Task { await setWake(on) } }))
                            .disabled(wakeBusy)
                        if state.settings.wakeForScan, let t = state.settings.wakeScheduleTime, t != WakeSchedule.wakeTime(hour: st.settings.fullScanHour, minute: st.settings.fullScanMinute) {
                            HStack {
                                Text("起床時刻（\(t)）が実行時刻とずれています").font(.caption).foregroundStyle(Theme.warn)
                                Spacer()
                                Button("起床時刻を再設定") { Task { await setWake(true) } }.buttonStyle(.secondary).disabled(wakeBusy)
                            }
                        }
                        if let e = wakeError { Text(e).font(.caption).foregroundStyle(Theme.warn) }
                        Text("実行時刻の \(WakeSchedule.leadMinutes) 分前に Mac を起こします（pmset の繰り返しスケジュール。設定時に管理者パスワードが必要です）。スキャン中はスリープしないよう保持しますが、バッテリー駆動で蓋を閉じている場合は macOS が眠ることがあり、その場合は次の復帰後に実行します。")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                    card("クリーンアップ・大容量ファイル") {
                        Stepper("大容量ファイルの閾値: \(st.settings.largeFileThresholdMB) MB", value: $st.settings.largeFileThresholdMB, in: 50...50_000, step: 50)
                        Stepper("node_modules を古いとみなす日数: \(st.settings.nodeModulesStaleDays) 日", value: $st.settings.nodeModulesStaleDays, in: 7...730, step: 7)
                        pathList("検索範囲", $st.settings.largeFileRoots)
                    }
                    card("セキュリティ") {
                        Toggle("じっくりスキャン（ClamAV で /Applications も対象にする。時間がかかります）", isOn: $st.settings.deepScan)
                        pathList("スキャン対象（YARA / ClamAV）", $st.settings.scanTargets)
                        labeled("無視リスト", "\(st.settings.ignoredDetections.count) 件")
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .onAppear { state.refresh(); launchAtLogin = LaunchAtLogin.isEnabled }
        .onChange(of: state.settings) { _, new in
            var disk = Settings.load()
            disk.mergeEditable(from: new)
            try? disk.save()
        }
    }
}
