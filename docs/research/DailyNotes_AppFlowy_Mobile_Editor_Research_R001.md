# DailyNotes 编辑器手机端源码研究 R001
- 日期：2026-11-15
- 决策范围：用户确认先研究实际移动端实现，再定稿编辑器交互。仅归档研究，不编码，不替用户批准细节。
- 需求关系：DN-009、DN-010、DN-011、DN-013、DN-015、DN-018、DN-020、DN-021、DN-044、DN-045、DN-047、DN-178、DN-179。
- 证据形式：阅读 GitHub 官方源码与公开 Issue；未执行真机、模拟器、依赖构建或回归验收。

## 1. 版本边界
- AppFlowy 完整应用 AppFlowy-IO/AppFlowy：官方 release 0.15.0（2026-11-02），源码参考 main，功能与独立包不同。
- appflowy_editor 独立 Flutter 包：GitHub 最新 release 6.1.0（2025-12-08），pubspec Flutter >=3.32.0；其 example/lib/pages/mobile_editor.dart 采用 MobileToolbarV2。
- 完整应用的 editor_page.dart 在 mobile 分支组合 AppFlowyMobileToolbar（设置 42.0）与 MobileFloatingToolbar；其专属自定义工具栏不能推定为独立包直接提供。

## 2. 源码核验
- `AppFlowy/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_page.dart`：根据 UniversalPlatform.isMobile 走单独组合；移动端初始选区通过 scrollTo 滚动，不走桌面 jumpTo。参考 https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_page.dart
- `mobile_toolbar_v3/toolbar_item_builder.dart`：普通输入、文本扩选、列表三种不同工具集；选中文字的格式项单独配置。https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/toolbar_item_builder.dart
- `mobile_toolbar_v3/appflowy_mobile_toolbar.dart`：OverlayEntry、selectionNotifier、键盘高度监听与缓存、键盘与子菜单切换、横向可滚动工具列表。https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/appflowy_mobile_toolbar.dart
- `mobile_toolbar_v3/add_block_toolbar_item.dart`：点击 + 时暂闭键盘、保留选区、显示 draggable bottom sheet。https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/add_block_toolbar_item.dart
- `mobile_toolbar_v3/add_block_menu_item_builder.dart`：标题、段落、清单、表格、引用、图片附件、代码、数学公式等多类型（DailyNotes 不应视为默认需全部引入）。https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/add_block_menu_item_builder.dart
- `mobile_floating_toolbar/custom_mobile_floating_toolbar.dart`：悬浮选择栏主要是复制/粘贴/剪切/选择/全选，文字格式的专用项主要在底部工具栏，不应误说悬浮菜单默认承载格式。https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_floating_toolbar/custom_mobile_floating_toolbar.dart
- `slash_menu/slash_command.dart`：支持移动端 MobileSelectionMenu 路径，但快速记录不必开启或推广 '/' 命令。https://github.com/AppFlowy-IO/AppFlowy/blob/main/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/slash_menu/slash_command.dart
- `appflowy-editor/example/lib/pages/mobile_editor.dart`：官方独立包演示使用 MobileToolbarV2、MobileFloatingToolbar、EditorStyle.mobile。https://github.com/AppFlowy-IO/appflowy-editor/blob/main/example/lib/pages/mobile_editor.dart
- `appflowy-editor/lib/src/editor_state.dart`：transactionStream 可观察事务变化，属于编辑事件，不等于本机已持久化或远端已同步。https://github.com/AppFlowy-IO/appflowy-editor/blob/main/lib/src/editor_state.dart

## 3. 已知风险
- Issue #1215 （2026-06-30，核验为 Open）：Android 16 Galaxy S23+ 表格单元焦点/自动滚动导致 ANR/跳动；主要表格场景，不应外推到普通纯文本。https://github.com/AppFlowy-IO/appflowy-editor/issues/1215
- Issue #1218（2026-07-05，核验为 Open）：初始化空文档无 Node，点击时 ArgumentError；新建时应确保至少一个有效段落并专门验收。https://github.com/AppFlowy-IO/appflowy-editor/issues/1218
- 历史更新涉及中文 IME、Gboard 全选、焦点、光标、自动滚动修复；修复记录并非特定机型测试通过证明。
- AGPL-3.0 / MPL-2.0 双许可，引入前需要合规审查；平台 UI 与正文数据结构应解耦。

## 4. 候选方向（均未确认）
- 阅读态无底部工具栏；进入输入后显示键盘上方轻量工具栏，显示少量高频操作；高级格式由 Aa/+/更多展开。
- 文字选区采用安卓原生样式的复制/剪切/选择菜单；格式工具沿用下方上下文工具栏，避免重叠。
- 插入区块优先普通段落/标题/列表/清单/图片/分隔线；表格、公式、复杂布局延期，不等于取消。
- 普通日记与笔记可共享文档排版与编辑引擎，但保存策略按业务不同：日记和笔记正式记录自动本机持久化；长期记录新增先草稿、明确提交之后才形成正式一次追加，不混淆。
- 本机成功落盘后才显示已保存，WebDAV 同步状态另示，编辑事件不等于持久化成功。
- 独立待办实体与文档里的清单区块保持独立，未经设计批准不自动互转。

## 5. 必要验证（尚未执行）
P0：中文拼音组合与删除、候选词、光标移动、剪切粘贴、长按选区、Gboard 与小米输入法；首字输入；纯空白文档；旋转/切后台/进程回收/键盘高度切换。
P0：断电或强杀前后的草稿/历史恢复；本机保存失败明确提示；WebDAV 不得误报同步成功；长期记录同日多次追加保持独立 ID、时间和顺序。
P1：2万字长文流畅性、图片/列表输入、连续撤销重做、返回草稿保护、附件失败恢复。
P1：全屏/分屏、深色模式、字体缩放、大字号和手势冲突。
P2：Slash 命令、复杂表格、数学公式与多媒体扩展。

## 6. 未决事项
选择固定精简工具栏 vs 仅选中时显示；区块清单及顺序；是否保留 slash；字数限制、图像插入与附件处理；编辑器引擎是否直接使用 appflowy_editor（须通过真机 P0 和许可审查）。所有内容继续待讨论，禁止把候选建议当已确认定稿。
