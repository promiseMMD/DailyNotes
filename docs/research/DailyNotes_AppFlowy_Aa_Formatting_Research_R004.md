# DailyNotes × AppFlowy 手机 Aa 排版菜单：源码研究 R004

日期：2026-11-15  
项目分支：`promiseMMD/DailyNotes@feat/bootstrap-ui-v0`  
目前需求基线：`docs/requirements/DailyNotes开发规范_V2.56.md`，DN-178～DN-182  
源码基线：`AppFlowy-IO/AppFlowy` main @ `8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93`，`AppFlowy-IO/appflowy-editor` main（以下链接用于定位，实现细节以本轮读取为准）。  
性质：源码研究与候选交互，**不是新增已确认需求**；用户同意继续研究 Aa，尚未批准所有样式能力、引擎或实施方案。**无代码修改、APK 测试、真机验收**。

## 一、完整 AppFlowy 手机 Aa 菜单是四行交互，而不是简单四格
- `frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/aa_toolbar_item.dart` 的 `_TextDecorationMenu`：第一行 `HeadingsAndTextItems`，第二行 `BIUSItems` + `ColorItem`，第三行 `BlockItems` + `AlignItems`，第四行 `FontFamilyItem` + `IndentAndOutdentItems`。弹出菜单是与键盘空间配合的滚动内容，而不是另开完整文档页。
- 第一行 `aa_menu/_heading_and_text_items.dart`：H1/H2/H3 和段落，`editorState.convertBlockType` 更改节点类型及标题层级，因此不是简单字体大小改变。
- 第二行 `aa_menu/_bius_items.dart`：粗体/斜体/下划线/删除线，通过 `editorState.toggleAttribute` 维护选区样式；`aa_menu/_color_list.dart` 分文字颜色与文字背景颜色；有选区时通过 `formatDelta(selection,...)` 写入，插入光标时通过 `updateToggledStyle` 设置后续输入。
- 第三行 `aa_menu/_block_items.dart`：项目列表、编号列表、引用及链接/行内代码相关菜单；`aa_menu/_align_items.dart`：左/中/右对齐，操作 `editorState.alignBlock`。
- 第四行 `aa_menu/_font_item.dart`：独立字体选择页 `FontPickerScreen.routeName`，可对选区应用字体属性，或针对折叠光标设置后续输入字体；`aa_menu/_indent_items.dart`：加/减缩进，带可用性判断并执行相应命令。

## 二、编辑器排版与数据格式的三层边界
1. 视觉状态：Aa 面板当前选项、光标、选区、键盘显隐、格式预览。
2. 编辑内容：`appflowy-editor/lib/src/editor_state.dart` 暴露事务流 `transactionStream`，`Document` 和 `Node`/Delta 能表示段落与行内富文本；`Document.toJson/fromJson` 为文档序列化手段，但其本身不执行 SQLite 持久化、不生成 DailyNotes 业务 revision、不保证断电恢复、更不等于 WebDAV 已同步。
3. DailyNotes 业务数据：普通日记/笔记/长期追加仍分别适用 DN-020/021、DN-045/047、DN-009/010；本机事务提交确认后才可标记保存成功；同步需独立持久化事件队列、版本与附件引用机制，保持 DN-147～150。长期记录某日追加仍有独立 append ID/创建时间/正式提交边界；富文本区块不能吞并这些身份字段。

## 三、待定稿而非已确认的 Aa 交互候选
- 保留 AppFlowy 的四行面板结构和组合控制组，不再以自创的「仅 B/I/U/颜色」作为替代；这是与 DN-181、DN-182 一致的设计候选，具体每个按钮需要逐项批准。
- 按光标和选区应用不同的文字样式语义：折叠光标作用于后续输入，扩展选区作用于所选内容；多段选区与换段行为必须验证。
- 标题类型是块级变化；对齐与缩进要验证多段/列表；切换字体后恢复原选区，不可跳到错误位置或丢失未提交内容。
- 颜色需要区分「字体颜色」与「文字高亮背景」，取消后正文不应残留未知格式；在夜间模式/主题变更中保持明确可读性。
- 支持原版布局不等于必须使用原版品牌图标资产/直接复制 GPL 代码：上游完整 App 与独立 editor 的许可路径需单独审核。
- 不推荐在尚无持久化协议时宣称「格式已保存」；避免仅将浏览器式 Markdown 字符串作为唯一源导致节点/选区/背景色属性丢失。

## 四、必须验证的场景（此轮均未执行）
P0：中文拼音输入、组合态删除/选区、换行转换标题，切换 Aa 后选区保留、键盘切换、撤销与重做的格式完整性。
P0：本机成功落盘状态与编辑器事务严格区分；强杀/异常关闭后文本、标题、颜色、背景色及段落层级可恢复。
P0：长期追加草稿未提交时可以保留并恢复，不能因触发 Aa 造成正式追加或数据覆盖。
P1：多段/跨区块选区格式化、列表层级缩进/撤销、字体从选择页返回后的光标恢复、深浅色/辅助功能字体。
P1：富文本 JSON 序列化→存储→重载往返一致，WebDAV 增量同步后与另一台设备往返仍一致，附件保持引用完整。
P2：自定义字体包授权、Markdown/Delta 导入导出不丢格式、更多块类型兼容。

## 五、源码链接
- Aa 主面板：https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/aa_toolbar_item.dart
- 标题与段落：https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/aa_menu/_heading_and_text_items.dart
- 样式：https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/aa_menu/_bius_items.dart
- 颜色与背景：https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/aa_menu/_color_list.dart
- 列表引用与对齐：https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/aa_menu/_block_items.dart
- 字体选择：https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/aa_menu/_font_item.dart
- 缩进：https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/aa_menu/_indent_items.dart
- Document/JSON：https://github.com/AppFlowy-IO/appflowy-editor/blob/main/lib/src/core/document/document.dart
- EditorState 事务：https://github.com/AppFlowy-IO/appflowy-editor/blob/main/lib/src/editor_state.dart

## 六、对下一轮定稿的建议
先让用户评估与原版同构的四行 Aa 低保真概念图，再讨论不同菜单交互顺序、颜色弹层、字体列表、格式激活态、返回焦点。只有用户明确确认具体细节后按 DN-153 增量更新需求版本；当前 V2.56 不需变更，因为本轮没有新增已确认产品行为。
