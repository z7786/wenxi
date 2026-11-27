# Windows 程序路径兜底与播放器启动隔离

## 日志依据

`logs/文析助手-logs-2.3.5-235-1795253101655766.zip` 包含 Windows
2.3.5+235 的四个启动会话，共 16 次 `app.bootstrap_failed`。
`Platform.resolvedExecutable` 底层返回空值，触发
`type 'Null' is not a subtype of type 'String'`；堆栈位于
`WindowsPlayerComponents.initializeRuntime`。
没有进入 `app.runtime_ready`，不能据此判断为播放中原生崩溃。

## 行为变化

- 应用获取程序路径时先尝试 Dart 的 resolvedExecutable。
  抛错、空值或无效路径时，Windows 使用 `GetModuleFileNameW(NULL, …)`
  获取宿主 EXE 的 Unicode 完整路径，再以绝对的原始 executable 为最后兜底。
  不将相对路径或仅文件名拼接到工作目录。
- 播放库、组件解压工具、Gopeed、独立播放窗口和设备互联防火墙
  使用统一程序路径方法。完整组件正常加载时不获取精简库路径。
- 主界面及账号、任务恢复不再等待播放器加载。主界面提交首帧后预加载一次；
  失败记录为 `player.runtime_load_failed`，不触发启动失败页。
- 打开音视频时复用同一个初始化任务。失败后显示“重试播放器”，
  支持外部播放器的平台同时显示对应入口，原有下载入口可继续使用。
  缺库时先终止内置播放，不提前解析取链、转存或创建解码器。
- 重试保留原有播放记录和账号；成功初始化后不重复加载。
  退出或切集取消当前等待，不取消其他播放可能需要的共享加载。
- Gopeed 在实际调用时获取路径，创建服务、查看任务记录不需要加载下载组件。
  路径获取失败后允许后续重试；已成功的路径复用。
- 组件安装、删除、选择与后台初始化互相隔离，防止加载时替换库文件。
- 桌面窗口附加配置及显示操作的异常记录为窗口错误，不阻断主界面。
  应用主窗口仍由原生 runner 管理。

本次不改变本地账号、设置、下载记录的格式，不执行迁移或删除。
本地状态无法安全读取、已有实例占用等原有启动保护保留。

## 验证

- 静态检查覆盖所有改动源码和测试。
- Windows 实际调用 `GetModuleFileNameW`，核对与运行宿主路径一致；
  模拟 resolvedExecutable 的 TypeError、空值、相对路径，
  覆盖中文、UNC、扩展路径和 macOS bundle 路径。
- 模拟同步/异步播放器失败和未完成加载：仍进入主界面、使用解析输入框、
  切换传输页面并保留暂停任务进度；窗口配置和显示失败亦可进入。
- 验证初始化合并、失败重试、播放记录续播、下载取链、外部播放器入口、
  加载期间退出，以及组件安装/选择与初始化的互斥。
- 使用本地 Gopeed 实际解析种子并下载 2 MiB 文件，
  在模拟播放器加载失败的状态下校验 SHA-256 和保存字节均一致。
- 338 项相关回归通过，覆盖启动数据恢复、播放、切集、外部播放、
  最近播放、下载边播、BT 播放和播放器界面。
  最终另有 56 项针对路径、窗口、组件并发、初始化恢复的检查通过。

本次没有编译或上传安装包。尚未在日志对应用户机器复测。
Dart 级隔离不能捕获进程级原生崩溃，不将此改动描述为所有闪退的修复。

## 接口参考

- [Dart Platform.resolvedExecutable](https://api.dart.dev/stable/latest/dart-io/Platform/resolvedExecutable.html)
- [Microsoft GetModuleFileNameW](https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulefilenamew)

本轮文档工具网络连接失败，已直接读取官方文档并核对本地依赖实现。
