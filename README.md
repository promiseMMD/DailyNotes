# DailyNotes

Android 日记 / 长期记录 / 待办 / 笔记 / 知识库 / 助手项目。

## 当前阶段

本仓库的 `feat/bootstrap-ui-v0` 分支是**界面与构建流程预览**，不是可用于保存个人记录的版本。

- 已接入：四个底栏主页面、第五个上下文新建入口的位置、日记抽屉菜单、笔记/待办双标签、只读数据健康状态占位。
- 未接入：本地持久化、编辑与保存、回收站、真实数据健康检查、WebDAV 同步、附件、加密、AI 服务。
- **不要输入或导入真实日记与重要数据。** 未实现的操作明确提示，不虚构「已保存」「同步成功」「健康正常」。
- 候选图稿尚未最终批准；当前界面只验证结构与导航，非正式 UI 定稿。
- 规范与交接说明见 `docs/`，所有实现须按 DN-ID 溯源。

### 预览构建

具备 Flutter SDK 后：

```sh
flutter create --platforms=android --project-name dailynotes .
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

CI 同样执行以上检查。生成的 debug APK 仅作结构预览，不可视为正式可用版本。
