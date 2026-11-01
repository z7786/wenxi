# 文析助手下载内核

本工程沿用原 AsterLink 已修复的 Gopeed **1.8.1** HTTP/HTTPS 与 BitTorrent 内核。Dart 负责队列、来源刷新、校验、HLS 与文件导出；Android 通过 gomobile/JNI 调用，Windows 通过专用 helper 的标准输入/输出调用。

2026-11-01：BT 在原四个 Tracker 的基础上后台检查其他公共候选，近期连接节点和 DHT 引导节点写入现有加密缓存。默认上传上限 512 KiB/s，可在下载设置调整，下载与播放共用上限；快照增加来源、做种者和会话复用状态。同种子连续文件完成后最多保留连接 30 秒，冻结旧输出、重置新输出完成标记后接续；暂停仍重新校验数据。保持 80 个对等连接及单 BT 文件任务队列，没有修改 Go 依赖。Android AAR 四种架构已重新编译，Android 2.1.0+210 安装包已生成并通过签名及原生库核验；Windows 仅构建临时 helper 做回归，发布时仍须重建各架构 helper。设计与验证见 [BT 找源与连续下载](../docs/BT-DOWNLOAD.md)。

2026-11-01：在现有 Gopeed 运行库内嵌入 MIT 许可的 Kelpie ED2K 内核，固定来源版本与补丁见 `gopeed/internal/ed2kcore/ASTERLINK_PATCHES.md`。ED2K 通过 eDonkey 服务器、Kad 和明确链接来源找源，直接连接节点下载，保留分片 MD4 / AICH 校验、暂停和重启断点。断点、节点和身份由现有 AES-GCM 加密数据库保存；不新增后台服务或独立进程，首次 ED2K 下载才启动网络。同一时间执行一个 ED2K 任务（任务内自动连接多个来源），HTTP / BT 仍可并行。任务下载上限沿用设置，上传上限 128 KiB/s，暂停、完成收尾和退出时关闭共享网络。安卓文件描述符通过原有输出授权重开，不写入持久化状态。使用与构建说明见 `../docs/ED2K-DOWNLOAD.md`。

2026-10-29：优化限速下载的慢尾段调度。工作线程完成分段后保留为可取消的空闲线程，每 500 毫秒检查剩余分段的实际速度；超过 750 毫秒的观测期、预计仍需 3 秒以上时，即使剩余不足原来的 1 MiB 门槛也允许分担。每次只拆分尚未写入的范围，两个新范围各至少 16 KiB，快速小尾段保持原请求；用户设置任务总限速时保留原分段门槛。空闲等待不占请求名额，完成、终止失败及暂停及时唤醒并回收等待线程。百度账号下载与预览的单连接限制、阿里/主机预算及重试策略继续适用；计时和速度观测不写入旧断点格式，没有新增依赖。

2026-10-05 / 1.1.0：百度预览下载保持单连接，每次顺序请求最多 8 MiB，避免大文件整段 Range 被服务器拒绝（403）。下载仍保留原文件名、完整内容和断点进度；旧多分段记录也按单连接续传。校验每次响应的范围与长度，截断响应按已写入位置重试，范围变化时停止写入。普通百度下载线路及其他网盘沿用各自策略，没有新增依赖。

2026-09-26 / 1.0.0：修复光鸭 CDN 对 `Range: bytes=0-0` 返回 HTTP 200、长度 1，导致大文件被误判为一字节的问题。Dart 探测和 Gopeed 内核在遇到这种响应时用前两个字节复核，保留原文件大小及分段校验；真正的一字节文件与空文件仍可下载。没有新增依赖。

2026-09-25 / 0.5.0：迅雷签名直链的分段不再等待首个请求的重定向结果；慢尾段剩余超过 512 KiB 时允许空闲连接分担，每次取剩余部分的一半。收到 429/503 后，同主机共享两分钟的繁忙窗口，最多允许 8 个请求，已发出的请求计入占用；其他主机不受该窗口影响。窗口过期恢复正常预算，排队及冷却支持取消，并保留用户的重试次数和 Retry-After。分段交接与写入使用连接锁，断点返回稳定副本，下载完成后及时关闭分段响应与空闲连接。没有新增依赖。详细证据见 迅雷下载优化。

2026-09-25 / 0.5.0：阿里原文件的分段请求同时启动，同一下载主机最多 8 个活动请求，并服从用户设置的更小上限。共享名额也覆盖多个任务及旧版本保存的较多分段，排队可被暂停取消。Windows 在支持的文件系统上使用稀疏文件，避免大文件首次写入远端分段时长时间补零；不支持时沿用普通文件。Android AAR 与 Windows helper 均已重新编译。实测与限制见 网盘刷新和下载验证。

0.3.22：增加 BT 媒体读取会话，仅在播放期间开放带随机令牌的 `127.0.0.1` 随机端口。节点发现、连接预算及复用策略集中于 `internal/btpolicy`；当前播放位置优先取片，分片校验后才提供给播放器，拖动/退出可中断等待。关闭同步覆盖缓存读写、刷盘和完成状态，防止迟到 I/O 重建已删除的缓存。详细说明见 BT 在线播放。

播放存储使用现有 `anacrolix/generics` 的公开类型，因此 `go.mod` 将该依赖从间接引用改为直接引用；固定版本、`go.sum` 和 vendored 依赖源码均未变化，没有新增依赖或媒体运行库。

0.3.21：`connectionProfile=quark_route_1` 使用约 64 KiB 的分段预算，其余线路保留约 256 KiB；40 MB 夸克文件不再被减少到 153–160 个分段。Fetcher 通过原子计数公开工作请求数和总分段数，桥接快照返回 `activeConnections`、`totalConnections`。计数不等待任务锁、不额外分配分段统计列表；暂停和完成事件的工作数为零。详情见 夸克下载调整。

## 来源与版本

- Gopeed 上游：https://github.com/GopeedLab/gopeed/tree/v1.8.1
- 加速归档：https://gh-proxy.com/https://github.com/GopeedLab/gopeed/archive/refs/tags/v1.8.1.zip
- 原始归档 SHA-256：363b075f80209316e99050f13a18bd6cbbd5e0f97d09c8889ece1651c0d18c7e
- Go：1.24.7；gomobile/gobind：golang.org/x/mobile v0.0.0-20250911085028-6912353760cf
- NDK：28.2.13676358；AAR 的 API 下限为 23，Flutter 应用下限为 24。
- 许可：GPL-3.0，完整文本见 gopeed/LICENSE。对应源码、补丁与 Go 依赖源码保存在 gopeed/ 和 gopeed/vendor/。

## 重建 Android AAR

安装 Go、JDK、Android SDK 和上述 NDK 后，在项目根目录执行：

```powershell
.\native\build-gopeed.ps1 -Go go -JavaHome $env:JAVA_HOME -AndroidHome $env:ANDROID_HOME -Test
```

脚本固定 gomobile/gobind 版本，Go 模块默认走国内镜像并保留校验，也可通过 GOPROXY 指定可访问的下载源。输出为 android/app/libs/gopeed-1.8.1.aar；该生成文件不提交到 Git，缺少时 tool/build-android.ps1 会自动重建。AAR 包含四个 ABI；当前 Flutter release APK 仅包含 arm64-v8a。

package-gopeed-runtime.ps1 为各 ABI 补齐 NDK 的 libc++_shared.so，在临时目录 strip，并检查 DT_NEEDED 引用。省略这个库会导致 go.Seq 初始化失败。NDK 安装目录自身不被修改。APK 压缩 native 库以控制下载体积。

## Windows helper

```powershell
.\tool\build-native-windows.ps1 -Go go
```

输出 native/bin/asterlink_gopeed.exe。该 helper 是下载组件，需要与 Flutter 主程序一起使用；单独打开没有界面。下载管理继续走私有管道，BT 按协议连接对等节点和 tracker；在线播放使用仅回环可访问的媒体读取端口。支持 version/open/begin/snapshot/pause/remove/close/freeSpace、torrentResolve/torrentMetadata/torrentCancel 以及 torrentStreamStart/torrentStreamStatus/torrentStreamStop/torrentStreamInterrupt，响应按 seq 关联。凭据不经命令行传递。CMake 会将 helper 复制到 Windows 发布目录。

本地验证：

```powershell
go test -tags nosqlite -ldflags=-checklinkname=0 ./bind/asterlink -count=1 -timeout=120s
# 上一行在 native/gopeed 中执行；下一行在 Flutter 工程根目录执行
flutter test --no-pub test/native_integration_test.dart
```

## 上游修改记录

2026-09-12 原 Android 集成保留以下修改：

- bind/asterlink：JNI API、AES-GCM 加密 bbolt 状态、错误脱敏、任务 ID 校验、过期事件隔离、缓存恢复。
- pkg/download/asterlink.go：同步暂停并保存 checkpoint，远端身份确认后替换请求。
- pkg/download/downloader.go、model.go：暂停后取消排队启动，忽略删除后的过期完成事件。
- internal/protocol/http/fetcher.go、asterlink_range.go：重试、任务限速、超时、严格 Range 检查、小文件分段、空文件和未知长度流、重试计数、等待写入停止。
- pkg/protocol/http/model.go：逐任务重试和限速选项。
- go.mod / go.sum：固定工具链和模块版本。

2026-09-13 Flutter 迁移新增：

- cmd/asterlink：Windows 私有管道协议、空间查询和通用错误信息。
- 原生构建与 C++ runtime 打包脚本改为 Flutter 工程目录。
- Windows helper 的生命周期、重启续传、失效地址刷新、异常退出恢复由真实进程集成测试验证。
- Dart 的冷删除保留待删除标记；活动删除等待 native 写入结束。

HTTP 线程策略延续原版：全局 64、夸克直链与 UC 平台预设 512、每任务允许 1–512、同时任务 1–3。旧任务保留添加时的设置；调整设置影响新任务。BT 使用最多 80 个对等连接，单次只运行一个 BT 文件下载任务，在线播放时该队列让出带宽，退出后恢复等待任务；下载限速沿用任务设置。未增加夸克秒传。


2026-09-14 / 0.3.9 接入 BT：

- `bind/asterlink/torrent.go` 提供元数据异步解析、取消和选中文件下载，沿用 Gopeed 的 anacrolix 引擎；最多一个元数据网络客户端，90 秒超时，4 MiB 种子限制。
- `internal/protocol/bt` 将默认存储限定在应用缓存，修复单文件、多文件与空文件路径；暂停/移除最后一个种子后关闭客户端并清除分片完成缓存，下次从磁盘重新校验。
- 元数据最多 10000 个文件、目录深度 32，拒绝穿越路径、危险文件名与重复路径；支持 v1 和含 v1 信息的混合种子，分片上限 64 MiB。
- 选中文件完成后释放原生句柄，再交给 Dart 校验/导出；初始与持续空间预算包含边界分片。Windows JSON 输入帧限制增至 8 MiB，种子内容不经过进程参数。
- AAR 与 Windows helper 均重新编译；HTTP 协议修复、媒体运行库和 JNI keep 规则继续保留。
- 测试使用自行生成的种子、本地 tracker、真实做种端与 HTTP webseed，覆盖先元数据后负载、连续选文件、空文件、暂停、缓存驱逐、重启续传、校验和删除；无外部 BT 内容。

2026-09-14 / 0.3.15 下载可靠性：

- `internal/protocol/http/asterlink_policy.go` 按约 256 KiB 的最小分段预算限制小文件连接，保留大文件的 512 连接配置；HTTP 工作连接限制为同一下载地址主机 512、总体 768。
- `fetcher.go` 接受可取消 Resolve 上下文，读取 Retry-After 秒数/日期，对 429/503 共享主机冷却；连接名额及冷却等待可随暂停中断。未引入新的 Go 依赖。
- `pkg/download` 在等待任务锁前取消 Resolve，并合并普通 checkpoint；显式暂停及完成仍及时保存，保留删除/写入顺序及旧事件隔离。
- `bind/asterlink` 在快照中返回网络错误类别、已耗尽重试标记和剩余冷却时间，避免 Dart 重复叠加原生重试。
- Android AAR 与 Windows helper 均由此源码重建；本地测试覆盖取消、限流、连接名额回收、小文件和大文件 Range，详情见 验证报告。
