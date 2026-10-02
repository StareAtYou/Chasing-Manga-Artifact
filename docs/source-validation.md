# 漫画源验证记录

验证日期：2026-10-02。环境：macOS 15.7.7、Swift 6.2.4、Command Line Tools；未安装完整 Xcode。
测试工具使用真实 URLSession 请求和 ImageIO 解码。网页样本测试只证明解析规则；在线阅读与原站内容授权分别处理。

| 来源 | 首页 | 浏览 | 搜索 | 详情/目录 | 正文 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| [瓜子漫画](https://www.guazimanhua.com/) | HTTP 200 | 40 项 | 2 项 | 812 章 | 首/末章各首/末图已解码：True | 单作品验证，通过时仍只算有限验证 |
| [DM5](https://www.dm5.com/) | 待本轮探针 | 待验证 | 待验证 | 待验证 | 待验证 | 未验收 |
| [漫画站](https://www.manhuazhan.com/) | 待本轮探针 | 待验证 | 待验证 | 待验证 | 待验证 | 未验收 |

## 瓜子漫画

正常详情：`https://www.guazimanhua.com/comic.php?id=26470`。公开搜索表单为 `/category.php?keyword=…`，目录从 `[data-chapter-list]` 提取，正文为 `img.reading-image`。
在线排查发现 `data-reader-next` 是下一章，不能作为章内分页；回归测试已覆盖，适配器不会把后续章节拼入当前章。
Python urllib 图片请求曾返回 403；本机 URLSession 重新验证的结果如下，不能将某一种客户端结果推广到所有设备或网络。

- 目录序号 0：18 页；首、末图解码成功。
- 目录序号 811：19 页；首、末图解码成功。

Mac WebKit 与 iOS 真机环境下的验证、两作品各两章的完整源级验证仍待执行。候选源首次启动不预设可用能力。

## 图片支持

本机 ImageIO 声明支持 PNG、JPEG 和 WebP（`org.webmproject.webp`）；实际校验按每张图的解码结果判断。iOS 实测待完整 Xcode。

## 额外免费源调研

[xkcd 官方 JSON](https://xkcd.com/json.html) 可提供明确的数据结构，可作为额外技术验证对象；没有自动替代用户指定的三站。[Dinosaur Comics](https://www.qwantz.com/) 与 [ComicFury](https://comicfury.com/) 可继续逐站验证。网站免费阅读不代表所有作品、章节或地区都免费，当前不作“完全免费且长期可用”的保证。
