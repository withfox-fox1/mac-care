import SwiftUI

/// 初回起動時だけ表示するあいさつ（1 枚のみ。表示判定は Core/Onboarding.swift）
struct OnboardingView: View {
    var onStart: () -> Void

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accentText).frame(width: 24)
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("MacCare へようこそ").font(.system(size: 22, weight: .heavy)).foregroundStyle(Theme.text)
            point("eye", "スキャンは読み取りのみで、何も削除しません")
            point("trash", "削除するときは、必ず確認してからゴミ箱へ移します（元に戻せます）")
            point("lock.shield", "フルディスクアクセスは任意です（許可するとゴミ箱の中も確認できます）")
            HStack {
                Spacer()
                Button("はじめる", action: onStart).buttonStyle(.primary).fixedSize().keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 460)
        .background(ThemedBackground())
        .oceanScheme()
    }
}
