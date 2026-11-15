# DailyNotes × AppFlowy 第一阶段：Enter / Backspace / 列表缩进 / 中文输入 R017（讨论稿）

- 归档：2026-11-15。
- DailyNotes 当前基线：`docs/requirements/DailyNotes开发规范_V2.72.md`，DN-001～DN-198。
- 用户本轮指示：继续第一阶段编辑手感讨论，沿用“尽可能与 AppFlowy 完整应用一样”的方向。**本轮各键位的具体行为是基于源码的研究与实施建议，并非用户新确认的正式 DN 规则。**
- AppFlowy 完整应用工具栏固定参考点：`AppFlowy-IO/AppFlowy@8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93`，R002/R003。
- 独立底层编辑器测试参考点：`AppFlowy-IO/appflowy-editor@01eccc6ee36bd07698bd80915289fe7070478cd2`，2026-11-15 读取的 main SHA。此独立包测试不能直接证明完整 AppFlowy Android APK 上所有中文软键盘行为。
- 性质：原版行为证据对照、建议验收用例、未决决策；不修改应用源码/规范、不编译 APK、不做真机测试。

## 一、对标源代码已实际核对的行为

1. **Enter 在非空列表中保留列表类型；空列表项再次 Enter 可转回段落。**
   - `test/new/service/shortcuts/command_shortcut_events/enter_without_shift_in_text_node_handler_test.dart` 的 `_testStyleNeedToBeCopy`：针对 bulleted_list、numbered_list、todo_list，断言新行节点类型继续是原列表类型，然后在空项再次 Enter 后节点类型为 paragraph。
   - `_testListOutdent` 对部分缩进列表验证了 Enter/层级/退出路径；实际目标手机软键盘与不同嵌套层级仍须复现。
2. **Backspace 在节点边界可能涉及合并、去嵌套或转换段落。**
   - `backspace_command_test.dart` 覆盖光标中间删除、段落起点合并、嵌套节点上提、列表转换成段落并保留文本方向；不是“任何时候 Backspace 都删除前一个 Unicode 字符”。
   - 避免误称“列表符号被删除时一定发生哪一种转换”，须按实际嵌套层级与光标位置对照。
3. **缩进与撤销/重做既是内容结构操作，也有专项测试。**
   - `indent_command_test.dart`、`outdent_command_test.dart` 包括 LTR/RTL、混合段落与多行缩进场景。
   - `undo_redo_command_test.dart` 含嵌套列表、Enter/Tab 后两次撤销重做的测试。
4. **IME 覆盖范围和实际不足。**
   - `test/new/service/ime/delta_input_on_insert_impl_test.dart` 只证明有单行/跨行选区替换等编辑器测试，**不能据此宣布小米 Android 16/HyperOS 中文拼音组合输入已无问题**。
   - AppFlowy Editor 更新历史曾含中文输入法连续删除、Android 选区、列表 undo/redo 与 Enter 优化修复记录；是回归测试风险线索而非 DailyNotes 的实测通过证明。

## 二、阶段一建议交互方案（待讨论，尚非已批准需求）

| 场景 | 建议行为 | 需验收 |
|---|---|---|
| 普通段落 Enter | 光标处分段，前后文本不丢，选区/格式合理继承 | 段首、段中、段末、跨段选区 |
| H1/H2/H3 Enter | 优先贴近 AppFlowy 实际标题拆段/退出行为，而非自定义；需锁定原版真机脚本 | 标题空行、标题末尾、标题中间 |
| 非空项目符号/编号/清单 Enter | 新建同类列表项，正确编号、未预先勾选新的清单项（需原版/源码进一步核对） | 每种列表、嵌套列表、连续 Enter |
| 空列表项 Enter | 根据 AppFlowy 测试退出为普通段落 | 多层缩进空项、光标与工具栏切换 |
| 文本中间 Backspace | 删除光标前的文本单元，中文组合文字不得被误分割 | 拼音组合态、emoji/代理对、换行 |
| 段落/列表开头 Backspace | 合并段落或取消列表/上提层级，保留正文和格式，按原版测试分支处理 | 列表首项、层级、选区、全文首段 |
| 列表增加/减少缩进 | 使用原版列表模式工具栏与外接键盘快捷键；支持多行，调整后 undo/redo 可还原 | 多选、多级、RTL/LTR、边界限制 |
| 文本选择/输入法 | 选词、长按、拖动选区与工具栏状态切换一致 | 系统输入法候选栏、剪切粘贴 |
| 中文 IME 组合 | 拼音输入尚未上屏时，不应被自动区块转换或重复写入；待提交后才触发明确相应的结构转换（需要看上游具体处理） | 例如“光刻ji台”、候选切换、连击退格、数字编号 |
| 撤销/重做 | 按有意义的用户编辑操作恢复文字及结构，不跨文档、不清除已保存版本 | 快速输入、列表转换、格式、退格、锁定/解锁 |

### 输入法特别注意

- Android 软键盘发送的编辑变化可能不是物理 KeyDown 事件的简单对应；必须测试 Flutter text input / IME delta、composing range、selection 更新，而非只模拟物理 Enter 与 Backspace。
- 中文拼音、数字联想与 Markdown 风格触发字符（`-`、`1.`、`/`）相互作用，需确认不会在拼音组合未提交时自动变更区块或误删未提交候选。
- 验收至少包括小米设备自带输入法、Gboard（若测试环境具备）、外接蓝牙键盘；报告必须区分“SDK widget tests passed”与“目标手机真机输入通过”。

## 三、和已确认 DailyNotes 阅读锁定规则的交叉测试

- DN-197：新建日记/笔记/新追加草稿直接聚焦并弹键盘；已存在记录默认锁定只读，不能因光标移动/Enter/Backspace/工具栏事件写入。
- DN-198：已存在记录点解锁后只进入可编辑态，不弹键盘；再次点正文才输入；可请求重新锁定，先处理未落盘写入。
- DN-195/196：业务标题与正文同区滚动，输入、撤销或键盘变化不得造成标题重新出现、误跳文首、光标遮挡或滚动位置错乱。
- DN-020/021、DN-045/047：正式保存只能在手机持久事务成功后标识；Enter、Backspace 的 EditorState 内存事务不等于「已保存」。
- DN-009/010：长期记录新追加草稿的分段和列表变更不自动触发正式提交；退出时未提交内容保留草稿与确认边界。
- DN-183/187：正文 Document JSON 要完整往返，业务身份/revision 独立；手机是唯一正式权威存储；WebDAV 仍只由用户手动触发。

## 四、第一阶段建议验收脚本（仅设计，未执行）

1. 新建日记，用中文拼音输入 3 段，Enter、Backspace、撤销重做，锁屏/强杀/重启后内容/结构恢复（正式保存语义需实现）。
2. 新建笔记依次输入：普通段落、H1、H2、H3、清单、编号列表、项目符号、嵌套两级；各项连按 Enter 及退格，观察节点 JSON。
3. 在列表中已有内容/空内容交替按 Enter，验证新项类型、退出列表、编号顺序。
4. 在列表首、中、尾执行 Backspace，验证文本、格式、缩进、方向、选区无意外丢失。
5. 多选两个列表项执行增加缩进→撤销→重做→减少缩进，比较原始/最终 Document JSON。
6. 输入“光刻设备设备安装”、含拼音未上屏时连退格与切换选区；对 emoji、中文标点、英文数字混排做边界测试。
7. 已有记录以阅读锁打开，用软键盘/外接键盘/清单勾选尝试修改：必须失败；解锁但未点击正文不弹键盘；点击后可编辑；重新锁定后禁止误写。
8. 长文（至少几千字）末尾连续输入/删除/新建列表，确认键盘工具栏不遮挡光标，业务标题按 DN-196 仅随正文滚动。
9. 保存失败和重新锁定碰撞：不能丢内存/恢复草稿，必须可明确重试或复制，只有真落盘可显示本机已保存。
10. 所有操作保留与目标 AppFlowy 版本截图/屏录/对应测试脚本的对照证据，逐项登记相同/差异/待验证。

## 五、下一步讨论建议

优先确定**列表里的 Enter/Backspace 与原版尽量 1:1**的设计方向：
- 非空列表 Enter → 同类新项；
- 空列表 Enter → 退出列表成普通段落；
- Backspace 在开头按结构退层级/转换/合并，正文绝不丢失；
- 缩进采用已有的原版按钮分组，支持多项和撤销重做。

**上述仍是提议，用户尚未逐项确认**。确认后再追加正式 DN 编号，不把讨论稿直接当成审批。

## 六、可追溯证据

- Enter tests: https://github.com/AppFlowy-IO/appflowy-editor/blob/01eccc6ee36bd07698bd80915289fe7070478cd2/test/new/service/shortcuts/command_shortcut_events/enter_without_shift_in_text_node_handler_test.dart
- Backspace tests: https://github.com/AppFlowy-IO/appflowy-editor/blob/01eccc6ee36bd07698bd80915289fe7070478cd2/test/new/service/shortcuts/command_shortcut_events/backspace_command_test.dart
- Indent tests: https://github.com/AppFlowy-IO/appflowy-editor/blob/01eccc6ee36bd07698bd80915289fe7070478cd2/test/new/service/shortcuts/command_shortcut_events/indent_command_test.dart
- Outdent tests: https://github.com/AppFlowy-IO/appflowy-editor/blob/01eccc6ee36bd07698bd80915289fe7070478cd2/test/new/service/shortcuts/command_shortcut_events/outdent_command_test.dart
- Undo/redo tests: https://github.com/AppFlowy-IO/appflowy-editor/blob/01eccc6ee36bd07698bd80915289fe7070478cd2/test/new/service/shortcuts/command_shortcut_events/undo_redo_command_test.dart
- IME delta tests: https://github.com/AppFlowy-IO/appflowy-editor/blob/01eccc6ee36bd07698bd80915289fe7070478cd2/test/new/service/ime/delta_input_on_insert_impl_test.dart
- Changelog: https://github.com/AppFlowy-IO/appflowy-editor/blob/01eccc6ee36bd07698bd80915289fe7070478cd2/CHANGELOG.md
- DailyNotes requirement: docs/requirements/DailyNotes开发规范_V2.72.md
- R014: docs/research/DailyNotes_AppFlowy_Five_Phase_Parity_Inventory_R014.md

**真实状态：完成源码/测试审查与讨论稿归档。没有 DailyNotes 代码修改、自动化执行、真机截图或验收成功证据。**
