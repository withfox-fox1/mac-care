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
    @State private var selection: SidebarItem = .dashboard

    var body: some View {
        ZStack {
            ThemedBackground()
            HStack(spacing: 0) {
                sidebar
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
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
        return Button { selection = item } label: {
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
            selection = item
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
                        Toggle("定期スキャンを有効にする", isOn: $st.settings.scheduledScanEnabled)
                        Stepper("スキャン間隔: \(st.settings.scanIntervalDays) 日", value: $st.settings.scanIntervalDays, in: 1...60)
                        labeled("前回の定期実行", st.settings.lastScheduledRun?.formatted(date: .abbreviated, time: .shortened) ?? "なし")
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
