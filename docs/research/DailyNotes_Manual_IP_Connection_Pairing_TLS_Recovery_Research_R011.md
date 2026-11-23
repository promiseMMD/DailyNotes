# DailyNotes 手动 IP 连接、PC 配对、TLS 证书与异常恢复研究 R011

- 日期：2026-11-15
- 规范基线：DailyNotes开发规范 V2.62，DN-001～DN-188。
- 用户明确选择：PC 连接手机采用**方案 B：手动输入 IP 地址**；继续沿用 DN-188 的手机前台手动开启会话、PC 连接后维持、息屏服务为目标。
- DN-187 硬约束继续优先：手机是唯一正式权威数据中心；PC 是局域网远程编辑端；正式写入必须由手机校验并落盘；WebDAV 仅用户主动手动触发。
- 范围：连接协议、配对安全、TLS 证书、Chrome/Windows 信任与异常恢复研究；不编码、不构建 APK、不修改应用代码、不做真实设备验证。

## 一、结论摘要

1. PC 通过手动输入手机当前 Wi-Fi IPv4 地址和固定端口访问手机，例如 `https://192.168.31.24:8443`（示例地址；端口 8443 是候选值，需 PoC 验证占用和兼容）。
2. 第一阶段不使用二维码连接、不使用 mDNS/SSDP 自动发现、不扫描局域网；手机页面显示当前 IP、端口、服务状态和配对码。
3. 手机同源托管 HTTPS 页面、REST API 和 WSS；浏览器页面、API、实时通道使用完全相同的 scheme/host/port，避免跨域与额外代理。
4. IP 只负责定位；TLS 证书负责服务器身份验证和链路加密；一次性配对码负责授权 PC。三者不可混为一谈。
5. TLS 证书必须在 Subject Alternative Name 中使用 iPAddress 类型，精确匹配 PC 地址栏输入的 IP；不得只使用 Common Name，也不得要求用户忽略浏览器证书警告。
6. 长期方向优先 PoC「手机私有 CA + 当前 IP 动态服务器叶证书」；简化备选为「路由器 DHCP 地址保留 + 固定 IP 自签名服务器证书」。二者均未完成 PoC，暂不定最终路线。
7. 同源手机 HTTPS 页面访问同一手机 IP 的 API/WSS 属于 local-to-local；Chrome LNA 的权限检查按 public→local、local→loopback 的地址空间边界执行，通常不会因同源 local→local 请求额外弹出 local-network 权限。若改为公网/其他 origin 页面访问手机局域网服务，则需要重新处理 Chrome LNA。
8. Android 17 / target SDK 37+ 的 ACCESS_LOCAL_NETWORK 是 Android 手机端系统权限；接受入站 TCP 连接也受其约束，手动输入 IP、二维码或关闭 mDNS 都不能绕过。
9. 手机 Wi-Fi/IP 变化、PC 睡眠、前台服务被杀、权限撤销、证书不匹配和配对失效都必须可诊断、可恢复；断线时 PC 保留本地未提交草稿，手机继续独立记录。

## 二、连接地址与网络绑定

### 用户操作

1. 用户在手机 DailyNotes 前台点击「开启 PC 编辑模式」。
2. 手机检查 Wi-Fi 网络、Android 局域网权限、前台服务/通知状态和监听端口。
3. 手机显示当前 Wi-Fi IPv4 地址、固定端口（候选 8443）、完整 HTTPS 地址和会话状态。
4. 用户在 Windows 浏览器手动输入该地址。
5. PC 打开手机托管的同源页面，完成 TLS 验证与配对。
6. IP 变化时手机更新地址并提示；PC 需要手动输入新地址。不后台扫描、不静默自动连接其他网络。

### 监听边界

- 只绑定当前 Wi-Fi 网络接口的有效地址，不默认绑定 `0.0.0.0` 或所有 IPv4/IPv6 接口；不监听蜂窝网络、VPN 或公网接口。
- 第一阶段优先 IPv4；IPv6 地址输入、链路本地作用域 ID 与证书 SAN 兼容留待后续。
- 手机失去 Wi-Fi、网络切换、IP 变化时，停止旧接口监听并关闭/标记旧连接；确认新 Wi-Fi 接口后重新绑定并更新 UI。
- 不配置路由器端口转发、UPnP、云隧道或公网中继。
- PC 可通过 Wi-Fi 或有线 Ethernet 接入同一 LAN；访客网络、AP/client isolation、不同 VLAN/子网或防火墙隔离会阻止设备互访，应给出可理解提示。
- 固定端口 8443 为候选方案；启动时检查占用。若被占用，首期应明确报错或经设计后显示备用端口，不可静默换端口导致用户无法连接。

## 三、通信协议与持久化确认

### 同源协议

- 页面：HTTPS，`https://<phone-ip>:8443/`
- 业务请求：同源 HTTPS REST API，例如 `/api/v1/...`
- 实时更新：同源 WSS，例如 `wss://<phone-ip>:8443/ws`
- 不使用第三方公网页面作为编辑入口；不启用宽泛 CORS（优先完全同源，拒绝不匹配的 Origin/Host）。
- HTTP/WS 不作为正式生产链路；不依赖浏览器「继续访问不安全网站」来获得加密或安全上下文。

### 可靠写入

每次 PC 正式修改携带：
- `operationId`：全局唯一、用于重试幂等；
- `documentId` / 业务 ID；
- `baseRevision`：修改所依据的手机当前版本；
- 文档载荷或操作内容；
- 附件身份/哈希（如适用）。

手机执行鉴权、权限、revision/CAS 检查；在一个可恢复的事务边界中提交正文、业务 revision、必要附件引用和持久化 outbox 事件。**事务真正提交后才返回 durable save acknowledgement**。若响应在网络中丢失，PC 用同一 operationId 重试，手机返回原提交结果而不是重复写入。

WebSocket 消息主要用于低延迟通知；不得把消息送达等同于数据落盘。PC 保存最后确认的 eventSequence；重连后请求从该序号之后的持久化事件补齐，并与手机当前 revision 对账。通知丢失不应造成数据丢失。

## 四、配对与访问控制

### 首次配对候选流程

1. 手机进入 PC 编辑会话后生成一次性随机配对码，暂定 8 位 Crockford Base32（排除易混字符），有效期暂定 2 分钟。
2. PC 手动输入手机 IP 打开 HTTPS 页面，输入配对码。
3. 配对接口只接受 TLS 有效、当前服务会话有效的请求；配对码仅在手机本次会话中有效。
4. 首次配对时，手机显示 PC 配对请求并要求用户确认。
5. 成功后生成至少 256-bit 随机长期设备凭证；手机仅保存安全摘要/必要元数据，PC 通过 Secure、HttpOnly、SameSite=Strict Cookie 保存；每次会话再换发短期 session credential。
6. 手机设置页提供已配对 PC 列表、最后连接时间、撤销入口；撤销后旧凭证立即失效。
7. 配对码失败次数暂定 5 次后短时冷却；具体码长度、时效和限速参数需安全 PoC 验证。

### 安全边界

- TLS 负责服务器身份认证与传输加密；配对码负责授予 PC 应用访问权；IP 地址不是身份凭证。
- 仅允许同源 Host/Origin；拒绝未知 Host、跨站 Origin、任意 CORS、可疑 DNS rebinding 请求。
- Cookie 使用 Secure、HttpOnly、SameSite=Strict；写入接口还需 Origin 检查与 CSRF 防护。
- 对 HTML/富文本内容做严格输出转义与安全清洗，使用严格 Content Security Policy，降低 XSS 窃取会话能力。
- 对配对接口和 API 做速率限制、请求体大小限制、权限检查；不在日志中记录配对码、长期令牌、文档正文和附件内容。
- 会话停止时撤销活动 session token、关闭 WebSocket；是否保留已配对 PC 的长期授权以便下次服务启动后免重复配对，建议保留但可由手机随时撤销。
- 初期是否只允许一台受信任 PC 尚待用户确认；不把浏览器 User-Agent 当作可靠设备身份。

## 五、TLS 证书方案

### 为什么 IP 必须进入 SAN

依据 RFC 9525，若 URL 主机部分是 IP 地址，证书需要在 subjectAltName 中包含精确匹配的 iPAddress 标识；不能依赖 Common Name 或通配符。IP 匹配是地址字节的精确比较。因此 DHCP 地址变化会直接影响证书名称匹配。

### 路线 A：DHCP 地址保留 + 固定自签名服务器证书

- 路由器为手机 Wi-Fi MAC 地址设置 DHCP reservation，确保 IP 稳定。
- 手机为固定 IP 生成一张自签名 TLS 服务器证书，SAN 为该 IP，EKU 包含 serverAuth。
- PC 将该证书作为本地信任锚/受信任证书导入当前用户信任库。
- IP 变化时必须生成新证书并重新信任/导入。
- 优点：实现相对简单，适合首个 TLS PoC。
- 缺点：依赖路由器地址保留；IP 改变后需要 PC 重新安装信任。

### 路线 B：手机私有 CA + 动态 IP 叶证书（长期候选）

- DailyNotes 首次初始化时在 Android Keystore 中生成 CA 私钥；私钥不导出，仅调用 Keystore 签名能力。
- 创建带 CA:TRUE、keyCertSign 等正确扩展的公开根证书；根证书公钥文件可导出到 PC。
- 手机 app 显示根证书 SHA-256 指纹；PC 导入根证书前必须与手机屏幕显示的指纹进行带外核对。可以经 USB/文件传输或先下载公开证书后核对；不允许无核对地从未认证 HTTP 页面直接信任。
- Windows 用户将公开根证书导入 Current User → Trusted Root Certification Authorities。Chrome 证书验证器会考虑 Windows 当前用户信任库中的本地信任决策；需在实际 Chrome 157 / Windows 10 环境验证。
- 手机每次启动服务或 IP 变化时，为当前 IP 签发短期服务器叶证书；叶证书含精确 iPAddress SAN、CA:FALSE、serverAuth EKU、合适 KeyUsage 和有效期。
- IP 变化时只需重新签发叶证书；PC 已信任的根 CA 不需要重新安装。
- 评估 CA NameConstraints 将签发范围限制在私网地址空间；需要验证 Chrome 对本地信任锚约束的处理，不能只写扩展而不做实测。
- 需要 PoC 验证 AndroidKeyStore 非导出私钥能否通过选定 X.509 证书构建库正确签发 CA/叶证书、TLS ServerSocket/Web Server 是否能读取 KeyStore 密钥、证书链是否被 Chrome/Windows 接受。
- 缺点：证书生命周期、CA 密钥轮换、卸载/清数据后的重新注册更复杂；安装根 CA 是高影响信任变更，必须由用户明确确认。

### 不采用的方案

- 不接受用户每次忽略 Chrome 证书错误。
- 不将 CA 私钥或服务器私钥写入仓库、网页资源、普通配置文件或公开日志。
- 不把公钥证书文件和私钥/PFX 混淆。
- 不依赖公网 Let's Encrypt 证书、DNS-01 云账户或公网隧道作为默认架构。
- 不把浏览器 JavaScript 自己实现的证书指纹比较当作 TLS 验证替代品；JS 运行前 TLS 握手已经发生。

## 六、Windows / Chrome 信任初始化

- 当前用户信任库优先于 Local Machine 全局信任库，减少管理员权限和对其他 Windows 用户的影响。
- Windows 可通过 `certmgr.msc` 查看当前用户证书；Chrome 可通过 `chrome://certificate-manager` 查看证书管理信息（Chrome 134+）。
- Chrome Certificate Verifier 官方文档说明：Windows Current User → Trusted Root Certification Authorities 中明确安装的本地信任证书会被考虑；TLS over TCP 也会考虑本地 trust/distrust 决策。
- 导入前检查 Subject、Issuer、SAN、有效期、用途、SHA-256 thumbprint；信任根证书必须由用户明确确认。
- 如果用户删除根 CA、Chrome 企业策略禁用本地信任或证书库策略不允许安装，则显示明确修复说明；不能退回忽略警告。
- 证书私钥永远不从手机导出；PC 只持有公开 CA 证书和浏览器会话凭证。

## 七、Chrome Local Network Access 与 Android Local Network Permission 的区别

### PC Chrome（用户当前浏览器为 Chrome 157）

Chrome LNA 基于 public → local、local → loopback 的地址空间边界。手机托管 HTTPS 页面并同源访问相同手机 IP 的 REST/WSS，属于 local → local，同源路径原则上不跨越地址空间边界，不应额外触发 local-network 权限提示。若将网页改为公网或另一局域网 origin，再请求手机 IP，则会触发 LNA 相关安全检查；浏览器要求发起局域网请求的网页处于 secure context，用户权限请求必须由明确的用户操作触发。

### Android 手机

Android 17（API 37）对 target SDK 37+ 的 app 强制执行 ACCESS_LOCAL_NETWORK；发起或接受局域网 TCP、UDP 流量都在保护范围内。手动输入 IP 不豁免。target SDK 36 及以下的过渡行为不同，不能提前为所有旧 target SDK 请求新权限；应根据实际 target SDK 实现运行时检查和拒绝/撤销处理。

## 八、异常恢复矩阵

| 异常 | 用户可见状态 | 处理策略 |
|---|---|---|
| 手机没有 Wi-Fi | 服务不可用 | 不启动监听，手机本地编辑照常 |
| 手机 IP 改变 | 地址已更新，PC 连接断开 | 手机重新绑定/签发当前 IP 证书；用户手动输入新地址 |
| PC 输入旧 IP | 无法连接 | 提示检查手机当前显示地址 |
| 端口被占用 | 服务启动失败 | 显示端口占用，不静默改变端口 |
| PC 与手机不同网段/访客隔离 | 无法访问 | 提示确认同一可互通 LAN，避免公网暴露 |
| TLS 不受信任 | 浏览器证书错误 | 不允许绕过；检查根证书安装和指纹 |
| 证书 IP SAN 不匹配 | 身份验证失败 | 视为地址过期或潜在冒充，停止连接并重新核验 |
| 证书过期/系统时间异常 | TLS 握手失败 | 检查手机时间，必要时重新签发 |
| 配对码过期 | 配对失败 | 回手机重新生成 |
| 配对码错误过多 | 暂时锁定 | 等待冷却或在手机端重置 |
| PC 凭证被撤销 | 401/重新配对 | 手机端重新授权 |
| PC 浏览器清理 Cookie | 需要重新配对 | 不丢手机正式数据 |
| PC 休眠/浏览器关闭 | PC 离线 | 重新连接后按 eventSequence 补齐 |
| 手机息屏网络挂起 | 重连中 | 手机继续本地保存，PC 草稿保留 |
| 手机前台服务被杀 | 手机服务不可达 | PC 保留草稿；用户重新打开手机 App 并启动服务 |
| Android LAN 权限撤销 | 手机拒绝 LAN 服务 | 解释并重新请求权限，拒绝时仍可本机使用 |
| App 卸载/清数据/换机 | CA/设备身份可能丢失 | 重新生成身份，撤销 PC 旧根证书并重新信任/配对 |

## 九、建议的端到端验收顺序

1. **网络 PoC：** 手机监听当前 Wi-Fi IPv4 的候选固定端口；Windows 手动输入 IP 访问；验证有线 PC、Wi-Fi PC、不同子网和访客隔离。
2. **TLS PoC：** 先做路线 A 固定 IP 自签名证书；再验证路线 B AndroidKeyStore 私有 CA + 动态 IP SAN 叶证书；记录 Chrome 157 的实际证书链结果。
3. **配对 PoC：** 错误码、过期、重放、暴力尝试、未经手机批准、撤销、浏览器 Cookie 丢失。
4. **服务与恢复 PoC：** 手机息屏、Wi-Fi 断开/切换、IP 改变、PC 睡眠、进程被杀、用户停止服务。
5. **数据端到端验收：** PC 提交文档变更，手机事务提交后确认；模拟响应丢失并使用 operationId 重试；WebSocket 通知丢失后用 eventSequence 补齐；确认 WebDAV 不会被 LAN 事件触发。

所有测试均要保留日志与证据；没有实机执行的项目不能标记通过。

## 十、待用户后续决定与技术 PoC

- 证书路线最终选择：A 固定 DHCP 地址自签名证书，还是 B 私有 CA + 动态叶证书。
- 是否接受首次在 Windows 当前用户信任库中安装 DailyNotes 私有根 CA。
- 首期授权 PC 数量：仅一台，还是允许多个可信 PC。
- 首次配对是否每次都要求手机点击批准；建议只首次批准，之后凭证可复用。
- 端口 8443 是否最终固定；仍需冲突与设备兼容验证。
- AndroidKeyStore CA 证书签发和证书 NameConstraints 的真实 PoC。
- 手机卸载/清数据后 CA 身份恢复策略。
- TLS 信任初始化是否提供 USB/文件导入、HTTP 下载后指纹核对等方式。

**本报告结论：** 采用手动 IP 输入、同源 HTTPS/WSS、一次性配对码、可撤销设备凭证和持久化事件补齐。证书长期路线倾向私有 CA + 动态叶证书，但路线 A 作为简单 PoC 备选。当前均是研究与候选方案，不代表实现已完成或安全测试已通过。

## 十一、公开技术来源

- Chrome Local Network Access：https://developer.chrome.com/docs/modern-web-guidance/guides/security/local-network-access
- Chrome Local Network Access permission announcement：https://developer.chrome.com/blog/local-network-access
- Android Local Network Permission：https://developer.android.com/privacy-and-security/local-network-permission
- Android foreground service types：https://developer.android.com/develop/background-work/services/fgs/service-types
- Android Keystore：https://developer.android.com/privacy-and-security/keystore
- Android KeyChain：https://developer.android.com/reference/android/security/KeyChain
- Chrome Root Store FAQ：https://chromium.googlesource.com/chromium/src/net/+/HEAD/data/ssl/chrome_root_store/faq.md
- Windows Current User / Local Machine certificate stores：https://learn.microsoft.com/en-us/windows-hardware/drivers/install/local-machine-and-current-user-certificate-stores
- RFC 9525 Service Identity in TLS：https://www.rfc-editor.org/rfc/rfc9525.html
