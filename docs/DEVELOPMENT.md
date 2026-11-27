# 长期开发与验证

本指南维护日常开发、模块定位和验收方法；构建参数见 [BUILDING](BUILDING.md)，发布与更新配置见 [GITHUB-PUBLISH](GITHUB-PUBLISH.md)。AI 入口是根目录 [AGENTS.md](../AGENTS.md)，贡献要求见 [CONTRIBUTING](../CONTRIBUTING.md)。

## 任务闭环

1. 先看工作区差异和相关专题，明确一个可验证目标：用户看到的变化、现有可复用能力、修改范围、异常路径及验收方法。只有用户体验或数据行为有关键歧义时才停下来澄清。
2. 一个阶段完成一条用户路径。业务计算、协议、状态管理和页面呈现沿用已有边界，避免把新协议或长生命周期任务继续堆进页面。
3. 开发中跑最相关的测试；实现后检查真实操作路径、账号归属、失败/取消/重试、旧任务恢复和资源释放。审查发现要转为具体修复与验证项。
4. 同步维护现有专题文档，执行源码检查；跨模块阶段完成后执行全量 Flutter 回归和相关原生检查。说明跳过项与人工体验结果。
5. 结束时记录最终行为、实际执行的命令与结果、尚未验证的设备或账号情况。不要把旧审计里的通过数复制为本次结果。

独立功能确需同时开发时使用独立分支和工作目录，合并后验证组合行为。当前工作区已有的修改不能通过重置、清理或覆盖来“整理”。测试和构建会共用 Flutter 缓存、原生产物与 `.local/`，同一工作目录避免并发运行多个 Flutter 构建/测试进程。

## 模块地图与复用入口

| 工作内容 | 先读代码 | 关联说明 |
| --- | --- | --- |
| 启动、服务与恢复 | `lib/main.dart`、`lib/app_services.dart`、`lib/ui/startup_failure_page.dart`、`lib/data/state_store.dart` | [本地状态恢复](LOCAL-STATE-RECOVERY.md) |
| 网盘协议与账号 | `lib/data/providers/`、`lib/data/cloud_repository.dart`、`lib/domain/auth.dart` | [链接识别](LINK-RECOGNITION.md)、[浏览器 UA](CLOUD-BROWSER-UA.md) |
| 搜索与来源运行时 | `lib/data/resource_search.dart`、`lib/data/client_search_engine.dart`、`lib/data/sources/` | [资源搜索](RESOURCE-SEARCH.md)、[来源架构](REMOTE-SOURCE-ARCHITECTURE.md) |
| 下载、上传、跨盘传输 | `lib/download/`、`lib/upload/`、`lib/transfer/`、`lib/data/uploads/` | [下载性能](DOWNLOAD-PERFORMANCE.md)、[文件夹上传](FOLDER-UPLOAD.md)、[跨盘传输](CROSS-DRIVE-TRANSFER.md) |
| 文档预览 | `lib/preview/`、`lib/ui/document_preview.dart`、`lib/ui/document_download_preview.dart` | [本地文档预览](DOCUMENT-PREVIEW.md) |
| 播放与投屏 | `lib/playback/`、`lib/ui/player_page.dart`、`lib/ui/player_theme.dart` | [播放恢复](PLAYER-RECOVERY.md)、[性能验收](PLAYER-PERFORMANCE-CHECKLIST.md)、[投屏](TV-CASTING.md) |
| 平台能力 | `lib/platform/`、`android/app/src/main/`、`windows/runner/`、`ios/Runner/`、`macos/Runner/` | [构建](BUILDING.md)、[iOS](IOS-BUILD.md)、[macOS](MACOS-BUILD.md) |
| 更新与诊断 | `lib/data/app_update_service.dart`、`lib/data/remote_control_service.dart`、`lib/diagnostics/` | [App 内更新](IN-APP-UPDATE.md)、[隐私](PRIVACY.md) |

UI 优先复用 `app_theme.dart` 的配色和外观、`common.dart` 的消息/格式化/文件展示、`app_context_menu.dart` 和 `app_popup_menu.dart` 的菜单、`app_switch.dart` 的开关、`transfer_widgets.dart` 的传输行，以及已有进度、加载与错误反馈。播放器设置使用 `player_theme.dart`，故障操作呈现使用 `player_error_panel.dart`，分享参数由 `share_options_dialog.dart` 收集；业务执行与取消/重试仍由页面和管理器负责。下载列表排序与删除进度分别由 `download_task_index.dart`、`download_deletion_progress.dart` 维护。先搜索调用示例，再决定是否需要扩展公共组件；不要为了统一而一次替换所有页面常量。

`pubspec.yaml` 是版本来源，`lib/core/app_version.dart` 由 `dart tool/sync_version.dart --write` 生成。工具链版本取自 `.github/actions/setup/action.yml`；依赖按 `pubspec.lock` 安装。保留原生及 vendor 补丁的来源、许可和回归用例。

## 分层验证命令

工具入口要求 Python 3.10 及以上，CI 使用 Python 3.12。本机 Windows 的 `python` 可能仍指向旧版本，下面使用 `py -3` 选择已安装的新版本；其他系统可改用满足版本要求的 `python3`。所有路径相对于仓库根目录解析，也可从其他目录通过脚本绝对路径调用。依赖缺失时先按构建指南准备工具链，并运行 `flutter pub get --enforce-lockfile`；验证入口不会自动升级依赖。

```powershell
# 修改中：明确选择与本次变更有关的测试
py -3 tool/verify.py test test/startup_recovery_test.dart test/startup_recovery_widget_test.dart

# 原生播放等共享资源测试可串行执行
py -3 tool/verify.py test --concurrency 1 test/native_playback_test.dart

# 收尾：公开文件、版本、文档入口、Python 工具测试和 Flutter 静态分析
py -3 tool/verify.py source

# 提交暂存后，公开文件检查改读 Git 索引；其他检查仍针对工作区
py -3 tool/verify.py source --staged

# 跨模块阶段完成：源码检查 + test/ 下全部 Flutter 测试
py -3 tool/verify.py full

# 只查看将执行的命令，不运行、不写文件
py -3 tool/verify.py full --dry-run
```

任何一步失败立即停止并返回非零状态；运行元信息保存在 `.local/verification/`，包含命令、耗时、退出码，不保存测试输出。记录只是本次运行凭据，不是发布授权，也不能在继续修改后当作新代码已验证的证明。

`test` 不自动运行静态分析或 Python 检查，适合局部循环。`full` 覆盖源码检查与 `test/`，**不代表所有平台、原生工具及真实账号场景已经通过**。环境依赖测试可能跳过，需检查测试输出；不要为消除失败批量更新 golden、删除断言或屏蔽分析规则。

| 变更范围 | 还要完成的验证 |
| --- | --- |
| 页面和交互 | 相关 widget/golden，窄屏/宽屏、深浅色、大字体、键盘及返回行为；人工确认交互 |
| 网盘协议/任务 | 合成数据或本地 HTTP 服务覆盖成功、过期凭据、取消、重试、断点与账号隔离；真实网盘另行记录 |
| Windows 播放 | 同一 PowerShell 会话先运行 `./tool/prepare-player-test.ps1`，再运行相关原生播放测试；真机硬解和长时间播放另验 |
| Go 下载内核 | 在 `native/gopeed` 按 CI 执行 `go test -p=1 -mod=vendor -tags nosqlite -ldflags=-checklinkname=0 ./bind/asterlink ./internal/protocol/http ./internal/btpolicy -count=1 -timeout=600s`；环境准备见 CI |
| Android/Apple/Windows 桥 | 对应原生单测及目标平台构建；Apple 构建在 Mac 验证，Windows 本机结果不能代替 |
| 构建/发布工具 | Python 工具测试、`./tool/tests/build-config.test.ps1`、对应安装包检查；浏览器脚本用现有专项测试 |

重型回归安排在功能阶段完成后。测试应验证可观察的行为与曾出现的故障；速度慢先定位瓶颈，再考虑分层或抽出纯逻辑，不能仅因耗时删除有价值的回归。涉及外网、真实账号或私有回放的诊断测试应显式启用，默认回归不应依赖私人目录。

### 私有回放与真实网络诊断

8 个依赖私人后台、捕获样本或外部审计服务的入口集中在 `tool/diagnostics/`，默认 `flutter test`、`verify.py full` 和 GitHub 检查只运行 `test/`。普通 `test` 命令拒绝诊断目录（也拒绝包含它的整个 `tool/`），改用明确的诊断命令：

```powershell
$env:ASTERLINK_BACKEND_ROOT = 'D:\private-fixtures' # 自己准备的绝对目录
$env:ASTERLINK_JS_LIBRARY = 'D:\native-test\asterlink_js.dll'
py -3 tool/verify.py diagnostic tool/diagnostics/rule_repair_20261116_test.dart
```

命令只给子进程启用 `ASTERLINK_DIAGNOSTICS=1`；不自动设置真实网络开关。延迟审计另外需要 `ASTERLINK_LATENCY_AUDIT=1`，修复后的网络审计需要 `ASTERLINK_RULE_REPAIR_AUDIT=1`，短剧实时查询需要 `ASTERLINK_LIVE_SEARCH=1`。独立转存服务诊断使用 `ASTERLINK_TRANSFER_AUDIT=1` 和 `ASTERLINK_TRANSFER_AUDIT_URL`。缺少必要环境或捕获文件应报错，附加的线上签名样本仍可能跳过；诊断输出沿用指定私有样本目录，不进入源码。两个延迟入口共享 `rule_network_audit.dart`，避免同一测量逻辑独立演化。

### GitHub 平台构建

安装包统一走现有 GitHub Actions；本机执行检查和测试，不默认生成安装包。`CI` 在源码检查通过后构建 Android、Windows x64/ARM64；正式包用 `Build signed release`，Apple 平台用已有 iOS/macOS 工作流。源码检查先准备固定版本原生播放器，并从当前源码编译 JS 测试运行库，再运行全量测试，避免因缺少原生库而跳过回归。发布产物附各自的 SHA-256 清单，验收关联对应 run 与提交 SHA，详见 [发布说明](GITHUB-PUBLISH.md)。

## 文档维护与疑难止损

入口 [文档索引](README.md) 指向维护中的专题。日期命名的审计/复测文档属于当时的诊断证据；使用前核对当前实现，不能当作永久接口约定。新增功能优先更新已有专题，必要的新专题加入索引；本地验收日志和机器报告放 `.local/`。

`python tool/check_project_docs.py` 检查七个维护入口中的行内 Markdown 本地链接、图片路径和 Markdown 标题锚点；不联网，不检查所有历史文档、引用式链接或 HTML 导航。通过只说明这些入口引用可用，不能证明业务描述与代码完全一致。修改功能时仍需人工核对相应专题。

连续两轮同类修复失败时，先固定复现步骤、预期行为、日志和已排除假设，重新判断根因。必要时用不同方法独立检查；依据可复现证据作决定，不把模型自报置信度当作正确率。改变用户可见功能范围时再请用户决定取舍。

## 当前治理里程碑

2026-11-23 初次盘点：432 个 `lib/` Dart 文件、430 个 `test/` 测试文件、63 篇顶层专题/记录；工作区已有大量未提交业务变更。以下是当时规模，不是自动更新的统计。

| 阶段 | 范围 | 完成标准 |
| --- | --- | --- |
| 已落地：可持续验证 | 开发约束、分层命令、文档入口校验、现有诊断测试静态问题 | 源码检查通过，新增工具行为有回归，原有业务修改保留 |
| 已落地：职责拆分 | 播放故障面板、分享选项、下载排序与删除进度独立维护 | 相关原有用户路径回归通过；后续按功能需求继续拆分，不以减少行数为目标 |
| 已落地：测试依赖治理 | 私有回放移出默认目录，网络诊断显式启用，共享测量实现 | 默认测试不再读取写死的私人后台路径；原生播放器准备接入 GitHub 测试前置步骤 |
| 发布时：平台与恢复验收 | GitHub 构建、安装、升级、更新配置、旧版状态兼容、启动恢复 | 关联实际 GitHub run/提交和产物哈希；真实安装与设备体验需在产物生成后完成 |

现有启动失败页支持备份恢复、保留旧数据重新初始化和日志导出；播放器初始化已有独立恢复路径。它们不能捕获进程级原生崩溃。恢复验收应在这些入口上补充，不再创建一套平行机制。

网盘文件列表的时间排序直接使用网盘返回的文件或文件夹时间，切换排序不自动读取子目录。文件夹保持在文件之前，无有效时间的条目按名称回退；排序和显示沿用已有时间解析。收藏整理支持单层分类文件夹，新建、改名、移动收藏与删除分类；删除分类保留收藏，旧数据和缺失分类归入未分类。分类随备份与恢复回退一同保存。

网盘文件、文件夹和分享链接新增收藏时，可选择现有分类、未分类或直接新建分类；新建后自动选中。收藏列表和首页快捷收藏菜单的“编辑收藏”统一修改名称及分类，名称留空使用原名称，保存通过一次状态提交完成；整理页面的移动入口复用同一分类选择器。取消新增或编辑不会提交收藏变更，已明确创建的分类保留。分类在选择期间被删除时提示重新选择，保存失败保留编辑窗口和输入。收藏分类沿用 `folderId` 与 `cloudFavoriteFolders`，保持原备份格式。
