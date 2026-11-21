# DailyNotes 简化安全架构：每次连接由手机确认 R013

- 日期：2026-11-15
- 规范基线：DailyNotes开发规范 V2.64，DN-001～DN-190。
- 用户明确选择：手机连接确认方案 B——**每次 PC 新建连接/重新连接都必须由手机端再次确认**。
- 用户场景：个人使用，家庭 Wi-Fi 局域网；手机为唯一权威数据存储；PC 手动输入手机 IP；手机前台手动开启 PC 编辑模式；不开放公网。
- 范围：简化 PC 访问授权机制、定义连接状态机、明确 TLS 和手机人工确认的分工、异常恢复与验收要求。不编码、不修改应用、不安装证书、不构建 APK、不做真机/Windows PoC。
- 本报告取代 R011 中「配对码 + 长期 PC 设备凭证」作为首期应用层授权方案；R011/R012 关于 IP SAN、TLS 传输、Windows 信任库、Chrome、Android Keystore 的技术研究仍作为证书 PoC 参考。

## 一、最终收敛结论

首期家庭局域网安全模型采用三层：
1. **网络边界：** 手机服务只绑定当前 Wi-Fi 局域网接口，不监听蜂窝网络/所有接口，不开放公网、端口转发、UPnP、云隧道或中继。
2. **TLS：** 采用单张 `CA:FALSE` 自签名服务器终端证书，`EKU=serverAuth`，`SAN=iPAddress` 精确匹配当前手机 Wi-Fi IPv4；私钥保存在 Android Keystore。Windows 优先导入当前用户 Trusted Root Certification Authorities，证书指纹必须通过手机端带外显示核对。首期不建设私有 CA、不做动态 CA 签发；Chrome/Windows 兼容性仍须 PoC 验证，禁止忽略证书错误。
3. **每次手机人工授权：** 每次 PC 新建编辑连接，或连接中断后重新建立编辑连接，都必须由手机用户明确点击「允许」。每次批准只授权当前会话；断线、会话失效、手机停止服务后立即撤销，不记住 PC，不保存长期 PC 凭证，不使用配对码。

**定义边界：**「每次重新连接」指 PC 编辑器逻辑会话/实时 WSS 会话从 disconnected 状态重新建立，不指每一条 HTTP API 请求，也不指同一有效 WSS 会话期间底层 HTTP keep-alive/TCP 连接池正常重建。否则会把正常业务请求误变成反复弹窗。WSS 断开或心跳超时、页面刷新/新建会话、PC 睡眠后会话失效、网络切换后会话重建、手机服务重启，都视为新连接，必须重新请求手机批准。

## 二、连接与授权状态机

### 状态

- `service_off`：手机未开启 PC 编辑模式。
- `service_ready`：手机服务已启动，等待 PC 请求；无 PC 数据访问授权。
- `tls_connected_unapproved`：PC TLS 连接有效，只允许取得静态登录/等待页面，不允许读取任何个人笔记、日记、附件、索引或调用写入 API。
- `approval_pending`：手机收到连接请求，向用户展示来源 IP、请求时间及允许/拒绝操作。
- `session_active`：用户批准后，手机签发本次会话临时 token；PC 才可读取/修改授权范围内数据。
- `session_disconnected`：WSS 关闭或心跳超时；撤销本次 token，所有数据 API 立即拒绝。
- `service_stopped`：用户停止 PC 编辑模式，关闭监听并撤销全部活动会话。

### 正常流程

1. 用户在手机前台手动开启 PC 编辑模式。
2. 手机显示当前 Wi-Fi IPv4 和候选端口；HTTPS 服务开始监听当前 Wi-Fi 接口。
3. 用户在 Windows 浏览器手动输入手机显示的 IP 地址。
4. 浏览器完成 TLS 验证；只加载不包含用户数据的等待/连接页面。
5. PC 发送新的编辑会话请求；手机显示「PC 连接请求」，至少显示客户端 IP 和请求时间，明确提供「允许本次连接」「拒绝」。
6. 用户点击允许后，手机为当前会话生成高熵、短期、不可复用的随机 session token；服务端只保存 token 摘要及会话状态，浏览器通过 Secure、HttpOnly、SameSite=Strict 的会话 Cookie 使用；不得设置长期 Max-Age，不写入 localStorage/IndexedDB。
7. 仅当前有效会话可以访问个人数据 API 和 WSS；其他来源即使知道 IP 也只能看到无个人数据的等待页/被拒绝响应。
8. 用户拒绝、审批超时、WSS 断开/心跳超时或手机停止服务时，token 立即撤销，数据 API 拒绝后续请求。

### 重连规则（用户明确选择 B）

以下任一情况后恢复 PC 编辑访问，都必须再次由手机点击允许：
- PC 浏览器页面刷新，重新发起编辑连接；
- PC 关闭浏览器/标签页后重新打开；
- PC 休眠导致 WSS 断开并被服务端判定会话失效；
- Wi-Fi 断开、漫游、IP 改变或网络切换导致实时会话断开；
- 手机服务/应用进程重启后重新建立会话；
- WSS 断开后重新握手；
- 之前会话被手机主动终止或撤销；
- 任何新 PC、浏览器配置文件或新的编辑会话。

以下情况不额外弹窗：
- 同一有效编辑会话内的普通 REST API 请求；
- 同一有效 WSS 会话期间，浏览器正常建立/关闭底层 HTTP keep-alive 或 TCP 连接池；
- 同一会话中的普通文档读取、保存、附件请求。

WSS 一旦被确认断开或心跳超时，旧会话必须撤销；不能为了避免弹窗而在断线后继续保留数据 API 访问权限。心跳间隔、断线判定宽限时间和审批等待超时需在 PoC 中确定，不能在无实测情况下固定为某个数字。

## 三、手机确认界面要求

- 手机处于前台时，在 PC 编辑模式页面显示连接请求卡片。
- 手机息屏/应用后台时，使用前台服务已有持续通知引导用户返回 DailyNotes；可以另发连接请求通知，但不能未经用户操作自动打开全屏界面或自动批准。
- 确认内容至少包括客户端 IP、请求到达时间、请求状态；不将 User-Agent 当作可靠设备身份。
- 两个明确操作：「允许本次连接」「拒绝」；不提供「记住这台 PC」「以后自动允许」。
- 未批准时不返回任何个人数据，不允许枚举文档、索引、附件、缩略图或统计。
- 审批超时、拒绝、请求被撤销时，PC 显示等待超时/被拒绝，并可由用户在 PC 再次发起请求；再次请求仍需手机批准。
- 多个请求同时到达时需限流并清楚显示排队状态；首期是否只允许一个活动 PC 会话待后续讨论。
- 不要求手机端每条 API 操作都确认；手机确认的是本次 PC 编辑会话。

## 四、首期 TLS 简化方案

### 采用单张自签名服务器终端证书作为首期目标

- 不建设私有 CA、不签发证书链、不实现动态 CA/叶证书管理。
- X.509 服务器证书必须为 CA:FALSE、EKU=serverAuth、SAN 中包含精确匹配当前 Wi-Fi IP 的 iPAddress；KeyUsage 按选定 TLS 算法正确设置。
- 服务器私钥由 Android Keystore 生成并保存，不导出到普通文件、PC、仓库或日志。
- Windows 首选 Current User → Trusted Root Certification Authorities；导入前由手机显示 SHA-256 指纹，用户核对后明确安装。
- 选择家庭路由器 DHCP reservation 作为减少 IP 变化的可选建议；不要求用户必须修改路由器，也不在 Android 中盲设静态 IP。
- 若 IP 改变导致 SAN 不匹配，手机需生成匹配新 IP 的服务器证书；Windows 端需按明确流程导入新证书、移除旧证书并核对指纹。
- 不允许忽略浏览器证书错误，不回退到明文 HTTP/WS。
- Chrome Windows 对 Windows Root store 自签名 CA:FALSE trusted leaf 的支持来自 Chromium 源码研究 R012，但尚未在用户的 Windows 10 + Chrome 157 实测；必须先 PoC 再作为实现验收项。
- Android Keystore 私钥是否由 TEE/StrongBox 保护，需读取目标设备 securityLevel；不可导出不等于一定硬件保护。

## 五、取消的首期复杂机制

以下机制从首期应用层授权范围中删除：
- 一次性配对码；
- 长期 PC 设备凭证；
- 已配对/可信 PC 设备列表；
- 记住 PC、自动信任或免确认重连；
- 私有 CA、根 CA 生命周期和动态叶证书签发；
- mDNS/SSDP 自动发现、二维码连接、局域网全网扫描；
- 公网中继或云端身份服务。

注意：取消长期 PC 凭证不等于没有会话认证。每次手机批准后仍发放一个只对当前会话有效的临时 token；它断线即撤销，不能用于下次重连。

## 六、数据可靠性与异常恢复

- PC 断线时保留浏览器未提交草稿，清楚显示「PC 本地未提交」。
- 手机本地记录不依赖 PC 会话，服务关闭/拒绝连接不影响手机记录。
- 重新获批后，PC 按原 baseRevision 提交；若手机版本已前进，进入冲突保留流程，不静默覆盖。
- 每个正式写入携带 operationId，手机事务提交后才返回 durable ACK；ACK 丢失使用同一 operationId 幂等重试。
- WSS 只承担实时通知；断线后按 eventSequence 补齐。
- 用户停止手机 PC 编辑模式时撤销所有活动 session token、关闭 WSS 和数据 API、停止监听。
- 连接授权、自动重连、断线恢复均不得触发坚果云 WebDAV；WebDAV 仍由用户手动点击。
- 手机拒绝/不响应/息屏未确认时，PC 不得访问任何个人数据。
- LAN 请求需限速；同一来源短时间重复请求应合并/冷却，避免手机通知轰炸。限速阈值和审批超时留待 PoC。

## 七、影响分析

| 模块 | 影响 |
|---|---|
| 手机 PC 编辑模式 | 新增每次连接的明确审批 UI/通知 |
| HTTPS/TLS | 保留，采用单张自签名服务器证书目标路线 |
| REST API | 每个请求必须带当前会话 token；未经批准拒绝 |
| WebSocket | 新建/重建 WSS 会话都必须重新审批 |
| PC 编辑器 | 断线后保留草稿，显示待手机批准 |
| 手机本地编辑 | 不受影响 |
| 多 PC | 每个新会话分别批准；并发策略待讨论 |
| WebDAV | 不变，始终手动触发 |
| 电池/息屏 | 用户可能需要唤醒手机处理连接请求；不能自动批准 |

## 八、PoC / 验收矩阵

1. 未批准连接只能看到等待页面，不能读取任何个人数据/API/附件。
2. 手机批准后当前会话可正常读写。
3. 手机拒绝或审批超时后无数据访问。
4. 浏览器刷新后重新请求，必须再次手机批准。
5. WSS 断开后旧 token 被撤销，重新握手必须再次手机批准。
6. PC 休眠、Wi-Fi 切换、IP 改变后重新连接，必须手机批准。
7. 普通 REST API 请求和同一有效 WSS 会话期间的 HTTP keep-alive 变化不会反复弹窗。
8. 手机停止 PC 编辑模式，所有活动会话立即失效。
9. 手机息屏/后台时，不会自动批准；用户能通过通知返回确认。
10. 未提交草稿不丢失；重连获批后 revision 冲突能被保留。
11. HTTPS 证书验证失败时必须阻止访问，不能忽略警告。
12. WebDAV 不因任何 LAN 事件自动运行。

## 九、后续待讨论/待实测

- Windows 10 + Chrome 157 是否接受 CA:FALSE 自签名终端证书导入 Current User Root。
- 小米目标设备 Android Keystore 与 TLS server 的实际集成。
- DHCP reservation 是否作为用户建议而非强制要求。
- 连接审批超时、WSS 心跳和断线判定宽限时间。
- 手机息屏时通知如何呈现连接请求，用户点击后如何进入审批页面。
- 首期是否只允许一个活动 PC 会话。
- Android 17 target SDK 37+ ACCESS_LOCAL_NETWORK 权限及前台服务类型仍须遵循 R010 研究。
- TLS 证书指纹首次核验和 IP 变化后的重新信任流程。

## 十、版本与来源说明

- R011：手动 IP、TLS、配对、持久化通信与异常恢复的广泛研究。其配对码/长期 PC 凭证方案被本报告取代；TLS、SAN、网络边界和事件补齐研究仍有效。
- R012：Windows 自签名 trusted leaf 与私有 CA 的比较。本报告首期不采用私有 CA，优先验证 CA:FALSE 自签名服务器证书；R012 证据仍作为 PoC 依据。
- R010：Android 前台服务、息屏、Doze、局域网权限研究，继续有效。
- 本报告记录产品决策和待验证设计，不代表任何代码、证书、权限、连接或真机验收已经完成。

## 十一、公开技术依据

- Chromium Windows trust store implementation: https://chromium.googlesource.com/chromium/src/+/main/net/cert/internal/trust_store_win.cc
- Chrome Root Store FAQ: https://chromium.googlesource.com/chromium/src/net/+/HEAD/data/ssl/chrome_root_store/faq.md
- Android Keystore: https://developer.android.com/privacy-and-security/keystore
- Android Local Network Permission: https://developer.android.com/privacy-and-security/local-network-permission
- RFC 9525: https://www.rfc-editor.org/rfc/rfc9525.html
- RFC 5280: https://www.rfc-editor.org/rfc/rfc5280.html
