import Foundation
public enum SourceScope {
    public static func contains(_ document: URL, in base: URL) -> Bool {
        guard let origin = WebOrigin(base), WebOrigin(document) == origin, document.user == nil, document.password == nil else { return false }
        let basePath = (URLComponents(url: base, resolvingAgainstBaseURL: false)?.path ?? base.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = URLComponents(url: document, resolvingAgainstBaseURL: false)?.path ?? document.path
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return basePath.isEmpty || path == "/" + basePath || path.hasPrefix("/" + basePath + "/")
    }
}
