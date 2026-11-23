# DailyNotes — AppFlowy 手机编辑工具栏复刻源码基线 R002

- 归档日期：2026-11-15
- 关联要求：DN-178、DN-179、DN-180、DN-181；与保存及业务边界 DN-009/010、DN-020/021、DN-044/045/047、DN-155 保持相容。
- 用户设计决定：手机端编辑工具栏以 AppFlowy 完整 App 的现有移动端工具栏为 1:1 复刻基准，不默认采用此前另行设计的六按钮精简工具栏。复刻对象限工具栏及其直接关联的弹出菜单/状态切换；不代表整个 AppFlowy 产品、区块库、云服务或数据格式均被批准导入。
- 源码固定基线：AppFlowy-IO/AppFlowy 仓库 main，2026-11-15 核查时 commit `8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93`。此为源码快照，不等于 0.15.0 已发布二进制的逐像素真机验收。若以后上游变动，需重新核对并经确认后更新基线。
- 注意对照：AppFlowy-IO/appflowy-editor 为单独的编辑器库，其示例以 MobileToolbarV2 实现，不等同于完整 App 的 mobile_toolbar_v3；直接取用完整 App 代码会涉及其 AGPL-3.0 授权评估，独立编辑器库为 AGPL-3.0/MPL-2.0 双授权。相关依赖、图片素材和商标的法律/技术审核与实机验证均未完成。

## 原版手机工具栏的源码清单

1. 编辑器入口：`frontend/appflowy_flutter/lib/plugins/document/presentation/editor_page.dart`
   - UniversalPlatform.isMobile 分支使用 `AppFlowyMobileToolbar(toolbarHeight: 42.0, toolbarItemsBuilder: buildMobileToolbarItems)` 与 `MobileFloatingToolbar`。
   - https://github.com/AppFlowy-IO/AppFlowy/blob/8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_page.dart
2. 按钮生成与状态分组：`frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/toolbar_item_builder.dart`
   - 默认插入光标状态 `_defaultToolbarItems` 实际顺序：插入 +、Aa、清单、项目符号列表、附件/媒体、编号列表、粗体、斜体、下划线、删除线、颜色、撤销、重做。
   - 非折叠文字选区：Aa、粗体、斜体、下划线、删除线、颜色；满足单段文字条件下追加链接按钮。
   - 列表内光标：插入 +、Aa、减少缩进、增加缩进、清单、项目符号列表、编号列表、粗体、斜体、下划线、删除线、颜色、附件/媒体、撤销、重做。
   - https://github.com/AppFlowy-IO/AppFlowy/blob/8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/toolbar_item_builder.dart
3. 工具栏面板、键盘监听和横向滚动：`mobile_toolbar_v3/appflowy_mobile_toolbar.dart`
   - 监听 selectionNotifier 与键盘高度，通过 OverlayEntry 显示，横向 ScrollablePositionedList 显示所有工具，右侧提供关闭键盘/菜单按钮。打开子菜单时可以暂收键盘，保留其高度空间。
   - https://github.com/AppFlowy-IO/AppFlowy/blob/8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/appflowy_mobile_toolbar.dart
4. 插入按钮：`mobile_toolbar_v3/add_block_toolbar_item.dart`
   - `+` 进入 showMobileBottomSheet 弹出插入菜单，处理当前选区与键盘；菜单内容由 `add_block_menu_item_builder.dart` 管理。已确认复刻这个直接入口/交互，不代表全部块类型都已确认加入 DailyNotes。
   - https://github.com/AppFlowy-IO/AppFlowy/blob/8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/add_block_toolbar_item.dart
5. 选区浮动操作菜单：`mobile_floating_toolbar/custom_mobile_floating_toolbar.dart`
   - 文本附近显示复制、粘贴、剪切、选择、全选等；文字格式主要来自键盘上方动态工具栏。已有的 DN-180 方案 C 与这套实现一致。
   - https://github.com/AppFlowy-IO/AppFlowy/blob/8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_floating_toolbar/custom_mobile_floating_toolbar.dart

## 复刻范围与待定边界
- 确认：移动端工具栏 UI/按钮优先参考上述源码快照；保留原版默认顺序、条件分组、横向滚动、键盘上方定位、插入 + 的面板入口与光标/选区联动。不擅自因为所谓极简而删除原版功能或改变排列。
- 保留：DailyNotes 原有的阅读态不常驻工具栏（DN-180）、普通日记本机正式自动保存、笔记本机自动保存及失败保护、长期记录的草稿/正式追加区别，编辑器内 + 与底部导航全局 + 不同职责。
- 待讨论：插入菜单的区块内容是否完全复制，是否支持所有原版附件和格式能力；未实现功能是否隐藏/禁用以及状态提示；颜色、图标、精确尺寸是否逐像素；文字选区原生/自定义融合方式；Slash、技术架构、依赖选择和本地/同步数据模型。
- 质量门槛：普通输入、中文 IME 组合/删除、列表缩进、段落转换、撤销重做、选区复原、键盘高度、长文滚动和本机落盘确认等 P0/P1 必须实机验证后才能称为已实现。
- 当前状态：仅官方源码核验和设计记录；无 Android APK 预览、模拟器运行或真机验收，未修改 App 代码。

## 与旧候选图稿的关系
- 此前“常用 6 项 + 更多”的自创两级工具栏布局仅为候选，不再作为默认实施基线；AppFlowy 原版工具栏优先。
- 用户先前称“两级紧凑底部面板可以但要看概念图”并未确认每个区块或二级菜单结构；这部分与 + 菜单内容继续讨论，不能自动认定完全复制。
