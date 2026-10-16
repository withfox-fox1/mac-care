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
                // お知らせは詳細領域の上に差し込み、下の内容を押し下げる（ボタンを覆わない）
                VStack(spacing: 0) {
                    if let n = state.update.notice {
                        NoticeBanner(text: n.text, isError: n.isError) { state.update.notice = nil }
                            .padding(.horizontal, 30).padding(.top, 12)
                    }
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // 検証用: `--window-size <幅>x<高さ>` で表示サイズを指定する（レイアウト確認の撮影用）
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--window-size"), i + 1 < args.count {
                let p = args[i + 1].split(separator: "x").compactMap { Double($0) }
                if p.count == 2 {
                    DispatchQueue.main.async { w.setContentSize(NSSize(width: p[0], height: p[1])) }
                }
            }
        }
    }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ v: NSView, context: Context) {}
}
