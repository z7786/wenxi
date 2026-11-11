# 跨盘传输

在文件菜单选择跨盘传输后，任务进入「传输 → 上传」。目标支持秒传且来源有可信 MD5 时先请求秒传，未命中则下载原文件后上传；目前 MD5 目标为 123、天翼和光鸭。秒传是否命中由网盘接口决定。

中转下载与上传分别显示进度。下载完成后校验文件，同时计算 MD5 和 SHA-1，上传复用这些结果。上传失败时保留完整的中转文件；继续任务会先核对来源、目标和缓存校验值，目标已确认保存则跳过，否则重新上传。缓存损坏或丢失会重新下载。部分下载及校验失败的文件会清理。

删除任务记录会清理该任务的中转文件。「清理失败跨盘传输」批量删除已停止且仍可重试的任务和缓存，保留正在传输的任务及目标网盘中的文件。

实现对比参考 OpenList `25da9901f50fecc6cb417193680f0f3cfe2ffcdd` 和 AList `92e745360766cce32564f94a468cb576f577d27e` 的跨存储复制及驱动上传逻辑。两者跨存储也通过源文件流和目标驱动上传；123 使用 MD5，夸克/UC 使用 MD5 与 SHA-1，115 还要求 SHA-1 和片段校验。应用不会把普通 ETag 或不匹配的摘要当成通用秒传凭证。

参考：[OpenList 跨存储复制](https://github.com/OpenListTeam/OpenList/blob/25da9901f50fecc6cb417193680f0f3cfe2ffcdd/internal/fs/copy_move.go)、[OpenList 夸克/UC 上传](https://github.com/OpenListTeam/OpenList/blob/25da9901f50fecc6cb417193680f0f3cfe2ffcdd/drivers/quark_uc/driver.go)、[AList 跨存储复制](https://github.com/AlistGo/alist/blob/92e745360766cce32564f94a468cb576f577d27e/internal/fs/copy.go)。
