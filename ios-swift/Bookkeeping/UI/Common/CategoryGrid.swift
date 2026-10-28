import SwiftUI
import BKModel

/// 选分类：大类排成格子，点一下就选上；有小类的大类点开后下面列出它的小类（第一格是「不细分」，就记在大类上）。
/// 待分类、编辑流水、手动记一笔共用。隐藏的分类不出现。
struct CategoryGrid: View {
    let type: CategoryType
    var selected: String?
    let pick: (String) -> Void

    @Environment(LedgerStore.self) private var store
    @State private var expanded: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        let tree = store.categoryTree
        let nodes = tree.nodes(type)
        let selectedTop = tree.topLevel(selected)?.id
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(nodes) { node in
                    cell(node.category.name, symbol: node.category.symbol, on: selectedTop == node.id || expanded == node.id) {
                        if node.children.isEmpty {
                            expanded = nil
                            pick(node.id)
                        } else {
                            expanded = expanded == node.id ? nil : node.id
                        }
                    }
                }
            }
            if let node = nodes.first(where: { $0.id == expanded }) {
                Divider()
                LazyVGrid(columns: columns, spacing: 12) {
                    cell("不细分", symbol: node.category.symbol, on: selected == node.id) { pick(node.id) }
                    ForEach(node.children) { child in
                        cell(child.name, symbol: child.symbol, on: selected == child.id) { pick(child.id) }
                    }
                }
            }
        }
        .onAppear {
            // 选中的是小类：把它所在的大类展开
            if let category = tree.category(selected), let parent = category.parentID { expanded = parent }
        }
    }

    private func cell(_ name: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(on ? Color.accentColor : Color.primary)
                    .frame(width: 48, height: 48)
                    .background(on ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06), in: Circle())
                Text(name)
                    .font(.caption)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// 面板里选一个分类，选好就关上
struct CategoryPickerSheet: View {
    let type: CategoryType
    var selected: String?
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                CategoryGrid(type: type, selected: selected) { id in
                    pick(id)
                    dismiss()
                }
                .padding()
            }
            .navigationTitle("选择分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 选图标
struct SymbolPicker: View {
    @Binding var symbol: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 12) {
                ForEach(CategorySymbols.all, id: \.self) { name in
                    Button {
                        symbol = name
                        dismiss()
                    } label: {
                        Image(systemName: name)
                            .font(.title3)
                            .foregroundStyle(symbol == name ? Color.accentColor : Color.primary)
                            .frame(width: 48, height: 48)
                            .background(symbol == name ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                }
            }
            .padding()
        }
        .navigationTitle("选择图标")
        .navigationBarTitleDisplayMode(.inline)
    }
}
