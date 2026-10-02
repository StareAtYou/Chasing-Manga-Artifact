import Foundation
public enum MangaError: Error, Codable, Equatable, Sendable, LocalizedError {
    case invalidURL, networkUnavailable, timedOut, requiresLogin, verificationRequired, chapterUnavailable, regionRestricted
    case accessRestricted(Int), parseMismatch(String), unsupported(String), expiredResource, invalidImage, diskFull, storage(String)
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入有效的 HTTP 或 HTTPS 网站地址"
        case .networkUnavailable: "网络不可用"
        case .timedOut: "请求超时，请重试"
        case .requiresLogin: "该来源需要登录"
        case .verificationRequired: "请打开来源页面完成验证"
        case .regionRestricted: "作品有版权地区限制，请在来源允许的地区阅读"
        case .chapterUnavailable: "该章节暂时不可访问"
        case .accessRestricted(let status): "来源限制访问（HTTP \(status)）"
        case .parseMismatch(let message): "解析方式不匹配：\(message)"
        case .unsupported(let message): "尚未支持：\(message)"
        case .expiredResource: "图片地址已过期，请重新获取"
        case .invalidImage: "正文图片损坏或格式不受支持"
        case .diskFull: "存储空间不足，下载已暂停"
        case .storage(let message): "本地资料保存失败：\(message)"
        }
    }
}
