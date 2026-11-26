# DailyNotes

基于 Moodiary 与 promiseMMD 魔改分支建立的开发基线。当前已实现第一批本地核心功能，预览 APK 正在构建；尚未完成完整规范与真机验收。

- 当前规范跟踪：[开发进度](docs/DEVELOPMENT_PROGRESS.md)；此前采用的 V3.92 原文件尚未随仓库保存。
- 历史规范：[V2.52](docs/DailyNotes开发规范_V2.52.md)、[V2.51](docs/DailyNotes开发规范_V2.51.md)
- 开发入口：[规范与交接索引](docs/INDEX.md)
- 上游介绍：[README.upstream.md](README.upstream.md)
- 许可证：[AGPL-3.0](LICENSE)。保留上游版权与署名；分发及网络交互须遵守适用的源码提供要求。

工程入口为 `mobile/`，共享包在 `packages/`。源码已应用魔改补丁，无需再运行旧仓库的补丁应用脚本。
按 `.fvmrc` 使用 Flutter 3.47.8，Dart >=3.13.0，其余原生依赖见 `AGENTS.md`。

```bash
fvm dart tool/task.dart setup
fvm dart tool/task.dart analyze
fvm dart tool/task.dart test --all
```

DailyNotes 使用独立 Android flavor `dailynotes`，应用包名 `io.github.promisemmd.dailynotes`。预览构建与实际限制见 [PREVIEW.md](docs/PREVIEW.md)，构建工作流位于 `.github/workflows/dailynotes-preview.yml`。签名密钥不入库。
