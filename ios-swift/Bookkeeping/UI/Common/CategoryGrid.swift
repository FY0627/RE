import SwiftUI
import BKModel

/// 选分类：大类排成格子，点一下就选上；有小类的大类名称旁有个小箭头，点它在下面展开小类
/// （横线隔开，放在一个框里，第一格是「不细分」，就记在大类上）。待分类、编辑流水、手动记一笔共用。隐藏的分类不出现。
///
/// 只有选中的分类（或选中的小类所在的大类）是选中的样子；展开着、没选的大类只描一圈边，不会看起来像两个都选了。
/// 格子不用懒加载的网格：放在列表的一行里时，懒加载会在行高变化时重新摆放，图标上下跳一下。
struct CategoryGrid: View {
    let type: CategoryType
    var selected: String?
    let pick: (String) -> Void

    @Environment(LedgerStore.self) private var store
    @State private var expanded: String?

    private static let columns = 4

    private enum CellState {
        case normal
        /// 展开了小类，但没选它
        case open
        case selected
    }

    private struct Cell: Identifiable {
        let id: String
        let name: String
        let symbol: String
        var hasChildren = false
    }

    var body: some View {
        let tree = store.categoryTree
        let nodes = tree.nodes(type)
        let selectedTop = tree.topLevel(selected)?.id
        VStack(alignment: .leading, spacing: 12) {
            rows(nodes.map { Cell(id: $0.id, name: $0.category.name, symbol: $0.category.symbol, hasChildren: !$0.children.isEmpty) }) { cell in
                let state: CellState = selectedTop == cell.id ? .selected : expanded == cell.id ? .open : .normal
                return button(cell, state: state) {
                    if cell.hasChildren {
                        withAnimation(.snappy(duration: 0.3)) { expanded = expanded == cell.id ? nil : cell.id }
                    } else {
                        withAnimation(.snappy(duration: 0.3)) { expanded = nil }
                        pick(cell.id)
                    }
                }
            }
            if let node = nodes.first(where: { $0.id == expanded }) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(node.category.name)的小类").font(.footnote).foregroundStyle(.secondary)
                    let cells = [Cell(id: node.id, name: "不细分", symbol: node.category.symbol)]
                        + node.children.map { Cell(id: $0.id, name: $0.name, symbol: $0.symbol) }
                    rows(cells) { cell in
                        button(cell, state: selected == cell.id ? .selected : .normal) { pick(cell.id) }
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .top) {
                    // 和上面的大类隔开的横线
                    Divider().offset(y: -7)
                }
                .padding(.top, 2)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                    removal: .opacity
                ))
            }
        }
        .onAppear {
            // 选中的是小类：把它所在的大类展开
            if let category = tree.category(selected), let parent = category.parentID { expanded = parent }
        }
    }

    /// 每行 4 格；最后一行不满时用空白补齐，格子宽度不变
    private func rows<Content: View>(_ cells: [Cell], content: @escaping (Cell) -> Content) -> some View {
        let lines = stride(from: 0, to: cells.count, by: Self.columns).map { Array(cells[$0..<min($0 + Self.columns, cells.count)]) }
        return VStack(spacing: 12) {
            ForEach(lines.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 6) {
                    ForEach(lines[index]) { cell in content(cell) }
                    ForEach(0..<(Self.columns - lines[index].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
        }
    }

    private func button(_ cell: Cell, state: CellState, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: cell.symbol)
                    .font(.title3)
                    .foregroundStyle(state == .selected ? Color.accentColor : Color.primary)
                    .frame(width: 48, height: 48)
                    .background(state == .selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06), in: Circle())
                    .overlay {
                        if state == .open { Circle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5) }
                    }
                HStack(spacing: 2) {
                    Text(cell.name)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if cell.hasChildren {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.secondary)
                            .rotationEffect(.degrees(state == .open || expanded == cell.id ? 180 : 0))
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cell.name)
        .accessibilityHint(Text(cell.hasChildren ? "展开小类" : ""))
        .accessibilityAddTraits(state == .selected ? [.isSelected] : [])
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
