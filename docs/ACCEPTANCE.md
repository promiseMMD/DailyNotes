# 验收证据台账

日期：2026-11-15（北京时间）。状态为开发基线，不能正式交付。

| 检查 | 结果 | 证据及局限 |
|---|---|---|
| 固定提交与历史补丁重建 | 通过 | prepare-workspace.sh 退出 0；完成至 W9.8.4.15；日志归档于 evidence/restore.txt |
| 旧魔改 CI 结构与安全门禁脚本 | 通过 | python3 moodiary-ci/check-gates.py 退出 0；输出于 evidence/source-gates.txt；仅检查旧仓库规则，非 DailyNotes CI 或 App 集成验收 |
| 导入字节一致性及需求原件一致性 | 通过 | 由本轮导入后核验脚本写入 evidence/import-verification.json |
| Flutter analyze / 单元与集成测试 | 未执行 | 当前环境无 Flutter、Dart；不得声称编译通过 |
| App 故障注入、原生依赖构建 | 未执行 | 尚未准备完整工具链 |
| Android APK、签名、安装升级、真机 | 未执行 | 无 APK，未使用签名密钥，未操作真实数据 |
| 页面截图及设计图对照 | 未执行 | 缺少已确认图稿；尚未运行 App |
| GitHub 最新 CI 运行状态 | 未核验 | 本轮运行的是本地源码检查，不引用历史通过替代当前验证 |

正式交付沿用 DN-149、152：单元、集成、故障注入、真机四阶段，且不存在未解决 P0/P1。

## 首版开发验证补录

- 已新增独立 Android flavor，包名 io.github.promisemmd.dailynotes，版本 0.1.0+1；源代码使用 Moodiary 原导航组件。
- 新模块及长期记录编辑器：合并测试24项通过，清空数据回归1项通过，共25项；见 evidence/dailynotes-store-tests.txt 和 dailynotes-reset-tests.txt。
- 修改路径定向静态分析：退出0，无编译错误或警告；仍有23项风格提示。未据此声称全仓旧代码分析通过。
- 两种预览标志下的 AI 权限策略纯 Dart 检查通过。
- APK 构建进行中；安装、运行截图、真机和四阶段完整验收均未完成。
- 新模块尚未接入 WebDAV 与旧导出备份；限制已显示在页面并列入 PREVIEW.md。
