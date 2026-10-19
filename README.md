# 日常记账

本地优先的记账 App，支持 Android 和 iOS。

- **不需要服务器**：数据保存在手机本地，离线完整可用，用户不需要部署任何东西。
- **设备互传同步**：扫码配对，通过局域网直接同步，Android 和 iOS 之间也能互传。
- **自动记账**：截图 + OCR 识别支付页面。Android 上点悬浮窗触发，iOS 上用快捷指令。
- **低端机友好**：以 2020 年左右的 60Hz 手机作为性能基准。

> 当前阶段：项目骨架。前端原型在 [`prototype`](https://github.com/FY0627/RE/tree/prototype) 分支。

## 结构

```
app/        前端：Flutter 界面
backend/    后端：运行在手机内的业务层（纯 Dart）
database/   数据库：SQLite + drift
native/     原生能力：悬浮窗截屏、OCR、iOS App Intent（Kotlin / Swift）
docs/       文档，从 docs/INDEX.md 开始看
```

## 运行

```sh
flutter pub get        # 在仓库根目录执行
cd app
flutter run
```

更多命令见 [docs/guides/development.md](docs/guides/development.md)。

## 文档

- [文档与代码索引](docs/INDEX.md)
- [架构总览](docs/architecture/overview.md)
- [架构决策记录](docs/decisions/)

## 许可证

[PolyForm Noncommercial 1.0.0](LICENSE)：源码公开，允许个人学习、研究和其他非商业用途，**禁止商用**。

注意：这类许可证不属于 OSI 认证的「开源许可证」，因为 OSI 的定义不允许限制商业使用。
