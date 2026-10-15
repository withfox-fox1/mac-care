import SwiftUI
import AppKit

// MARK: - Ocean テーマ（常にダーク）

extension Color {
    /// "#rrggbb" / "rrggbb"
    init(hex: String, opacity: Double = 1) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255, opacity: opacity)
    }
}

extension Color {
    /// 白に近づけた色（macOS 14 には Color.mix がないため NSColor で混色）
    func lightened(_ fraction: CGFloat) -> Color {
        let ns = NSColor(self)
        return Color(nsColor: ns.blended(withFraction: fraction, of: .white) ?? ns)
    }
}

enum Theme {
    static let text = Color(hex: "eaf6f8")
    static let secondary = Color(hex: "9fc3cf")
    static let accentText = Color(hex: "5eead4")
    static let ok = Color(hex: "4ade80")
    static let warn = Color(hex: "fbbf24")
    static let danger = Color(hex: "f87171")
    static let info = Color(hex: "38bdf8")
    static let teal = Color(hex: "14b8a6")
    static let blue = Color(hex: "3b82f6")
    static let cardFill = Color.white.opacity(0.06)
    static let cardBorder = Color.white.opacity(0.10)
    static let rowAlt = Color.white.opacity(0.035)
    static let accentGradient = LinearGradient(colors: [teal, blue], startPoint: .leading, endPoint: .trailing)
    static let ringGradient = LinearGradient(colors: [accentText, info], startPoint: .leading, endPoint: .trailing)

    // 機能ごとの色
    static let cleanup = Color(hex: "0ea5e9")
    static let largeFiles = Color(hex: "6366f1")
    static let video = Color(hex: "f59e0b")
    static let security = Color(hex: "10b981")
    static let loginItems = Color(hex: "ef4444")
    static let apps = Color(hex: "8b5cf6")
    static let neutral = Color(hex: "475569")
}

/// 背景: 160° のグラデーション＋ティール／ブルーの柔らかい光
struct ThemedBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "0f4c5c"), Color(hex: "0b2a3d"), Color(hex: "06131f")],
                           startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1))
            RadialGradient(colors: [Color(hex: "2dd4bf", opacity: 0.20), .clear],
                           center: UnitPoint(x: 0.8, y: 0), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(hex: "3b82f6", opacity: 0.18), .clear],
                           center: UnitPoint(x: 0.3, y: 1), startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

struct CardView<Content: View>: View {
    var padding: CGFloat = 14
    var radius: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1))
    }
}

enum BadgeKind {
    case ok, warn, danger, info
    var color: Color {
        switch self { case .ok: Theme.ok; case .warn: Theme.warn; case .danger: Theme.danger; case .info: Theme.info }
    }
}

struct StatusBadge: View {
    let kind: BadgeKind
    let text: String
    init(kind: BadgeKind, _ text: String) { self.kind = kind; self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(kind.color.opacity(0.15), in: Capsule())
            .foregroundStyle(kind.color)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 14, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 22).padding(.vertical, compact ? 7 : 10)
            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous))
            .shadow(color: Theme.teal.opacity(enabled ? 0.35 : 0), radius: 10, y: 4)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(destructive ? Theme.danger : Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryCompact: PrimaryButtonStyle { PrimaryButtonStyle(compact: true) }
}
extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var secondaryDestructive: SecondaryButtonStyle { SecondaryButtonStyle(destructive: true) }
}

/// 健康スコアのリング（中央は数字、または symbol 指定時はアイコン）
struct ScoreRing: View {
    let score: Int
    var size: CGFloat = 132
    var lineWidth: CGFloat = 12
    var caption: String? = "健康スコア"
    var symbol: String? = nil
    var tint: Color? = nil

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: lineWidth)
            Circle().trim(from: 0, to: CGFloat(max(0, min(100, score))) / 100)
                .stroke(tint.map { LinearGradient(colors: [$0, $0.opacity(0.7)], startPoint: .leading, endPoint: .trailing) } ?? Theme.ringGradient,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundStyle(tint ?? Theme.accentText)
            } else {
                VStack(spacing: 3) {
                    Text("\(score)").font(.system(size: size * 0.29, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    if let caption { Text(caption).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary) }
                }
            }
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
    }
}

struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26
    var filled = true   // false: 色を薄く敷いてアイコンを色付きにする（カード見出し用）
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(filled ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.25)))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(filled ? Color.white : color.lightened(0.35)))
    }
}

/// ペイン上部の見出し: アイコン + タイトル + 説明 + 右側の操作
struct SectionHeader<Actions: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 22, weight: .heavy)).foregroundStyle(Theme.text)
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions }
        }
    }
}

/// 空状態: 機能色の大きな SF Symbol + 短い説明 + 主ボタン
struct EmptyStateView<Action: View>: View {
    let symbol: String
    let color: Color
    let message: String
    @ViewBuilder var action: Action
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 54, weight: .light)).foregroundStyle(color)
            Text(message).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            action
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// 常にダークで表示する（ウィンドウ・パネル共通）
    func oceanScheme() -> some View {
        self.preferredColorScheme(.dark).tint(Theme.teal).foregroundStyle(Theme.text)
    }
    /// リスト/テーブルを透明にしてカードに馴染ませる
    func themedList() -> some View {
        self.scrollContentBackground(.hidden).background(Color.clear)
    }
}

struct ThemedDivider: View {
    var body: some View { Rectangle().fill(Theme.cardBorder).frame(height: 1) }
}

/// カード下端の操作バー（選択件数・実行ボタンなど）
struct FooterBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            ThemedDivider()
            HStack(spacing: 8) { content }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.black.opacity(0.12))
        }
    }
}

/// 一覧の行（交互に薄い背景）
struct ThemedRow<Content: View>: View {
    let index: Int
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(index % 2 == 1 ? Theme.rowAlt : Color.clear)
    }
}
