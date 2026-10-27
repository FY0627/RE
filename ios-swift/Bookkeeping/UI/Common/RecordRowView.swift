import SwiftUI
import BKModel

/// 流水行：金额、方向、交易对方、尾号、时间、备注。卡里没有这笔流水的币种时，金额下面写按主币种扣了多少。
/// 字号用系统文字样式，跟随「更大字体」设置。在系统列表里直接使用；在自定义滚动页面里用 `boxed: true` 自带卡片背景。
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
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.signed(r))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(r.direction == .inflow ? AppTheme.income : Color.primary)
                    .strikethrough(r.status == .failed)
                if let charge = row.charge {
                    Text(Fmt.charge(charge)).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
            }
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

/// 单笔流水详情。右上角「编辑」可以改金额、币种、收支、类型、账户、交易对方、时间、备注和实际扣款；最下面可以删除。
/// 来源和通知原文只能看。
struct RecordDetailView: View {
    let recordID: String
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var detail: RecordDetail?
    @State private var saveError: String?
    @State private var showRaw = false
    @State private var editing = false
    @State private var confirmDelete = false

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
                Button("编辑") { editing = true }
                    .disabled(detail == nil)
            }
        }
        .sheet(isPresented: $editing) {
            if let detail {
                RecordEditor(detail: detail) { Task { await reload() } }
            }
        }
        .confirmationDialog("删除这笔流水？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await delete() } }
        } message: {
            Text("删除后不能恢复。收到它的那条通知再来，也不会重新记上。")
        }
        .task { await reload() }
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
                if let charge = detail.row.charge {
                    chargeRow(charge, record: r)
                }
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
            if (r.kind == .transferIn || r.kind == .transferOut), r.transferGroupID == nil {
                Section("转账对方") {
                    Picker(r.direction == .outflow ? "转给" : "来自", selection: Binding(
                        get: { r.transferParty },
                        set: { party in Task { await setTransferParty(party) } }
                    )) {
                        Text("未确认").tag(TransferParty?.none)
                        Text("自己的账户").tag(TransferParty?.some(.own))
                        Text("别人").tag(TransferParty?.some(.other))
                    }
                }
            }
            if let peer = detail.transferPeer {
                Section("内部转账") {
                    LabeledContent("对方账户", value: "\(peer.bankName) ·\(peer.last4)")
                }
            } else if r.isInternalTransfer {
                Section("内部转账") {
                    LabeledContent("对方账户", value: "你自己的另一张卡")
                }
            }
            if let related = detail.related {
                Section("关联的原交易") {
                    RecordRowView(row: related)
                }
            }
            if !r.note.isEmpty {
                Section("备注") {
                    Text(r.note).textSelection(.enabled)
                }
            }
            if let saveError {
                Section { Text(saveError).font(.footnote).foregroundStyle(.red) }
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
            Section {
                Button("删除这笔流水", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
    }

    /// 卡里没有这个币种：按主币种扣了多少（估算的写明用哪天的汇率）
    private func chargeRow(_ charge: RecordCharge, record: LedgerRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(record.direction == .inflow ? "存入\(charge.currency.chineseName)" : "从\(charge.currency.chineseName)扣款") {
                Text(charge.amountMinor.map { Fmt.money($0, charge.currency) } ?? "还没有汇率").monospacedDigit()
            }
            Text(chargeNote(charge)).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func chargeNote(_ charge: RecordCharge) -> String {
        if charge.isActual { return "你填写的实际金额" }
        guard let day = charge.rateDay else { return "导入汇率后按交易当天的汇率估算，可以在编辑里改成实际金额" }
        return "按 \(Fmt.rateDay(day)) 的汇率估算，可以在编辑里改成实际金额"
    }

    private func reload() async {
        detail = await store.detail(recordID: recordID)
    }

    private func setTransferParty(_ party: TransferParty?) async {
        do {
            try await store.setTransferParty(recordID: recordID, party: party)
            await reload()
            saveError = nil
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }

    private func delete() async {
        do {
            try await store.deleteRecord(id: recordID)
            dismiss()
        } catch {
            saveError = "删除失败：\(error.localizedDescription)"
        }
    }
}
