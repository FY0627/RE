import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@main
struct BookkeepingApp: App {
    @State private var store = LedgerStore()
    @State private var rates = ExchangeRateStore()
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCurrency = "CNY"
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(rates)
                .preferredColorScheme(AppearanceMode(rawValue: appearance)?.colorScheme)
                .task { await store.start() }
                .onChange(of: scenePhase) { _, phase in
                    // 自动化在后台入账后，用户下次打开 App 时刷新
                    if phase == .active { store.scheduleRefresh() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .ledgerDidChange)) { _ in
                    store.scheduleRefresh()
                }
                // 换了主要币种：首页的本月合计重新换算
                .onChange(of: primaryCurrency) { store.scheduleRefresh() }
        }
    }
}
