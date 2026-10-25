import SwiftUI
import BKModel

/// 多币种账户的其他币种：常用币种列表，点按勾选。添加银行卡和卡片信息共用。
struct ExtraCurrencyList: View {
    let primary: CurrencyCode?
    @Binding var selection: [CurrencyCode]

    var body: some View {
        ForEach(CurrencyCode.common.filter { $0 != primary }, id: \.self) { code in
            let selected = selection.contains(code)
            Button {
                if let index = selection.firstIndex(of: code) { selection.remove(at: index) } else { selection.append(code) }
            } label: {
                HStack {
                    Text("\(code.chineseName) \(code.rawValue)").foregroundStyle(.primary)
                    Spacer()
                    if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
                .contentShape(Rectangle())
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}
