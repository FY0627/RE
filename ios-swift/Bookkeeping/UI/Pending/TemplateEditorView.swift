import SwiftUI
import UIKit
import BKBackend
import BKModel

/// 用一条待处理的通知做识别模板：在原文里选中金额（必选）、尾号、对方，选好交易性质，保存。
///
/// 模板只保存在这台 iPhone；保存的是写法，选中的内容和原文里的其他数字都不保存。
/// 保存后，待处理里同样写法的通知按模板重新识别，之后收到的同样写法的通知先按模板识别。
struct TemplateEditorView: View {
    let item: PendingItem
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var sample = ""
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var amount: NSRange?
    @State private var cardTail: NSRange?
    @State private var counterparty: NSRange?
    @State private var kind: TransactionKind = .purchase
    @State private var direction: FlowDirection = .outflow
    @State private var name = ""
    @State private var errorText: String?
    @State private var saving = false
    @State private var savedCount: Int?

    private enum Mark {
        case amount, cardTail, counterparty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SelectableText(text: sample, highlights: highlights, selection: $selection)
                        .frame(height: 220)
                } header: {
                    Text("原文")
                } footer: {
                    Text("按住原文拖动选中一段，再在下面点「用选中的」。金额必须选。")
                }

                Section("选中的内容") {
                    markRow("金额", mark: .amount, range: amount, tint: .green, required: true)
                    markRow("尾号", mark: .cardTail, range: cardTail, tint: .blue, required: false)
                    markRow("对方", mark: .counterparty, range: counterparty, tint: .orange, required: false)
                }

                Section("这是什么交易") {
                    Picker("性质", selection: $kind) {
                        ForEach(TransactionKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("方向", selection: $direction) {
                        Text("流出").tag(FlowDirection.outflow)
                        Text("流入").tag(FlowDirection.inflow)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextField("模板名称", text: $name)
                } header: {
                    Text("名称")
                } footer: {
                    Text("模板只保存在这台 iPhone，不会发给任何人。保存的是写法：选中的金额、尾号、对方和原文里的其他数字都不保存。")
                }

                if case .success(let pieces)? = built {
                    Section("模板写法") {
                        Text(pieces.map(\.preview).joined()).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("做成识别模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await save() } }
                        .disabled(amount == nil || saving)
                }
            }
            .onAppear(perform: setup)
            .onChange(of: kind) { _, kind in
                if let preferred = Self.defaultDirection(kind) { direction = preferred }
            }
            .alert("已保存", isPresented: Binding(get: { savedCount != nil }, set: { if !$0 { savedCount = nil } })) {
                Button("好") { dismiss() }
            } message: {
                Text(savedCount.map { $0 > 0 ? "待处理里有 \($0) 条通知按这个模板重新识别。" : "之后收到同样写法的通知会按这个模板识别。" } ?? "")
            }
        }
    }

    private func markRow(_ title: String, mark: Mark, range: NSRange?, tint: Color, required: Bool) -> some View {
        HStack(spacing: 12) {
            Circle().fill(tint.opacity(0.6)).frame(width: 10, height: 10).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(range.map(substring) ?? (required ? "必选" : "可不选"))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if range != nil {
                Button("清除", systemImage: "xmark.circle.fill") { set(mark, nil) }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
            }
            Button("用选中的") { set(mark, selection) }
                .buttonStyle(.bordered)
                .disabled(selection.length == 0)
        }
    }

    private var highlights: [(range: NSRange, color: UIColor)] {
        var result: [(range: NSRange, color: UIColor)] = []
        if let amount { result.append((range: amount, color: UIColor.systemGreen.withAlphaComponent(0.3))) }
        if let cardTail { result.append((range: cardTail, color: UIColor.systemBlue.withAlphaComponent(0.3))) }
        if let counterparty { result.append((range: counterparty, color: UIColor.systemOrange.withAlphaComponent(0.3))) }
        return result
    }

    private var built: Result<[TemplatePiece], MessageTemplates.BuildError>? {
        guard let amount else { return nil }
        return MessageTemplates.build(sample: sample, amount: amount, cardTail: cardTail, counterparty: counterparty)
    }

    private func substring(_ range: NSRange) -> String {
        let ns = NSString(string: sample)
        guard NSMaxRange(range) <= ns.length else { return "" }
        return ns.substring(with: range)
    }

    private func set(_ mark: Mark, _ range: NSRange?) {
        switch mark {
        case .amount: amount = range
        case .cardTail: cardTail = range
        case .counterparty: counterparty = range
        }
        errorText = nil
        if case .failure(let error)? = built { errorText = error.message }
    }

    /// 用通用读法对这条通知的猜测预先填好：金额位置、性质、方向
    private func setup() {
        guard sample.isEmpty else { return }
        sample = MessageParser.cleaned(item.rawText ?? "", source: item.source)
        if let draft = item.draft {
            let found = NSString(string: sample).range(of: draft.amount.digits)
            if found.location != NSNotFound { amount = found }
            if draft.kind != .other { kind = draft.kind }
            if let preferred = draft.direction ?? Self.defaultDirection(draft.kind) { direction = preferred }
        }
        let bank = item.draft?.bankHint.flatMap { BankDirectory.profile(id: $0)?.name }
        name = [bank, kind.displayName + "通知"].compactMap { $0 }.joined(separator: " ")
    }

    private func save() async {
        guard case .success(let pieces)? = built else {
            if case .failure(let error)? = built { errorText = error.message }
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = MessageTemplate(
            id: UUID().uuidString, name: trimmedName.isEmpty ? kind.displayName + "通知" : trimmedName,
            pieces: pieces, kind: kind, direction: direction, createdAt: Date()
        )
        // 模板至少要认得出做它用的这条通知
        guard MessageTemplates.match(template, in: sample) != nil else {
            errorText = "用这个模板认不出这条通知，请换一种选法"
            return
        }
        saving = true
        defer { saving = false }
        do {
            savedCount = try await store.saveTemplate(template)
        } catch {
            errorText = "保存失败：\(error)"
        }
    }

    /// 性质决定方向时直接选好；还款、其他由用户选
    static func defaultDirection(_ kind: TransactionKind) -> FlowDirection? {
        switch kind {
        case .purchase, .transferOut, .interestCharge, .fee, .withdrawal: .outflow
        case .income, .salary, .transferIn, .refund, .deposit, .interestIncome, .reversal: .inflow
        case .repayment, .other: nil
        }
    }
}

/// 只读、可以用系统选择手柄选中的原文。选中范围按 UTF-16 计，与 `NSString` 一致。
struct SelectableText: UIViewRepresentable {
    let text: String
    let highlights: [(range: NSRange, color: UIColor)]
    @Binding var selection: NSRange

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: UIFont.preferredFont(forTextStyle: .callout), .foregroundColor: UIColor.label]
        )
        for highlight in highlights where NSMaxRange(highlight.range) <= attributed.length {
            attributed.addAttribute(.backgroundColor, value: highlight.color, range: highlight.range)
        }
        guard view.attributedText != attributed else { return }
        let selected = view.selectedRange
        view.attributedText = attributed
        if NSMaxRange(selected) <= attributed.length { view.selectedRange = selected }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableText

        init(parent: SelectableText) {
            self.parent = parent
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            if parent.selection != range { parent.selection = range }
        }
    }
}
