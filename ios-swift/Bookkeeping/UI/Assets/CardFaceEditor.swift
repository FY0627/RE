import SwiftUI
import PhotosUI
import UIKit
import BKModel

/// 编辑卡面：配色或相册图片作背景，文字颜色和大小。只影响显示，不影响账户匹配。
/// 选图后立即裁剪缩小存成文件；没有保存就关闭时删除这次新存的图片。
struct CardFaceEditor: View {
    let accountID: String
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var paletteID = ""
    @State private var face = CardFace.standard
    @State private var loaded = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var importing = false
    @State private var saving = false
    @State private var saved = false
    @State private var importedIDs: [String] = []
    @State private var errorText: String?
    /// 预览卡片的像素宽度：选图时缩小到这个尺寸
    @State private var pixelWidth: CGFloat = 1080

    var body: some View {
        NavigationStack {
            if let account = store.account(id: accountID) {
                form(account)
            }
        }
        .onDisappear {
            // 没有保存：删除这次选过的图片
            if !saved { CardFaceImages.shared.discard(importedIDs) }
        }
    }

    private func form(_ account: Account) -> some View {
        var preview = account
        preview.paletteID = paletteID
        preview.face = face
        let palette = CardPalette.named(paletteID)
        return Form {
            Section {
                Color.clear
                    .aspectRatio(AppLayout.cardAspect, contentMode: .fit)
                    .overlay {
                        WalletCardView(
                            account: preview,
                            balanceText: store.balances[account.id]?.cardText ?? "余额未知"
                        )
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pixelWidth = min(1200, $0 * displayScale) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            Section {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    HStack {
                        Label(face.imageID == nil ? "从相册选择图片" : "更换图片", systemImage: "photo")
                        Spacer()
                        if importing { ProgressView() }
                    }
                }
                .disabled(importing)
                if face.imageID != nil {
                    Button("移除图片", systemImage: "trash", role: .destructive) { face.imageID = nil }
                }
            } header: {
                Text("背景图片")
            }

            Section(face.imageID == nil ? "配色" : "配色（移除图片后显示）") {
                PaletteGrid(selection: $paletteID).padding(.vertical, 4)
            }

            Section("文字") {
                ColorPicker("文字颜色", selection: textColor(default: palette.text), supportsOpacity: false)
                if face.textColor != nil {
                    Button("恢复默认颜色") { face.textColor = nil }
                }
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("文字大小", value: "\(Int((face.textScale * 100).rounded()))%")
                    Slider(value: $face.textScale, in: CardFace.textScaleRange, step: 0.05) {
                        Text("文字大小")
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller")
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger")
                    }
                }
                .padding(.vertical, 2)
            }

            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .navigationTitle("编辑卡面")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", systemImage: "checkmark") { Task { await save(account) } }
                    .disabled(saving || importing)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            paletteID = account.paletteID
            face = account.face
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await importImage(item) }
        }
    }

    private func textColor(default palette: UInt32) -> Binding<Color> {
        Binding {
            Color(hex: face.textColor ?? palette)
        } set: { color in
            face.textColor = Self.hex(color)
        }
    }

    private static func hex(_ color: Color) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(1, max(0, v)) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    private func importImage(_ item: PhotosPickerItem) async {
        importing = true
        defer {
            importing = false
            pickerItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw CardFaceImages.ImportError.unreadable }
            // 缩小到卡片在屏幕上的像素宽度；低端机屏幕小，图片也小
            let pixelWidth = pixelWidth
            let id = try await Task.detached(priority: .userInitiated) {
                try CardFaceImages.importImage(data, pixelWidth: pixelWidth, aspect: AppLayout.cardAspect)
            }.value
            importedIDs.append(id)
            // 第一次换成图片时文字默认改为白色，在大多数照片上更清楚
            if face.imageID == nil, face.textColor == nil { face.textColor = 0xFFFFFF }
            face.imageID = id
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "无法读取这张图片"
        }
    }

    private func save(_ account: Account) async {
        saving = true
        defer { saving = false }
        do {
            try await store.updateCardFace(accountID: account.id, paletteID: paletteID, face: face)
            saved = true
            // 删除被替换的旧图和这次选过但没用上的图
            var unused = importedIDs.filter { $0 != face.imageID }
            if let old = account.face.imageID, old != face.imageID { unused.append(old) }
            CardFaceImages.shared.discard(unused)
            dismiss()
        } catch {
            errorText = "保存失败：\(error)"
        }
    }
}
