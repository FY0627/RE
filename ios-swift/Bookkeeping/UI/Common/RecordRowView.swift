import SwiftUI
import BKModel

/// 流水行：金额、方向、交易对方、尾号、时间、备注。字号用系统文字样式，跟随「更大字体」设置。
/// 在系统列表里直接使用；在自定义滚动页面里用 `boxed: true` 自带卡片背景。
struct RecordRowView: View {
    let row: RecordRow
    var showAccount = true
    var boxed = false

    var body: some View {
        let r = row.record
        let counted = r.status == .posted
        HStack(spacing: 12) {
            Image(systemName: r.kind.symbolName)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.counterparty ?? r.kind.displayName)
                        .font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    if r.status != .posted { badge(r.status.displayName) }
                    if r.isInternalTransfer { badge("内部转账") }
                }
                Text(subtitle(r))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if !r.note.isEmpty {
                    Text(r.note).font(.subheadline).foregroundStyle(Color.primary.opacity(0.8)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(Fmt.signed(r))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(r.direction == .inflow ? AppTheme.income : Color.primary)
                .strikethrough(r.status == .failed)
                .opacity(counted ? 1 : 0.55)
        }
        .padding(.vertical, boxed ? 12 : 2)
        .padding(.horizontal, boxed ? 14 : 0)
        .background {
            if boxed {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ r: LedgerRecord) -> String {
        var parts = [Fmt.recordTime(r), r.kind.displayName]
        if showAccount { parts.append("\(row.bankName) ·\(row.last4)") }
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

/// 以面板方式打开流水详情（没有导航栈的页面使用）。
struct RecordDetailSheet: View {
    let recordID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RecordDetailView(recordID: recordID)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", systemImage: "xmark") { dismiss() }
                    }
                }
        }
    }
}

/// 单笔流水详情：所有字段只读，唯一可编辑的是备注。
struct RecordDetailView: View {
    let recordID: String
    @Environment(LedgerStore.self) private var store
    @State private var detail: RecordDetail?
    @State private var note = ""
    @State private var saving = false
    @State private var saveError: String?
    @State private var showRaw = false

    var body: some View {
        Group {
            if let detail {
                form(detail)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("流水详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存备注") { Task { await save() } }
                    .disabled(saving || detail == nil || note == detail?.row.record.note)
            }
        }
        .task {
            detail = await store.detail(recordID: recordID)
            note = detail?.row.record.note ?? ""
        }
    }

    private func form(_ detail: RecordDetail) -> some View {
        let r = detail.row.record
        return Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.counterparty ?? r.kind.displayName).font(.headline)
                    Text(Fmt.signed(r))
                        .font(.largeTitle.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(r.direction == .inflow ? AppTheme.income : Color.primary)
                }
                .padding(.vertical, 4)
                LabeledContent("方向", value: r.direction.displayName)
                LabeledContent("交易性质", value: r.kind.displayName)
                LabeledContent("状态", value: r.status.displayName)
                if let fee = r.includedFeeMinor { LabeledContent("通知金额含手续费", value: Fmt.money(fee, r.currency) + "（已单列）") }
            }
            Section {
                LabeledContent("账户", value: "\(detail.row.bankName) ·\(detail.row.last4)")
                LabeledContent("交易对方", value: r.counterparty ?? "通知未写明")
                LabeledContent("交易时间（通知内）", value: r.transactionTime?.displayText ?? "通知未写明")
                LabeledContent("接收时间（系统）", value: r.receivedAt.map { Fmt.dateTime($0) } ?? "系统未提供")
                LabeledContent("处理时间", value: Fmt.dateTime(r.processedAt))
                LabeledContent("来源", value: Set(detail.evidence.map(\.source)).map(\.displayName).sorted().joined(separator: " + "))
                if let ref = r.bankReference { LabeledContent("交易标识", value: ref) }
                if let balance = r.balanceAfterMinor { LabeledContent("通知中的余额", value: Fmt.money(balance, r.currency)) }
            }
            if let peer = detail.transferPeer {
                Section("内部转账") {
                    LabeledContent("对方账户", value: "\(peer.bankName) ·\(peer.last4)")
                    Text("不计入收支").font(.footnote).foregroundStyle(.secondary)
                }
            } else if r.isInternalTransfer {
                Section("内部转账") {
                    Text("转到你自己的另一张卡，不计入收支").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let related = detail.related {
                Section("关联的原交易") {
                    RecordRowView(row: related)
                }
            }
            Section {
                TextField("添加备注", text: $note, axis: .vertical)
                    .lineLimit(1...5)
                if let saveError { Text(saveError).font(.footnote).foregroundStyle(.red) }
            } header: {
                Text("备注")
            }
            Section {
                DisclosureGroup("原始通知（仅本机保存）", isExpanded: $showRaw) {
                    ForEach(detail.evidence, id: \.ingestID) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(e.source.displayName) · \(Fmt.dateTime(e.processedAt))").font(.caption).foregroundStyle(.secondary)
                            Text(e.rawText ?? "原文已按保留期限清理").font(.footnote).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await store.updateNote(recordID: recordID, note: note)
            detail?.row.record.note = note
            saveError = nil
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }
}
