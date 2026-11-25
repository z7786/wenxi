# 上传与发布

日后“上传代码”“提交”“合并”均默认只发布前端客户端；后台服务及本机运维工具保持本地，除非用户另行明确要求。安装包仅在用户要求时上传 Releases，不进入源码提交。

本仓库只提交 Flutter 客户端及其构建依赖，包括 `lib/`、Android/Windows 原生代码、`native/` 下载内核、`vendor_plugins/`、客户端测试和通用协议文档。客户端使用的规则引擎、来源脚本运行时及 `lib/data/parser_rules/server.dart` 等接口调用代码属于客户端，需要一起提交。

后台站点源码放在本仓库之外，不随本项目提交。仓库内的密码更新器 `tool/password_updater/`、启动脚本、后台规则测试 CLI 和构建脚本、后台部署与本机验收记录已忽略；`backend/`、`wwwroot/`、`5.com/` 也预留为后台副本的忽略目录。上述文件保留在本机，强制暂存后会被上传检查拒绝。

正式安装包使用现有 GitHub Actions 构建，本机只做检查与测试。`.local/`、`outputs/`、`dist/` 本机测试输出、日志、账号备份、签名、构建缓存和安装包已被忽略；不要通过网页拖入整个原始目录。本机磁盘清理面板及其启动脚本和说明也不进入源码仓库。

公告 HTML 编辑器及其配套测试、根目录公告工作文件、版本配置草稿和本地素材不进入源码仓库。公告功能源码、通用 JSON 示例、项目介绍和界面图片正常保留。检查脚本也会拒绝被强行加入暂存区的本地专用文件。

已有的 `远程配置编辑器.html` 是公开配置 JSON 的静态辅助工具，与其测试一起保留，不包含后台站点源码。

上传前检查：

```powershell
python tool/check_public_files.py
# git add 后检查暂存内容
python tool/check_public_files.py --staged
```

`.gitignore` 对已经跟踪的文件不生效，因此两项检查都要通过。CI 也会检查 Git 索引中的实际内容；它不会自动移除文件、提交或推送代码。

GitHub Actions 生成的 APK、EXE 和便携包单独上传 **Releases**，不要加入源码历史。同版本维护包需要用户手动安装；推送新版本更新时递增版本和构建号。

## 验证与恢复准备

本地收尾运行 `py -3 tool/verify.py source`，跨模块版本完成后运行 `py -3 tool/verify.py full`（其他系统用 Python 3.10+ 的 `python3`）；暂存后另跑公开文件索引检查。该入口失败即停止，运行记录在 `.local/verification/`；它不推送、不发布，也不代替各平台原生测试、构建和安装验收。CI 的正式构建依赖 `checks` 成功，继续保留这项门禁。

发布前将“待发布”内容整理到与 `pubspec.yaml` 一致的版本，核对目标平台产物、安装包哈希、覆盖安装、更新链接及必要的人工体验。README 下载区描述的是实际已发布版本，不能只因本地版本变化就提前改成未发布版本。

切换远程更新配置前，在 `.local/` 保存上一份有效配置和本次配置、产物哈希与验证记录。恢复配置可停止分发坏包，但不能假定已升级客户端会自动降级：Android 版本限制、本地状态格式和旧版兼容性必须单独验证；必要时以更高构建号发布修复版，不覆盖旧标签。

启动失败的恢复沿用 [本地状态恢复](LOCAL-STATE-RECOVERY.md) 和现有故障页；验收备份恢复、保留旧数据初始化及日志导出。进程级原生崩溃可能无法进入 Flutter 恢复页，发布说明应保留可在浏览器访问的安装包与修复路径。

## 远程更新配置

更新字段中的 `version` 和 `build` 应与安装包一致；`downloadUrl` 填纯 HTTPS 地址，不能写成 Markdown 链接。

若同一个配置地址还服务 **0.3.47**，保持 `schema: 1`，`clouds` 只填写旧版认识的 8 项：`baidu`、`quark`、`uc`、`pan123`、`c139`、`tianyi`、`xunlei`、`lanzou`。新网盘字段会让旧版拒绝整份配置；省略这些字段时，新版中的新网盘仍默认开启。`config/control.example.json` 包含新网盘字段，仅供新版参考。

每次发布递增 `revision`，公告变更时更新 `id`，兼容旧版缓存判断。主配置访问失败后，应用才检查 GitHub 备用更新。

## GitHub Actions 打包

仓库配置 `release` Environment，在 Secrets 中设置：

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Secrets 中另设 `ASTERLINK_CONTROL_URL`、`UMENG_APPKEY`；Variables 中设置 `ASTERLINK_GITHUB_REPO`、`ASTERLINK_APPLICATION_ID` 和 `UMENG_CHANNEL`。正式版包名为 `com.asterlink.app`；正式配置不完整时工作流会停止，本机参数不会自动上传。

修改 `pubspec.yaml` 后运行 `dart tool/sync_version.dart --write`。推送与完整版本一致的新标签，或在 Actions → Build signed release → Run workflow 选择分支，均可生成正式签名安装包。完成后下载 `release-android`、`release-windows`、`release-windows-arm64` 附件；工作流不会自动创建或发布 Release。需要发布时，再单独上传附件并发布版本。不要覆盖已发布标签。只有正式 Release 会被备用更新识别。

每个平台附件包含各自产物的 `SHA256SUMS.txt`，由已有打包工具生成。下载多个平台时分目录保存校验文件，避免同名文件互相覆盖。验收记录写明 GitHub run URL、提交 SHA、版本、对应平台结果和安装测试；只引用同一次提交的构建结果。本机仍有未提交修改时，远端旧提交的绿灯不能证明这些修改已通过。

手动运行时可将 `targets` 选择为 `android-windows`，仅构建 Android ARM64 与 Windows x64；默认 `all` 和标签触发仍包含 Windows ARM64。无论选择哪些目标，均须通过同一套源码检查与测试。
