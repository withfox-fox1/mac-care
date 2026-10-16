import SwiftUI
import AppKit

/// 起動済みアプリの再クリック（Finder / Launchpad / open -a）でウィンドウを開く
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // 動画圧縮: ffmpeg を即時停止し、作りかけの出力を片付ける（元ファイルは残る）
        MainActor.assumeIsolated { AppState.shared.compressQueue.terminateForQuit() }
        ChildRegistry.terminateAll()   // 一時停止中のものを含め ffmpeg 等の子プロセスを止める
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Task { @MainActor in WindowOpener.open() } }
        return true
    }
}

@MainActor
enum WindowOpener {
    /// MenuBarExtra のラベル表示時に openWindow を登録する
    static var action: (() -> Void)?
    /// 検証用 --show-panel のパネル窓を開く
    static var panelAction: (() -> Void)?
    private static var handledArgs = false

    static func open() {
        action?()
        NSApp.activate(ignoringOtherApps: true)
        bringToFront()
    }

    private static var lastFront = Date.distantPast

    /// ウィンドウを開いた直後に一度だけ前面化する。まだ見えていなければ 0.5 秒後に 1 回だけ再試行する。
    /// 確認ダイアログ（モーダル）表示中は何もしない。
    static func bringToFront() {
        guard Date().timeIntervalSince(lastFront) > 1.0 else { return }   // 連続呼び出しを1回にまとめる
        lastFront = Date()
        func visible() -> Bool {
            NSApp.windows.contains {
                !($0 is NSPanel) && $0.canBecomeMain && $0.isVisible && $0.isOnActiveSpace && $0.occlusionState.contains(.visible)
            }
        }
        func front() {
            guard NSApp.modalWindow == nil else { return }
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            NSApp.activate(ignoringOtherApps: true)
            for w in NSApp.windows where !(w is NSPanel) && w.canBecomeMain {
                if w.isMiniaturized { w.deminiaturize(nil) }
                w.collectionBehavior.insert(.moveToActiveSpace)   // 別の Space で開かないようにする
                w.makeKeyAndOrderFront(nil)
            }
        }
        front()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard NSApp.modalWindow == nil, !visible() else { return }
            action?()   // openWindow を再実行して既存ウィンドウを前面に出す
            front()
        }
    }

    /// 起動引数 `--open-window <section>`（初回のみ処理）
    static func handleLaunchArguments(state: AppState) {
        guard !handledArgs else { return }
        handledArgs = true
        state.startBackgroundServices()
        let args = CommandLine.arguments
        // 検証用: 定期スキャンを今すぐ実行（読み取り専用）
        if args.contains("--run-scheduled-now") {
            Task { await state.scheduler.tick(state: state, force: true) }
        }
        // 検証用: メニューバーパネルと同じ内容を通常ウィンドウで開く（スクリーンショット用）
        if args.contains("--show-panel") {
            panelAction?()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        // `--compress-list <file>`: 1行1パスのリストを圧縮キューに入れて開始し、動画圧縮画面を開く
        if let c = args.firstIndex(of: "--compress-list"), c + 1 < args.count,
           let text = try? String(contentsOfFile: args[c + 1], encoding: .utf8) {
            let urls = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }
            if state.compressQueue.add(urls) > 0 { state.compressQueue.start() }
            state.requestedSection = "video"
            open()
            return
        }
        guard let i = args.firstIndex(of: "--open-window") else { return }
        state.requestedSection = i + 1 < args.count ? args[i + 1] : "dashboard"
        open()
    }
}

/// メニューバー用テンプレート画像（Resources の PNG。@2x は自動選択）。見つからなければ SF Symbol にする。
enum MenuBarIcon {
    static func image(warning: Bool) -> NSImage? {
        guard let img = Bundle.main.image(forResource: warning ? "MenuBarIconWarning" : "MenuBarIcon") else { return nil }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true   // ライト/ダークに自動で合わせる
        return img
    }
}

struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let state = AppState.shared
        let warning = state.needsAttention
        Group {
            if let img = MenuBarIcon.image(warning: warning) {
                Image(nsImage: img)
            } else {
                Image(systemName: warning ? "exclamationmark.triangle.fill" : "sparkles")
            }
        }
        .opacity(state.smartCare.running ? 0.5 : 1)   // スキャン中は薄く表示
            .onAppear {
                WindowOpener.action = { openWindow(id: "main") }
                WindowOpener.panelAction = { openWindow(id: "panel") }
                WindowOpener.handleLaunchArguments(state: AppState.shared)
            }
    }
}

@main
struct MacCareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

    init() {
        // 子プロセス用: 接続中 Bluetooth デバイスの残量を JSON で出力して終了する（残量は都度別プロセスで読む必要がある）
        if CommandLine.arguments.contains(BluetoothInfo.dumpArgument) {
            BluetoothInfo.dump()
            exit(0)
        }
        // アンインストール用: ログイン項目の登録を解除して終了する（ウィンドウは開かない）
        if CommandLine.arguments.contains("--unregister-login-item") {
            do { try LaunchAtLogin.set(false); print("ログイン項目の登録を解除しました") }
            catch { print("解除に失敗: \(error.localizedDescription)") }
            // 再登録されないよう、初期登録済みフラグを立てておく
            var s = Settings.load(); s.launchAtLoginInitialized = true; try? s.save()
            exit(0)
        }
    }

    /// 画面を切り替える。ウィンドウが閉じていれば開く
    @MainActor static func show(_ item: SidebarItem) {
        AppState.shared.requestedSection = item.rawValue
        WindowOpener.open()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environment(state)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("MacCare", id: "main") {
            MainWindow()
                .environment(state)
                // ウィンドウ表示中だけ Dock アイコンを出す
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            // 表示メニュー: ⌘1〜⌘9 で各画面へ（削除系にはショートカットを付けない）
            CommandGroup(replacing: .sidebar) {
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element.id) { i, item in
                    Button(item.title) { MacCareApp.show(item) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
            }
            // 標準の「設定…」(⌘,) を、アプリ内の設定画面を開く動作に置き換える
            CommandGroup(replacing: .appSettings) {
                Button("設定…") { MacCareApp.show(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        // 検証用（--show-panel）: パネルの内容を通常のウィンドウで表示する
        Window("MacCare パネル", id: "panel") {
            MenuBarView().environment(state)
                .onAppear { NSApp.setActivationPolicy(.regular) }
        }
        .windowResizability(.contentSize)
    }
}
