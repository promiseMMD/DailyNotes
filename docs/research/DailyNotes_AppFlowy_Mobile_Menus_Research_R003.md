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
