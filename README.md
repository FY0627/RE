# 日常记账

本地优先的记账 App，支持 Android 和 iOS。

- **不需要服务器**：数据保存在手机本地，离线完整可用，用户不需要部署任何东西。
- **设备互传同步**：扫码配对，通过局域网直接同步，Android 和 iOS 之间也能互传。
- **自动记账**：截图 + OCR 识别支付页面。Android 上点悬浮窗触发，iOS 上用快捷指令。
- **低端机友好**：以 2020 年左右的 60Hz 手机作为性能基准。

> 这里是 iOS 原生 Swift 版。Flutter 版骨架在 [`main`](https://github.com/FY0627/REC/tree/main) 分支，前端原型在 [`prototype`](https://github.com/FY0627/REC/tree/prototype) 分支。

## 结构

```
ios-swift/  iOS 原生 Swift 版：SwiftUI 界面、App Intents、SQLite
docs/       文档，从 docs/INDEX.md 开始看
```

## 运行

App 由 GitHub Actions 构建，安装方法见 [docs/guides/ios-swift-windows-sideloadly.md](docs/guides/ios-swift-windows-sideloadly.md)。

本地运行核心测试见 [ios-swift/README.md](ios-swift/README.md)。

## 文档

- [文档与代码索引](docs/INDEX.md)
- [iOS Swift 版说明](ios-swift/README.md)
- [架构决策记录](docs/decisions/)

## 许可证

[Apache License 2.0](LICENSE)：允许自由使用、修改和分发，包括商业用途。分发时需要保留版权声明和 [NOTICE](NOTICE)，并标明修改过的文件。许可证不授予使用 REC 名称的权利。
