import SwiftUI
import UIKit
import BKBackend

/// 「用快捷指令更新汇率」：由快捷指令下载汇率并交给 App 动作「导入汇率」，App 自己不联网。
struct ExchangeRateGuideView: View {
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Text("App 不联网也能换算").font(.title2.weight(.bold))
                    .padding(.vertical, 4)
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = ExchangeRateFeed.url.absoluteString
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制汇率地址", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    Button {
                        if let url = URL(string: "shortcuts://") { openURL(url) }
                    } label: {
                        Label("打开快捷指令", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
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
                Text("4 步完成")
            }
        }
        .navigationTitle("用快捷指令更新汇率")
        .navigationBarTitleDisplayMode(.inline)
    }

    static let steps: [LocalizedStringKey] = [
        "点上面 **复制汇率地址**，再点 **打开快捷指令**，在底部选 **自动化**，点右上角 **+**。",
        "选 **App** → 选 **日常记账** → 勾选 **已打开**；或者选 **特定时间**，设成每天几点。然后选 **立即运行**，点 **下一步**。",
        "点 **新建空白自动化** → **添加操作**，搜索 **获取 URL 内容** 并添加，把地址粘贴进去。",
        "再添加 **导入汇率**，确认 **汇率数据** 显示为 **URL 的内容**（没有就点它选上），点 **完成**。",
    ]
}
