import SwiftUI
import BKModel

/// 卡片详情里卡片下面、流水之前的部分：待处理提示；多币种的卡按币种分开看流水；
/// 「交易记录」标题、时间段和笔数（没有流水时还有「暂无流水」）。
/// 放在详情列表（`WalletDetailList`）里；卡片本身、流水和顶部按钮在别处。余额在卡片上，初始余额在「卡片信息」里。
struct AccountDetailSummary: View {
    let model: WalletDetailModel
    let openPending: () -> Void
    let selectCurrency: (CurrencyCode) -> Void
    let selectPeriod: (RecordPeriod) -> Void
    let chooseCustomPeriod: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.pendingCount > 0 {
                pendingStrip.padding(.bottom, 16)
            }
            if model.currencies.count > 1 {
                currencyPicker.padding(.bottom, 16)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("交易记录").font(.title3.weight(.semibold))
                periodMenu
                Spacer()
                Text("共 \(model.recordTotal) 笔").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            .padding(.bottom, 10)
            if !model.hasRecords {
                Text("暂无流水")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// 只有这张卡有待处理的账单时出现。
    private var pendingStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full").font(.title3).foregroundStyle(AppTheme.debt)
            Text("\(model.pendingCount) 条账单待处理").font(.headline).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .tapAction(openPending)
    }

    /// 每个币种的流水分开看。卡里没有的币种的交易按主币种扣款，放在主币种里
    @ViewBuilder
    private var currencyPicker: some View {
        let selection = Binding<CurrencyCode> {
            model.currency ?? model.currencies.first ?? .cny
        } set: { selectCurrency($0) }
        if model.currencies.count <= 4 {
            Picker("币种", selection: selection) {
                ForEach(model.currencies, id: \.self) { Text(Self.shortName($0)).tag($0) }
            }
            .pickerStyle(.segmented)
        } else {
            Picker("币种", selection: selection) {
                ForEach(model.currencies, id: \.self) { Text("\($0.chineseName) \($0.rawValue)").tag($0) }
            }
            .pickerStyle(.menu)
        }
    }

    /// 分段控件放得下的名称：中文名不超过 4 个字，否则用代码
    private static func shortName(_ code: CurrencyCode) -> String {
        code.chineseName.count <= 4 ? code.chineseName : code.rawValue
    }

    private var periodMenu: some View {
        Menu {
            ForEach(RecordPeriod.presets, id: \.self) { period in
                Button { selectPeriod(period) } label: {
                    if model.period == period { Label(period.title, systemImage: "checkmark") } else { Text(period.title) }
                }
            }
            Button(action: chooseCustomPeriod) {
                if model.period.isCustom { Label(model.period.title, systemImage: "checkmark") } else { Text("自定义…") }
            }
        } label: {
            HStack(spacing: 3) {
                Text(model.period.title)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
        }
        .accessibilityLabel("时间：\(model.period.title)")
    }
}

private extension View {
    /// 点按执行。不用 Button：按钮在手指横向划过后松手仍会触发，右滑返回时会同时点开它；点按手势一移动就不算
    func tapAction(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

/// 卡片详情里看哪段时间的流水（按收到通知的时间）
enum RecordPeriod: Hashable {
    case all
    case thisWeek
    case thisMonth
    case lastMonth
    case thisYear
    /// 含开始和结束那天
    case custom(from: Date, to: Date)

    static let presets: [RecordPeriod] = [.all, .thisWeek, .thisMonth, .lastMonth, .thisYear]

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .all: "全部"
        case .thisWeek: "本周"
        case .thisMonth: "本月"
        case .lastMonth: "上月"
        case .thisYear: "今年"
        case .custom(let from, let to): "\(Fmt.shortDate(from))–\(Fmt.shortDate(to))"
        }
    }

    /// 查询的时间范围：含 `from`，不含 `to`
    func range(now: Date = Date(), calendar: Calendar = .current) -> (from: Date?, to: Date?) {
        func interval(_ component: Calendar.Component, _ date: Date) -> (from: Date?, to: Date?) {
            guard let interval = calendar.dateInterval(of: component, for: date) else { return (nil, nil) }
            return (interval.start, interval.end)
        }
        switch self {
        case .all:
            return (nil, nil)
        case .thisWeek:
            return interval(.weekOfYear, now)
        case .thisMonth:
            return interval(.month, now)
        case .lastMonth:
            return interval(.month, calendar.date(byAdding: .month, value: -1, to: now) ?? now)
        case .thisYear:
            return interval(.year, now)
        case .custom(let from, let to):
            let start = calendar.startOfDay(for: min(from, to))
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to)))
            return (start, end)
        }
    }

    /// 自定义时打开的初始日期：当前的自定义范围，否则本月 1 日到今天
    var customDates: (from: Date, to: Date) {
        if case .custom(let from, let to) = self { return (from, to) }
        let now = Date()
        let start = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        return (start, now)
    }
}

/// 自定义时间段：选开始和结束日期
struct CustomPeriodSheet: View {
    let initial: (from: Date, to: Date)
    let apply: (RecordPeriod) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var from = Date()
    @State private var to = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("开始", selection: $from, in: ...to, displayedComponents: .date)
                DatePicker("结束", selection: $to, in: from..., displayedComponents: .date)
            }
            .navigationTitle("自定义时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") {
                        apply(.custom(from: from, to: to))
                        dismiss()
                    }
                }
            }
            .onAppear {
                from = initial.from
                to = initial.to
            }
        }
        .presentationDetents([.medium])
    }
}

struct PaletteGrid: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
            ForEach(CardPalette.all) { palette in
                Button { selection = palette.id } label: {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.gradient)
                        .frame(height: 64)
                        .overlay(alignment: .bottomLeading) {
                            Text(palette.name).font(.footnote.weight(.semibold)).foregroundStyle(palette.textColor).padding(10)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.accentColor, lineWidth: selection == palette.id ? 3 : 0)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(palette.name)
                .accessibilityAddTraits(selection == palette.id ? [.isSelected] : [])
            }
        }
    }
}
