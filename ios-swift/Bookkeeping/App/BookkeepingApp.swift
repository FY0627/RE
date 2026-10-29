import SwiftUI
import UIKit

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
    /// 桌面图标：浅色、深色各一套备用图标，系统是什么外观都保持这个颜色；
    /// 跟随系统时用主图标（它自己有深色外观）
    var iconName: String? {
        switch self {
        case .system: nil
        case .light: "AppIconLight"
        case .dark: "AppIconDark"
        }
    }

    /// 换成这个外观的桌面图标。每次换系统都会弹提示，所以图标已经对了就不换
    @MainActor func applyIcon() {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.alternateIconName != iconName else { return }
        Task { try? await app.setAlternateIconName(iconName) }
    }
}

@main
struct BookkeepingApp: App {
    @State private var store = LedgerStore()
    @State private var rates = ExchangeRateStore()
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCurrency = "CNY"
    @Environment(\.scenePhase) private var scenePhase

    private var appearanceMode: AppearanceMode { AppearanceMode(rawValue: appearance) ?? .system }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(rates)
                .preferredColorScheme(appearanceMode.colorScheme)
                .task { await store.start() }
                .onChange(of: scenePhase) { _, phase in
                    // 自动化在后台入账后，用户下次打开 App 时刷新
                    if phase == .active { store.scheduleRefresh() }
                }
                .onChange(of: appearance) { appearanceMode.applyIcon() }
                // 删掉重装后系统会换回主图标；打开 App 时对一下
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { appearanceMode.applyIcon() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .ledgerDidChange)) { _ in
                    store.scheduleRefresh()
                }
                // 换了主要币种：首页的本月合计重新换算
                .onChange(of: primaryCurrency) { store.scheduleRefresh() }
        }
    }
}
