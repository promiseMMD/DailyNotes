# DailyNotes — AppFlowy 移动端关联菜单源码研究 R003

- 日期：2026-11-15
- 需求关联：DN-178～DN-182
- 研究基线：AppFlowy-IO/AppFlowy 完整应用 main，当前引用用于定位源文件，真实交付前需固定具体源码提交与完成真机验证；此前 R002 已锁定上游 commit 8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93
- 研究等级：已读取源码实现路径；未运行 APK、未做真机、未按像素核验界面；所有概念图仅低保真设计示意。

## + 插入菜单（源码）
- `frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/add_block_toolbar_item.dart`：工具栏 +，点击后控制键盘与保留选区，`showAddBlockMenu` 使用 `showMobileBottomSheet`，内含 `TypeOptionMenu` 条目列表。
- `.../mobile_toolbar_v3/add_block_menu_item_builder.dart`：`_buildDefaultTypeOptionMenuItemValues` 聚合标题、段落、清单、表格、引用、项目符号/编号/折叠列表、折叠标题、图片、相册、文件、日期和页面提及、分隔线、提示、代码及数学公式等菜单构造器；表格单元格内的项集合有所不同。
- 不得误画成默认六宫格/自建两级六项菜单。

## Aa 排版（源码）
- `.../mobile_toolbar_v3/aa_toolbar_item.dart`：Aa 入口在工具栏，可打开菜单。内容 `_TextDecorationMenu` 内按行布置：HeadingsAndTextItems；BIUSItems 与 ColorItem；BlockItems 与 AlignItems；FontFamilyItem 与 IndentAndOutdentItems。
- `.../aa_menu/_heading_and_text_items.dart`：标题 1/2/3 与段落。
- `.../aa_menu/_bius_items.dart`：B/I/U/删除线格式。
- `.../aa_menu/_block_items.dart`：列表、编号列表、引用、链接/行内代码相关入口。
- `.../aa_menu/_align_items.dart`：左/中/右对齐。
- `.../aa_menu/_font_item.dart`：字体选择经 AppFlowy 应用内的独立页面，不能假定独立 editor 包直接带相同字体页。

## 附件/媒体（源码）
- `.../mobile_toolbar_v3/add_attachment_item.dart`：工具栏媒体入口与 + 菜单文件/图片入口不是完全同一个快捷面板；媒体入口的底部面板三项是选择照片、拍照、选择文件。

## 选区（源码）
- `.../mobile_floating_toolbar/custom_mobile_floating_toolbar.dart`：文字旁的上下文工具栏包括复制、粘贴、剪切、选择、全选，具体显示随是否折叠选区而变化。
- `.../mobile_toolbar_v3/toolbar_item_builder.dart`：非折叠选区显示格式工具栏 Aa、B/I/U/删除线/颜色，特定条件显示链接；在列表内部显示不同的缩进与列表操作。

## 讨论中，不是批准的实现
- 用户同意以 AppFlowy 原版菜单作为概念图与交互讨论基线，不意味着所有插入块、字体资源、复杂表格、媒体保存流程都已授权复制或通过验证。
- 仍需处理 DailyNotes 记录 ID、编辑修订、附件引用、WebDAV 手动增量同步、笔记与日记自动保存、长期记录的草稿/正式追加分隔，不得由 editor 内存事务取代可靠持久化。
- 开发之前确认上游代码和素材的授权适用性、选择实际引擎及明确按钮功能范围，避免空按钮。
- 真机验证含中文输入法、长按选区、键盘/底部菜单切换、撤销、相册权限与断点恢复。

## 可追溯链接
- https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/add_block_toolbar_item.dart
- https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/add_block_menu_item_builder.dart
- https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/aa_toolbar_item.dart
- https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/add_attachment_item.dart
- https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_floating_toolbar/custom_mobile_floating_toolbar.dart

## 后续确认：Aa 四组与 + 原版纵向区块菜单（DN-200）

- 2026-11-15，用户明确同意：**DailyNotes 手机端 Aa 排版菜单尽可能 1:1 沿用 AppFlowy 完整应用的四组控件布局和交互；编辑器内部 + 采用 AppFlowy 原版纵向区块插入菜单，按原版条目层次、顺序、滚动方式、底部面板与上下文状态复刻，而不是另设计简化六宫格、五类卡片或自定义二级菜单。**
- 本条对旧的「继续研究和待选择菜单结构」提出明确批准：菜单结构、排版顺序、高一致性复刻方向已确认。**不代表所有高级区块已实现、已通过许可审查或真机验证**；复杂表格、媒体、公式等仍按既定五阶段实现，未实现项列入差异清单，不能出现假按钮。
- 已核对的完整 AppFlowy 固定源码：`AppFlowy-IO/AppFlowy@8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93`。
  - `mobile_toolbar_v3/aa_toolbar_item.dart` 控件顺序：HeadingsAndTextItems；BIUSItems + ColorItem；BlockItems + AlignItems；FontFamilyItem + IndentAndOutdentItems。后续视觉应按原版具体布局核验，不可用研究概括的“四组”擅自另排版。
  - `mobile_toolbar_v3/add_block_toolbar_item.dart`：点击编辑器 + 关闭键盘、保留选区，`showMobileBottomSheet` 展示 `AddBlockMenu`；顶部标题、拖动柄、关闭按钮等需核对。
  - `mobile_toolbar_v3/add_block_menu_item_builder.dart`：默认序列依次聚合标题、段落、清单、表格、引用、列表、折叠标题、图片、相册、文件、提及、分隔线、提示块、代码、数学公式；表格单元格等上下文使用不同允许项，不能不加判定地罗列一模一样的所有项。
- 用户另已批准 DN-197/198 的既有记录默认阅读锁定、须解锁并点正文才出现键盘，DN-193 的统一编辑器，DN-194 的功能不静默删减。工具栏 Aa 和编辑器 + 只允许在可编辑上下文操作，不能绕过阅读锁改写文档；编辑器 + 不等同于底部全局新建 +（DN-155）。
- **仍待讨论**：颜色子面板的文字色/高亮色与选区保留、字体选择页面返回焦点、键盘与 Aa/+ 菜单交替、具体图标/边距/字体、每种区块的交付阶段与能力状态；不能将本次“可以”视为对上述实施细节的全部批准。
- 仅作规范和研究确认；未修改 DailyNotes 源码，未执行 flutter test、构建或真机对比。研究历史段落原样保留，以本后续确认为最新决策。
