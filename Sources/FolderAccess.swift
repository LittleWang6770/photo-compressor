import Foundation

struct FolderSource: Identifiable, Sendable {
    let id: UUID
    var url: URL
    var bookmark: Data?
    var accessIssue: String?
    var writeAuthorized: Bool

    init(url:URL,id:UUID = UUID(),bookmark:Data? = nil,accessIssue:String? = nil,writeAuthorized:Bool = false) {
        self.id = id; self.url = url; self.bookmark = bookmark; self.accessIssue = accessIssue; self.writeAuthorized = writeAuthorized
    }
}

enum FolderAccess {
    static let key = "compressor.photoFolderBookmark.v1"
    static let listKey = "compressor.photoFolders.v1"
    private struct Stored: Codable {
        let id: UUID
        let path: String
        let bookmark: Data?
        var writeAuthorized: Bool? = nil
    }
    static func identity(_ url:URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
    static func bookmark(_ url:URL,writable:Bool = false) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let options:URL.BookmarkCreationOptions = writable ? [.withSecurityScope] : [.withSecurityScope,.securityScopeAllowOnlyReadAccess]
        return try url.bookmarkData(options:options,includingResourceValuesForKeys:nil,relativeTo:nil)
    }
    static func make(_ url:URL,writable:Bool = true) -> FolderSource {
        do { return FolderSource(url:url,bookmark:try bookmark(url,writable:writable),writeAuthorized:writable) }
        catch { return FolderSource(url:url,accessIssue:"本次可用，但权限未能保存；下次请重新添加。",writeAuthorized:writable) }
    }
    static func refresh(_ source:FolderSource) -> FolderSource {
        guard let data = source.bookmark else { return source }
        var result = source
        do {
            var stale = false
            result.url = try URL(resolvingBookmarkData:data,options:[.withSecurityScope,.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale)
            if stale { result.bookmark = try bookmark(result.url,writable:source.writeAuthorized) }
            result.accessIssue = nil
        } catch {
            // Keep the path and bookmark: an external disk may simply be offline.
            result.accessIssue = "暂时无法访问，请连接磁盘；权限失效时请重新添加。"
        }
        return result
    }
    static func save(_ sources:[FolderSource],defaults:UserDefaults = .standard) throws {
        let stored = sources.map { Stored(id:$0.id,path:$0.url.path,bookmark:$0.bookmark,writeAuthorized:$0.bookmark != nil && $0.writeAuthorized) }
        defaults.set(try JSONEncoder().encode(stored),forKey:listKey)
        defaults.removeObject(forKey:key)
    }
    static func restore(defaults:UserDefaults = .standard) throws -> [FolderSource] {
        if let data = defaults.data(forKey:listKey) {
            return try JSONDecoder().decode([Stored].self,from:data).map {
                refresh(FolderSource(url:URL(fileURLWithPath:$0.path),id:$0.id,bookmark:$0.bookmark,writeAuthorized:$0.writeAuthorized ?? false))
            }
        }
        guard let data = defaults.data(forKey:key) else { return [] }
        var stale = false
        let url = try URL(resolvingBookmarkData:data,options:[.withSecurityScope,.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale)
        let source = FolderSource(url:url,bookmark:stale ? try bookmark(url) : data)
        try save([source],defaults:defaults)
        return [source]
    }
}
