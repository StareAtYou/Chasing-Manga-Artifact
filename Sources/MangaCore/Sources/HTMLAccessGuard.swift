import Foundation
import SwiftSoup
public enum HTMLAccessGuard {
    public static func check(_ document: Document) throws {
        let title = try document.title().lowercased()
        if ["just a moment", "access denied", "验证", "captcha"].contains(where: title.contains) { throw MangaError.verificationRequired }
        if ["login required", "请登录"].contains(where: title.contains) { throw MangaError.requiresLogin }
    }
}
