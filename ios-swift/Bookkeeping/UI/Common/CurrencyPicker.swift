import SwiftUI
import BKModel

/// 选币种的一项：国旗、中文名、代码和英文名。搜索时还比较繁体、手机语言的名称和国家 / 地区名。
struct CurrencyEntry: Identifiable, Hashable, Sendable {
    let code: CurrencyCode
    let name: String
    /// 例如「HKD · Hong Kong Dollar」
    let detail: String
    let flag: String?
    let keys: [String]
    var id: String { code.rawValue }
}

/// 选币种页面「全部币种」里的一组：中文名称拼音首字母相同的币种
struct CurrencySection: Identifiable, Sendable {
    let letter: String
    let entries: [CurrencyEntry]
    var id: String { letter }
}

/// 汇率数据源支持的全部币种。第一次用到时生成（要查系统的名称），添加银行卡等页面出现时先在后台准备好。
enum CurrencyCatalog {
    /// 按中文名称的拼音排序
    static let all: [CurrencyEntry] = CurrencyCode.supported.map(makeEntry)
        .sorted { $0.name.compare($1.name, locale: simplifiedChinese) == .orderedAscending }
    static let common: [CurrencyEntry] = CurrencyCode.common.map(entry)
    /// 按拼音首字母 A–Z 分组（侧边的字母索引跳到这里），不是字母开头的放在最后的「#」
    static let sections: [CurrencySection] = {
        var groups: [String: [CurrencyEntry]] = [:]
        for entry in all { groups[initial(entry.name), default: []].append(entry) }
        return groups.keys
            .sorted { a, b in a == "#" ? false : b == "#" ? true : a < b }
            .map { CurrencySection(letter: $0, entries: groups[$0] ?? []) }
    }()

    static func entry(_ code: CurrencyCode) -> CurrencyEntry {
        byCode[code.rawValue] ?? makeEntry(code)
    }

    /// 名称完全一样 > 开头一样 > 包含；同样像时按列表顺序
    static func search(_ query: String) -> [CurrencyEntry] {
        let q = BankCatalog.normalize(query)
        guard !q.isEmpty else { return all }
        var scored: [(score: Int, order: Int, entry: CurrencyEntry)] = []
        for (order, entry) in all.enumerated() {
            var best = Int.max
            for key in entry.keys {
                if key == q { best = 0; break }
                if key.hasPrefix(q) { best = min(best, 1) } else if key.contains(q) { best = min(best, 2) }
            }
            if best < Int.max { scored.append((best, order, entry)) }
        }
        return scored.sorted { ($0.score, $0.order) < ($1.score, $1.order) }.map(\.entry)
    }

    /// 在后台生成列表，打开选币种页面时不卡
    static func prepare() async {
        await Task.detached(priority: .utility) { _ = CurrencyCatalog.sections.count }.value
    }

    /// 名称拼音的首字母（大写）
    private static func initial(_ name: String) -> String {
        let latin = name.applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? name
        guard let first = latin.uppercased().unicodeScalars.first, first.isASCII, CharacterSet.uppercaseLetters.contains(first) else {
            return "#"
        }
        return String(first)
    }

    private static let byCode: [String: CurrencyEntry] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    private static let simplifiedChinese = Locale(identifier: "zh_Hans")
    private static let nameLocales = [Locale(identifier: "zh_Hant"), Locale.current]
    private static let regionLocales = [Locale(identifier: "zh_Hans"), Locale(identifier: "zh_Hant"), Locale(identifier: "en"), Locale.current]
    private static let isoRegions = Set(Locale.Region.isoRegions.map(\.identifier))

    private static func makeEntry(_ code: CurrencyCode) -> CurrencyEntry {
        let raw = code.rawValue
        let region = regionCode(raw)
        var names = [raw, code.chineseName, code.englishName]
        names += nameLocales.compactMap { $0.localizedString(forCurrencyCode: raw) }
        if let region { names += regionLocales.compactMap { $0.localizedString(forRegionCode: region) } }
        var keys: [String] = []
        for name in names {
            let key = BankCatalog.normalize(name)
            if !key.isEmpty, !keys.contains(key) { keys.append(key) }
        }
        let detail = code.englishName == raw ? raw : "\(raw) · \(code.englishName)"
        return CurrencyEntry(code: code, name: code.chineseName, detail: detail, flag: region.map(flag), keys: keys)
    }

    /// 币种代码的前两位多数是国家 / 地区代码；欧元用欧盟。X 开头的是多国共用的货币，没有国旗
    private static func regionCode(_ code: String) -> String? {
        if code == "EUR" { return "EU" }
        guard code.count == 3, !code.hasPrefix("X") else { return nil }
        let region = String(code.prefix(2))
        return isoRegions.contains(region) ? region : nil
    }

    private static func flag(_ region: String) -> String {
        String(String.UnicodeScalarView(region.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }))
    }
}

/// 选币种：全部 160 多种币种，带国旗，按拼音首字母分组，侧边的 A–Z 索引可以直接跳；
/// 最下面的搜索框可以打中文、英文、代码或国家名，也可以直接往下翻着选。
/// 单选（币种、主币种、主要币种）点一下就返回；多选（多币种账户的其他币种）勾好后点「完成」返回。
struct CurrencyPicker: View {
    let title: String
    @Binding var selection: [CurrencyCode]
    let multiple: Bool
    /// 多选其他币种时的主币种：排在已选的最前面，不能取消
    var fixed: CurrencyCode?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                if !chosen.isEmpty {
                    Section("已选") { ForEach(chosen) { row($0) } }
                }
                Section("常用") { ForEach(CurrencyCatalog.common) { row($0) } }
                ForEach(CurrencyCatalog.sections) { section in
                    Section(section.letter) { ForEach(section.entries) { row($0) } }
                        .sectionIndexLabel(Text(section.letter))
                }
            } else {
                let results = CurrencyCatalog.search(query)
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(results) { row($0) }
                }
            }
        }
        .listSectionIndexVisibility(.visible)
        // 收起键盘时列表跟着变高，变高之前露出的是页面底色（浅色模式是白色），看起来像一块白的在闪。
        // 列表后面铺满和列表一样的底色（盖到键盘那块区域），就看不出来
        .background { Color(.systemGroupedBackground).ignoresSafeArea() }
        .scrollDismissesKeyboard(.immediately)
        .searchable(text: $query, prompt: "币种、代码或国家")
        .autocorrectionDisabled()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if multiple {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private var chosen: [CurrencyEntry] {
        let codes = (fixed.map { [$0] } ?? []) + selection.filter { $0 != fixed }
        return codes.map(CurrencyCatalog.entry)
    }

    private func row(_ entry: CurrencyEntry) -> some View {
        let isFixed = entry.code == fixed
        let isSelected = isFixed || selection.contains(entry.code)
        return Button {
            choose(entry.code)
        } label: {
            HStack(spacing: 12) {
                // 颜色用 Color.primary / Color.secondary：按钮里的层级样式 .primary 会跟着强调色变成蓝色
                Group {
                    if let flag = entry.flag {
                        Text(flag).font(.title2)
                    } else {
                        Image(systemName: "globe").font(.title3).foregroundStyle(Color.secondary)
                    }
                }
                .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isFixed ? "\(entry.name)（主币种）" : entry.name).foregroundStyle(isFixed ? Color.secondary : Color.primary)
                    Text(entry.detail).font(.footnote).foregroundStyle(Color.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(isFixed)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func choose(_ code: CurrencyCode) {
        if multiple {
            if let index = selection.firstIndex(of: code) { selection.remove(at: index) } else { selection.append(code) }
        } else {
            selection = [code]
            dismiss()
        }
    }
}

/// 表单里的一行：点开选币种页面（单选）
struct CurrencyLink: View {
    let title: String
    @Binding var currency: CurrencyCode?

    var body: some View {
        NavigationLink {
            CurrencyPicker(title: title, selection: Binding { currency.map { [$0] } ?? [] } set: { currency = $0.first }, multiple: false)
        } label: {
            LabeledContent(title, value: currency.map { "\($0.chineseName) \($0.rawValue)" } ?? "请选择")
        }
    }
}
