# 本地文档预览

网盘文件列表的“预览”和下载管理中的“预览文档”使用同一套本地阅读器。远程文档尚未下载时，先显示文件大小与“下载并预览”，用户确认后才通过原有下载管理器保存并打开文档。已有可读文件直接打开；暂停或失败的同一任务保持原状态，由用户点击继续或重试。返回预览页不会取消已经开始的普通下载，可在传输管理中继续操作。

## 格式与能力

| 格式 | 阅读组件 | 当前能力 |
| --- | --- | --- |
| PDF | [Mozilla PDF.js](https://github.com/mozilla/pdf.js)，6.5.438 legacy build | 单页阅读、页码跳转、放大缩小、适合宽度、密码输入 |
| DOCX | [docx-preview](https://github.com/VolodymyrBaydalka/docxjs)，0.4.1 | 中文、图片、表格、页眉页脚、已有分页、缩放和适宽 |
| XLS、XLSX、XLSM、XLSB、ODS | [SheetJS CE](https://git.sheetjs.com/sheetjs/sheetjs)，0.20.3 | 工作表切换、每页 200 行、单元格内容、缩放；不执行公式与宏 |
| PPTX | [PPTXjs](https://github.com/meshesha/PPTXjs)，2.0.0 | 单张幻灯片、上一页/下一页、缩放和适合屏幕；不播放音视频和动画 |
| TXT、Markdown、代码 | 原有 `TextPreview` | 本地文本阅读、Markdown 显示及代码高亮 |
| DOC、PPT、RTF 等其他办公格式 | 系统外部应用 | 下载后提供“用其他应用打开” |

Office 预览用于阅读，不提供编辑，也不保证复杂排版与 Microsoft Office 完全一致。DOCX 依据文件已有分页，不能精确重排所有长文档；表格只预览前 10000 行和 256 列，超出时明确提示。PDF 支持密码输入；加密 Office 文档交给外部应用。

## 下载和恢复

- 复用 `CloudRepository.planDownload`、`DownloadManager`、保存位置选择、百度下载确认和移动流量确认，不另外实现网盘取链或下载协议。
- 按网盘、账号、个人/分享、盘空间、分享 ID 和文件 ID 匹配任务，同时核对已知大小、修改时间和哈希，避免跨账号、跨分享或跨版本误用文件。临时下载地址、Cookie 和分享 Token 不作为文件身份。
- 已完成记录必须能实际读取保存文件。文件已删除时再次确认后重新下载；权限不足时提示检查保存目录，不静默创建重复文件。连续或并发预览同一文件复用任务。
- 下载中可暂停、继续或重试。退出只移除页面观察者，任务保留现有断点和恢复行为；不修改旧用户数据格式或全局默认打开方式。
- 内置阅读失败、格式不支持或文件超过预览上限时，保留下载文件，提供重试及外部打开；阅读器初始化与播放组件独立，不阻断解析、下载或主界面。

## 本地读取和资源预算

`DocumentServer` 只绑定 `127.0.0.1` 的随机端口，每页使用独立随机路径凭据，并检查 Host、Origin、Referer 和请求方法。页面、字体、解码资源与 JavaScript 均随安装包提供，预览不向 Google、Microsoft 或其他在线文档站上传文件。下载阶段仍使用所选网盘的既有接口。

Android 的下载目录 `content://` 文件复用 `LanFiles` 的 SAF 读取句柄和范围读取，不将大 PDF 再复制到缓存。关闭页面、渲染失败或重试时关闭本地服务；底层读取用 `finally` 释放句柄。文件服务每次读取前检查文件是否变化。

PDF 上限 256 MiB，采用 worker 解析、范围读取和单个可见区域画布，清晰画布最多 6 Mi 像素（约 24 MiB RGBA）、单边不超过 4096 像素。放大、滚动、窗口尺寸及系统双指缩放变化时，按设备像素比与 `visualViewport.scale` 重新绘制当前区域，不通过缩小整页画布再拉伸来满足内存上限。另保留最多 1 Mi 像素的整页底图，快速滚动时显示过渡内容而非空白；停止操作后显示清晰绘制。滚动区域保留少量边缘缓冲，连续滚动合并请求并等待当前绘制，切页/改倍率取消旧绘制；切页与关闭释放旧画布及页面缓存。

DOCX、表格与 PPTX 使用 DOM/SVG 阅读，缩放采用 CSS `zoom` 重新排版，避免将原尺寸的栅格层整体拉伸。PDF、DOCX、表格与 PPTX 提供最高 5 倍按钮缩放，手机仍可使用系统双指缩放。低分辨率扫描页和文档中的原始图片受源像素限制，重新绘制不能生成原文件没有的细节。

Office 压缩文件上限 32 MiB；解析前在 isolate 检查 ZIP 目录，展开总量上限 96 MiB、单条目 32 MiB、最多 10000 条目。超限交给外部应用。

CSP 阻止外部网络、iframe、媒体和文档脚本；PDF 不渲染活动注释或 XFA，DOCX 不渲染 HTML altChunks，表格只输出文本，文档超链接不能跳离本地阅读页。只启用渲染器所需的本地脚本和 WASM，不加载 PDF 的 QuickJS 资源。

## 维护和验证

生产代码集中在 `lib/preview/`、`document_preview.dart` 和 `document_download_preview.dart`；入口复用 `preview_page.dart` 和 `downloads_page.dart`。本地网页资源在 `assets/documents/`；固定组件文件及 SHA-256 记录在 `vendor/manifest.json`，许可全文与上游来源见 [第三方声明](../assets/licenses/THIRD_PARTY_NOTICES.md)。更新组件时一并核对资源、版本、许可、CSP 与最低浏览器兼容性，不直接跟随滚动 CDN。

相关回归入口：

```powershell
py -3 tool/verify.py test test/document_server_test.dart test/document_downloads_test.dart test/document_preview_widget_test.dart test/image_preview_page_test.dart test/windows_downloads_test.dart test/resource_search_widget_test.dart --concurrency 1
node --test tool/tests/document-viewer.test.cjs
```

回归覆盖首次预览不下载、确认/取消、任务复用、账号与版本隔离、暂停/重试、退出后继续下载、文件丢失/变化/权限、HTTP 范围、SAF 句柄关闭、阅读失败、菜单和窄屏/宽屏。JavaScript 回归检查手机高像素密度、系统双指缩放、可见区域覆盖与画布预算；仍应运行语法检查并用合成 PDF、DOCX、XLSX、PPTX 样本检查实际排版、分页、主题和外部网络阻断。自动 widget 测试的假 WebView 不能代替渲染验证。Android 真机另验旧版 System WebView、密码输入、文档打开/返回、长文档内存、下载目录权限和覆盖升级。
