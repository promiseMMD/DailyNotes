# DailyNotes — 借鉴 Moodiary LAN 的双端低延迟自动同步研究 R008

- 日期：2026-11-15
- DailyNotes 当前基线：`docs/requirements/DailyNotes开发规范_V2.59.md`（DN-001～DN-185）
- 参考仓库：`promiseMMD/codex-learning` 分支 `moodiary-v3-w9-8-4-31-permanent-application-id-20261110`，读取 `moodiary-v3-w7/`、`moodiary-v3-w9-3/`、`moodiary-v3-w9-4/` 已归档代码和状态（**不假定为最新正式 APK 的实机表现**）。
- 用户方向：手机与局域网 PC 毫秒级互相同步，参考 Moodiary 魔改版；只有单用户局域网场景，坚果云 WebDAV 保持手动增量备份/恢复，不把它当成局域网热路径。
- 本轮范围：设计研究与规范，未改 Dart/Flutter/Rust/TypeScript 应用代码，未运行 CI、APK、双端性能压测或实体 Android 验收。

## 一、Moodiary 已能借鉴什么，不能宣称什么
1. `moodiary-v3-w7/STATUS.md` 的实现说明：手机端作为局域网 HTTP 服务器和耐久数据写入方，PC 以 React 19 + Tiptap 3 访问手机网页；配对授权、同源/Host-Origin、CSRF、版本 CAS；通过认证 WebSocket 发送保存后的变更失效通知。原文对**真实两设备及正式发布仍要求另行验收**。
2. `moodiary-v3-w7/web/src/main.tsx` 代码中，普通日记的 `queueSave` 使用 `setTimeout(...,2000)`，即编辑停止约 2 秒后触发 HTTP 自动保存；`save()` 接收真正的 revision 回执后才显示「已保存到手机 · 云端 WebDAV 状态独立」；**这不是每按一次键立即远端落盘的毫秒级同步**。
3. 同一文件通过 `new WebSocket('ws://'+window.location.host+'/api/events')` 接收 `invalidate` 通知；消息带 `epoch` 和 `sequence`，重连发 `since`，失序或缺口请求重读。监听到其他端编辑时，若当前 PC 有 dirty 草稿，先读权威 revision，发现不同则阻止覆盖且保留草稿；HTTP CAS 负责拒绝旧版本写入。
4. `moodiary-v3-w9-3/DEVELOPMENT_PLAN.md` 记载 W9.3 PC 端已有浏览器/CI 闭环但新月度块 WebDAV、历史恢复、全设备验收等尚有缺口。PC 编辑器使用 Tiptap JSON，**不是 AppFlowy Document JSON**，可借鉴传输/冲突/失效通知，但不能直接把 Moodiary 的正文格式当作 DailyNotes 已确认的 AppFlowy 格式。
5. `moodiary-v3-w9-4/overlay/mobile/lib/app/home/mod_month_updates.dart` 是 `StreamController<String>.broadcast(sync:true)` 的手机进程内主题失效总线，只传 topicId，不是逐字符富文本同步协议；W9.4 状态文档指出手机 PC 保存后相互通知，但并不强制刷新和覆盖打开的草稿。
6. Moodiary 存在 phone-hosted server 的历史实现；DailyNotes V2.59 只规定局域网私有 Web，**尚未选择 PC-hosted 或 phone-hosted**。借用协议不等于照搬主机选择和锁屏前台服务。

## 二、明确的速度分层，不能混淆
- T0 用户本地编辑响应：编辑器在本机即时响应，不等待网络。
- T1 低延迟编辑事件（候选）：两端同时打开相同笔记时，发送小粒度的**暂态变更/光标态**，以接近毫秒级的 LAN 推送体验为目标；但即使发送成功也**不得标识为已持久化**。
- T2 已确认的耐久提交：本机数据库原子提交正文/业务 revision/持久 outbox 后发出 `committed` 事件；对端校验序号并增量读/应用，产生另一端可恢复的本地持久版本后才确认对端保存。**端到端「已落盘并在另一端可见」速度受 IO、节流、网络、调度制约，不能承诺稳定单毫秒**。
- T3 设备断线：事件日志序号+检查点/版本向量对账，重连自动补齐且保留未同步原件；手机锁屏、PC 关机、Wi-Fi 漫游可能暂停实时通道，离线照常编辑并可靠保存。
- T4 WebDAV：独立、用户手动触发的增量同步/备份；LAN 自动同步不等于用户允许 WebDAV 在后台自动上传。

## 三、两阶段实现建议（目前是候选，不是新功能批准）
**阶段一：可靠记录/追加级自动同步**。
- 局域网连接、配对及访问控制（局域网无需公网但不等于无需鉴权），双端以 HTTPS/WSS 或有明确受限威胁边界的安全传输连接服务。
- 先本机事务保存，生成原子 outbox 和全局/逐记录 revision；WebSocket 发布 `{sequence, entityId, revisionId, kind}` 轻量通知，必要时对端通过安全 API 增量拉取正文、附件索引。
- 双端都可编辑、发起提交，不以单向 PC 写手机代替双向；幂等 requestId、CAS / expectedRevision、防重复重放、断线以来序号恢复、跨端版本冲突时保留两个草稿和历史、未知格式阻止破坏性覆盖。
- 附件按字节校验独立可靠传输，不用 WebSocket 一次推送整个图片；删除/回收站也作为事件。
- 仅在接收端真正落盘后标记「两端同步完成」。如果 PC 浏览器刷新，未落盘编辑不能以“WebSocket 已发”为成功。
**阶段二：如需同一篇文档逐键实时协同编辑**。
- 须另行验证 CRDT/OT 或经过证明的编辑操作合并（例如 Yjs/Yrs/Automerge 类型思路）及其对 AppFlowy 树节点/样式、列表、跨区块选区、IME 组合输入、撤销、图片的映射；避免直接对 JSON 文本用最后写入覆盖或按偏移合并。
- 同一文档两个编辑器同时活跃，基于 revision 的“保存后通知”只能做到更新提醒/冲突拒绝，**不能等价于 Google Docs 式逐键毫秒协同**；当技术尚未验证时应以保留双端草稿 + 可靠冲突处理代替不安全自动覆盖。

## 四、DailyNotes 的建议产品状态
- 本机已保存：当前设备持久化事务成功；不得等同于局域网已同步。
- 局域网同步中 / 已同步到对端 / 对端离线 / 冲突待处理：基于对端持久确认与版本对账显示。
- WebDAV 待备份 / 已备份：单独显示，不因 LAN 已同步而改变。
- 不支持远端格式、附件未完成、服务器会话撤销等状态，保持只读/阻断覆盖与可恢复副本。

## 五、分级验收，所有项目当前未执行
P0：真实 Android↔PC 双向编辑同一条日记，先后成功保存并可靠复制；两端断线、断网、强杀、重连数据一致。
P0：双方离线同时修改同一 revision，恢复时不无提示覆盖；冲突保留两份可恢复内容。
P0：同日两次长期记录 appendId 独立、仅改变一条只发送其增量；删除、回收站、附件校验均可重放且幂等。
P0：WebSocket 事件丢包、乱序、重复、重连后能依据 sequence + snapshot 对账，不把未持久化消息冒充保存完成。
P0：局域网未配对设备、恶意网页跨站请求/CSRF、Host/Origin 欺骗、会话过期/撤销均不允许读取私人日记或写入。
P1：在实际 Android（含 HyperOS）与 Windows PC、不同网络质量、系统休眠/后台省电策略下，用明确时钟基线分别测量「本端操作→事件送达」「本端落盘→对端展示」「本端落盘→对端持久确认」的 p50/p95/p99；用户希望毫秒级，具体数值阈值与测试配置待批准并实测。
P1：文本 + H1/颜色/清单/图片/附件在 Android 与 PC 往返不会丢格式；Moodiary 的 Tiptap JSON 不可直接混作 AppFlowy Document JSON。
P1：真正逐字符双端同编辑能力只在编辑器操作语义、性能和冲突算法验收通过后开放；暂不宣称已有。

## 六、与既有需求兼容
- DN-185 的「局域网 Web 服务不会默认为开启实时同步」是**尚未批准同步机制时的限制**；用户现在明确希望 LAN 双向自动实时同步，应以**新增较新 DN-186 明确修订覆盖这一点**，不影响 DN-185 对局域网私有和安全的其他约束。
- DN-020/021、045/047、009/010：日记自动正式保存、笔记本机自动保存、长期追加草稿/正式提交边界不变。尤其长期追加草稿编辑中的快速预览不能当作正式追加同步。
- DN-036～038、DN-148/151：WebDAV 仍是手动优先、具持久事件/快照/检查点的备份/跨网同步；局域网自动同步另设独立可靠事件通道。
- DN-183：AppFlowy Document JSON 保留富文本与版本封装；业务 ID/revision/appendId/附件 ID 独立，PC Web 编辑格式须兼容。
- PC Web 服务实际主机（手机/PC/NAS）、首次配对/发现、是否仅局域网还是支持 VPN、精确延迟指标、真正逐键协同实现，尚未由用户确认。

## 七、来源和验证身份
- Moodiary W7 状态：https://github.com/promiseMMD/codex-learning/blob/moodiary-v3-w9-8-4-31-permanent-application-id-20261110/moodiary-v3-w7/STATUS.md
- Moodiary PC WebSocket/2 秒保存：https://github.com/promiseMMD/codex-learning/blob/moodiary-v3-w9-8-4-31-permanent-application-id-20261110/moodiary-v3-w7/web/src/main.tsx
- Moodiary W9.3 开发限制：https://github.com/promiseMMD/codex-learning/blob/moodiary-v3-w9-8-4-31-permanent-application-id-20261110/moodiary-v3-w9-3/DEVELOPMENT_PLAN.md
- Moodiary W9.4 进程内变更总线：https://github.com/promiseMMD/codex-learning/blob/moodiary-v3-w9-8-4-31-permanent-application-id-20261110/moodiary-v3-w9-4/overlay/mobile/lib/app/home/mod_month_updates.dart
- Yjs 官方离线思路：https://docs.yjs.dev/getting-started/allowing-offline-editing
- Automerge 官方离线协作思路：https://automerge.org/docs/

本轮无任何 DailyNotes 或 Moodiary 功能代码修改，也没有证实 Moodiary 正式安装包已经实现毫秒级逐键双向同步。
