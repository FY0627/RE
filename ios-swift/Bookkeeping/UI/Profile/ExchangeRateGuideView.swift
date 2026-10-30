import SwiftUI
import UIKit
import BKBackend

/// 「用快捷指令更新汇率」：添加共享的快捷指令「导入汇率」（获取 URL 内容 → App 动作「导入汇率」），
/// 再建一个打开 App 时运行它的自动化。联网的是快捷指令，App 自己不联网。
struct ExchangeRateGuideView: View {
    /// 共享的快捷指令「导入汇率」：下载 `ExchangeRateFeed.url` 的汇率，交给 App 动作「导入汇率」，用户不用自己搭
    static let shortcutURL = URL(string: "https://www.icloud.com/shortcuts/22f748b09286411b98d5af7ac8b5cff7")!

    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                Text("App 不联网也能换算").font(.title2.weight(.bold))
                    .padding(.vertical, 4)
                HStack(spacing: 12) {
                    Button {
                        leave(to: Self.shortcutURL)
                    } label: {
                        Label("添加快捷指令", systemImage: "plus.square.on.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    Button {
                        if let url = URL(string: "shortcuts://") { leave(to: url) }
                    } label: {
                        Label("打开快捷指令", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    StepRow(number: index + 1, text: step)
                }
            } header: {
                Text("3 步完成")
            }
        }
        .navigationTitle("用快捷指令更新汇率")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 导入成功后 App 发通知：离开 App 前先要通知权限
    private func leave(to url: URL) {
        Task {
            _ = await IngestNotifier.requestAuthorization()
            openURL(url)
        }
    }

    static let steps: [LocalizedStringKey] = [
        "点上面 **添加快捷指令**，在打开的页面点 **添加快捷指令**。它会下载最新汇率，交给日常记账导入。",
        "点 **打开快捷指令**，在底部选 **自动化**，点右上角 **+**，选 **App** → **日常记账** → 勾选 **已打开**，选 **立即运行**，点 **下一步**。",
        "在列表里选刚添加的 **导入汇率**。以后每次打开 App，汇率都会自动更新。",
    ]
}
