import SwiftUI
import BKModel

/// 卡面（原型 `_walletCardFace`）：渐变底或自定义图片、机构圆标、名称与卡类型、余额、尾号。
/// 文字颜色和大小可以在「编辑卡面」里自定义。
struct WalletCardView: View {
    let account: Account
    let balanceText: String
    let hideBalance: Bool
    let height: CGFloat
    /// 0 = 堆叠中，1 = 详情页；阴影随之加深
    var elevation: CGFloat = 0

    var body: some View {
        let palette = CardPalette.named(account.paletteID)
        let flags = PerfFlags.shared
        face(palette)
            .frame(height: height)
            .modifier(CardRasterization(enabled: flags.rasterizeCards))
            .shadow(
                color: flags.cardShadows ? .black.opacity(0.12 + 0.10 * elevation) : .clear,
                radius: flags.cardShadows ? (4 + 14 * elevation) / 2 : 0,
                y: -1.5 + 9.5 * elevation
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(account.bankName) \(account.cardType.displayName) 尾号\(account.last4)，\(hideBalance ? "余额已隐藏" : balanceText)")
    }

    private func face(_ palette: CardPalette) -> some View {
        let style = account.face
        let s = style.textScale
        let text = style.textColor.map { Color(hex: $0) } ?? palette.textColor
        let subtext = style.textColor == nil ? palette.subtextColor : text.opacity(0.75)
        return ZStack(alignment: .topLeading) {
            background(palette, imageID: style.imageID)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(text.opacity(0.15))
                            .frame(width: 30 * s, height: 30 * s)
                            .overlay(Text(String(account.bankName.prefix(1))).font(.system(size: 14 * s, weight: .bold)))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(account.name).font(.system(size: 14 * s, weight: .bold)).lineLimit(1)
                            Text("\(account.bankName) · \(account.cardType.displayName)")
                                .font(.system(size: 11 * s, weight: .medium))
                                .foregroundStyle(subtext)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        Image(systemName: "wave.3.right").font(.system(size: 13 * s)).opacity(0.8)
                        Text(hideBalance ? "••••" : balanceText).font(.system(size: 14 * s, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                Spacer(minLength: 0)
                HStack(alignment: .lastTextBaseline) {
                    Text("•••• \(account.last4)").font(.system(size: 15 * s, weight: .semibold)).tracking(1.2)
                    Spacer()
                    Text(account.currency.rawValue).font(.system(size: 12 * s, weight: .bold)).italic().opacity(0.8)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .foregroundStyle(text)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// 自定义图片在后台解码完成之前先显示配色渐变。
    @ViewBuilder
    private func background(_ palette: CardPalette, imageID: String?) -> some View {
        if let imageID, let image = CardFaceImages.shared.image(imageID) {
            Color.clear
                .overlay { Image(uiImage: image).resizable().scaledToFill() }
                .clipped()
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(palette.gradient)
        }
    }
}

/// 单变量开关：卡面是否先合成为一张离屏位图。
private struct CardRasterization: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.drawingGroup() } else { content }
    }
}

extension AccountBalanceSummary {
    /// 卡面上显示的余额：银行通知余额，或从你填写的初始余额推算的余额；
    /// 两者都没有时显示「余额未知」，不用部分流水冒充。
    var cardText: String {
        switch base {
        case .bankReported:
            guard let reported = bankReported else { return "余额未知" }
            return Fmt.money(reported.amountMinor, reported.currency)
        case .opening:
            guard let derived = ledgerDerivedMinor, let currency = ledgerDerivedCurrency else { return "余额未知" }
            return Fmt.money(derived, currency)
        case .none:
            return "余额未知"
        }
    }
}
