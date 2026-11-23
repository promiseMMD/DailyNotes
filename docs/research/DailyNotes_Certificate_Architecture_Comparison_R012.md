# DailyNotes Windows TLS 证书策略比较与风险深化 R012

- 日期：2026-11-15
- 规范基线：DailyNotes开发规范 V2.63，DN-001～DN-189。
- 用户决定：证书策略选择 C——暂不决定，继续比较两种方案；没有授权实施或最终选型。
- 连接方式继承 DN-189：PC 手动输入手机当前 Wi-Fi IPv4；手机同源 HTTPS 页面、REST API、WSS；手机是唯一权威数据存储。
- 本轮范围：比较 Windows 信任安装范围、Chrome 157 行为、证书权限边界、Android Keystore、IP/网络变化、撤销与恢复。没有编码、没有构建 APK、没有修改应用代码、没有在真实 Windows 10 / 小米设备上安装证书或进行 PoC。
- 本报告对 R011 做一项重要技术细化：路线 A 可以研究「CA:FALSE 的自签名服务器终端证书作为直接可信叶证书」，不应把它误写成必须创建一个可签发其他证书的 CA。

## 一、结论摘要

1. **A、B 都需要在 Windows 建立一次明确的本地信任。** 如果坚持 PC 直接输入 IP 并使用 Chrome 原生 HTTPS，不能依赖忽略证书警告。区别不是“是否安装证书”，而是“安装并信任一张绑定单个 IP 的自签名服务器证书”，还是“安装并信任一个能够签发多张服务器证书的 CA”。
2. 发现 Chromium Windows 当前实现：放入 Windows Root store 的证书可作为 trust anchor，或在证书自签名时作为 trusted leaf；对 Root store 的信任对象使用 `ForTrustAnchorOrLeaf`、`WithEnforceAnchorExpiry`、`WithEnforceAnchorConstraints`、`WithRequireLeafSelfSigned`。因此，路线 A 可以 PoC 一张 `CA:FALSE`、`EKU=serverAuth`、`SAN=iPAddress(当前手机 IP)` 的自签名终端证书，导入 Windows 当前用户 Root store，由 Chrome 将其作为该服务器的可信叶证书。该行为必须在用户的 Windows 10 + Chrome 157 上端到端验证。
3. Chromium Windows 实现对 Current User 的 Root store 有明确支持；Current User 的 Trusted People 并未列为可信终端证书来源，Trusted People 相关路径主要读取 Local Machine。为了避免机器级修改和管理员权限，PoC 应优先验证 `certmgr.msc` → Current User → Trusted Root Certification Authorities，而不是 `certlm.msc` / Local Machine。
4. 路线 A 的安全优势：信任对象是单张自签名服务器证书；证书明确 `CA:FALSE`，不能作为 CA 签发其他证书；SAN 精确绑定一个 IP，EKU 限定 serverAuth。IP 变化需要重新生成、重新导入并移除旧证书；路由器 DHCP reservation 可显著减少换证频率。
5. 路线 B 的便利优势：PC 只需信任 CA 一次；手机可为当前 IP 自动签发新的叶证书。其代价是 Windows 信任一个 CA，而非一张叶证书；CA 私钥若被滥用，可为其允许的名称范围签发多张证书。
6. 路线 B 应研究在 CA 根证书上设置 critical IP NameConstraints，将允许范围收窄到当前家庭 LAN CIDR（例如 `192.168.31.0/24` 仅为格式示例，不代表用户真实网络）。Chromium 自 Chrome 112 起强制执行平台信任锚上的 X.509 constraints；相关临时策略在 Chrome 126 移除，当前 Chrome 157 不应假设可以关闭此约束。Chromium Windows 源码也显式使用 `WithEnforceAnchorConstraints()`。
7. 根证书 NameConstraints 若限定当前 LAN 子网，则 IP 在该子网内变化不需重新导入根证书；手机换到另一个子网时必须更换带新约束的根证书并重新导入。若根 CA 允许所有 RFC1918 私有网段，可跨更多网络使用，但信任范围显著变宽，不作为默认建议。
8. Android Keystore 私钥不可导出不等于一定由 StrongBox/TEE 硬件保护。应在目标小米设备上通过 KeyInfo.getSecurityLevel() 实测；同时要理解被攻陷的应用进程可能仍能请求 Keystore 执行签名，只是不能直接导出密钥材料。
9. 两条路线都面对 Android 应用卸载/密钥命名空间清理、换机、PC 重装、信任证书撤销和私钥轮换问题。CA 路线的 CA 私钥丢失会导致整个信任身份重建；直接服务器证书路线只需重建该服务器证书身份。
10. 当前初步判断：**单手机 + 单 PC + 稳定家庭 Wi-Fi 时，A 的最小信任范围和低复杂度更有吸引力；IP 经常变化、需要频繁自动换证时，B 的便利性更有价值。** 这只是研究倾向，不是最终选型。

## 二、重要证据：Chrome Windows 可以信任自签名终端证书

Chromium 当前 `net/cert/internal/trust_store_win.cc` 源码明确说明：
- Windows Root store 中的证书可被视为 trust anchor，或在 self-signed 时被视为 trusted leaf。
- Root store trust 对象同时要求 self-signed leaf 满足自签名要求，并对 anchor expiry 与 constraints 执行检查。
- Chrome 检查证书是否可用于 TLS Server Authentication，主要依据 Enhanced Key Usage（EKU）。
- Trusted People store 的 trusted leaf 支持与 Local Machine 路径相关；源码注释明确指出 trusted end-entity certificates 仅允许从 Local Machine 的 Trusted People 作为 server-auth trusted leaf，不从 Current User Trusted People 读取。

Chrome Root Store FAQ 进一步明确 Windows Current User `Trusted Root Certification Authorities` 是 Chrome 本地信任决策的来源之一；TLS over TCP 会考虑本地信任决策。HTTPS/WSS 使用 TCP TLS 时适用这一验证路径。

### 路线 A 可验证的证书形态

- 自签名 X.509 v3 server certificate。
- BasicConstraints：`CA:FALSE`。
- ExtendedKeyUsage：仅 `serverAuth`。
- SubjectAlternativeName：`iPAddress` 精确匹配当前手机 IPv4。
- KeyUsage：按实际 TLS 算法设置；优先评估 ECDSA P-256 + digitalSignature。
- 私钥：Android Keystore 生成，不能导出。
- Windows：将公开证书导入 Current User → Trusted Root Certification Authorities。
- Chrome：验证该自签名终端证书能否在 Windows 10 / Chrome 157 被作为 trusted leaf 接受；验证错误 IP、过期证书和撤销后的行为。

这里的 Windows 存储区名称叫 Root，但证书自身是 CA:FALSE 的终端服务器证书。它不是一个能够签发其他服务器证书的 CA。不能仅凭名称把两种信任对象混淆。

## 三、路线 A：自签名终端服务器证书直接信任

### 结构

1. 手机生成一对 TLS server key pair，私钥放 Android Keystore。
2. 手机用该私钥构造自签名服务器证书，证书只包含当前 IP 的 iPAddress SAN，且 CA:FALSE。
3. 手机通过安全的首次信任流程把公开证书交给 PC；用户核对 SHA-256 指纹后导入 Windows 当前用户 Root store。
4. Chrome 访问当前 IP 时，校验该证书确实是受信任的自签名叶证书、有效期正确、用途为 serverAuth、SAN 精确匹配地址。
5. 手机 IP 改变时，生成新的 server key/certificate；PC 必须手动导入新证书，并移除旧证书。不能静默绕过证书名称错误。

### 优点

- 无 CA 私钥，无证书签发体系，无中间 CA。
- 信任范围窄：一张服务器证书绑定一个 IP。
- CA:FALSE 避免这张证书获得签发其他证书的能力。
- 手机只需要管理一组 TLS 私钥/证书。
- 证书泄露/更换时只需撤销该证书信任，不需要重建 CA 层级。
- 代码、证书链、调试与长期维护成本相对低。

### 缺点

- IP 改变时证书 SAN 不再匹配；新证书需要每台 PC 重新导入。
- 如果 PC 有多个 Windows 用户账户，每个用户账户的 Current User trust store 需要各自处理。
- 如果手机连接多个不同 LAN 子网，IP 变化更频繁，维护体验下降。
- 证书过期、手机更换密钥或 App 重装也需要重新导入。

### 降低换证频率

- 可选在路由器配置 DHCP reservation，让手机在家庭 Wi-Fi 中保持稳定地址。
- DHCP reservation 只固定 IP，不取代证书校验。
- 不建议为了证书稳定在 Android 里盲目手动设置静态 IP，以免地址冲突或影响网络接入。
- 如果用户不想配置路由器，仍可采用动态 IP，但每次 IP 变化都要重新导入证书。

## 四、路线 B：私有 CA + 动态叶证书

### 结构

1. 手机首次初始化，在 Android Keystore 生成私有 CA key pair。
2. 生成公开根 CA 证书，BasicConstraints CA:TRUE，KeyUsage 包含 keyCertSign，并配置 critical IP NameConstraints。
3. 手机显示根证书 SHA-256 指纹；PC 只导入公开根证书，不导入任何私钥。
4. 手机为当前 IP 生成叶证书，SAN 为精确当前 IP，EKU serverAuth，CA:FALSE，由私有 CA 签名。
5. 手机 IP 变化时，生成新叶密钥/叶证书并切换 TLS server identity；PC 已信任根 CA，因此在 NameConstraints 允许的范围内不需重新导入根证书。
6. CA 私钥只保留在 Android Keystore；PC 永远不获得 CA 私钥。

### NameConstraints 的范围策略

**优先研究当前 Wi-Fi 子网约束：**
- 通过手机网络接口取得当前 IPv4 和子网掩码，计算当前 LAN CIDR。
- 根 CA 的 NameConstraints 仅允许当前 LAN IP block。
- 叶证书 SAN 只能是当前手机 IP。
- Chromium 112+ 会执行平台 trust anchor 的 X.509 constraints；Chrome 126 起移除关闭此约束的临时策略，当前 Chrome 157 应保持约束开启。
- 例如允许 `192.168.31.0/24`（仅说明 CIDR 表达形式，非真实配置）。

**不推荐默认允许所有 RFC1918：**
- 允许 10/8、172.16/12、192.168/16 可减少换网络时重新导入根证书的次数。
- 但根 CA 的可签发名称范围显著扩大，若 CA 私钥被滥用，攻击者可签发其他私有 IP 的服务器证书。
- 其他非 Chrome TLS 客户端是否同样执行 trust anchor NameConstraints 需要分别验证；不能把 Chrome 的实现保证泛化到所有应用。

### 优点

- 根 CA 只需在每个 Windows 用户账户安装一次。
- 同一允许子网内 IP 变化时，手机可自动签发新的叶证书。
- 叶证书可短期轮换，不必每次变化都让用户操作 Windows。
- 多台 PC 的初次根证书安装完成后，后续 IP 变化无需逐台重新导入叶证书。

### 缺点

- 需要 CA 和 server 两套密钥、证书签发、证书链和轮换管理。
- CA 私钥拥有签发能力，风险高于单张 server key。
- 若 CA 私钥被滥用，必须在 PC 上移除/替换根 CA 信任；不能只换叶证书。
- 若 NameConstraints 只允许当前子网，手机换到另一子网时需要重签根证书并重新导入。
- 如果根 CA 允许所有 RFC1918，跨网便利性提高，但信任边界变宽。
- Android Keystore + X.509 builder + HTTPS server TLS stack 的集成复杂度更高。
- CA 私钥丢失/Keystore namespace 清理时，整个 CA 身份无法从公开根证书恢复；必须生成新 CA 并重新导入。

## 五、A / B 对比矩阵

| 维度 | A：自签名服务器叶证书 | B：私有 CA + 动态叶证书 |
|---|---|---|
| Windows 首次信任安装 | 每台 PC 导入一张服务器证书 | 每台 PC 导入一张 CA 根证书 |
| 是否真正安装 CA | 否，证书 CA:FALSE | 是，CA:TRUE |
| Windows 作用范围 | 当前用户 Root store；Chrome 按自签名 trusted leaf 处理 | 当前用户 Root store；信任该 CA 的签发链 |
| IP 在同一子网变化 | 重新签发并重新导入服务器证书 | 自动签发新叶证书，无需重装根证书 |
| IP 换到不同子网 | 新证书重新导入 | 当前子网约束下须更换根证书并重新导入 |
| 可否用 DHCP reservation 减少操作 | 可以，收益明显 | 可以，但不是动态换证的必要条件 |
| 私钥数量/管理 | 一组服务器私钥 | CA 私钥 + 叶证书服务器私钥，通常至少两组 |
| 私钥权限 | 只能完成服务器 TLS 身份证明 | CA 私钥可以签发允许范围内的多个叶证书 |
| 信任范围 | 单个 IP 的自签名服务器证书 | 根 CA 的 NameConstraints 允许范围 |
| 密钥泄露影响 | 主要是对应 IP / 证书身份 | 可签发允许范围内的其他服务器证书 |
| 撤销/恢复 | 移除旧服务器证书，导入新证书 | 移除根 CA，重新生成 CA 并逐台导入 |
| App 卸载/换机 | 重新生成服务器证书并重新导入 | 重新生成 CA 身份并重新导入 |
| 实现复杂度 | 较低 | 较高 |
| 长期维护 | IP 变化时需用户操作 | 同一约束网段内自动换叶证书 |
| 当前倾向 | 单机、固定家庭 LAN 更合适 | IP 经常变化、愿意承担 CA 复杂度时更合适 |

## 六、Windows 信任范围和安全影响

### Current User 与 Local Machine

- Chrome Windows 当前信任机制会读取 Current User → Trusted Root Certification Authorities。
- Windows Current User store 仅属于当前登录用户；Local Machine store 面向整台电脑所有用户。
- 应优先选择 Current User，而不是 Local Machine；不需要把 DailyNotes 的证书作为全机级根 CA 分发。
- Chrome 157 使用内置 Certificate Verifier；Chromium 官方 FAQ 说明 Chrome 134+ 可通过 `chrome://certificate-manager` 查看/管理证书信息。
- 仍需在真实 Windows 10 + Chrome 157 上验证导入、移除、重启 Chrome 后信任是否生效。

### 重要的信任范围区别

- A 的证书即使放入 Root store，也应是 CA:FALSE 自签名叶证书；Chrome 源码将其作为 trusted leaf 接受。它不能签发其他证书。
- B 的 CA 根证书能为 NameConstraints 允许范围签发证书。Chrome 会执行平台 trust anchor constraints，但并非所有 Windows 应用/第三方 TLS 栈都保证完全相同的约束行为。
- Windows 当前用户 Root store 不只是 DailyNotes 专属的浏览器隔离存储。其他使用该用户信任库的应用也可能读取其中的信任对象。因此 B 的 CA 信任范围应尽量小，不能只考虑 Chrome。
- 若用户完全不接受 Windows 当前用户证书信任变更，则手动输入 IP + 原生 Chrome HTTPS 没有一个可无警告、无额外信任配置的简单方案。HTTP 或忽略证书错误不作为可接受的正式替代；公共 CA 的域名证书则需要稳定域名，不符合当前纯 IP 访问设计。

## 七、Android Keystore 和 Flutter/原生服务集成

### 密钥安全

Android Keystore：
- 可生成不可导出的私钥；应用通过签名 API 使用密钥，密钥材料不会直接进入应用进程。
- 若硬件支持，密钥可以由 TEE 或 StrongBox 保护；必须通过 KeyInfo.getSecurityLevel() 现场确认，不能默认宣称 StrongBox。
- 应用进程被攻陷时，攻击者仍可能请求 Keystore 使用密钥；不可导出不等于无法滥用。
- StrongBox 不是所有设备/算法组合都支持；若不可用，需要记录实际安全等级并安全回退。
- Android Keystore key namespace 在 App 卸载维护时会被清理；卸载/重装应视为证书身份可能丢失的事件。清除应用数据、系统迁移和恢复备份的实际影响还需设备验证。

### A 与 B 的实现差异

- A 只需一组 Keystore TLS server key pair，生成自签名 CA:FALSE 证书。
- B 需一组 CA signing key，再加一组 TLS server key；每次 IP 变化需要签发新叶证书。
- Android 官方文档支持通过 KeyPairGenerator 在 AndroidKeyStore 生成密钥，并可使用 KeyStore.setKeyEntry 替换后续 CA 签名的证书；这说明证书链关联具备 API 路径，但不代表完整 HTTPS server 已经验证成功。
- 若 Dart/Flutter HTTPS server 不能直接使用 AndroidKeyStore 中不可导出的 Java PrivateKey，则可能需要 Kotlin 原生 TLS listener/SSLContext + Flutter/Dart 业务仓库桥接。A、B 都需要验证这一边界，B 的 CA 签名链更复杂。
- PoC 必须证明 TLS server 确实使用 Keystore 私钥完成握手，不能为了兼容 Dart 而把 CA 私钥写入普通文件或公开导出。

## 八、撤销、恢复和生命周期

| 事件 | A | B |
|---|---|---|
| 手机 IP 改变 | 重新签发服务器证书；PC 移除旧证书并导入新证书 | 新签叶证书；同一 NameConstraints 范围内自动恢复 |
| 手机 Wi-Fi 子网改变 | 新 IP 证书重新导入 | 若 CA 限定旧子网，需新根证书重新导入 |
| 手机 App 卸载/Keystore key 丢失 | 新 server key/cert，PC 更新信任 | 新 CA key/root/leaf，所有 PC 更新根信任 |
| 手机丢失 | 旧 server cert 在 PC 移除；新手机新证书 | 旧 CA root 在 PC 移除；新手机新 CA，所有 PC 重新信任 |
| PC 重装 Windows/更换用户 | 重新导入服务器证书 | 重新导入根 CA |
| 私钥疑似泄露 | 移除对应自签名证书并换 server key | 移除 CA 根信任并换 CA key，所有 PC 重新导入 |
| 证书过期 | 重新生成并重新导入 | 自动换叶证书；CA 根证书另行续期/轮换 |
| PC 误删证书 | 重新导入手机公开证书并核对指纹 | 重新导入根证书并核对指纹 |

不建议把 OCSP/CRL 在线吊销作为唯一恢复手段：DailyNotes 是私有局域网服务，可能离线，Chrome 也明确指出互联网吊销机制存在超时、阻断和隐私问题。关键事件应采用短期叶证书、明确的本地移除/换证流程和手机端状态提示。B 的 CA 密钥一旦泄露，必须更换根信任，不是只换叶证书。

## 九、建议 PoC 顺序（仍不编码业务功能）

### PoC-1：先验证路线 A

1. 用测试证书生成一张自签名 CA:FALSE 服务器证书，SAN 指定测试 IP。
2. 检查 EKU=serverAuth、SAN=iPAddress、CA:FALSE、有效期和 SHA-256 指纹。
3. 导入 Windows 10 当前用户 Root store。
4. 在 Chrome 157 访问正确 IP，验证无警告。
5. 访问错误 IP，验证必须失败。
6. 删除证书后验证访问重新失败。
7. 证书过期后验证失败。
8. 确认不需要管理员权限，不影响其他 Windows 用户。
9. 在真实手机上验证 Android Keystore 私钥与 Kotlin TLS server 握手。

### PoC-2：验证路线 B

1. 生成 CA:TRUE 根证书，加入 critical IP NameConstraints。
2. 先用一个测试子网，例如 192.168.31.0/24（仅示例）作为 permitted subtree。
3. 生成一个该子网内的叶证书，Chrome 应接受。
4. 生成一个子网外的叶证书，Chrome 必须拒绝。
5. 通过改变叶证书 IP SAN 模拟手机 IP 变化，确认同一子网内无需重新导入根证书。
6. 改变子网后确认旧根约束拒绝新 IP，并验证换根证书/重新导入流程。
7. 模拟 CA key 丢失/换新，验证 PC 端旧 CA 移除和新 CA 注册。
8. 验证其他常用 Windows 客户端是否执行相同 NameConstraints；若不一致，必须明确缩小信任范围或放弃该路线。

### PoC-3：设备与架构验证

- 在目标小米设备读取 KeyInfo.getSecurityLevel()，记录 Software / TEE / StrongBox 实际结果。
- 验证 AndroidKeyStore 生成的私钥能否用于自签名证书和 CA 签名证书。
- 验证 KeyStore.setKeyEntry 替换证书链后，原私钥仍不可导出且 TLS server 可使用。
- 验证 Kotlin TLS listener 和 Flutter/Dart 业务数据库桥接，确认不会形成两套数据权威。
- 验证应用卸载、清除数据、系统升级、手机更换后的身份恢复。

## 十、暂定判断（不构成最终选型）

- 若 DailyNotes 首期只在一台手机和一台 Windows PC、同一个家庭 Wi-Fi 使用，并且能接受路由器 DHCP reservation 或偶尔重新导入证书，**A 的最小权限和低复杂度更值得优先 PoC**。
- 若实际使用中手机 IP 频繁变化，用户更重视自动换证、且愿意承担 CA 维护成本，**B 才体现明显价值**；应优先限制到当前 LAN CIDR，而不是默认放开所有 RFC1918。
- 两者都需要用户明确确认 Windows 当前用户证书信任安装；B 不是“只安装一次就永远没有安全维护”，它只是把日常 IP 换证变成 CA 内部操作。
- 在 PoC 前，不更新最终选型，不把任何证书方案标记为已实现或已验收。

## 十一、公开技术来源

- Chromium Windows trust store implementation: https://chromium.googlesource.com/chromium/src/+/main/net/cert/internal/trust_store_win.cc
- Chrome Root Store FAQ (last updated 2025-11-14): https://chromium.googlesource.com/chromium/src/net/+/HEAD/data/ssl/chrome_root_store/faq.md
- Chrome local anchor constraints policy: https://chromium.googlesource.com/chromium/src/+/main/components/policy/resources/templates/policy_definitions/Miscellaneous/EnforceLocalAnchorConstraintsEnabled.yaml
- Windows certificate store management: https://learn.microsoft.com/en-us/windows-server/identity/ad-cs/inspect-certificates-manage-certificate-stores
- Windows Current User / Local Machine certificate stores: https://learn.microsoft.com/en-us/windows-hardware/drivers/install/local-machine-and-current-user-certificate-stores
- Android Keystore: https://developer.android.com/privacy-and-security/keystore
- Android KeyGenParameterSpec: https://developer.android.com/reference/android/security/keystore/KeyGenParameterSpec
- AOSP hardware-backed Keystore: https://source.android.com/docs/security/features/keystore
- RFC 9525: https://www.rfc-editor.org/rfc/rfc9525.html
- RFC 5280: https://www.rfc-editor.org/rfc/rfc5280.html
