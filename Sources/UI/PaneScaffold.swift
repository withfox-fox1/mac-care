import SwiftUI

/// 各機能ペイン共通のレイアウト: 上部にアイコン・タイトル・説明・操作ボタン、下に本体（カード）
struct PaneScaffold<Actions: View, Content: View>: View {
    let item: SidebarItem
    let subtitle: String
    var framed = true
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(symbol: item.symbol, color: item.color, title: item.title, subtitle: subtitle) { actions }
            if framed {
                CardView(padding: 0) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// 注意メッセージ（警告色）
struct NoticeText: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(Theme.warn)
            .padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
    }
}
