# DailyNotes handoff and acceptance baseline

**状态：仅结构预览，尚不满足用户真实数据保存需求。**

## 当前权威架构决策（2026-11-15，接手必须优先阅读）

**当前唯一规范基线：** `docs/requirements/DailyNotes开发规范_V2.66.md`（DN-001～DN-192）。历史 V2.51 UI 记录仅供追溯，不是当前完整规范。

**不可偏离的核心边界（DN-187）：**
1. **Android 手机是唯一正式、权威的数据存储中心（Single Source of Truth）。** 日记、笔记、长期记录、追加项、富文本 JSON、revision、删除状态、附件和业务历史均由手机权威数据库管理；手机脱离 PC、LAN、WebDAV 仍可可靠记录。
2. **PC 是局域网远程富文本编辑终端，不是第二套权威数据库。** PC 打开时从手机读取；PC 的正式创建/编辑/删除操作必须传回手机，由手机鉴权、revision/CAS 校验并完成原子持久化。只有手机确认落盘后，PC 才能显示「已保存到手机」。
3. PC 可以有临时编辑缓冲/可恢复浏览器草稿，但手机不可达时必须标记为「仅本浏览器未提交草稿」，不能伪装正式保存；重连后提交须带原 baseRevision，冲突时保留草稿，禁止静默覆盖。
4. **手机与 PC 在线时自动低延迟双向更新**，两端均可发起编辑；「双向」不代表两端拥有独立权威数据库。手机服务后台/息屏可用性仍待实机验证。
5. **坚果云 WebDAV 只由用户主动手动点击触发。** LAN 自动更新、保存、WebSocket、连接/断开、应用启动和后台任务都不得隐式触发 WebDAV；PC 不作为独立 WebDAV 同步节点。
6. DN-187 覆盖 DN-185 的「不指定唯一权威」及 DN-186 中「两端各自独立持久化权威」的解释；DN-183 富文本格式、DN-184 PC Web 入口、DN-185 LAN 私有范围、DN-186 自动 LAN 更新目标继续有效。细节见 `docs/research/DailyNotes_Phone_Authoritative_PC_Remote_Editor_Architecture_R009.md`。

**实现状态：以上是已确认的产品架构，不代表已经实现。**
## 开发投入优先级（2026-11-15，DN-192）

用户明确要求：**把更多开发时间投入功能完整度和实际使用体验，不要让非必要的局域网安全细节持续占用讨论与开发时间。**

1. 手机端核心记录与快速编辑体验：日记、笔记、长期记录、待办、AppFlowy 风格富文本。
2. 手机本机数据可靠性：保存事务、自动保存、崩溃恢复、附件完整性。
3. PC 局域网富文本编辑，以及 PC 与手机唯一权威存储之间的低延迟更新、可靠提交和冲突保护。
4. 用户主动手动触发的坚果云 WebDAV 备份与恢复。
5. 搜索、日历、归档、统计、数据健康等辅助功能。

执行原则：保持 DN-191 最低必要安全边界；只有安全问题实际阻塞功能、数据可靠性或验收时，才做定向研究和最小验证。不再单独反复打磨连接请求 UI、通知视觉、企业级 PKI/设备管理或非阻断安全细节。该优先级不允许跳过必要的数据可靠性与安全验收，也不代表功能已经实现。

---

## 手机 PC 编辑服务运行方式（2026-11-15，DN-188）

用户明确选择：**A——手机前台手动开启 PC 编辑模式，PC 连接后维持会话；允许息屏后继续服务，必要时配置后台运行权限。**

- 手机直接托管 PC 网页、HTTP API、WebSocket；手机仍是唯一权威数据库，PC 不运行第二套正式数据服务。
- 技术优先验证 Android connectedDevice 前台服务类型，不把 dataSync 用于长连接；手动由手机前台用户操作启动，显示持续通知和停止入口。
- 息屏继续服务是目标，不是绝对在线保证。Doze、Low Power Standby、HyperOS 后台网络、电池限制、Wi-Fi/IP 变化、进程被杀和用户停止都可能中断；须自动重连、持久事件补齐，未收到手机落盘确认不得报保存成功。
- 默认不持有整个会话永久 WakeLock；先实测再决定是否需要受控短时锁。HyperOS「无限制」可按需配置，但不等于绕过 Android 系统省电机制。
- Android 13+ FGS 通知、Android 17/API 37 target SDK 37+ ACCESS_LOCAL_NETWORK、HTTPS/WSS 与证书信任、Flutter UI/原生服务共享单一事务仓库，均为后续实现前检查项。
- 完整平台限制和 P0 实机测试见 `docs/research/DailyNotes_Phone_LAN_Foreground_Service_Risk_Research_R010.md`。

**状态：用户已确认运行方式；服务、权限、息屏在线与耗电尚未实现或实测。**
## 历史连接与安全协议研究（2026-11-15，DN-189，首期授权方案已由 DN-191 覆盖）

用户明确选择：**方案 B——PC 手动输入手机当前 Wi-Fi IP 地址**。首期不使用二维码连接、不使用 mDNS/SSDP 自动发现或局域网扫描。以下原配对设计仅作历史记录，当前必须以 DN-191 为准。

- 手机显示当前 Wi-Fi IPv4、候选固定端口 8443 和完整 HTTPS 地址；PC 手动输入 `https://<phone-ip>:8443`。端口仍待 PoC 验证。
- 手机同源托管 HTTPS 页面、REST API 和 WSS；只绑定当前 Wi-Fi 接口，不监听蜂窝/所有接口，不开放公网端口、UPnP、隧道或云中继。
- 历史分层设计为 IP 定位、TLS 身份验证、配对码/设备凭证授权；**配对码和长期设备凭证已被 DN-191 取消**，当前改为每次新建/重建会话由手机人工批准。
- 证书 SAN 必须包含精确匹配当前 IP 的 iPAddress。DN-191 已将首期方向简化为 CA:FALSE 自签名服务器终端证书，不建设私有 CA；Windows/Chrome 仍待 PoC，不得忽略证书警告。
- Windows/Chrome 信任初始化必须验证公开服务器证书 SHA-256 指纹；私钥不离开 Android Keystore。首次信任安装必须用户明确确认。
- Chrome 同源 local→local 请求与 Android 17 ACCESS_LOCAL_NETWORK 是不同权限问题；target SDK 37+ 的 Android 入站 TCP 权限仍须处理，手动输入 IP 不豁免。
- PC 正式写入携带 operationId/baseRevision；手机事务落盘后 ACK；WSS 只作通知，断线按 eventSequence 补齐。所有异常下保留 PC 未提交草稿，手机本地记录继续可用。
- 完整配对、证书、通信和恢复矩阵见 `docs/research/DailyNotes_Manual_IP_Connection_Pairing_TLS_Recovery_Research_R011.md`。

**历史状态：手动 IP 方式已确认；本节原配对/证书方案已由 DN-191 简化并覆盖。**
## 家庭局域网简化安全架构与每次连接手机审批（2026-11-15，DN-191）

用户明确选择：**B——PC 每次新建连接或断线后重新连接，都必须由手机再次人工确认。**

- 首期家庭 LAN 安全边界：手机服务只监听当前 Wi-Fi 局域网接口；不监听蜂窝/所有接口，不开放公网、UPnP、端口转发或云中继。
- TLS 继续使用 HTTPS/WSS；首期目标简化为一张 `CA:FALSE`、`EKU=serverAuth`、`SAN=iPAddress(当前手机 Wi-Fi IPv4)` 的自签名服务器终端证书，私钥留在 Android Keystore；Windows 优先 Current User → Trusted Root Certification Authorities，导入前核对手机显示的 SHA-256 指纹。首期不建设私有 CA、不做动态 CA/叶证书签发。Chrome 157 / Windows 10 兼容性尚待 PoC，不得忽略证书警告。
- 家庭路由器 DHCP reservation 作为减少 IP 变化的可选建议，不强制；IP 变化后若 SAN 不匹配，需要重新生成服务器证书并在 PC 重新信任。
- 取消首期一次性配对码、长期 PC 凭证、可信 PC 列表、「记住 PC」和自动授权。
- 每次新的逻辑编辑/WSS 会话由手机显示客户端 IP、请求时间，用户明确点击「允许本次连接」或「拒绝」。未经批准只能看到无个人数据等待页，不能读取文档/日记/索引/附件或调用业务 API。
- 手机批准后只发放当前会话临时 token；WSS 断开/心跳超时、页面刷新、新标签、新浏览器会话、PC 休眠导致会话失效、网络/IP 变化、手机服务重启等导致重建会话时，旧 token 撤销，重新请求手机批准。
- 同一有效 WSS 会话中的普通 REST 请求及底层 HTTP keep-alive/TCP 连接池变化不重复弹窗。手机息屏/后台时通过通知引导用户手动确认，禁止自动批准。
- PC 断线保留未提交草稿；重新获批后按 baseRevision 提交，operationId 幂等，手机事务落盘后 ACK；WebDAV 仍只由用户手动触发。
- 详细状态机和验收见 `docs/research/DailyNotes_Simplified_PerConnection_Approval_Security_Research_R013.md`。DN-191 取代 DN-189 的配对码/长期 PC 凭证方案和 DN-190 的首期 A/B 证书长期比较方向；R010 的 Android 服务权限、R011/R012 的网络与 Chromium TLS 证据仍供 PoC 使用。

**状态：用户已确认逐次手机审批及首期简化方向；应用实现、证书安装、Windows/Chrome 兼容性、息屏通知和真机测试均未完成。**

---

## 历史 Windows TLS 证书路线比较（2026-11-15，DN-190，首期方向已由 DN-191 覆盖）

历史决策：当时用户选择 C 暂不决定 A/B；随后 DN-191 已将首期方案收敛为单张 CA:FALSE 自签名服务器证书目标路线，不建设私有 CA。该路线仍须 PoC。

- **路线 A（进一步细化）：** 自签名终端服务器证书，`CA:FALSE`、`EKU=serverAuth`、`SAN=iPAddress(当前手机 IP)`。Chromium Windows 当前实现允许 Windows Root store 中的自签名证书作为 trusted leaf；研究导入 Windows 当前用户 `Trusted Root Certification Authorities`。它不是可签发其他证书的 CA，但仍需要一次本地信任安装；IP 改变时需重新导入新证书并移除旧证书。
- **路线 B：** Android Keystore 私有 CA + 动态 IP 叶证书。Windows 信任 CA；手机在 NameConstraints 允许范围内自动签发新叶证书。应先研究将 CA 的 critical IP NameConstraints 限定到当前家庭 LAN CIDR，不默认允许所有 RFC1918；同一子网内 IP 改变无需重新安装根证书，跨子网则需重新签发根证书并重新导入。
- 两条路线都优先验证 Windows Current User Root store，不修改 Local Machine 全机信任；Chromium Windows 对当前用户 Root、自签名 trusted leaf、anchor constraints 的实现细节见 R012。
- Android Keystore 非导出不等于必然硬件保护；需在目标小米设备检查 KeyInfo securityLevel。App 卸载/换机后需考虑密钥身份重建。
- **研究倾向而非决策：** 单手机/单 PC/稳定家庭 LAN 可优先 PoC A；频繁 IP 变化且接受 CA 权限与维护复杂度时再评估 B。
- 详细比较、风险、证书生命周期和 PoC 验收见 `docs/research/DailyNotes_Certificate_Architecture_Comparison_R012.md`。

**历史状态：R012 的 A/B 比较已归档；当前以 DN-191 单张自签名服务器证书为首期 PoC 目标，尚未安装、未实测。**

---


---


---
 当前仍是 UI 结构预览；手机权威数据库、LAN API/WebSocket、PC 编辑端、断线草稿、冲突保护、手动 WebDAV 和端到端验收均未完成。未通过四阶段验收前，不得将真实重要数据交给当前预览 APK。

---

## 依据与已确定范围

- 历史 UI 基线摘录：`docs/requirements/DailyNotes开发规范_V2.51.md`；当前完整规范以 `docs/requirements/DailyNotes开发规范_V2.65.md`（DN-001～DN-191）为准。
- DN-154/155/163：四个底栏主页面及第五个按上下文新建。
- DN-159/165/173/174：抽屉菜单入口、顺序、底部设置、70%–80% 非全屏。
- DN-161/162：日记极简文档时间流；不增加旧的顶部输入卡片。
- DN-164/166–168：四个右上快捷入口（第三项尚未确认）；排序面板从底部展开；两类记录排序互不影响，具体规则未定。
- DN-169/170：当天/分组待办顶部双标签。
- DN-171/172：笔记/知识库顶部双标签、四个常用文件夹位置、最近笔记及主题逐级进入。
- DN-156–158/160：「我的」是独立数据中心；回收站属于「我的」，同步入口属于抽屉。
- DN-175：健康检查 B 概览+C 详情，默认只读，「未检查」不等于「正常」。
- DN-147/148/150/151：业务模块分离，共享版本、附件、回收站、事务化事件队列；后续实现不可绕过这些要求。
- DN-149/152/176/177：四阶段验收；设计候选图稿不得伪装定稿。

## 修改范围与风险

仅新增 Flutter UI 预览、Widget 测试和 CI，没有写入手机个人数据、网络调用或修改既有存储。Flutter 是当前**可替换的 UI 实现尝试**，不表示 Flutter/Rust 分界、SQLite Schema、设备身份、包名、加密或同步细节已经获最终批准。Android 预览项目由 CI 的 `flutter create` 临时生成，不作为稳定签名的正式 APK。

## 没有解决的阻断

- P0：真实本地数据持久化及崩溃恢复未经设计、实现和故障注入验证。
- P0：可恢复备份、增量 WebDAV、设备间修订冲突及 Tombstone 未实现。
- P1：编辑器、回收站、附件、知识主题与 AI 权限未实现。
- P1：8 张候选页面图稿待用户逐图批准；实际截图一致性未验收。
- P1：尚未完成四阶段验收，禁止正式交付或存入真实重要数据。

## 本轮可量化的验收

1. `flutter analyze` 静态检查通过。
2. `flutter test` 验证底栏导航、加号拒绝误报保存、抽屉宽度/健康状态、排序卡片。
3. `flutter build apk --debug` 能生成仅用于结构预览的 APK。
4. Android 真机检查尚未执行，状态必须如实标为未验收。

**本文后续 UI/测试条目是历史阶段记录；与最新 V2.66 规范不一致时，以 V2.66 为准。核心架构决策见本文顶部 DN-187～DN-192。**
