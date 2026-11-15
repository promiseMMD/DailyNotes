# DailyNotes × AppFlowy 富文本 JSON、本机持久化及 WebDAV 研究 R006

- 归档日期：2026-11-15
- DailyNotes 基线：`promiseMMD/DailyNotes@feat/bootstrap-ui-v0`，读取前 HEAD `774fe049eb79451f73c2d1a2a89613af7fea6a1b`；规范 `docs/requirements/DailyNotes开发规范_V2.56.md`（DN-001～182），本轮不更改已确认设计。
- 上游：`AppFlowy-IO/AppFlowy@8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93`；`AppFlowy-IO/appflowy-editor` main 源码。独立编辑器库和完整应用的自定义图片/附件行为必须区分。
- 调研范围：JSON 树结构、节点 ID、富文本样式、图片附件依赖、导入限制、事务/同步边界、潜在原型验收。
- 证据等级：**源码审阅、官方文档、已有上游测试/公开问题**。**无本地 Flutter 运行、无 Android APK 及真机端到端验收、无数据持久化实施。** 以下任何 Schema/流程提案均标为「候选」而不是已批准实现。

## 1. 上游确证：Document、Node、Delta
1. `appflowy-editor/lib/src/core/document/document.dart`：根节点 `page`，`Document.fromJson` 读取键 `document`，`Document.toJson` 写回 `{'document':root.toJson()}`；`Document.blank(withInitialText:true)` 含一个空段落。启用 `withInitialText:false` 的完全无节点文档曾触发点击选区异常（Issue #1218 Open），不能未经验证用于新建日记。
2. `appflowy-editor/lib/src/core/document/node.dart`：Node 以 `type`、`data`（Attributes）、`children` 递归序列化。**重要：内存 Node.id 通过 `nanoid(6)` 构造，但 `Node.toJson()` 默认不包含 `id` 字段，`Node.fromJson()` 也没有解析 `id`，因此通常重新加载产生新节点 ID。** 即便内部 Node.id 在某次编辑会话可使用，也不能当作长期稳定同步身份、业务 revision ID 或附件关联的唯一来源。对本判断的依据是直接阅读两个函数，不是依赖二手文档。
3. `appflowy-editor/lib/src/core/document/text_delta.dart`：文本 `Delta` 的 `insert` 携带 `attributes`（例如 `bold`），`retain/delete` 可描述编辑操作。**存储的文档快照**与**用于修改的临时 Delta 操作**必须区分，不能把单次键盘事件当作已形成持久化业务事件。
4. `appflowy-editor/lib/src/editor/block_component/heading_block_component/heading_block_component.dart`：标题 `type=heading`、`data.level`（1～6）和 `data.delta`。
5. `appflowy-editor/lib/src/editor/block_component/todo_list_block_component/todo_list_block_component.dart`：清单 `type=todo_list`、`data.checked` 布尔值和 `data.delta`。与 DailyNotes 独立待办实体不是同一种业务对象。
6. `appflowy-editor/test/core/document/document_test.dart` 有 `serialize` 测试，验证 `Document.fromJson(json).toJson()==json` 的特定样例，**不等于覆盖 AppFlowy 完整应用所有自定义图片、文件、表格区块与外部附件字节**。
7. `appflowy-editor/documentation/importing.md` 的导入说明对字体大小、字体和文本对齐等样式存在不支持的注释；因此 **不能默认 Markdown/Quill Delta 作为无损正本**，但这并不意味着原生 `Document.toJson/fromJson` 一定丢这些字段，必须按格式分别验证。

## 2. 基于源码的简化实例（仅概念示例，不是完整 DailyNotes JSON Schema）
下面是按源码键组织的、可以讨论的富文本片段；不是从真实用户笔记中导出：
```json
{
  "document": {
    "type": "page",
    "children": [
      {
        "type": "heading",
        "data": {
          "level": 2,
          "delta": [{"insert": "Stage系统"}]
        }
      },
      {
        "type": "paragraph",
        "data": {
          "delta": [
            {"insert": "定位"},
            {"insert": "重复精度", "attributes": {"bold": true}}
          ]
        }
      },
      {
        "type": "todo_list",
        "data": {
          "checked": false,
          "delta": [{"insert": "检查Overlay波动"}]
        }
      }
    ]
  }
}
```
实际还可能包含 `url`、大小、对齐、字体、颜色、背景色、表格/子节点等。上例不承诺与所有 AppFlowy 完整应用自定义块的序列化兼容。

## 3. 附件和图片的重要差别
- 独立库：`appflowy-editor/lib/src/editor/block_component/image_block_component/image_block_component.dart` 使用 `ImageBlockKeys.url='url'` 与 `width/height/align`；注释指出 url 可为 URL 或 web Base64。
- 完整应用：`AppFlowy/.../image/custom_image_block_component/custom_image_block_component.dart` 额外包含 `image_type` 与 `url`；`.../image/common.dart` 的 local 图像使用 `FileImage(File(url))`。
- 完整应用 `.../image/image_util.dart`：本机保存图片时复制到应用数据目录 `images` 下，以 UUID 加扩展名命名；云模式走上传服务。**路径只是当前设备可用的位置，不具有跨设备可移植性。**
- 完整应用 `.../file/file_block_component.dart`：文件块包含 `url`、`name`、`url_type`、`uploaded_at` 等；`.../file/file_util.dart` 本机复制到 `files` 目录，通常以 UUID 命名。
- 结论：**备份文档 JSON 不等于备份图片/附件本体**；在另一台手机恢复相同 url/local absolute path 可能不可访问。DailyNotes 应在自己的数据层维护跨设备稳定附件 ID、内容校验、上传状态与本地逻辑映射，不能只传 OS 文件路径。
- 候选安全处理：附件字节写入受控存储 → 计算 SHA-256 → 元数据/内容关联本地事务记录 → 同步时先确保被引用的必要 blob 可用/上传完成，再发布可读取的引用或保持待完成状态 → 接收端用校验值验证 → 引用恢复成功后再展示完整。顺序、重试和部分失败需实际选择实现并用故障注入验证，不把这段顺序误标成已确认协议。

## 4. 同步颗粒度：绝不能误把每个页面 JSON 等同于全部长期记录
- 已确认 DN-036/037/038：增量同步包括修改、删除与回收站，**修改某日某次长期追加不能迫使整条长期历史重传**。
- 已确认 DN-009/010/011/013/015：每次正式追加有独立时间与提交边界，同日按顺序在阅读视图聚合；不是将同日文字都写入一个不可拆分的大编辑器 JSON 作为唯一正本。
- **候选业务布局**：普通笔记/日记拥有独立的业务记录 ID，关联其富文本 JSON 文档快照及修订；长期记录由 seriesId + 每次独立 appendId、日期、创建时间、修订、正式/草稿状态 + 每次追加单独富文本文档组成；同日、月/季/年只做阅读组合，不混合底层业务身份。带附件的块用 DailyNotes 附件 ID/映射定位内容，不直接用 AppFlowy 运行时 Node.id。
- **候选同步布局**：业务编辑先本地事务更新记录/修订和持久化 outbox；用户触发手动 WebDAV 同步时，按变更对象及 tombstone（墓碑）发送，附带必要 blob；快照和检查点用于恢复及快速拉取；失败保留未完成队列。与 DN-148、DN-151 的已经确认的大方向一致，具体 JSON Schema、事件格式、原子写入和 WebDAV 远端文件布局尚待讨论。
- **必须区分**：本机成功、待同步、远端已同步、远端冲突，以及草稿状态。颜色/加粗按钮完成、EditorState.transactionStream 的 after 事件都不能直接触发“本机已保存”提示。
- 多设备相同记录并发编辑的冲突、附件共享引用的清理、删除和回收站恢复需要额外验证；不能简单默认最后写入覆盖。

## 5. 最大风险分层与测试证据
- P0-01 JSON 原生往返：H1/H2/H3、粗体/斜体/下划线、textColor/backgroundColor、对齐/缩进、清单 checked、列表层级、图片/附件占位及所有元数据，在关闭/重载后保持信息不变。使用规范化 JSON 语义比较，不要求随机运行时 Node.id 相同。
- P0-02 **业务身份**：同一长期记录的 3 次追加（同一天两次、跨日一次）形成 3 个独立 appendId；编辑一次只产生该追加相关的业务变更；阅读可同日聚合而不改变原时间。
- P0-03 本机原子提交 + 故障注入：编辑 JSON 成功但 DB 落盘失败时不误报已保存；切换后台/强杀/空间不足/撤销重做、恢复后文档与 revision 不错配；待同步 outbox 原子同步。
- P0-04 附件完整性：照片/文件选取→复制本机受控目录→断电/缺文件/重名/上传一半→备份恢复→其他设备路径重映射，内容 Hash 一致、缺失状态可诊断且不得误报完整。
- P0-05 WebDAV 增量：同步仅一条 append、同时处理 tombstone 与回收站，远端第一次拉取及断点续传可恢复；不意外覆盖他设备的新 revision；同一事件重放保持幂等。
- P1-01 导入导出差异：原生 JSON 与 Markdown、Quill Delta、HTML 的富文本损失矩阵；**以选定的无损正本格式为准**，并测试版本升级迁移与未知块保留。
- P1-02 大文档：长文、图片/附件、富文本高频输入下存储写入的抖动、磁盘占用、恢复时间和电量；不在每次按键都全库备份。

## 6. 上游实际测试与公开未关闭 Issue
- `appflowy-editor/test/core/document/document_test.dart`：serialize 例子与基本文档操作。
- `appflowy-editor/test/core/document/node_test.dart`：序列化/复制/Node.fromJson；不证明 Node.id 被保存。
- `appflowy-editor/test/core/document/text_delta_test.dart`：富文本 Delta 的 compose 与差异逻辑。
- `appflowy-editor/issues/1218`（Open，2026-07-05）：完全空节点文档点击选区 ArgumentError；新建必须有合法初始段落并单独测试。
- `appflowy-editor/issues/1215`（Open，2026-06-30）：物理 Android 16 表格焦点滚动 ANR 风险，暂不外推为普通段落必有问题。
- `appflowy-editor/issues/1241`（Open，2026-09-23）：默认 H1 字号索引报告；须按实际选中编辑引擎做视觉验证，完整 AppFlowy 自定义样式不一定相同。
- 不意味着这些 Bug 已复现或在 DailyNotes 存在；它们只帮助规划实机验收。

## 7. 设计决策留白与下一轮研究
**已经确认的只有** DN-001～182 的需求原则；R006 是新研究，不自动升级为 DN-183。
下一阶段需明确：
1. DailyNotes 正本是否保留完整 editor Document JSON 加业务元数据包，还是定义独立规范化 AST；尤其未来版本兼容和未知区块升级。
2. 正文普通笔记的版本颗粒度（整篇记录 revision+操作流）与长期记录 append 的独立版本颗粒度，以及 editor Node id 不持久化的应对边界。
3. 附件的跨设备稳定 ID、物理存储与完整性协议、WebDAV 远端布局和备份恢复顺序。
4. WebDAV 无 rename/多文件事务担保时如何通过 manifest、阶段提交与检查点保证“可读取的远端状态”一致。
5. 私密内容的本机加密与手动备份加密具体选择；不把 WebDAV 账号凭据放进编辑器 JSON。
6. 撤销重做粒度、业务 revision 与同步事件一一/多对一映射；避免误把一次键盘操作作为必须上传一个远端文件的事件。

## 8. 资料索引（官方原始资料）
- https://github.com/AppFlowy-IO/appflowy-editor/blob/main/lib/src/core/document/document.dart
- https://github.com/AppFlowy-IO/appflowy-editor/blob/main/lib/src/core/document/node.dart
- https://github.com/AppFlowy-IO/appflowy-editor/blob/main/lib/src/core/document/text_delta.dart
- https://github.com/AppFlowy-IO/appflowy-editor/blob/main/lib/src/editor/block_component/heading_block_component/heading_block_component.dart
- https://github.com/AppFlowy-IO/appflowy-editor/blob/main/lib/src/editor/block_component/todo_list_block_component/todo_list_block_component.dart
- https://github.com/AppFlowy-IO/appflowy-editor/blob/main/lib/src/editor/block_component/image_block_component/image_block_component.dart
- https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/image/custom_image_block_component/custom_image_block_component.dart
- https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/image/image_util.dart
- https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/file/file_block_component.dart
- https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/file/file_util.dart
- https://github.com/AppFlowy-IO/appflowy-editor/blob/main/documentation/importing.md
- https://github.com/AppFlowy-IO/appflowy-editor/blob/main/test/core/document/document_test.dart
- https://github.com/AppFlowy-IO/appflowy-editor/blob/main/test/core/document/node_test.dart
- https://github.com/AppFlowy-IO/appflowy-editor/blob/main/test/core/document/text_delta_test.dart

## 9. 当前仓库开发状态核对
`docs/STATUS_AND_HANDOFF.md` 明确当前仅 UI 结构预览，无真实持久化、WebDAV 或附件后端；本文的 Schema/流程都是供后续正式设计/验收使用，不得宣称应用代码已经具备。
