# 阿里开放平台播放

阿里视频播放改用此前分析的 AinanPlayer 豆源取链流程：普通账号登录授权、OpenList OAuth 换取开放平台凭据、分享先转存、阿里官方开放接口取播放地址。Android 与 Windows 共用 Dart 实现，不增加新的包或应用私钥。

## 授权与取链

1. 复用现有网页登录的普通 `accessToken` 和轮换 `refreshToken`。
2. 从 `https://api.oplist.org/alicloud/requests` 读取 OAuth 授权参数，使用 `driver=alicloud`、`driver_txt=alicloud_go`、`server_use=true`。
3. 向阿里官方 `https://open.aliyundrive.com/oauth/users/authorize` 发送普通账号 Bearer Token，授权 `user:base,file:all:read,file:all:write`，取得一次性授权码。
4. 将授权码提交到 OpenList `/alicloud/callback`，禁止自动跳转，从响应 `Location` 的 Base64 JSON fragment 读取开放平台凭据。
5. 开放 Token 和普通登录凭据分开保存在当前账号的本地加密字段中，保留账号 revision。临近过期两分钟或接口明确拒绝该 Token 时重新授权，同一连接器的并发授权共用一个结果。

普通 Token 和普通 refresh token 不发送给 OpenList。OpenList 会处理授权码及换取的开放平台凭据，详见 [隐私说明](PRIVACY.md)。授权、回调和变更请求不进入普通读取重试，迟到响应在取消、账号替换或移除后不能覆盖新的账号状态。

播放取链请求使用 `https://open.aliyundrive.com/adrive/v1.0/`：

| 用途 | 接口 | 处理 |
| --- | --- | --- |
| 转码视频 | `openFile/getVideoPreviewPlayInfo` | `category=live_transcoding`、`url_expire_sec=14400`，优先 `quick_video_list`，否则 `live_transcoding_task_list` |
| 原文件播放 | `openFile/getDownloadUrl` | 使用返回的 `url`，校验可选文件/空间标识与大小 |
| 分享目标资源库 | `user/getDriveInfo` | 使用当前开放账号的 `resource_drive_id` |
| 播放临时目录 | `openFile/create`、`openFile/list` | 新建独立目录并等待转存后的文件可见 |

转码按 `template_width` 从大到小选择；缺少宽度时按清晰度模板补充排序。保留本项目对未完成任务、无效 URL 与 `preview_url` 试看地址的过滤；快速转码任务允许省略 `status`。没有完整转码或转码接口暂时失败时，使用开放平台的原文件地址。文件已删除、空间错误、账号失效或返回文件标识不符时显示错误。

## 分享转存与兼容

分享视频先获取 `share_token`，使用普通账号调用 `adrive/v2/file/copy`，附带 `X-Share-Token`，转存到开放平台返回的资源库。转存后等待文件可见，继续校验文件大小和可用哈希，再按新 `file_id` 取链。

本项目继续使用每次独立的 `AsterLink临时转存_<UUID>` 目录及持久清理任务。播放器仍在使用的目录会保留，使用结束后按原账号、原空间和目录名称/位置验证后移入回收站。没有采用豆源每次清空同一个 `CatPawPlay` 目录的做法，以兼容原有播放、下载和清理生命周期。

转码 HLS 交给现有播放器读取；原文件复用现有本机分块代理和播放器连接设置。地址重试与播放历史恢复重新调用开放平台取链。播放器的文件下载按钮及普通文件下载继续调用原有下载接口，图片、音频、上传、目录管理、资源库/备份盘/相册入口和快传处理保持原流程。

## 来源与验证

协议依据为本机 2026-10-29 已下载的 AinanPlayer v4.4.0 与更新服务器豆源脚本，并核对 OpenList 文档和不含账号凭据的授权参数入口。协议以 Dart 独立实现，未执行或打包第三方完整脚本。现有 BoxPlayer/OpenList 许可声明保留。

本次检查不使用真实阿里账号。公开 `/alicloud/requests` 实际返回 HTTP 200，授权地址位于 `openapi.aliyundrive.com/oauth/authorize`，回调指向 OpenList；转码和原文件开放接口的无凭据查询均返回 HTTP 401、`AccessTokenInvalid`。这些检查验证入口和错误响应格式。真实账号的自动授权、会员权限、转码可用性和播放速度需在编译安装后联调。当前未生成新的 APK 或 Windows 程序。

验证结果：11 个相关测试文件共 241 项通过，覆盖阿里播放、普通下载、文件列表、相册、快传、下载恢复、账号凭据与分享兼容；最后补充缓存账号绑定和非 JSON 限流处理后，授权与播放两个测试文件共 60 项通过。`dart analyze lib test` 无问题，格式检查和 `git diff --check` 通过。日志位于本机 `.local/aliyun-open-playback-20261029/`。
