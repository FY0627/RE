# AGENTS.md

AI 编程助手的入口文件。Claude Code 通过 `CLAUDE.md` 引用本文件，其他工具直接读取本文件。

## 项目

本地优先的记账 App，用 Flutter 开发，支持 Android 和 iOS。

- **没有服务器**：数据保存在手机本地的 SQLite 里；多台设备之间通过「扫码配对 + 局域网直传」同步。
- **低端机优先**：目标设备包括 2020 年左右的 60Hz 手机，性能、资源占用和稳定性优先于视觉效果。
- **当前阶段**：只有骨架。前端原型在 `prototype` 分支，只作参考，不合并进 main。

## 先查索引

定位问题前先读 [docs/INDEX.md](docs/INDEX.md)。按索引只打开相关的文档和目录，不要通读整个仓库。

## 结构

| 目录 | 层 | 包名 |
|---|---|---|
| `app/` | 前端：Flutter 界面 | `bookkeeping_app` |
| `backend/` | 后端：运行在手机内的业务层，纯 Dart | `bk_backend` |
| `database/` | 数据库：SQLite + drift，纯 Dart | `bk_database` |
| `native/` | 原生能力：Flutter 插件（Kotlin / Swift） | `bk_native` |
| `ios-swift/` | iOS 原生 Swift 版（独立工程，不依赖 Flutter；见 ADR 0006–0009） | `BKModel` / `BKDatabase` / `BKBackend` |

详细说明见 [docs/architecture/overview.md](docs/architecture/overview.md)。

## 命令

```sh
flutter pub get            # 在仓库根目录执行，一次解析全部包（pub workspace）
flutter analyze            # 在仓库根目录执行
cd app && flutter test
cd native && flutter test
cd app && flutter run      # 真机调试；测性能用 flutter run --profile
```

## 硬性规则

1. **依赖方向是单向的**：`app → backend → database`，`app → native`。
   - `app` 不能直接 import `bk_database`。
   - `backend` 和 `database` 不能依赖 Flutter。
2. **UI isolate 不做重活**：数据库运行在后台 isolate；统计、同步合并、文本解析用 `Isolate.run`。
3. **性能改动**按 [docs/architecture/performance.md](docs/architecture/performance.md) 执行：在测试机上用 profile 模式测量，一次只改一个变量，用 `--dart-define` 开关做对照。
4. **引入新的第三方依赖、改变架构或技术选型**时，在 `docs/decisions/` 新增一份 ADR。
5. **新增、移动或删除模块 / 文档 / 决策后**，同步更新 [docs/INDEX.md](docs/INDEX.md)。
6. **包名是临时的**：`bookkeeping_app`、`bk_*` 和 `com.example` 会在项目改名时统一替换，不要再引入新的命名前缀。
