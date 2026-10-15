import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case smartCare, cleanup, largeFiles, compress, apps, loginItems, security, history, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartCare: "スマートケア"
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
        case .smartCare: "sparkles"
        case .cleanup: "trash"
        case .largeFiles: "externaldrive"
        case .compress: "film"
        case .apps: "square.grid.2x2"
        case .loginItems: "person.badge.key"
        case .security: "shield"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
    /// 起動引数用の名前（rawValue のほか別名も受け付ける）
    static func from(_ name: String) -> SidebarItem? {
        let n = name.lowercased()
        if n == "video" { return .compress }
        return allCases.first { $0.rawValue.lowercased() == n }
    }
    var phase: String {
        switch self {
        case .cleanup: "P1"
        case .largeFiles, .compress: "P2"
        case .security: "P3"
        case .apps, .loginItems: "P4"
        case .smartCare: "P5"
        default: ""
        }
    }
}

struct MainWindow: View {
    @Environment(AppState.self) private var state
    @State private var selection: SidebarItem? = .smartCare

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label { Text(item.title) } icon: { Image(systemName: item.symbol).foregroundStyle(.tint) }.tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .smartCare {
            case .smartCare: SmartCareView()
            case .cleanup: CleanupView()
            case .security: SecurityView()
            case .apps: AppsView()
            case .loginItems: LoginItemsView()
            case .largeFiles: LargeFilesView()
            case .compress: VideoView()
            case .history: HistoryView()
            case .settings: SettingsView()
            case let item: PlaceholderView(item: item)
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .background(WindowConfigurator())
        .onAppear { applyRequest(); WindowOpener.bringToFront() }
        .onChange(of: state.requestedSection) { applyRequest() }
    }

    private func applyRequest() {
        guard let name = state.requestedSection else { return }
        if let item = SidebarItem.from(name) {
            selection = item
            // --scan 指定時のみ、表示後に読み取り専用スキャンを自動開始する
            if state.launchScanPending { state.autoScanSection = item.rawValue; state.launchScanPending = false }
        }
        state.requestedSection = nil
    }
}

struct PlaceholderView: View {
    let item: SidebarItem
    var body: some View {
        ContentUnavailableView(item.title, systemImage: item.symbol,
                               description: Text("\(item.phase)で実装予定です"))
    }
}

struct HistoryView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.history.isEmpty {
                ContentUnavailableView("履歴はありません", systemImage: "clock.arrow.circlepath")
            } else {
                Table(state.history) {
                    TableColumn("日時") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }
                        .width(min: 120, ideal: 150)
                    TableColumn("種類") { Text($0.kind.rawValue) }.width(80)
                    TableColumn("対象") { Text($0.target).lineLimit(1).truncationMode(.middle) }
                    TableColumn("サイズ") { Text(formatBytes($0.bytes)) }.width(80)
                    TableColumn("結果") { Text($0.result) }.width(70)
                }
            }
        }
        .navigationTitle("履歴")
        .onAppear { state.refresh() }
    }
}

/// ウィンドウのタイトル文字を隠す（ペイン見出しと重複するため）
struct WindowConfigurator: NSViewRepresentable {
    final class V: NSView {
        var obs: NSKeyValueObservation?
        override func viewDidMoveToWindow() {
            guard let w = window else { return }
            w.titleVisibility = .hidden
            // navigationTitle の変更で戻されないよう、タイトル変更のたびに隠し直す
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

    @ViewBuilder private func pathList(_ title: String, _ binding: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Button("追加…") { pickFolder { p in if !binding.wrappedValue.contains(p) { binding.wrappedValue.append(p) } } }
            }
            ForEach(binding.wrappedValue, id: \.self) { p in
                HStack {
                    Text(p).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { binding.wrappedValue.removeAll { $0 == p } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    var body: some View {
        @Bindable var st = state
        PaneScaffold(title: "設定", subtitle: "変更は自動で保存されます。") { EmptyView() } content: {
            Form {
                Section("外部ツール") {
                    ForEach(state.tools) { t in
                        LabeledContent(t.name) {
                            if let p = t.path { Text(p).foregroundStyle(.secondary).textSelection(.enabled) }
                            else { Text("未インストール").foregroundStyle(.orange) }
                        }
                    }
                    if state.tools.contains(where: { !$0.isAvailable }) {
                        Text("導入コマンド: \(Tools.installHint)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Section("一般") {
                    Toggle("ログイン時に MacCare を起動", isOn: Binding(get: { launchAtLogin }, set: { on in
                        do { try LaunchAtLogin.set(on); launchError = nil } catch { launchError = "\(error.localizedDescription)" }
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }))
                    if let e = launchError { Text(e).font(.caption).foregroundStyle(.orange) }
                    Toggle("定期スキャンを有効にする", isOn: $st.settings.scheduledScanEnabled)
                    Stepper("スキャン間隔: \(st.settings.scanIntervalDays) 日", value: $st.settings.scanIntervalDays, in: 1...60)
                    LabeledContent("前回の定期実行",
                                   value: st.settings.lastScheduledRun?.formatted(date: .abbreviated, time: .shortened) ?? "なし")
                }
                Section("クリーンアップ・大容量ファイル") {
                    Stepper("大容量ファイルの閾値: \(st.settings.largeFileThresholdMB) MB", value: $st.settings.largeFileThresholdMB, in: 50...50_000, step: 50)
                    Stepper("node_modules を古いとみなす日数: \(st.settings.nodeModulesStaleDays) 日", value: $st.settings.nodeModulesStaleDays, in: 7...730, step: 7)
                    pathList("検索範囲", $st.settings.largeFileRoots)
                }
                Section("セキュリティ") {
                    Toggle("じっくりスキャン（ClamAV で /Applications も対象にする。時間がかかります）", isOn: $st.settings.deepScan)
                    pathList("スキャン対象（YARA / ClamAV）", $st.settings.scanTargets)
                    LabeledContent("無視リスト", value: "\(st.settings.ignoredDetections.count) 件")
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { state.refresh(); launchAtLogin = LaunchAtLogin.isEnabled }
        .onChange(of: state.settings) { _, new in
            var disk = Settings.load()
            disk.mergeEditable(from: new)
            try? disk.save()
        }
    }
}
