import SwiftUI
import BKModel

/// 「我的 › 自动记账 › 识别模板」：本机做的模板，可以删除。新模板在「待处理」里用一条通知做。
struct TemplateListView: View {
    @Environment(LedgerStore.self) private var store
    @State private var templates: [MessageTemplate] = []
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                if templates.isEmpty && loaded {
                    Text("还没有识别模板").foregroundStyle(.secondary)
                }
                ForEach(templates) { template in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(template.name).font(.headline)
                        Text("\(template.kind.displayName) · \(template.direction.displayName)")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(template.preview)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    let ids = offsets.map { templates[$0].id }
                    Task {
                        for id in ids { try? await store.deleteTemplate(id: id) }
                        await reload()
                    }
                }
            } footer: {
                Text("在「待处理」里点一条通知的「做成识别模板」来添加。模板只保存在这台 iPhone；同样写法的通知会先按模板识别。")
            }
        }
        .navigationTitle("识别模板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !templates.isEmpty { EditButton() }
        }
        .task { await reload() }
    }

    private func reload() async {
        templates = await store.templates()
        loaded = true
    }
}
