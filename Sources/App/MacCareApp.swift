import SwiftUI
import AppKit

/// 起動済みアプリの再クリック（Finder / Launchpad / open -a）でウィンドウを開く
final class AppDelegate: NSObject, NSApplicationDelegate {
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

    /// メインウィンドウを最前面・キーウィンドウにする。
    /// 表示直後は未生成・非表示のことがあるため、可視になるまで間隔を空けて再試行する。
    static func bringToFront() {
        func front() {
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            for w in NSApp.windows where !(w is NSPanel) && w.canBecomeMain {
                if w.isMiniaturized { w.deminiaturize(nil) }
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
            }
        }
        front()
        for delay in [0.2, 0.6, 1.2, 2.5, 4.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let visible = NSApp.windows.contains { !($0 is NSPanel) && $0.canBecomeMain && $0.isVisible }
                if !visible || delay < 1 { front() }
            }
        }
    }

    /// 起動引数 `--open-window <section>`（初回のみ処理）
    static func handleLaunchArguments(state: AppState) {
        guard !handledArgs else { return }
        handledArgs = true
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--open-window") else { return }
        state.requestedSection = i + 1 < args.count ? args[i + 1] : "smartCare"
        open()
    }
}

struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(systemName: "sparkles")
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
        .defaultSize(width: 920, height: 600)
    }
}
