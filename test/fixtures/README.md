# 兼容性测试样本

`player-pgs.mkv` 是 tool/fixtures/make_pgs_sample.py 生成的原创小视频，内嵌 PGS 绿色矩形图形字幕，不含第三方视频或账号信息。用于验证真实 Windows libmpv 的图形字幕解码、自动选择和手动切换，不能用文本字幕渲染测试替代。

`legacy-jvm-backup.json` 是用于验证原 JVM 备份能被 Dart 正确解密的固定样本，密码为测试代码公开使用的 `测试密码123`。

公开前已解密核验：夸克 Cookie、123 账号与密码均带有 `fixture` / `test-only` 标记，登录 UUID 为模拟值，迅雷设备标识由同一字符重复组成。它不包含真实账号或可用登录凭据。

保留固定密文可以检查跨语言加密兼容性，不能在测试运行时使用待测 Dart 加密实现重新生成它。源码扫描只按 `tool/public-fixtures.json` 中的路径、标准化为 LF 后的 SHA-256 和明确规则放行；修改内容或复制到其他路径会重新触发检查。
