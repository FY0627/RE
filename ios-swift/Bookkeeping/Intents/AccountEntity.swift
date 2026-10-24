import AppIntents
import Foundation
import BKModel

/// 快捷指令里可选择的银行卡账户。只暴露名称、银行和后四位。
struct AccountEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "银行卡账户"
    static let defaultQuery = AccountEntityQuery()

    let id: String
    let title: String
    let subtitle: String

    init(account: Account) {
        id = account.id
        title = "\(account.bankName) ·\(account.last4)"
        subtitle = "\(account.name) · \(account.cardType.displayName) · \(account.currency.rawValue)"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)", image: .init(systemName: "creditcard"))
    }
}

struct AccountEntityQuery: EntityQuery {
    init() {}

    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        let accounts = try await AppServices.shared.backend().accounts(includeArchived: true)
        return accounts.filter { identifiers.contains($0.id) }.map(AccountEntity.init)
    }

    func suggestedEntities() async throws -> [AccountEntity] {
        try await AppServices.shared.backend().accounts().map(AccountEntity.init)
    }
}
