# 夸克移动转存参数

搜索结果、资源首页和 App 内夸克更新链接在 Android 手机上需要账号转存时，优先使用 `drive-m.quark.cn`。Windows、macOS、Linux、iOS、平板和电视继续使用网页转存。免转存下载、资源池和公共解析的自适应策略继续生效。

当前使用已验证的精简网盘请求参数，不复用短信登录的 `device/client_info` 配置。每次转存读取当前手机环境，网页 Cookie 仅用于 `/account/info` 获取 `mobilekps`；移动请求通过实时生成的 `kps/sign/vcode` 认证。

| 网盘参数 | 当前来源与处理 |
|---|---|
| `device_model`、`mi` | Android `Build.MODEL`；不使用固定机型 |
| `ss` | 当前屏幕宽高除以显示密度，输出逻辑尺寸，例如 `393x852` |
| `la` | 当前完整语言地区标签的语言部分，例如 `zh-Hans-CN` → `zh`；无法读取时省略 |
| `nt`、`nw` | Wi‑Fi：`5/0`；系统报告 LTE：`6/4G`；系统报告 NR：`7/5G` |
| `ve`、移动 UA 版本 | 统一引用已验证的夸克协议版本 `7.4.5.680`，不是 AsterLink 自身的版本号 |
| `fr`、`pr` | 网盘平台 `android`、产品 `ucpro`；短信接口的同名 `fr` 含义不同 |
| `pf`、`bi`、`kt`、`sv` | 保留已验证客户端配置 `3300/35937/4/release`；`kt` 与 AES key4 分开 |
| `kps`、`sign`、`vcode` | 由账号凭据和当前时间生成；不作为设备身份 |

原生桥接分别提供 `networkTransport/cellularSubtype` 供夸克使用，以及 `networkType/networkSubtype` 供已有百度 APN 逻辑使用。账号 SDK 的 `net_type/net_id` 不参与 `nt/nw` 映射。不通过 APN、计费状态、手机品牌或网络默认值推测制式；系统无法确认蜂窝代际、VPN 隐藏底层连接或网络数据受限时省略 `nt/nw`。不为补充这些参数新增电话权限。

完整语言地区标签保留在本次设备信息中，URL 只发送 `la`。屏幕、语言、网络和型号不写入账号备份，不保存到下载任务或日志。所有 URL 参数均为字符串。

UTDID 是 SDK 的设备/安装身份，`uid` 是登录服务器返回的账号身份，二者不可互换。当前精简转存不要求 UTDID；缺少真实 SDK 来源及已验证的 key3 材料时，省略 `ut/ds`。不拿 Android ID、手机号、账号 UID 或随机 UUID 代替它。`sn` 是 App/SDK 保存的标识，不能用 `Build.SERIAL` 替代；因此 `ni/dn` 及没有来源的 `imei/imsi/mac/game_id`、内部缓存字段也不补造。`client_id=258` 和 `client_info` 属于账号登录配置，不加入网盘转存请求。`local_ip` 不需要时不读取或发送。

移动认证、分享校验或转存明确失败后回退网页接口。手机环境缺失时同样回退。保存请求已发送而结果未确认时，保留任务查询和等待状态，防止重复提交网页转存。

相关实现：`lib/platform/quark_transfer_device.dart`、`android/app/src/main/kotlin/com/asterlink/app/ClientEnvironment.kt`、`lib/data/providers/quark_mobile_transfer.dart`。
