# DailyNotes × AppFlowy：最新版 Android 交互基准核对 R018（设计研究，非真机验收）

- 记录日期：2026-11-15（北京时间）。
- DailyNotes 当前需求基线：`docs/requirements/DailyNotes开发规范_V2.76.md`（DN-001～DN-202）。
- 用户本轮明确要求：「确保这些交互跟 appflow 最新版本一样的情况下进行迭代，主要目的是为了体验感更好。」此为新版设计对标和验证流程方向，不自动批准尚未实测的具体关闭手势。
- 本轮核对方式：直接读取 AppFlowy-IO/AppFlowy 与 AppFlowy-IO/AppFlowy-Builder 官方 GitHub API 的最新 release、tag、APK artifact digest 和完整应用菜单源码；没有安装/运行官方 APK，没有 Android 真机或模拟器 UI 录屏证据。
- 结论等级：版本/构建元数据与标记源码可核验；APK 的实际运行行为在未跑真机前**不能标为已核实**。

## 1. 官方最新发布与构建出处（2026-11-15）

- AppFlowy 官方最新版非预发布 Release：`0.15.1`，发布于 `2026-11-15T11:08:51Z`，带官方 `AppFlowy-0.15.1-android.apk`，资产大小 249,914,267 bytes，SHA-256 `9dbbbf5b53b904871ab8d7effe93f06a6f1258bda046c2134a9fdddb5add0a29`。
- `refs/tags/0.15.1` 指向 `8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93`，与本项目先前 R002 固定的 AppFlowy 源码参考点相同。
- **关键来源差异：** AppFlowy-Builder 最新相应 Release `0.15.1-release/0.15.1-261115-0759` 声称 APK 使用 `release/0.15.1` 分支及 **Source Commit `9efaa3edaa6b8f1034d6c95f3d404fd6e32d2700`**；其 Android APK 的大小和 SHA-256 与正式 Release 所载 APK **完全一致**。
- 上述构建提交在本次公开 AppFlowy-IO/AppFlowy 连接器 API 的 commits 查询中返回 `No commit found`，release/0.15.1 分支亦未能公开解析；因此**不可证明标签所指的 8fcee 与实际上架 Android APK 的每一处实现完全相同**。研究与开发不得把 tag 源码直接当作 APK 运行结果。
- 官方 0.15.1 发布说明着重于数据库、Feed、上传和桌面等修复，未明确保证本文 Aa 退出手势有变化；不可从版本号直接猜测行为。

证据：
- 最新发布：https://github.com/AppFlowy-IO/AppFlowy/releases/tag/0.15.1
- 官方 Release API：https://api.github.com/repos/AppFlowy-IO/AppFlowy/releases/latest
- 官方标签 API：https://api.github.com/repos/AppFlowy-IO/AppFlowy/git/ref/tags/0.15.1
- Builder 发布：https://github.com/AppFlowy-IO/AppFlowy-Builder/releases/tag/0.15.1-release%2F0.15.1-261115-0759

## 2. AppFlowy 完整应用固定标签源码下可证实的交互结构

### 2.1 Aa 主菜单并非可拖动 Modal BottomSheet

- `mobile_toolbar_v3/aa_toolbar_item.dart`：Aa 通过工具栏 `menuBuilder` 构造 `_TextDecorationMenu`，内部 `SingleChildScrollView` 放置四组排版控件。
- `mobile_toolbar_v3/appflowy_mobile_toolbar.dart`：`showMenuNotifier` 控制 Aa 菜单占用**缓存的键盘高度对应的区域**；并非 `showModalBottomSheet`。
- 点击已打开的同一个工具栏菜单按钮：源码 `selectedMenuIndex == index && showMenuNotifier.value` 分支执行 `closeItemMenu()` 和 `_showKeyboard()`。这是源码可证实的**重复点击 Aa 关闭菜单并请求键盘恢复**。
- 工具栏右侧的 `CloseKeyboardOrMenuButton` 点击后直接清空 selection，Android 额外请求 `TextInput.hide`，**这不等同于重复点击 Aa 的「恢复键盘」动作**；不能用“一切关闭 Aa 都恢复键盘”描述最新源码。
- `didUpdateWidget` 选区变化可能关闭当前菜单并请求恢复键盘；这需要与点击正文、Android 后退键、手势行为分开测试。
- **不能声称：** Aa 主菜单必然支持“点击外部关闭”和“下滑拖动关闭”；当前固定源码不能支持将它们归为原版已核验动作。

### 2.2 颜色与 + 是 Modal BottomSheet；字体是页面路由

- `aa_menu/_color_list.dart` 通过 `showMobileBottomSheet` 打开颜色/高亮底部弹层，且配置了拖动柄和「完成」按钮，保留 selection 并在弹层结束后延迟尝试恢复选择。
- `add_block_toolbar_item.dart` 的编辑器内部 `+` 通过 `showMobileBottomSheet` 打开可拖动、纵向滚动的区块插入底部弹层，含标题、拖动柄和关闭按钮。
- `mobile/presentation/bottom_sheet/show_mobile_bottom_sheet.dart` 调用 Flutter `showModalBottomSheet`，并将 `isDragEnabled`（默认 true）传为 `enableDrag`，未自行重写 `isDismissible`。这支持源代码层面对底部弹层拖动和屏障关闭的研究，但不能直接当作 v0.15.1 APK Android 设备已通过的实际操作证据。
- `aa_menu/_font_item.dart` 使用 `GoRouter.push<String>(FontPickerScreen.routeName)`，字体页是独立路由，应按真实页面导航而不是把下滑关闭当作统一行为；返回后延时重设选区，有回调与编辑器切换竞态风险。
- **颜色弹层结束、点击 Aa、系统返回、点击文档空白、点击弹层外部等操作是否都严格遵循 DN-202 的状态机**，需以安装 v0.15.1 Android APK 的真机录屏或交互回归测试作为最终证据，不能只由局部源码推断。

## 3. 本次用户确认的迭代原则与历史规范的关系

- 新原则：**今后编辑器每阶段设计、关键状态机更改及交付验收前，先确定 AppFlowy 最新非预发布版本和对应 Android APK、核对具体菜单/功能在最新 App 的真实行为，然后对比 DailyNotes 版本与体验**。最新行为若更自然、符合数据可靠性原则，优先采纳，不以旧研究断点或旧宣传图为永久约束。
- 对标应按四层保留证据：①官方 Release 与 APK digest/来源；②对应可取得的完整 App 源码及 tag/commit/构建关系；③官方 Android APK 实际屏录/操作脚本（若环境可用）；④ DailyNotes 同脚本真机对照以及实际文件/JSON 持久化。
- **不等于直接自动覆盖 DN-202**：此前已批准“颜色/字体回到 Aa、退出 Aa 恢复此前有效键盘”的意图仍是体验约束；现查明上游 `CloseKeyboardOrMenuButton` 的特殊行为不同，应建立差异项并逐项讨论优化。对于任何官方实际行为与用户已批准交互不一致的情况，要如实告知，提出体验/风险分析并征得用户批准后再修改规范；不能把不一致改写成官方原版“天然如此”。
- 产品排序：保持内容与焦点安全、实际体验顺畅、正确中文输入、避免无谓键盘闪动与页面跳转，避免为了“百分百照抄”复制上游缺陷。日记/笔记自动本机保存、长期记录草稿/正式提交、手机唯一权威、手动 WebDAV、阅读锁定/显式解锁都属于 DailyNotes 自有边界。
- **不要再次作无根据承诺**：仅有源码的交互标为「源码证实」、仅有版本发布数据标为「发行元数据证实」、真实 APK 未测试标为「待实机核验」，不能写“已与最新 Android APK 1:1”。
- 发布后上游的新正式版本会变化，因此验证记录必须附上日期与版本；下次做相关迭代应重新查询最新版本，避免“当时最新”被误认为永远最新。

## 4. 当前 Aa / 颜色 / + 关闭操作核对台账

| 控件/动作 | 0.15.1 标签源码可确认情况 | 0.15.1 Android APK 实机状态 | DailyNotes 候选 |
|---|---|---|---|
| 已开 Aa 时再次点击 Aa | 关闭 Aa，调用 keyboard show（需有效选区） | 未测试 | 作为默认快捷退出方向，待实机对照 |
| Aa 工具栏右侧 CloseKeyboardOrMenuButton | 清空选区，Android 请求隐藏键盘；与再次点 Aa 不同 | 未测试 | 尊重“关闭编辑工具”的用户意图，不随意强制回弹键盘 |
| Aa 点击正文外部 | 没有足够局部源码证明存在 modal barrier/tap-to-dismiss | 未测试 | **不自动定稿** |
| Aa 主菜单向下拖动关闭 | Aa 不是 Draggable BottomSheet，未见直接拖拽关闭实现 | 未测试 | **不再将其冒充原版已确认手势** |
| Aa 系统返回键 | 现有局部源码不足以证明完整导航拦截结果 | 未测试 | 保留未决，须看完整页面及实际设备 |
| Aa → 颜色/高亮弹层 | `showModalBottomSheet` 包装，允许 drag；返回后尝试恢复 selection | 未测试 | 尽量先回 Aa，不频繁弹键盘，须实机确认 |
| Aa → 字体页面 | GoRouter push 独立页，返回后延迟恢复选区 | 未测试 | 先回 Aa，保护有效选区；竞态安全优先 |
| 编辑器内部 + | 是独立可拖动 BottomSheet，与 Aa 不同 | 未测试 | 跟随原版弹层交互，区别于全局创建加号 |

## 5. 后续按版升级时必须闭环的验收

1. AppFlowy 最新发布 APK 逐个测试 Aa 已开再点 Aa、右侧关闭按钮、系统返回、点击空白/弹层外部、下滑，区分主菜单与弹层，拍摄录屏留证据。
2. 同一文字选区 Aa→颜色→返回→字体页→返回→继续格式化→退出，检查显示/隐藏、选区、高亮、焦点、撤销重做和 Document JSON。
3. 中文拼音 composing、长文末尾、分屏、返回键和系统手势；重新锁定后旧回调绝不能再拉起键盘。
4. 原版与 DailyNotes 使用相同测试文档、版本/设备/输入法记录；对每个差异写结果「相同 / 更顺畅的有意差异 / 受限待开发 / 未测试」及原因。
5. 所有“已验证”必须含实际 APK、CI、目标设备或可复核脚本与日志，不用静态示意图/内存事务伪装完成。

**真实状态：本轮已核对最新官方 Release、同版本构建出处及标签源码，发现标签提交与 Android 构建元数据来源提交不同；没有运行官方 Android APK，没有对 DailyNotes 执行应用代码更改或自动化/真机验收。**
