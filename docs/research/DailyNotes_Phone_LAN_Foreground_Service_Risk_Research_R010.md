# DailyNotes 手机按需前台服务与息屏 LAN 会话技术研究 R010

- 日期：2026-11-15
- 基线：DailyNotes开发规范 V2.61，DN-001～DN-187；本轮新增用户确认 DN-188。
- 用户明确选择：A「手动开启编辑模式，PC 连接后维持会话」；息屏要求「允许息屏继续服务，必要时配置后台运行权限」。
- 核心边界继承 DN-187：Android 手机是唯一正式权威存储；PC 是 LAN 远程富文本编辑端；PC 正式修改由手机校验并落盘；WebDAV 只由用户主动手动点击触发。
- 范围：架构与平台限制研究；没有修改 Dart/Kotlin/AndroidManifest/Flutter/Web 应用代码，没有构建 APK、没有设备实测。

## 一、推荐运行模型

手机直接承载 LAN 服务。PC 不运行第二套服务器，也不持有第二份权威数据库。手机端将网页静态资源、HTTP API 与 WebSocket 事件端点作为同一局域网服务对 PC 提供；浏览器访问同一来源可减少跨域配置和额外的中间层。

1. 用户打开 DailyNotes，在前台主动点击「开启 PC 编辑模式」。
2. 应用先检查 Wi-Fi/LAN 状态、局域网权限、通知权限与会话状态。
3. 手机启动 Android 前台服务，建立本次会话 ID、局域网监听地址与限时配对信息。
4. 手机显示可复制 URL/二维码和短时一次性配对码；PC 浏览器连接、完成配对后获得仅限本次会话的访问令牌。
5. 会话期间手机提供网页、HTTP API、WebSocket；所有正式写入仍通过手机唯一权威数据仓库执行事务、Revision/CAS 和持久化事件。
6. 屏幕关闭后继续尝试维持会话，但不得宣称 Android/HyperOS 保证永久联网；网络挂起时 PC 显示手机暂不可达，手机本地保存继续可用，恢复后重连和补齐。
7. 用户主动停止会话时，先停止接受新写入、完成或中止在途事务、撤销配对令牌、关闭 socket、释放资源并停止前台服务。

## 二、Android 前台服务技术判断

### 推荐优先验证 connectedDevice，而不是 dataSync
Android 官方 foreground service type 文档把通过本地网络与外部设备交互列为 connectedDevice 的适用场景。其 Manifest 需要声明 FOREGROUND_SERVICE_CONNECTED_DEVICE，并满足官方列出的至少一项前置条件（例如 CHANGE_NETWORK_STATE、CHANGE_WIFI_STATE、CHANGE_WIFI_MULTICAST_STATE，或相应蓝牙/UWB/USB 条件）；不能误以为仅有 INTERNET 权限就自动满足 connectedDevice 的运行前置条件。最终选取哪项权限须与真实网络实现相匹配，不得为了过审无理由扩大权限。
Android 15+ 对 dataSync 和 mediaProcessing 前台服务分别设有每日累计 6 小时的后台运行时间限制；本项目是用户主动维持的本地设备连接会话，不应误用 dataSync 作为长连接服务类型。connectedDevice 更符合语义，但不代表没有 Doze、Low Power Standby、厂商后台管理或用户停止等其他限制。
服务应由用户可见的 Activity 点击启动，启动后及时提升为 foreground service 并发布持续通知；Android 12+ 限制后台随意启动 FGS，不能让 PC 在手机未开启会话时从网络侧偷偷唤醒服务。
Android 13+ POST_NOTIFICATIONS 并非启动 FGS 的绝对前置条件，但用户拒绝后，前台服务通知可能不出现在普通通知抽屉中；为了让用户清楚知道 PC 编辑会话正在运行并能停止服务，建议在首次开启前解释并请求通知权限。拒绝后的产品行为和是否阻止启动仍待确认。
Android Task Manager 的用户 Stop 会直接停止整个应用进程，且系统不保证回调；Force Stop、系统回收、重启也不能当作可靠自动恢复事件。PC 必须将连接丢失视为服务不可用，不能继续显示手机已保存。按需手动模式下，服务被用户终止后应由用户重新打开 App 并重新启动会话，不承诺 PC 自动唤醒手机服务。

## 三、息屏、Doze、WakeLock 与 HyperOS 风险

1. Android Doze/Low Power Standby 可能限制非交互设备的网络；官方 PowerManager 说明 Low Power Standby 开启时，非交互且不在维护窗口期间，即使前台服务运行，应用网络访问也可能被禁用，所持 WakeLock 也可能被忽略。因此「前台服务 + 永久 WakeLock」不能作为绝对在线保证。
2. Android 官方建议优先使用最轻量的保持唤醒方式；Partial WakeLock 会阻止 CPU 进入更低功耗状态，长期持有可能显著耗电。默认不持有整个会话期间的永久 WakeLock；先实测，再决定是否仅在处理在途请求/短时提交时使用有超时且必释放的 WakeLock。
3. 小米官方支持资料说明其电池保护可能在锁屏/后台时限制应用网络访问，并建议对需要持续后台网络的应用设置 Battery > No restrictions。此资料为小米通用支持说明，不是对用户 Xiaomi 14 Pro / HyperOS 3 当前设置路径的实机确认。未来应先核对实际系统版本和菜单路径，再由用户明确配置。
4. Background autostart 不应成为本方案的默认前置：用户主动在前台开启会话，且不要求开机自启。只有若后续决定进程异常后自动恢复，才重新评估自启动/恢复权限；当前不应让服务在手机重启后静默自动运行。
5. 即使配置 No restrictions，也不能绕过 Android 系统级 Doze/Low Power Standby；服务必须有心跳超时、断线状态、指数退避重连、事件序号补齐与手机本地保存兜底。

## 四、局域网连接、浏览器与安全

- 第一阶段优先用手机显示的 IP:port URL/二维码直接配对，先不强制实现 mDNS/全网扫描；这能减少服务发现复杂度，但 Android 17 的 Local Network Permission 对入站 TCP 仍然适用。
- Android 官方 Local Network Permission 文档：Android 16 是 opt-in 过渡；从 Android 17 / API 37 且 target SDK 37+ 开始，局域网 TCP/UDP/mDNS 等访问默认需要 ACCESS_LOCAL_NETWORK 运行时权限。即便用户用二维码直接输入 IP，也不免除实际 TCP 网络访问权限。DailyNotes 需按 target SDK 条件处理权限声明、解释、请求、拒绝和撤销。
- 网页静态资源、HTTP API 和 WebSocket 尽量同源托管在手机上，避免 CORS 和不同来源 Cookie/Token 管理。
- 不应默认用明文 HTTP/WS 承载私人日记。浏览器的 Web Crypto、异步剪贴板等 API 需要 secure context；通过普通局域网 IP 的 HTTP 地址通常不是安全上下文。优先研究 HTTPS/WSS 与证书信任方案（稳定主机名/证书 SAN/Windows 证书信任），不能仅以「在家 Wi-Fi」作为安全保证。自签名证书、首次信任和 IP 变化是必须解决的部署问题。
- 配对应采用一次性短时码/二维码、短期 session token、单 PC 会话上限、主动撤销、Origin/Host 校验、CSRF 防护、请求大小限制与速率限制。会话结束后令牌立即失效。
- 监听仅限当前 Wi-Fi/LAN 接口；不得无意监听蜂窝网络/所有可达接口，不做公网端口映射、UPnP 或云端隧道。路由器客户端隔离、访客网络、手机/PC 不在同一子网等情况需提示连接失败。
- 手机 IP 可能因 DHCP/漫游变化；监听地址和二维码应随网络变化更新，连接断开后重新发现/配对或安全恢复。服务发现技术最终待讨论。

## 五、Flutter + Android 原生服务的数据边界

当前 DailyNotes 是 Flutter UI-only 预览，尚无真实持久化数据库。未来 Android 前台服务的生命周期应由 Android 原生 Service 承载，不能依赖 Flutter Activity 始终在前台。无论 HTTP/WebSocket 服务最终采用 Kotlin 还是后台 FlutterEngine/Dart isolate，都必须调用同一个手机权威数据仓库/事务入口：
- 手机 Flutter UI 和 PC API 不得各自打开一套业务语义不同的数据库。
- 所有写入按一个可审计的串行事务入口或等价并发控制提交；保证正文、revision、附件引用与持久化 outbox 的事务边界。
- 如果采用后台 FlutterEngine/Dart isolate，必须专门验证插件注册、Engine 生命周期、数据库多 isolate 连接、进程重建和消息桥接；不能假定 UI isolate 会随 Activity detach 自动持续运行。
- 如果采用 Kotlin HTTP 服务，须定义其访问 Dart/SQLite 仓库的稳定桥接；不能绕过业务层直接写 SQLite。
- 技术 PoC 应先证明「屏幕关闭 + PC 发起编辑 + 手机数据库原子提交 + PC 收到持久化回执」，再选最终技术栈。

## 六、服务会话状态建议

STOPPED → STARTING → WAITING_FOR_PC → PAIRED/CONNECTED → SCREEN_OFF_CONNECTED（逻辑状态，不保证底层网络一直可用）→ NETWORK_SUSPENDED/RECONNECTING → CONNECTED；用户停止后 → STOPPING → STOPPED。
服务异常死亡、系统 Task Manager Stop、权限撤销、Wi-Fi 断开、手机 IP 改变、PC 休眠均应转为明确的 DISCONNECTED/UNAVAILABLE 状态；PC 未获手机事务回执时必须保留未提交草稿。
本次是否设「长时间无 PC 连接自动停止」尚未决定，不擅自加入超时关闭。

## 七、风险与验收矩阵（全部待实机执行）

| 风险 | 可能后果 | 处理/验收 |
|---|---|---|
| Doze / Low Power Standby | 屏幕关闭后网络暂停 | 断线识别、重连、补齐；测试设备真实策略 |
| HyperOS 后台网络限制 | WebSocket 被挂起/断开 | 核对实际 No restrictions 配置并测量 |
| 长时间 WakeLock | 电量消耗、发热 | 默认不用永久锁，记录锁持有时间和每小时耗电 |
| FGS 类型/权限不匹配 | 启动 SecurityException | 按目标 SDK、connectedDevice 前置条件和 Logcat 验证 |
| 通知权限拒绝 | 用户看不到服务状态 | 首次启动前解释；测试允许/拒绝两条路径 |
| Android 17 LAN 权限拒绝 | TCP 入站被系统阻断 | ACCESS_LOCAL_NETWORK 权限请求/撤销测试 |
| 进程被杀/Task Manager Stop | PC 会话突然断开 | 显示不可达，手机本地仍可保存；用户重新开启 |
| Wi-Fi 漫游/DHCP 变更 | IP 和 socket 失效 | NetworkCallback、监听地址更新、重连 |
| 访客网络/客户端隔离 | PC 无法访问手机 | 明确提示同 LAN/允许客户端互通 |
| 明文 LAN/伪造 PC | 日记泄露或被篡改 | HTTPS/WSS、配对、短期令牌、Origin/CSRF |
| 证书不受信任 | 浏览器安全 API 不可用/警告 | Windows 证书信任和稳定地址验证 |
| Flutter Engine/DB 并发 | 后台服务与 UI 写入竞争 | 单一仓库入口、原子事务和并发测试 |

P0 真机测试建议：Xiaomi 14 Pro 当前实际 Android/HyperOS 构建信息先登记；Wi-Fi 下手动开启服务，PC 配对，手机锁屏且不充电连续 60 分钟；执行 PC 写入、手机本地写入、图片上传、重连与版本冲突测试；记录消息到达、手机落盘、PC 确认的 p50/p95/p99，以及每小时耗电、温升、断线次数。随后分别测试省电模式、No restrictions、Low Power Standby、Wi-Fi 重连、进程被系统/用户终止、通知权限和 Local Network 权限拒绝。未通过不得宣称息屏持续在线。

## 八、结论与待定项

**用户已确认：** 手动开启编辑模式；PC 连接后维持会话；息屏期间允许并希望服务继续运行；必要时可以配置后台运行权限。

**本轮技术推荐：** 手机托管网页 + API + WebSocket；用户手动启动 Android connectedDevice 前台服务；常驻通知；不使用 dataSync 长连接；默认不持有永久 WakeLock；HyperOS 按需配置 No restrictions；自动重连和持久事件补齐；WebDAV 仍只由用户手动触发。

**仍待技术 PoC/用户后续讨论：** connectedDevice 前置权限的最终选取；Kotlin 服务与 FlutterEngine/Dart isolate 的桥接方式；TLS/证书/稳定主机名；二维码配对细节；通知权限拒绝时策略；是否需要短时 WakeLock；空闲会话是否自动关闭；实测息屏连续在线时长和耗电阈值。

## 九、公开技术来源

- Android foreground service types / connectedDevice：https://developer.android.com/develop/background-work/services/fgs/service-types
- Android data transfer to local devices：https://developer.android.com/develop/background-work/background-tasks/data-transfer-options
- Android 15 foreground service timeout：https://developer.android.com/develop/background-work/services/fgs/timeout
- Android FGS background start restrictions：https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- Android notification permission：https://developer.android.com/develop/ui/compose/notifications/notification-permission
- Android Doze/App Standby：https://developer.android.com/training/monitoring-device-state/doze-standby
- Android WakeLock guidance：https://developer.android.com/develop/background-work/background-tasks/awake
- Android Local Network Permission (Android 17)：https://developer.android.com/privacy-and-security/local-network-permission
- Xiaomi background battery protection：https://www.mi.com/global/support/faq/details/KA-538010/
- MDN Secure Contexts：https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Secure_Contexts
- MDN Web Crypto secure context：https://developer.mozilla.org/en-US/docs/Web/API/Web_Crypto_API
- MDN WebSocket secure transport：https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_client_applications

本报告只归档用户选择和技术研究；没有修改应用代码，没有 APK/CI/设备实测，不得将候选方案描述为已经实现。
