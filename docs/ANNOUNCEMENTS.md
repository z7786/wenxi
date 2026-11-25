# 消息公告

解析页右上角的铃铛直接打开消息列表，角标显示未读数量。点击公告可查看全文，支持置顶、发布时间、外部链接、全部已读和手动刷新。原三点菜单中的打赏入口移到「我的」右上角菜单。

公告使用独立的 `announcements.json`，与原在线配置的更新检查、网盘开关和启动弹窗分别管理。原启动公告及其「7天不再显示」规则继续保留。消息详情和启动公告均支持 Markdown 图片与微信小程序按钮。

## 编辑公告

### 搜索首页公告

搜索框下方、最近搜索上方显示一条公告，与启动弹窗、消息列表独立。使用根目录的 `远程配置编辑器.html` →「搜索公告」编辑，随现有在线配置 `config.json` 的 `searchAnnouncement` 下发；不使用 `announcements.json`，也不触发启动提醒或未读角标。旧配置缺少此项时不显示。

```json
{
  "searchAnnouncement": {
    "enabled": true,
    "title": "本周精选已更新，点击查看说明",
    "content": "## 本周更新\n\n新增学习资料与精选影片。",
    "startsAt": "2026-11-25T00:00:00Z",
    "expiresAt": "2026-12-01T00:00:00Z",
    "buttonText": "查看详情",
    "buttonUrl": "https://example.com/news"
  }
}
```

- `enabled` 默认关闭；启用时 `title` 必填，最多 160 个 UTF-16 单元。`content` 选填，最多 8192，支持现有 Markdown、图片和安全链接。
- `startsAt`、`expiresAt` 可省略或留空；分别表示立即生效、持续显示。结束时间必须晚于生效时间，生效时刻显示，结束时刻隐藏。配置用严格 UTC 日期；编辑器用设备本地时间输入并转换为 UTC。
- `buttonText`（最多 24）与 `buttonUrl` 同填或同空，支持 HTTPS 和既有微信小程序链接。公告条点击先展开全文，只有用户点击详情按钮才打开链接。
- 与搜索框同宽，随页面滚动；短文本静态，长文本停留两秒后以约 24 逻辑像素/秒循环滚动。图标与箭头固定；悬停、键盘聚焦、详情打开、切页和应用后台时暂停。减少动画或无障碍导航模式下使用静态省略文本，完整内容仍可展开。
- 手机使用底部弹层，电脑使用最大宽度 760 的详情窗；支持选择文字、复制完整公告。大字体增加公告条高度，操作按钮可换行。
- 配置关闭、删除或过期后公告和占位间距一起移除。正常配置同步后按本机时间定时生效，进入前台时重新判断；离线沿用最后有效缓存及其时间窗口。无效公告字段只回退本节的旧配置，不阻断其他节。修改后按现有在线配置发布流程更新，无需额外递增公告 ID。

### 消息列表公告

复制 [JSON 示例](../config/announcements.example.json) 为自己的 `announcements.json`，使用文本编辑器修改标题、正文和显示设置。

1. 每条公告填写标题与正文，正文可使用 Markdown。
2. 按需设置置顶、显示开关、日期和底部按钮；本地 `公告编辑器.html` 可插入图片并预览。
3. 使用文末的校验命令检查文件，再上传到公告地址。

发布时间只影响显示和排序，不是定时发布。根目录的公告工作文件仅供本地维护，仓库保留通用 JSON 示例。

## 正文排版

`content` 支持 Markdown：一级至六级标题、加粗、斜体、删除线、有序/无序列表、引用、分隔线、链接、图片、代码块和表格。普通文字与换行继续兼容，列表摘要会去掉排版标记；宽表格、长代码可横向滚动。

例如：`## 使用提示`、`**重要内容**`、`[反馈问题](https://github.com/z7786/wenxi/issues)`、`![图片说明](https://example.com/image.png)`。

图片使用可公开访问的 HTTPS 直链，不支持本机路径或登录后才能读取的图片；加载失败会显示占位提示。链接仅在点击后打开。正文不会执行 HTML、脚本或内嵌网页。

## 发布文件

参考 [JSON 示例](../config/announcements.example.json) 编辑公告，发布到能够直接返回 UTF-8 JSON 的 HTTPS 地址。

```json
{
  "announcements": [
    {
      "id": "notice-001",
      "title": "软件公告",
      "content": "## 使用提示\n\n**软件完全免费**。\n\n- 查看最新公告\n- 遇到问题可前往仓库反馈",
      "publishedAt": "2026-10-10T08:00:00+08:00",
      "pinned": true,
      "enabled": true,
      "buttonText": "反馈问题",
      "buttonUrl": "https://github.com/z7786/wenxi/issues"
    }
  ]
}
```

- `title`、`content` 必填，分别最多 80 和 8192 字；其他字段可省略。
- `id` 方便维护，可以省略；不需要设置或递增 `revision`。
- `publishedAt` 支持 `2026-10-10` 或上例中带时区的完整时间。
- `pinned` 默认为 `false`；置顶优先，同组按发布时间从新到旧排列。未填时间的公告按文件中的顺序排在该组末尾。
- `enabled` 默认为 `true`。设置为 `false` 或删除该条即可撤下；`"announcements": []` 清空列表。顶层也可设 `"enabled": false` 暂停全部公告。
- `buttonText` 和 `buttonUrl` 同时填写或同时省略；支持 HTTPS 网页链接和下面的微信小程序链接，仅在用户点击时打开。

文件最多 100 条、256 KiB。部分条目格式有误时跳过该条；整个文件无效或获取失败时保留上次缓存。已读状态保存在本机，修改标题、正文或按钮后重新显示未读，调整日期、置顶或 ID 不影响已读。

## 图片与微信小程序按钮

在正文中插入 `![图片说明](https://你的图片直链)`，可以放多张图，App 会按屏幕宽度缩放，并限制解码尺寸。JSON 保存图片地址；图片文件需要单独托管。

按钮地址推荐使用小程序方生成的 **URL Link**（`https://wxaurl.cn/…` 或 `https://wxmpurl.cn/…`）。安卓一般会先打开微信官方引导页，再由用户确认进入小程序；其他平台是否能打开由浏览器及微信客户端决定。

也支持微信官方 **URL Scheme**：`weixin://dl/business/?t=…`，以及已在小程序后台启用的明文 Scheme：`weixin://dl/business/?appid=wx…&path=pages/index/index`。App 将 Scheme 交给系统打开微信；没有微信或无法唤起时会提示。公告正文里的普通链接仍只支持 HTTPS，Scheme 请填在底部按钮地址。

下面只是配置格式示例，图片地址和跳转票据必须换成真实值：

```json
{
  "title": "活动公告",
  "content": "活动详情如下：\n\n![活动图片](https://example.com/notice.png)",
  "buttonText": "打开微信小程序",
  "buttonUrl": "weixin://dl/business/?t=REPLACE_WITH_REAL_TICKET"
}
```

启动公告在原配置的 `announcement` 对象填写相同的 `content`、`buttonText` 和 `buttonUrl` 字段，并设置 `enabled: true`；本地 `远程配置编辑器.html` 同样支持编辑及预览。旧文字公告、缓存和已读状态无需迁移。

微信链接需要由小程序方生成和维护；不能用 `#小程序://…` 分享口令或小程序原始 ID 代替。链接的有效期、访问次数和开放范围由微信管理，系统返回成功仅表示已发起跳转。参考微信官方的 [URL Link](https://developers.weixin.qq.com/miniprogram/dev/framework/open-ability/url-link.html) 和 [URL Scheme](https://developers.weixin.qq.com/miniprogram/dev/framework/open-ability/url-scheme.html) 文档。

## 公告地址

正式构建脚本默认使用原配置 JSON 同目录的 `announcements.json`。自定义地址时，在本机 `.local/build-config.json` 增加：

```json
"announcementsUrl": "https://example.com/announcements.json"
```

直接运行 Flutter 时可传 `--dart-define=ASTERLINK_ANNOUNCEMENTS_URL=https://example.com/announcements.json`。未配置在线服务的公开构建不会访问作者的公告地址。

应用进入前台时检查公告，正常情况下每 15 分钟刷新，失败后间隔 1 分钟重试；进入页面、下拉或点击刷新会立即获取。后台停止定时刷新。发布公告只需更新 JSON；更换构建中配置的地址才需要重新编译。

发布前可运行：

```powershell
dart run tool/validate_announcements.dart announcements.json
```
