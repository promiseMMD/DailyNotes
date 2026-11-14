# 来源、数据技术与实施顺序

## 来源事实

- 上游 https://github.com/ZhuJHua/moodiary 固定提交 `2c552ddd7939a054122380397fb914cf000824b0`。
- 魔改 https://github.com/promiseMMD/codex-learning 分支 `moodiary-v3-w9-8-4-31-permanent-application-id-20261110`，固定提交 `c96a786916070d89594f0968fb18480c98d1b643`。
- 在魔改仓库根目录运行 `bash moodiary-ci/prepare-workspace.sh` 可重新组装 `upstream/`。该脚本使用固定 `/tmp` 路径，须在干净隔离环境执行。
- 本仓库导入的是组装后的完整源码；不是把各历史 overlay 文件夹作为新的应用模块。
- 原 README 保存为 README.upstream.md；保留 LICENSE、CLA、作者信息、AGENTS.md 和现有测试。`.git` 与 `.github` 不导入，避免保留旧 remote 或触发不适配的构建/发布。
- 唯一有意调整的原文件是 `.gitignore`：取消忽略 docs/，让需求及证据能被 Git 跟踪。README.md 为 DailyNotes 入口。
- `baseline-manifest.json` 保存导入文件哈希；其中 README.upstream.md 映射原 README.md；.gitignore 哈希对应上述有意修改之后的文件。

## 已确认架构与差距

DN-147～151 要求业务分离，共享实体身份、附件、版本、回收站、事务事件队列，以及 WebDAV 操作事件日志+快照+检查点。已有 Flutter/Rust 分层结构可沿用；`moodiary_data`、`moodiary_models`、`moodiary_sync`、`moodiary_editor` 是主要扩展位置。不能只修改页面来宣称数据语义已完成。

长记录已有月/日模型及备份测试；旧脚本明确提示部分 W9 自定义迁移/恢复路径并非完整生产接入。需要对真实调用链、失败回滚与媒体引用逐项验收。现存测试数量不代表已通过。

不导入或读取私有签名保险库。基线包名 `cn.yooss.moodiary.v3safe`、版本 `2.9.2+126` 只是旧代码事实；DailyNotes 是否沿用身份或独立安装仍待明确，构建发布前处理，不阻塞纯源码开发。

## 建议实施顺序（工程建议，不新增产品需求）

1. 完成可用工具链及当前工程 analyze/test，先定位既有失败并建立新仓库 CI。
2. 建立数据实体、迁移策略、回收站和事务事件队列的技术方案及针对性测试。
3. 按已确认导航接入待办、笔记/知识树，再调整首页和抽屉；未确认细节显式保留。
4. 完成同步冲突、备份恢复、AI 授权与变更审核；最后处理安装身份、签名和真机验收。

首版开发已新增 dn_* 本地事务表与持久化 outbox，保留原日记表；独立 Android flavor 的包名为 io.github.promisemmd.dailynotes。正式签名和全量迁移尚未完成。
