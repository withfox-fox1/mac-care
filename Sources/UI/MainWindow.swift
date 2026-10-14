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
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .smartCare {
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
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { applyRequest(); WindowOpener.bringToFront() }
        .onChange(of: state.requestedSection) { applyRequest() }
    }

    private func applyRequest() {
        guard let name = state.requestedSection else { return }
        if let item = SidebarItem.from(name) {
            selection = item
            // --scan 指定時のみ、表示後に読み取り専用スキャンを自動開始する
            if CommandLine.arguments.contains("--scan") { state.autoScanSection = item.rawValue }
        }
        state.requestedSection = nil
        WindowOpener.bringToFront()
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

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            Section("外部ツール") {
                ForEach(state.tools) { t in
                    LabeledContent(t.name) {
                        if let p = t.path {
                            Text(p).foregroundStyle(.secondary).textSelection(.enabled)
                        } else {
                            Text("未インストール").foregroundStyle(.orange)
                        }
                    }
                }
                if state.tools.contains(where: { !$0.isAvailable }) {
                    Text("導入コマンド: \(Tools.installHint)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section("設定値（読み取り専用）") {
                let s = state.settings
                LabeledContent("大容量ファイルの閾値", value: "\(s.largeFileThresholdMB) MB")
                LabeledContent("検索範囲", value: s.largeFileRoots.joined(separator: ", "))
                LabeledContent("node_modules 未更新日数", value: "\(s.nodeModulesStaleDays) 日")
                LabeledContent("定期スキャン", value: s.scheduledScanEnabled ? "有効" : "無効")
                LabeledContent("スキャン間隔", value: "\(s.scanIntervalDays) 日")
                LabeledContent("スキャン対象", value: s.scanTargets.joined(separator: ", "))
                LabeledContent("無視リスト", value: "\(s.ignoredDetections.count) 件")
                LabeledContent("前回の定期実行",
                               value: s.lastScheduledRun?.formatted(date: .abbreviated, time: .shortened) ?? "なし")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("設定")
        .onAppear { state.refresh() }
    }
}
