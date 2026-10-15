import SwiftUI
import AppKit

/// 起動済みアプリの再クリック（Finder / Launchpad / open -a）でウィンドウを開く
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
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
        guard let i = args.firstIndex(of: "--open-window") else { return }
        state.requestedSection = i + 1 < args.count ? args[i + 1] : "smartCare"
        open()
    }
}

struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let state = AppState.shared
        Image(systemName: state.needsAttention ? "exclamationmark.triangle.fill" : "sparkles")
            .onAppear {
                WindowOpener.action = { openWindow(id: "main") }
                WindowOpener.handleLaunchArguments(state: AppState.shared)
            }
    }
}

@main
struct MacCareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

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
    }
}
