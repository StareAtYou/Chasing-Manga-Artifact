# 漫画源验证记录

验证日期：2026-10-02。环境：macOS 15.7.7、Swift 6.2.4、Command Line Tools；未安装完整 Xcode。
测试工具使用真实 URLSession 请求和 ImageIO 解码。网页样本测试只证明解析规则；在线阅读与原站内容授权分别处理。

| 来源 | 首页 | 浏览 | 搜索 | 详情/目录 | 正文 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| [瓜子漫画](https://www.guazimanhua.com/) | HTTP 200 | 41 项 | 2 项 | 812 章 | 首/末章各首/末图已解码：True | 单作品验证，通过时仍只算有限验证 |
| [DM5](https://www.dm5.com/) | HTTP 200 | 237 项 | 25 项 | 公开样本 4 章 | 首/末章首/末图已解码 | 有限验证；部分作品存在地区或付费限制 |
| [漫画站](https://www.manhuazhan.com/) | HTTP 200 | 136 项 | 本次安全验证页；早前 HTTP 500 | 991 章 | 首/末章首/末图已解码 | 有限验证，Mac WebKit + HTTP |

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

## DM5

指定样本 `https://www.dm5.com/manhua-yirenzhixia/` 的详情页明确表示当前地区无法观看，保留访问失败，不从推荐列表替换成该作品目录。正常公开样本 `https://www.dm5.com/manhua-xiangzizhixia-yili/` 共 4 章；首章 39 页、末章 36 页，首/末图均真实解码成功。

公开 reader 使用每页 `chapterfun.ashx` 返回的固定数据模板。实现只解包字符串字典并提取 pix / pvalue / 后缀字面量，不执行接口 JavaScript；页号作为稳定身份。每页均从网站当前上下文获取地址；源未声明失效时间时不伪造 expiresAt。合成检查验证签名刷新后身份不变；真实过期后恢复与双作品源级验证仍待完成。

## 漫画站

样本 `https://www.manhuazhan.com/comic/219424`（非人哉）取得 991 章目录；首章 36 页、末章 4 页，首/末图均正常解码。本机普通 URLSession 可访问；早期 urllib 和网页工具失败不代表本机原站读取失败。
搜索的 HTTP 200 内容为“安全验证”，会明确报告需要验证，不能当作零条结果启用搜索能力。
正文 `DATA` 由网站正常脚本生成 `newImgs`。App 在隔离 WebKit 会话中正常加载网页，通过内置固定表达式读取该数组，不运行自定义插件或执行接口代码。实际 Mac WebKit 探针已验证；iOS 会话与界面交互仍待验证。

## 最终复测

2026-10-02 最终探针三站 readingVerified 均为 true，原始非敏感结果见 source-probes/。瓜子浏览 41 项、DM5 浏览 237 项；漫画站搜索本次安全验证，仍不启用搜索。每站只验证一部作品，保持有限验证。
