# 外部网盘链接打开

“我的 → 链接唤起”管理 Android 的网盘解析入口。已注册 15 类可解析网盘：夸克、UC、百度、阿里、天翼、移动、联通、光鸭、迅雷、115、123、蓝奏、城通、小飞机、PikPak。

## Android

- 点击已关联域名的分享地址，进入解析页并识别网盘和提取码。
- 其他 App 可以通过系统分享菜单选择“文析助手解析”。
- 文本选择菜单提供“用文析助手解析”，保留整段分享文案。
- 各入口通过独立 `activity-alias` 注册；设置开关直接更新 PackageManager 的组件状态，重启后保留，不会结束正在运行的下载。
- 关闭某个网盘后，该网盘的普通 HTTP/HTTPS 分享超链接不再唤起应用；全部关闭后，下载器、播放器也不会接管普通网页或 HTML 页面。明确文件类型的下载、视频播放仍保留，分享菜单、选中文字和网页唤起协议由各自开关控制。
- Android 12 及以上的第三方域名通常需要用户在系统“默认打开 → 打开支持的链接”中授权。应用不会为不属于自己的网盘域名声明已验证归属；部分应用的内置浏览器仍需使用分享菜单或外部浏览器。
- 未注册的备用域名仍可使用分享菜单、剪贴板或下面的网页唤起协议。

外部分享与协议链接进入现有解析页，由用户选择账号解析或已配置的公益解析后发起解析。此入口不请求后台号池转存。

## 网页与 Windows

Android 与 Windows 共用以下接口。Windows 安装程序注册 `wenxi` 协议；原有 `wenxi://download` 和 `--download` 仍兼容。

```text
wenxi://resolve?url=<encodeURIComponent(分享链接)>&pwd=<可选提取码>
```

`url` 必须是完整 HTTP/HTTPS 地址，仅 URL 编码一次。可选 `pwd` 接受 1–12 位字母或数字；已经嵌在分享地址内的提取码保留原有识别优先级。原地址的查询参数及 fragment 保持完整。

网页按钮示例：

```html
<a id="open-in-wenxi">用文析助手打开</a>
<script>
  const shareUrl = 'https://pan.quark.cn/s/abc123';
  const target = new URL('wenxi://resolve');
  target.searchParams.set('url', shareUrl);
  target.searchParams.set('pwd', '1234'); // 没有提取码可省略
  document.querySelector('#open-in-wenxi').href = target.href;
</script>
```

浏览器会询问是否打开软件。Windows 不会接管所有普通 HTTPS 网盘链接；网站需要提供上述唤起按钮，也可继续通过复制链接后的剪贴板识别进入解析。便携版需要安装版先注册协议。

非法动作、本地文件路径、重复 `url`、错误转义、控制字符及异常提取码会被拒绝。软件已运行时，Windows 通过原有单实例消息转发，Android 通过原有 Intent 队列接收；不会因同一次冷启动重复消费链接。

## 参考

参考项目：[YunX](https://github.com/CYQawa/YunX)，源码审阅版本 `31eb0ec7436faeb542012dfbe125f27a8ef70b14`。参考其 Android 系统入口设计，本项目复用自己的原生桥接、链接解析器和解析界面。

[Flutter App Links 文档](https://docs.flutter.dev/cookbook/navigation/set-up-app-links)；[Android 深层链接文档](https://developer.android.com/training/app-links/deep-linking)。
