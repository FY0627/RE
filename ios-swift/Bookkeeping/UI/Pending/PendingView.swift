import SwiftUI
import BKModel

/// 待处理：只能「确认系统给出的候选」或「忽略」，不能借此手动编辑金额、方向、时间。
struct PendingView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PendingItem] = []
    @State private var log: [IngestLogEntry] = []
    @State private var loaded = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.footnote)
                }
                Section {
                    if items.isEmpty && loaded {
                        Text("没有待处理的通知").foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        PendingItemCard(item: item, accounts: store.accounts) { accountID in
                            await run { try await store.confirmPending(id: item.id, accountID: accountID) }
                        } ignore: {
                            await run { try await store.ignorePending(id: item.id) }
                        }
                    }
                } header: {
                    Text("待处理")
                } footer: {
                    Text("这些通知已经保存在本机，但信息不完整或有歧义，没有自动入账。")
                }
                Section {
                    ForEach(log.filter { $0.outcome == .filtered }.prefix(30)) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.classification.displayName).font(.subheadline)
                            Text("\(entry.source.displayName) · \(Fmt.dateTime(entry.processedAt))").font(.caption).foregroundStyle(.secondary)
                            if let raw = entry.rawText {
                                Text(raw).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                } header: {
                    Text("最近已过滤（未入账）")
                } footer: {
                    Text("验证码、营销、还款提醒、账单、额度变化、只有余额的通知不会记成交易。验证码正文不保存。")
                }
            }
            .navigationTitle("待处理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成", systemImage: "checkmark") { dismiss() } } }
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    private func reload() async {
        items = await store.pendingItems()
        log = await store.ingestLog()
        loaded = true
    }

    private func run(_ action: () async throws -> Void) async {
        do {
            try await action()
            errorText = nil
        } catch {
            errorText = "操作失败：\(error)"
        }
        await reload()
    }
}

private struct PendingItemCard: View {
    let item: PendingItem
    let accounts: [Account]
    let confirm: (String) async -> Void
    let ignore: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.reason.displayName).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(item.source.displayName) · \(Fmt.dateTime(item.receivedAt ?? item.createdAt))").font(.caption).foregroundStyle(.secondary)
            }
            if let draft = item.draft {
                Text(draftSummary(draft)).font(.footnote)
                Text(draft.evidenceSnippet).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            } else if let raw = item.rawText {
                Text(raw).font(.caption).foregroundStyle(.secondary).lineLimit(5)
            }
            if item.reason == .possibleDuplicate {
                Text("与另一来源（短信 / 邮件）的已有流水金额、账户一致，但证据不足以确定是同一笔。").font(.caption2).foregroundStyle(.secondary)
            }
            if item.reason.allowsConfirmation, item.draft != nil {
                ForEach(candidates) { account in
                    Button {
                        Task { await confirm(account.id) }
                    } label: {
                        Label(item.reason == .possibleDuplicate ? "不是重复，记入 \(account.bankName) ·\(account.last4)" : "记入 \(account.bankName) ·\(account.last4)", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button(role: .destructive) {
                Task { await ignore() }
            } label: {
                Label(item.reason == .possibleDuplicate ? "是重复，忽略" : "忽略", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private var candidates: [Account] {
        if item.candidateAccountIDs.isEmpty, let tail = item.draft?.cardTail {
            return accounts.filter { $0.last4 == tail }
        }
        return accounts.filter { item.candidateAccountIDs.contains($0.id) }
    }

    private func draftSummary(_ d: EventDraft) -> String {
        var parts: [String] = []
        let currency = d.amount.preferredCurrency?.rawValue ?? d.amount.currencyCandidates.map(\.rawValue).joined(separator: "/")
        parts.append("\(d.direction?.displayName ?? "方向未知") \(currency.isEmpty ? "" : currency + " ")\(d.amount.digits)")
        parts.append(d.kind.displayName)
        if let tail = d.cardTail { parts.append("尾号 \(tail)") }
        if let c = d.counterparty { parts.append(c) }
        if let t = d.transactionTime { parts.append(t.displayText) }
        return parts.joined(separator: " · ")
    }
}
