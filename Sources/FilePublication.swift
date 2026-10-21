import Foundation
import Darwin

struct FileSnapshot: Codable, Equatable {
    let device: Int32
    let inode: UInt64
    let bytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64
    let links: UInt16
    let permissions: UInt16
    let flags: UInt32
    let owner: UInt32
    let group: UInt32
    static func read(_ url:URL) throws -> FileSnapshot {
        var info = stat()
        guard lstat(url.path,&info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw AppFailure("目标不是普通照片文件，未写入") }
        return FileSnapshot(device:info.st_dev,inode:info.st_ino,bytes:info.st_size,
            modifiedSeconds:Int64(info.st_mtimespec.tv_sec),modifiedNanos:Int64(info.st_mtimespec.tv_nsec),
            changedSeconds:Int64(info.st_ctimespec.tv_sec),changedNanos:Int64(info.st_ctimespec.tv_nsec),
            links:info.st_nlink,permissions:info.st_mode & 0o777,flags:info.st_flags,owner:info.st_uid,group:info.st_gid)
    }
    // rename changes ctime; identity, size and mtime must still match after a swap.
    func matchesAfterRename(_ other:FileSnapshot) -> Bool {
        device == other.device && inode == other.inode && bytes == other.bytes &&
            modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos
    }
}

enum FilePublication {
    static func copyCandidates(_ job:PhotoJob, destination:URL, quality:Int) -> [URL] {
        let name = job.source.lastPathComponent
        var stem = job.source.deletingPathExtension().lastPathComponent
        let suffix = "-Q\(quality)-\(job.sourceID.prefix(12))"
        while (stem+suffix+"."+job.source.pathExtension).utf8.count > 240 && !stem.isEmpty { stem.removeLast() }
        return [destination.appendingPathComponent(name),
                destination.appendingPathComponent(stem+suffix+"."+job.source.pathExtension)]
    }
    static func isCompletedCopy(_ url:URL, job:PhotoJob, quality:Int) -> Bool {
        guard (try? FileSnapshot.read(url)) != nil, let stamp = try? PhotoCodec.marker(url) else { return false }
        return stamp.sourceID == job.sourceID && stamp.quality == quality
    }
    // O_EXCL-style publication remains safe when two workers encounter the same basename.
    static func publishCopy(_ temporary:URL, candidates:[URL], job:PhotoJob, quality:Int, token:StopToken) throws -> URL? {
        for target in candidates {
            try token.check()
            if renamex_np(temporary.path,target.path,UInt32(RENAME_EXCL)) == 0 { return target }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
            if isCompletedCopy(target,job:job,quality:quality) { return nil }
        }
        throw AppFailure("同名目标和备用文件名均已存在且标记不匹配，未覆盖任何副本")
    }
    static func replaceOriginal(_ temporary:URL, job:PhotoJob, token:StopToken, preserveTemporary:inout Bool) throws -> String? {
        let coordinator = NSFileCoordinator(filePresenter:nil)
        var coordinationError:NSError?, operationError:Error?, cleanupNote:String?
        // Hold the cooperative write coordination only for the final commit, after full encoding/verification.
        coordinator.coordinate(writingItemAt:job.source,options:.forReplacing,error:&coordinationError) { source in
            do {
                guard source.standardizedFileURL.path == job.source.standardizedFileURL.path,
                      source.deletingLastPathComponent().resolvingSymlinksInPath().path == source.deletingLastPathComponent().path else { throw AppFailure("来源目录发生变化或包含符号链接，请重新统计") }
                try token.check(); try PhotoCodec.unchanged(job)
                let expected = try FileSnapshot.read(source)
                guard expected.owner == geteuid() else { throw AppFailure("照片不属于当前用户，为保留所有权，本次未覆盖") }
                guard expected.links == 1 else { throw AppFailure("照片存在硬链接，为避免影响其他位置，本次未覆盖") }
                guard expected.flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0,
                      expected.permissions & 0o222 != 0 else { throw AppFailure("照片被锁定或设为只读，未覆盖") }
                // Preserve Finder tags / other xattrs and ACL in addition to EXIF and file dates.
                guard copyfile(source.path,temporary.path,nil,copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL)) == 0 else { throw AppFailure("无法保留文件标签或访问权限，未覆盖：\(String(cString:strerror(errno)))") }
                try FileManager.default.setAttributes([.posixPermissions:NSNumber(value:expected.permissions),.groupOwnerAccountID:NSNumber(value:expected.group)],ofItemAtPath:temporary.path)
                let encoded = try FileSnapshot.read(temporary)
                let file = try FileHandle(forWritingTo:temporary)
                try file.synchronize(); try file.close()
                try token.check(); try PhotoCodec.unchanged(job)
                // Unsupported filesystems fail before changing either file. Never fall back to truncating the source.
                guard renamex_np(temporary.path,source.path,UInt32(RENAME_SWAP)) == 0 else { throw AppFailure("目标文件系统无法安全原子替换，原件未覆盖：\(String(cString:strerror(errno)))") }
                preserveTemporary = true // This path now holds the old source, not the encoded temporary.
                do {
                    let old = try FileSnapshot.read(temporary), current = try FileSnapshot.read(source)
                    guard expected.matchesAfterRename(old), encoded.matchesAfterRename(current) else { throw AppFailure("提交时检测到文件变化") }
                } catch {
                    // Roll back only if our exact encoded file is still at the source path.
                    if let current = try? FileSnapshot.read(source), encoded.matchesAfterRename(current),
                       renamex_np(temporary.path,source.path,UInt32(RENAME_SWAP)) == 0 {
                        preserveTemporary = false
                        throw AppFailure("覆盖校验失败，已还原原件。请重新统计后重试。")
                    }
                    throw AppFailure("覆盖时发生外部修改。旧文件保留在 \(temporary.path)，请勿删除并先检查照片。")
                }
                do { try FileManager.default.removeItem(at:temporary); preserveTemporary = false }
                catch { cleanupNote = "替换已完成；旧文件未能清理，保留在 \(temporary.path)" }
            } catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        return cleanupNote
    }
}
