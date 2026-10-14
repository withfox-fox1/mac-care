import SwiftUI
import AppKit

@main
struct MacCareApp: App {
    @State private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra("MacCare", systemImage: "sparkles") {
            MenuBarView().environment(state)
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
