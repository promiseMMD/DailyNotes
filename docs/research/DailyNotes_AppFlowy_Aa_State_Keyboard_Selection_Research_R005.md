# DailyNotes 编辑器专项研究 R005：AppFlowy 手机 Aa 菜单状态、选区与键盘恢复

- 研究日期：2026-11-15。
- DailyNotes 分支：`promiseMMD/DailyNotes@feat/bootstrap-ui-v0`，读取时 HEAD `b14341c154314730299ad3e455bd78728f339f8d`。
- 上游完整应用：`AppFlowy-IO/AppFlowy@8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93`。
- 上游独立包：`AppFlowy-IO/appflowy-editor` main 源码与部分测试。
- 关联：DN-178～DN-182、DN-009/010、DN-020/021、DN-044/045/047、DN-147～150。
- **本轮是只读源码与公开 Issue / 测试审查；没有编译、没有运行 Flutter 测试、没有 APK/真机测试，也不新增“已确认”交互细则，不改 V2.56。**

## 1. 主链路：键盘与 Aa 面板互换
源：`frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/appflowy_mobile_toolbar.dart`。
- `itemWithMenuOnPressed` 当前未打开此菜单时：置 `canUpdateCachedKeyboardHeight=false`，记录 `selectedMenuIndex`，`showItemMenu()`，标记 `closeKeyboardInitiative=true`，执行 `_closeKeyboard()`。菜单并非简单地叠在键盘上，而是占用缓存键盘高度所在的区域（`_buildMenuOrSpacer`）。
- 再点同一菜单：`closeItemMenu()` 并 `_showKeyboard()`，延迟 500ms 之后恢复缓存键盘高度更新。注意：代码是发起请求，不能证明任何具体输入法真的成功恢复。
- `showItemMenu`/当前 selection 的 `didUpdateWidget` 联动：选区变化会关闭菜单并尝试重新显示键盘，存在需要实机验证的时序情况。
- Android 关闭工具栏按钮清空 editor selection，并额外调用 `SystemChannels.textInput.invokeMethod('TextInput.hide')`；用户切换文字选区、键盘或菜单的行为要与“清空当前选择”区分。
- `_onKeyboardHeightChanged` 会区分主动关闭键盘和系统关闭键盘；屏幕弹出其他系统界面时，是否会误清空选区需要验证。
- `cachedKeyboardHeight` 有跨实例静态记忆 `_globalCachedKeyboardHeight`；横竖屏、分屏、语言键盘高度变化、Android 导航区域变化尤其须测试，不可简单复制一个像素偏移值。
证据链接：https://github.com/AppFlowy-IO/AppFlowy/blob/8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/appflowy_mobile_toolbar.dart

## 2. Aa 按钮：样式和选中态
源：`.../mobile_toolbar_v3/aa_menu/_bius_items.dart`，`_heading_and_text_items.dart`。
- 粗体/斜体/下划线/删除线触发 `editorState.toggleAttribute(... selectionExtraInfoDisableFloatingToolbar:true, selectionExtraInfoDoNotAttachTextService:true)`；随后局部刷新按钮选择态，代码没有在每一次按钮点击后主动关闭 Aa 菜单。
- 标题 H1/H2/H3/正文通过 `editorState.convertBlockType` 改变节点类型/属性；转换后调用 `updateSelectionWithReason(editorState.selection,...)`，表明存在维持/调整选区的逻辑，**并非确保与转换前 offset 逐字节相同**。
- 多区块选区、标题和正文互转、选区端点与格式刷式连续输入行为仍需实测；P0 验收应比较动作前后文本、选区方向和实际文档结构。

## 3. 颜色子面板的选区快照
源：`.../mobile_toolbar_v3/aa_menu/_color_item.dart` + `_color_list.dart`。
- 点击颜色时 `service.closeKeyboard()`，通过 `updateSelectionWithReason` 暂抑制主手机工具栏和浮动工具栏，使用 `showTextColorAndBackgroundColorPicker` 打开底部面板。
- 打开时把 `selection` 传入颜色面板；改变颜色，若选区折叠，写 `updateToggledStyle` 影响后续输入；若扩展选区，写 `formatDelta(selection, {textColor|backgroundColor:hex})` 影响选中内容。
- 面板关闭后通过 `Future.delayed(100ms)` 请求恢复该快照选区。**这不是全局一致性保证**：在 100ms 内若记录被关闭/切换/删除或其他手势改变选区，需要检查是否会恢复旧路径或错误选区；不能因此断言存在 bug。
- 颜色面板提供完成按钮 `showDoneButton`，当前并不保证底层日记“已保存”；颜色面板完成与 DailyNotes 记录持久化完成是两件事。
链接：https://github.com/AppFlowy-IO/AppFlowy/blob/8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/aa_menu/_color_list.dart

## 4. 字体选择：异步导航，延迟恢复
源：`.../mobile_toolbar_v3/aa_menu/_font_item.dart`。
- 进入 `FontPickerScreen.routeName` 前缓存 selection，并请求临时隐藏浮动工具栏、主手机工具栏。
- 字体选择页面返回字符串后，如果有非折叠选区且字体不同，调用 `formatDelta(selection,{fontFamily:newFont})`。完成返回后再通过 `Future.delayed(250ms)` 恢复 selection；若只有插入光标，则设置 `updateToggledStyle(fontFamily,...)`。
- 未返回字体（系统 Back/取消）仍会尝试恢复 selection；恢复不等于自动打开键盘，必须在真实设备上区分「光标恢复」和「键盘恢复」。
- 风险验证：在快速连点 Aa/字体、离开页面、切换文档、旋转屏幕、字体包不存在时，延迟回调不得应用到另一文档或抛异常；此为测试建议，不代表已证实故障。
链接：https://github.com/AppFlowy-IO/AppFlowy/blob/8fcee27d9bd93aad4ee0191d5d8d915d6a9a4e93/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/aa_menu/_font_item.dart

## 5. 对齐、缩进：按当前区块语义执行
- `aa_menu/_align_items.dart`：左/中/右对齐通过 `editorState.alignBlock` 操作当前选区覆盖的块，菜单存在 PopupMenu 子项。
- `aa_menu/_indent_items.dart`：缩进/退格缩进按钮基于 `isIndentable`/`isOutdentable` 判定；点击会关闭菜单并执行命令，与 Aa 里的普通样式按钮处理并不完全相同。
- P0 场景：对列表内多段选区缩进、超过最大级数、混合段落选区执行格式、操作后撤销与重做、标签/清单 ID 不错位。

## 6. 第三方测试证据边界
从独立编辑器仓库读取：
- `test/mobile/toolbar/mobile/mobile_toolbar_test.dart`：验证无选区时工具栏隐藏、存在选择时工具栏渲染，不是完整 App 的 Aa → 颜色 → 返回的真实设备端到端测试。
- `test/mobile/toolbar/mobile/mobile_toolbar_item_test.dart`、`mobile_toolbar_style_test.dart`：基础配置/样式测试。
- `test/service/mobile_selection_gesture_test.dart`：点击、双击、三击手势测试。
- `test/new/service/ime/delta_input_on_insert_impl_test.dart`：单段及跨段选区替换输入测试；不能证明小米输入法的拼音组词状态或键盘显示时序。
- `appflowy-editor/CHANGELOG.md` 和完整 `AppFlowy/CHANGELOG.md` 历史包含中文输入、Android 选区及 Gboard 全选修复记录：这是风险背景，不代表目标机型已验证。

## 7. 截至本轮可复核的公开未关闭问题
- AppFlowy Editor Issue #1241，2026-09-23，Open：「[Bug] heading default font size wrong」报告默认标题字号的数组索引偏差；报告示例发生在独立包默认样式，**不能直接推断完整 AppFlowy 自定义样式也存在同样错误**。https://github.com/AppFlowy-IO/appflowy-editor/issues/1241
- Issue #1215，2026-06-30，Open：Android 16 实体机表格单元焦点/滚动 ANR 风险（仅报告涉及表格）。https://github.com/AppFlowy-IO/appflowy-editor/issues/1215
- Issue #1218，2026-07-05，Open：无初始段落的完全空白文档点击可能报错。https://github.com/AppFlowy-IO/appflowy-editor/issues/1218

## 8. 面向 DailyNotes 的待定状态机建议（非已批准需求）
S0 编辑正文、键盘显示 → 点击 Aa → S1 缓存光标/选区、收键盘，Aa 在原键盘区域展示；
S1 格式化 B/I/U/S → S1 原处保留菜单、正确更新选中态；
S1 点击颜色 → S2 颜色 BottomSheet，选区快照 → 颜色变更 → 关闭返回 S1 或可继续编辑状态，不能误换文档；
S1 点击字体 → S3 独立字体页，缓存文档身份与选区 → 返回时按当前文档校验快照、应用选择，恢复可编辑状态；
S1 再次点击 Aa → S0 恢复键盘；关闭/离开文档时阻止旧异步恢复影响其他文档。
上面状态机是 DailyNotes 安全实现候选，**不是声称 AppFlowy 现成代码已经实现所有防护**。

## 9. 数据安全约束
- 选区显示变化、`EditorState` 文档事务不是本机数据库提交：格式按钮成功不等于完成存储；只有本机事务写入成功可显示「本机已保存」。
- 保存选区属于 UI 快照，必须绑定当前文档 ID、其版本/块路径，避免异步返回落错对象；文档结构由 `Document.toJson/fromJson` 往返校验（依赖实际引擎方案）。
- DN-020/021 普通日记自动正式保存、DN-045/047 笔记本机保存及失败保护、DN-009/010 长期追加草稿/确认提交，保持原语义。
- WebDAV 只接受已落盘的业务事件和附件引用，不以颜色面板/选区关闭事件视为远端同步成功。

## 10. 建议下一步优先验证清单
P0-01：普通正文选区加粗/取消加粗后文字、选区与格式均正确，Aa 可连续操作。
P0-02：打开 Aa→颜色→完成/系统返回，原选区/光标正确、无跳文档或文字丢失。
P0-03：打开 Aa→字体→选择/取消/快速返回，正确恢复原上下文；编辑其他笔记后迟到的回调不能作用于新笔记。
P0-04：中文拼音组合中点击 Aa、切颜色/键盘、输入下一段、跨行选区，文本不能重复/丢失。
P0-05：标题转换、列表缩进、撤销重做后，文档序列化再重载内容与格式一致。
P0-06：本机写入失败 / 退出 / 进程终止不误报「已保存」，草稿与正式日记边界保持。
P1-01：蓝牙键盘、分屏、旋转、字体缩放、全面屏手势、浅/深主题切换。
P1-02：长文与图片混排下选区和滚动不卡顿；适配本机具体 Android/HyperOS 输入法。
参考源码：https://github.com/AppFlowy-IO/appflowy-editor/blob/main/lib/src/editor_state.dart

## 11. 完成本轮的范围说明
已核验：AppFlowy 源码存在相应状态协调、选区快照、延迟恢复和基础测试；相关公开 Issue 的状态截至研究日核查为 Open。  
未核验：正式上游 APK 的实际表现、DailyNotes 编辑器可编译性、自动持久化、任何真实设备上的成功率和外部键盘/特定输入法表现。  
没有变更已确认的 DN-001～DN-182；最新规范仍为 V2.56。

## 12. 用户确认：颜色与字体操作保留文字选区（DN-201）

- 用户在 2026-11-15 对「颜色和字体操作完成后，尽可能保留原来的文字选区，让用户可以连续进行多项排版操作，而不必反复选择文字」明确回复「同意」。**本条为已确认产品交互，覆盖本报告第 8 节状态机和第 10 节中作为候选的同类选区保留需求**；此前研究建议仍保留供追溯。
- 适用于统一的 AppFlowy 风格手机编辑器：选中一段正文后，经 Aa→文字颜色、Aa→高亮背景色，或字体选择页设置字体并返回，**只要原选区仍有效，尽可能继续保留该选区与滚动阅读位置**，让用户能连续对同一段文字进行粗体、斜体、下划线、背景色等多项格式化，而不必重复长按选取。
- 空选区（光标折叠）与非空文字选区的语义分开：折叠光标设置的是后续输入的样式，非折叠选区修改对应范围的现有文字。不同来源的菜单返回均不可意外丢文字、插入多余文字、打断中文拼音 composing 或随意移动光标。
- **必须有安全边界**：选区快照与编辑的文档/记录身份、文档结构与修订上下文匹配；当用户主动改变选区、转入另一篇记录、区块已经删除/重排、文档已经只读锁定、异步回调迟到或原选区无法安全恢复时，不得强制恢复过期选区，更不能把颜色/字体作用于错误正文。此时应保留内容、取消错误格式化并需要时提示重新选择文字。不得将「尽可能」误读为任何情况下必须不加校验地恢复旧选区。
- 连续排版时优先保留当前菜单上下文或提供顺畅的返回路径；**具体是颜色面板关闭后回到 Aa 还是回到正文、菜单精准尺寸/动画、字体页面返回时是否自动弹键盘等尚未由用户逐项确定**，不得借此自动升级为定稿。
- 与 DN-197/198 锁定模式协调：打开已有记录先只读，只有解锁才允许格式变更；未解锁时长按选中用于复制，不得把选区格式化入口变成绕过只读的写入途径。新建记录则按原已确认的可编辑入场方式。
- 与 DN-020/021、DN-045/047、DN-009/010、DN-187 的数据边界协调：选区/颜色/字体的 EditorState 更新不代表本机事务已成功落盘；保存状态只以真实持久化完成为准；长期追加仍需明确正式提交；WebDAV 继续手动启动。
- 实施验收（未来执行）：同一选区连续设置字体色→高亮色→加粗→下划线；字体页选择/取消/快速返回；长文滚动不跳；多段选区、跨区块、撤销/重做；一边编辑另一篇笔记时迟到的字体回调不得污染新文档；中文输入候选未提交时切换 Aa；锁定与重新解锁后的选区不能误用；JSON 往返不丢格式。本轮无源码改动、无测试/真机执行，不能标记已实现。

## 13. 用户确认：颜色/字体子菜单返回 Aa，退出 Aa 时恢复键盘（DN-202）

- 用户于 2026-11-15 明确同意：**选中文字→进入 Aa→打开颜色/字体子界面→完成或取消并返回 Aa 菜单，期间不因子界面结束自动弹出系统键盘；用户主动退出 Aa 菜单后，才恢复此前的键盘与编辑上下文**。这样可在 Aa 中对同一有效选区连续设置颜色、高亮、字体、粗斜体及下划线，不需要反复选字，也不在每一层菜单往返时频繁弹键盘。
- 本条正式解决 DN-201 及本文件第十二节中「子界面退出回 Aa 还是正文、是否直接弹键盘」的主要未决事项。历史研究内容保留供审计，最新决定以 DN-202 为准。
- **回到 Aa 与键盘策略**：从 Aa 打开颜色底部面板或字体选择页时，保留当前文档及可恢复的选区上下文；颜色/字体提交完成、取消、系统返回时原则上先回到 Aa；键盘继续隐藏。用户随后主动退出 Aa，才请求恢复打开 Aa 前的键盘显隐状态与安全有效的编辑焦点/选区；此前若键盘并未显示或当前已失去编辑权限，不能无条件强行弹出。
- **安全边界**：如用户在子页期间关闭文档、转去另一篇记录、重新锁定阅读、切换其他路由，或异步回调的原选区/文档身份/修订不再有效，不可回弹到过期 Aa、不可恢复键盘到错误文档、不可将颜色或字体应用到其他记录。尤其遵守 DN-197/198「打开已有记录默认只读，解锁后先不弹键盘、再点正文才输入」。
- **键盘输入完整性**：中文拼音 composing 尚未提交时打开 Aa / 子页，不应因软键盘显示切换重复插字、截断未提交中文、失去有效选区或改变段落。菜单关闭后的软键盘恢复与光标/选区实际位置必须通过目标机型实测，不能仅凭 AppFlowy 源码的调用推断操作成功。
- **保存/撤销边界**：设置颜色/字体产生的富文本事务仍按日记自动正式保存、笔记本机自动保存与异常保护、长期追加草稿/明确提交分别处理，键盘和菜单的关闭/返回本身不得误报「本机已保存」、不得自动触发 WebDAV 或正式提交长期追加草稿。
- **还未确定**：点击 Aa 以外区域关闭、系统返回在不同层级的精细手势与动画、具体色板/字体资源、恢复失败时的提示样式；上述不影响本轮已确认的基本返回顺序与键盘策略。若 AppFlowy 锁定源码/实际 APK 的某个边缘行为不同，须记录差异并以用户确认体验及数据安全原则为准，不能把上游实现当成已经通过 DailyNotes 真机验证。
- **未来验收**：键盘显示→选区→Aa→字体颜色→返回 Aa（键盘仍隐藏）→高亮→返回 Aa（选区仍有效）→粗体→退出 Aa（先前键盘与光标合理恢复）；字体页完成和取消各执行一次；先前键盘本来隐藏的情形不强制拉起；途中点击重新锁定/切换记录不会误弹键盘或错改文档；中文输入法与长文滚动/保存失败场景均验证。
- 本条是第二阶段交互的产品设计定稿，**不代表已编码、编译或完成实机验收**。
