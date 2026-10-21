import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func friendlyError(_ error: Error) -> String {
    let e = error as NSError
    if e.domain == NSCocoaErrorDomain {
        switch e.code {
        case CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileWriteVolumeReadOnly.rawValue:
            return "输出位置不可写，请重新选择保存位置或检查磁盘权限。"
        case CocoaError.fileWriteOutOfSpace.rawValue:
            return "目标磁盘空间不足，请释放空间后继续。"
        case CocoaError.fileReadNoPermission.rawValue:
            return "无法读取文件，请检查来源文件夹的访问权限。"
        case CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue:
            return "文件或文件夹已离线、移动或删除，请检查磁盘后重新扫描。"
        default: break
        }
    }
    return error.localizedDescription
}

final class StopToken: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func check() throws { if isCancelled { throw CancellationError() } }
}

enum OutputMode: String, Codable, CaseIterable {
    case copy, replaceOriginals
    var title: String { self == .copy ? "导出副本" : "原地覆盖原件" }
}

struct CompressionSettings: Codable, Equatable {
    var quality = 82
    var recursive = true
    var workers = 0
    var onlySmaller = true
    var outputMode: OutputMode = .copy
    var allowRecompression = false
    var isDangerous: Bool { outputMode == .replaceOriginals || allowRecompression }
}

struct CompressionStamp: Codable, Equatable {
    let app: String
    let version: Int
    let compressed: Bool
    let quality: Int
    let sourceID: String
    let originalBytes: Int64
    let date: Date
    var generation: Int? = nil
    var previousQuality: Int? = nil
    var firstOriginalBytes: Int64? = nil
    var compressionCount: Int { max(1, generation ?? 1) }
}

struct PhotoJob: Codable {
    let source: URL
    let relative: String
    let rootKey: String
    let bytes: Int64
    let modified: Date
    let created: Date?
    let pixels: Int64
    var snapshot: FileSnapshot? = nil
    var previousCompression: CompressionStamp? = nil
    var sourceID: String {
        let identity = snapshot.map { "|\($0.device)|\($0.inode)|\($0.changedSeconds)|\($0.changedNanos)" } ?? ""
        return digest(source.path + "|\(bytes)|\(modified.timeIntervalSince1970)" + identity)
    }
}

struct ScanSummary {
    var count = 0
    var bytes: Int64 = 0
    var skipped = 0
    var failed = 0
    var previouslyCompressed = 0
    var largestPixels: Int64 = 0
    var samples: [PhotoJob] = []
    var issues: [String] = []
    var manifest: URL
    var report: URL
    mutating func noteIssue(_ message:String) {
        if issues.count < 3 && !issues.contains(message) { issues.append(message) }
    }
}

func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

final class JSONLines {
    let handle: FileHandle
    private let lock = NSLock()
    init(_ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw AppFailure("无法建立任务文件：\(url.path)") }
        handle = try FileHandle(forWritingTo: url)
    }
    func append<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        lock.lock(); defer { lock.unlock() }
        try handle.write(contentsOf: data); try handle.write(contentsOf: Data([10]))
    }
    func close() throws { try handle.synchronize(); try handle.close() }
    func flush() throws { lock.lock(); defer { lock.unlock() }; try handle.synchronize() }
    deinit { try? handle.close() }
}

// A disk-backed queue: the number of paths in memory stays bounded for TB-scale libraries.
final class JobReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var eof = false
    private let lock = NSLock()
    init(_ url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    func next() throws -> PhotoJob? {
        lock.lock(); defer { lock.unlock() }
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                let job = try JSONDecoder().decode(PhotoJob.self, from: line)
                buffer.removeSubrange(...newline)
                return job
            }
            if eof { return nil }
            let block = try handle.read(upToCount: 64 * 1024) ?? Data()
            if block.isEmpty { eof = true } else { buffer.append(block) }
        }
    }
    deinit { try? handle.close() }
}

struct LogEntry: Codable {
    var path: String
    var status: String
    var detail: String
    var inputBytes: Int64 = 0
    var outputBytes: Int64 = 0
}

enum JPEGSegments {
    static let prefix = Data("PhotoCompressor.v1\0".utf8)
    struct Header { var metadata: [Data]; var coding: [Data]; var tail: UInt64; var mpf: MPFIndex? }

    // CIPA MPF is also used by ordinary camera JPEGs for large previews.
    // Only baseline-primary + JPEG-thumbnail combinations are accepted here.
    struct MPFIndex {
        struct Entry { let field: Int; let size: UInt64; let absoluteOffset: UInt64 }
        let segmentIndex: Int
        let tiffBase: UInt64
        let littleEndian: Bool
        let entries: [Entry]
        var primarySize: UInt64 { entries[0].size }

        init(segment: Data, segmentIndex: Int, markerOffset: UInt64, fileSize: UInt64) throws {
            let invalid = AppFailure("MPF 预览索引无效或数据不完整，未处理此照片")
            // Segment includes marker/length (4), MPF signature (4), then TIFF.
            let base = 8
            guard segment.count >= base + 8 else { throw invalid }
            let order = Array(segment[base..<base+2])
            guard order == [0x49,0x49] || order == [0x4d,0x4d] else { throw invalid }
            let little = order == [0x49,0x49]
            func uint(_ offset: Int, _ count: Int) throws -> UInt64 {
                guard offset >= 0, offset <= segment.count - count else { throw invalid }
                let bytes = Array(segment[offset..<offset+count])
                let ordered = little ? Array(bytes.reversed()) : bytes
                return ordered.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
            guard try uint(base+2,2) == 42 else { throw invalid }
            let ifd = base + Int(try uint(base+4,4))
            let count = Int(try uint(ifd,2))
            guard count <= (segment.count - min(segment.count,ifd+2)) / 12 else { throw invalid }
            var imageCount: Int?, entryStart: Int?, entryBytes: Int?
            for i in 0..<count {
                let field = ifd+2+i*12
                switch try uint(field,2) {
                case 0xb001:
                    guard try uint(field+2,2) == 4, try uint(field+4,4) == 1 else { throw invalid }
                    imageCount = Int(try uint(field+8,4))
                case 0xb002:
                    guard try uint(field+2,2) == 7 else { throw invalid }
                    entryBytes = Int(try uint(field+4,4)); entryStart = base + Int(try uint(field+8,4))
                default: break
                }
            }
            guard let imageCount, let entryStart, let entryBytes, imageCount > 0, imageCount <= 64,
                  entryBytes == imageCount*16, entryStart >= base, entryStart <= segment.count-entryBytes else { throw invalid }
            var parsed: [Entry] = []
            let tiffBase = markerOffset + 8
            for i in 0..<imageCount {
                let field = entryStart+i*16
                let attr = try uint(field,4), kind = attr & 0x00ffffff
                guard attr & 0x07000000 == 0 else { throw invalid }
                if i == 0 {
                    guard kind == 0x030000, try uint(field+8,4) == 0 else { throw invalid }
                } else if !(0x010001...0x010005).contains(kind) {
                    throw AppFailure("MPF 含 HDR 增益图、全景或多视角图像，本版暂不重编码")
                }
                let size = try uint(field+4,4), relative = try uint(field+8,4)
                let absolute = i == 0 ? 0 : tiffBase+relative
                guard size >= 4, absolute <= fileSize, size <= fileSize-absolute else { throw invalid }
                parsed.append(Entry(field:field,size:size,absoluteOffset:absolute))
            }
            guard parsed[0].size >= markerOffset + UInt64(segment.count), parsed.dropFirst().allSatisfy({ $0.absoluteOffset >= parsed[0].size }) else { throw invalid }
            self.segmentIndex = segmentIndex; self.tiffBase = tiffBase; littleEndian = little; entries = parsed
        }
        func validateBoundaries(_ reader: FileHandle) throws {
            for entry in entries {
                try reader.seek(toOffset: entry.absoluteOffset)
                guard try reader.read(upToCount:2) == Data([0xff,0xd8]) else { throw AppFailure("MPF 关联预览的起始位置无效") }
                try reader.seek(toOffset:entry.absoluteOffset+entry.size-2)
                guard try reader.read(upToCount:2) == Data([0xff,0xd9]) else { throw AppFailure("MPF 关联预览的结束位置无效") }
            }
        }
        func relocated(_ segment: Data, primarySize: UInt64, tiffBase newBase: UInt64) throws -> Data {
            var data = segment
            func write(_ value: UInt64, at offset: Int) throws {
                guard value <= UInt32.max else { throw AppFailure("MPF 输出超出 4 GB 索引范围") }
                for i in 0..<4 { data[offset+i] = UInt8((value >> (littleEndian ? i*8 : (3-i)*8)) & 255) }
            }
            try write(primarySize,at:entries[0].field+4)
            for entry in entries.dropFirst() {
                let absolute = primarySize + (entry.absoluteOffset-self.primarySize)
                guard absolute >= newBase else { throw AppFailure("MPF 预览重定位失败") }
                try write(absolute-newBase,at:entry.field+8)
            }
            return data
        }
    }
    static func header(_ url: URL) throws -> Header {
        let f = try FileHandle(forReadingFrom: url); defer { try? f.close() }
        func read(_ count: Int) throws -> Data {
            let data = try f.read(upToCount: count) ?? Data()
            guard data.count == count else { throw AppFailure("JPEG 数据不完整") }
            return data
        }
        guard try read(2) == Data([0xff, 0xd8]) else { throw AppFailure("JPEG 文件头无效") }
        let fileSize = try f.seekToEnd(); try f.seek(toOffset:2)
        var result = Header(metadata: [], coding: [], tail: 0, mpf: nil)
        while true {
            let offset = try f.offset()
            guard try read(1)[0] == 0xff else { throw AppFailure("JPEG 标记无效") }
            var marker = try read(1)[0]
            while marker == 0xff { marker = try read(1)[0] }
            if marker == 0xda {
                result.tail = offset
                if let mpf = result.mpf {
                    guard mpf.primarySize > offset else { throw AppFailure("MPF 主图长度无效") }
                    try mpf.validateBoundaries(f)
                }
                return result
            }
            guard marker != 0xd9 && marker != 0 && !(0xd0...0xd8).contains(marker) else { throw AppFailure("不支持的 JPEG 结构") }
            let length = try read(2)
            let n = Int(length[0]) * 256 + Int(length[1])
            guard n >= 2 else { throw AppFailure("JPEG 数据段长度无效") }
            let payload = try read(n - 2)
            let segment = Data([0xff, marker]) + length + payload
            if (0xe0...0xef).contains(marker) || marker == 0xfe {
                if marker == 0xe2 && payload.starts(with: Data("MPF\0".utf8)) {
                    guard result.mpf == nil else { throw AppFailure("MPF 含多个索引，暂不重编码") }
                    result.mpf = try MPFIndex(segment:segment,segmentIndex:result.metadata.count,markerOffset:offset,fileSize:fileSize)
                }
                result.metadata.append(segment)
            } else { result.coding.append(segment) }
        }
    }
    static func stamp(_ header: Header) -> CompressionStamp? {
        for segment in header.metadata.reversed() where segment.count > 4 + prefix.count {
            if segment[1] == 0xef && segment.dropFirst(4).starts(with: prefix) {
                if let stamp = try? JSONDecoder().decode(CompressionStamp.self, from: segment.dropFirst(4 + prefix.count)), stamp.app == "local.photo-compressor", stamp.version == 1, stamp.compressed { return stamp }
            }
        }
        return nil
    }
    static func isOwnStamp(_ segment:Data) -> Bool {
        segment.count >= 4+prefix.count && segment[1] == 0xef && segment.dropFirst(4).starts(with:prefix)
    }
    @discardableResult static func transplant(original: Header, source: URL, encoded: URL, output: URL, stamp: CompressionStamp, token: StopToken) throws -> [Data] {
        let encodedHeader = try header(encoded)
        let encodedSize = (try FileManager.default.attributesOfItem(atPath:encoded.path)[.size] as! NSNumber).uint64Value
        let payload = prefix + (try JSONEncoder().encode(stamp))
        let n = payload.count + 2
        let stampSegment = Data([0xff, 0xef, UInt8(n >> 8), UInt8(n & 255)]) + payload
        let encodedEnd = encodedHeader.mpf?.primarySize ?? encodedSize
        var metadata = original.metadata.filter { !isOwnStamp($0) }
        let primarySize = UInt64(2 + metadata.reduce(0) { $0+$1.count } + stampSegment.count + encodedHeader.coding.reduce(0) { $0+$1.count }) + encodedEnd-encodedHeader.tail
        if let mpf = original.mpf {
            let index = original.metadata.prefix(mpf.segmentIndex).filter { !isOwnStamp($0) }.count
            let newBase = UInt64(2 + metadata.prefix(index).reduce(0) { $0+$1.count } + 8)
            metadata[index] = try mpf.relocated(metadata[index],primarySize:primarySize,tiffBase:newBase)
        }
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw AppFailure("无法写入临时文件") }
        let writer = try FileHandle(forWritingTo: output); defer { try? writer.close() }
        try writer.write(contentsOf: Data([0xff, 0xd8]))
        for segment in metadata { try writer.write(contentsOf: segment) }
        try writer.write(contentsOf:stampSegment)
        for segment in encodedHeader.coding { try writer.write(contentsOf: segment) }
        let reader = try FileHandle(forReadingFrom: encoded); defer { try? reader.close() }
        try reader.seek(toOffset: encodedHeader.tail)
        func copy(_ handle:FileHandle, count:UInt64) throws {
            var remaining = count
            while remaining > 0 {
                try token.check()
                let block = try handle.read(upToCount:Int(min(remaining,1024*1024))) ?? Data()
                guard !block.isEmpty else { throw AppFailure("关联预览复制不完整") }
                try writer.write(contentsOf:block); remaining -= UInt64(block.count)
            }
        }
        try copy(reader,count:encodedEnd-encodedHeader.tail)
        if let mpf = original.mpf {
            let originalReader = try FileHandle(forReadingFrom:source); defer { try? originalReader.close() }
            let total = try originalReader.seekToEnd(); try originalReader.seek(toOffset:mpf.primarySize)
            try copy(originalReader,count:total-mpf.primarySize)
        }
        try writer.synchronize()
        return metadata
    }
    static func verifyTrailer(original:Header, source:URL, result:Header, output:URL, token:StopToken) throws {
        guard let before = original.mpf else { return }
        guard let after = result.mpf, before.entries.count == after.entries.count else { throw AppFailure("MPF 预览数量校验失败") }
        let a = try FileHandle(forReadingFrom:source), b = try FileHandle(forReadingFrom:output)
        defer { try? a.close(); try? b.close() }
        try a.seek(toOffset:before.primarySize); try b.seek(toOffset:after.primarySize)
        while true {
            try token.check()
            let x = try a.read(upToCount:1024*1024) ?? Data(), y = try b.read(upToCount:1024*1024) ?? Data()
            guard x == y else { throw AppFailure("MPF 原始预览数据校验失败，未导出") }
            if x.isEmpty { return }
        }
    }
}

enum PhotoCodec {
    static let namespace = "https://photo-compressor.local/ns/1.0/"
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif"]
    static func open(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw AppFailure("无法读取图片") }
        return source
    }
    static func properties(_ source: CGImageSource) throws -> [String: Any] {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { throw AppFailure("无法读取图片属性") }
        return props
    }
    static func marker(_ url: URL) throws -> CompressionStamp? {
        let source = try open(url)
        if CGImageSourceGetType(source) as String? == UTType.jpeg.identifier { return JPEGSegments.stamp(try JPEGSegments.header(url)) }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, "pc:Stamp" as CFString) as String?, let data = value.data(using: .utf8),
              let stamp = try? JSONDecoder().decode(CompressionStamp.self, from: data), stamp.app == "local.photo-compressor", stamp.version == 1, stamp.compressed else { return nil }
        return stamp
    }
    static func inspect(_ url: URL, root: URL, allowRecompression:Bool = false) throws -> PhotoJob? {
        let source = try open(url)
        guard let type = CGImageSourceGetType(source) as String?, [UTType.jpeg.identifier, UTType.heic.identifier, "public.heif"].contains(type) else { throw AppFailure("文件扩展名与编码不符") }
        let jpegHeader = type == UTType.jpeg.identifier ? try JPEGSegments.header(url) : nil
        guard CGImageSourceGetCount(source) == 1 || jpegHeader?.mpf != nil else { throw AppFailure("多帧 / 连拍照片暂不重编码") }
        let props = try properties(source)
        guard let w = props[kCGImagePropertyPixelWidth as String] as? Int64, let h = props[kCGImagePropertyPixelHeight as String] as? Int64, w > 0, h > 0, w * h <= 150_000_000 else { throw AppFailure("尺寸无效或超过 1.5 亿像素") }
        let previous = try marker(url)
        if previous != nil && !allowRecompression { return nil }
        // Preserve 10/16-bit and HDR data by refusing an unverified reduction to 8-bit SDR.
        if (props[kCGImagePropertyDepth as String] as? Int ?? 8) > 8 { throw AppFailure("高位深照片暂不重编码，避免动态范围损失") }
        if let model = props[kCGImagePropertyColorModel as String] as? String, model != "RGB" && model != "Gray" { throw AppFailure("特殊色彩模型暂不重编码，避免颜色偏差") }
        if type != UTType.jpeg.identifier {
            for kind in auxiliaryKinds where CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kind) != nil {
                throw AppFailure("含 HDR / 深度等辅助图像，本版保留原件并跳过")
            }
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return PhotoJob(source: url, relative: String(url.path.dropFirst(root.path.count + 1)), rootKey: root.lastPathComponent + "-" + digest(root.path).prefix(8), bytes: (attrs[.size] as? NSNumber)?.int64Value ?? 0, modified: attrs[.modificationDate] as? Date ?? .distantPast, created: attrs[.creationDate] as? Date, pixels: w * h, snapshot:try FileSnapshot.read(url),previousCompression:previous)
    }
    static var auxiliaryKinds: [CFString] {
        var kinds = [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte, kCGImageAuxiliaryDataTypeHDRGainMap]
        if #available(macOS 15, *) { kinds.append(kCGImageAuxiliaryDataTypeISOGainMap) }
        return kinds
    }
    static func unchanged(_ job: PhotoJob) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: job.source.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.size] as? NSNumber)?.int64Value == job.bytes, let date = attrs[.modificationDate] as? Date, abs(date.timeIntervalSince(job.modified)) < 0.001 else { throw AppFailure("源文件在扫描后发生变化，请重新扫描") }
        if let expected = job.snapshot, try FileSnapshot.read(job.source) != expected { throw AppFailure("源文件在扫描后发生变化，请重新扫描") }
    }
    static func encode(_ job: PhotoJob, quality: Int, to output: URL, token: StopToken, allowRecompression:Bool = false) throws -> Int64 {
        try token.check(); try unchanged(job)
        let previous = try marker(job.source)
        guard previous == nil || allowRecompression else { throw AppFailure("照片已有压缩标记，请明确开启「允许重复压缩」后重新统计") }
        guard previous?.compressionCount ?? 0 < Int.max else { throw AppFailure("压缩次数标记无效") }
        let source = try open(job.source)
        guard let type = CGImageSourceGetType(source), let dest = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else { throw AppFailure("系统不支持此格式的编码") }
        let stamp = CompressionStamp(app: "local.photo-compressor", version: 1, compressed: true, quality: quality, sourceID: job.sourceID, originalBytes: job.bytes, date: Date(),generation:(previous?.compressionCount ?? 0)+1,previousQuality:previous?.quality,firstOriginalBytes:previous?.firstOriginalBytes ?? previous?.originalBytes ?? job.bytes)
        let isJPEG = type as String == UTType.jpeg.identifier
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100]
        if !isJPEG {
            let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
            guard (previous != nil || CGImageMetadataRegisterNamespaceForPrefix(meta, namespace as CFString, "pc" as CFString, nil)),
                  CGImageMetadataSetValueWithPath(meta, nil, "pc:Stamp" as CFString, String(data: try JSONEncoder().encode(stamp), encoding: .utf8)! as CFString) else { throw AppFailure("无法写入压缩标记") }
            for (key,value) in try properties(source) { options[key as CFString] = value }
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AppFailure("HEIC 解码失败") }
            CGImageDestinationAddImageAndMetadata(dest, image, meta, options as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(dest, source, 0, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw AppFailure("压缩编码失败（可能是空间不足）") }
        try token.check()
        if isJPEG {
            let originalHeader = try JPEGSegments.header(job.source)
            let transplanted = output.appendingPathExtension("metadata")
            defer { try? FileManager.default.removeItem(at: transplanted) }
            let expectedMetadata = try JPEGSegments.transplant(original: originalHeader, source:job.source, encoded: output, output: transplanted, stamp: stamp, token: token)
            try FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: transplanted, to: output)
            let resultHeader = try JPEGSegments.header(output)
            guard Array(resultHeader.metadata.prefix(expectedMetadata.count)) == expectedMetadata else { throw AppFailure("原始元数据段校验失败") }
            try JPEGSegments.verifyTrailer(original:originalHeader,source:job.source,result:resultHeader,output:output,token:token)
        }
        let result = try open(output)
        guard let decoded = CGImageSourceCreateImageAtIndex(result, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary), decoded.width > 0 else { throw AppFailure("压缩文件解码校验失败") }
        let before = try properties(source), after = try properties(result)
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation] {
            guard (before[key as String] as? NSNumber ?? 1) == (after[key as String] as? NSNumber ?? 1) else { throw AppFailure("尺寸或方向校验失败") }
        }
        // ImageIO may normalize HEIF metadata. Reject a result if any original EXIF/GPS/TIFF/IPTC field changes.
        if !isJPEG {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary] {
                if let old = before[key as String] as? NSDictionary {
                    guard let new = after[key as String] as? NSDictionary, old.isEqual(to: new as! [AnyHashable: Any]) else { throw AppFailure("系统未完整保留 \(key)，已放弃此副本") }
                }
            }
            if let old = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                let new = CGImageSourceCopyMetadataAtIndex(result, 0, nil)
                var equal = true
                CGImageMetadataEnumerateTagsUsingBlock(old, nil, nil) { path, tag in
                    if CGImageMetadataTagCopyNamespace(tag) as String? == namespace && CGImageMetadataTagCopyName(tag) as String? == "Stamp" { return true }
                    guard let new, let newTag = CGImageMetadataCopyTagWithPath(new, nil, path), CFEqual(CGImageMetadataTagCopyValue(tag), CGImageMetadataTagCopyValue(newTag)) else { equal = false; return false }
                    return true
                }
                guard equal else { throw AppFailure("扩展元数据校验失败，已放弃此副本") }
            }
        }
        guard try marker(output) == stamp else { throw AppFailure("压缩标记回读校验失败") }
        try unchanged(job)
        var attrs: [FileAttributeKey: Any] = [.modificationDate: job.modified]
        if let created = job.created { attrs[.creationDate] = created }
        try FileManager.default.setAttributes(attrs, ofItemAtPath: output.path)
        let finalAttrs = try FileManager.default.attributesOfItem(atPath: output.path)
        guard let mtime = finalAttrs[.modificationDate] as? Date, abs(mtime.timeIntervalSince(job.modified)) < 2.1 else { throw AppFailure("文件修改时间校验失败") }
        if let created = job.created, let saved = finalAttrs[.creationDate] as? Date, abs(saved.timeIntervalSince(created)) >= 2.1 { throw AppFailure("文件创建时间校验失败") }
        return (finalAttrs[.size] as? NSNumber)?.int64Value ?? 0
    }
    static func displayImage(_ url: URL) throws -> CGImage {
        let source = try open(url), props = try properties(source)
        let size = max(props[kCGImagePropertyPixelWidth as String] as? Int ?? 0, props[kCGImagePropertyPixelHeight as String] as? Int ?? 0)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw AppFailure("预览解码失败") }
        return image
    }
}

enum Scanner {
    static func roots(_ urls: [URL], recursive: Bool) -> [URL] {
        var result: [URL] = []
        for url in urls.map({ $0.standardizedFileURL.resolvingSymlinksInPath() }).sorted(by: { $0.path.count < $1.path.count }) {
            if !result.contains(where: { $0.path == url.path || (recursive && url.path.hasPrefix($0.path + "/")) }) { result.append(url) }
        }
        return result
    }
    static func scan(roots input: [URL], settings: CompressionSettings, workspace: URL, token: StopToken, update: (ScanSummary, String) -> Void) throws -> ScanSummary {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var summary = ScanSummary(manifest: workspace.appendingPathComponent("jobs.jsonl"), report: workspace.appendingPathComponent("scan.jsonl"))
        let writer = try JSONLines(summary.manifest), log = try JSONLines(summary.report)
        defer { try? writer.close(); try? log.close() }
        var accessible = 0
        var last = ProcessInfo.processInfo.systemUptime
        for root in roots(input, recursive: settings.recursive) {
            try token.check()
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue, FileManager.default.isReadableFile(atPath: root.path) else {
                summary.failed += 1; summary.noteIssue("文件夹无法访问，请连接磁盘或重新添加来源。")
                try log.append(LogEntry(path: root.path, status: "error", detail: "文件夹无法访问")); continue
            }
            accessible += 1
            var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            if !settings.recursive { options.insert(.skipsSubdirectoryDescendants) }
            var enumerationError: Error?
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .isPackageKey]
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options, errorHandler: { url, error in
                summary.failed += 1
                summary.noteIssue(friendlyError(error))
                do { try log.append(LogEntry(path: url.path, status: "error", detail: error.localizedDescription)) } catch { enumerationError = error }
                return !token.isCancelled
            }) else { throw AppFailure("无法遍历 \(root.path)") }
            for case let url as URL in enumerator {
                try autoreleasepool {
                defer {
                    if ProcessInfo.processInfo.systemUptime - last > 0.2 { update(summary, url.path); last = ProcessInfo.processInfo.systemUptime }
                }
                try token.check()
                if let enumerationError { throw enumerationError }
                let values = try url.resourceValues(forKeys: Set(keys))
                // FileManager does not descend into symlinks. Calling skipDescendants on a
                // symlink file can accidentally skip the next real directory on macOS.
                if values.isSymbolicLink == true { return }
                guard values.isRegularFile == true else { return }
                let ext = url.pathExtension.lowercased()
                if !PhotoCodec.supportedExtensions.contains(ext) {
                    summary.skipped += 1
                    try log.append(LogEntry(path: url.path, status: "unsupported", detail: "本版压缩 JPEG / HEIC；其他格式不修改"))
                    return
                }
                    let inspected: PhotoJob?
                    do {
                        inspected = try PhotoCodec.inspect(url, root: root,allowRecompression:settings.allowRecompression)
                    } catch let error as CancellationError { throw error }
                    catch {
                        summary.failed += 1
                        summary.noteIssue(friendlyError(error))
                        try log.append(LogEntry(path: url.path, status: "protectedOrUnreadable", detail: friendlyError(error)))
                        return
                    }
                    guard let job = inspected else {
                        summary.skipped += 1; try log.append(LogEntry(path: url.path, status: "alreadyCompressed", detail: "存在本应用压缩标记")); return
                    }
                    try writer.append(job)
                    summary.count += 1; summary.bytes += job.bytes; summary.largestPixels = max(summary.largestPixels, job.pixels)
                    if job.previousCompression != nil { summary.previouslyCompressed += 1 }
                    // Keep only the largest eligible source, with a stable tie-break.
                    if let largest = summary.samples.first {
                        if job.bytes > largest.bytes || (job.bytes == largest.bytes && job.source.path < largest.source.path) { summary.samples = [job] }
                    } else { summary.samples = [job] }
                }
            }
            if let enumerationError { throw enumerationError }
        }
        guard accessible > 0 else { throw AppFailure("所有来源均无法访问，请检查磁盘和权限") }
        try writer.close(); try log.close()
        update(summary, "扫描完成")
        return summary
    }
}

struct BatchProgress {
    var done = 0
    var written = 0
    var skipped = 0
    var failed = 0
    var saved: Int64 = 0
    var inputBytes: Int64 = 0
    var current = ""
    var workers = 1
    var replaced = 0
}

enum BatchEngine {
    static func workerCount(settings: CompressionSettings, largestPixels: Int64) -> Int {
        let memoryBudget = min(UInt64(3 * 1024 * 1024 * 1024), ProcessInfo.processInfo.physicalMemory / 5)
        let perWorker = UInt64(max(1, largestPixels)) * 20 + 96 * 1024 * 1024
        let memoryLimit = max(1, Int(memoryBudget / perWorker))
        let requested = settings.workers == 0 ? min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)) : settings.workers
        return max(1, min(requested, memoryLimit, 8))
    }
    private static func process(_ job:PhotoJob, destination:URL?, settings:CompressionSettings, token:StopToken, log:JSONLines) throws -> LogEntry {
        let fm = FileManager.default
        var entry = LogEntry(path:job.source.path,status:"error",detail:"",inputBytes:job.bytes)
        try token.check()
        let replacing = settings.outputMode == .replaceOriginals
        let parent = replacing ? job.source.deletingLastPathComponent() : destination!
        let candidates = replacing ? [] : FilePublication.copyCandidates(job,destination:parent,quality:settings.quality)
        if !replacing {
            guard !candidates.contains(where:{ $0.standardizedFileURL.path == job.source.standardizedFileURL.path }) else { throw AppFailure("副本目标与源照片相同，请选择其他输出位置或明确使用原地覆盖") }
            if let existing = candidates.first(where:{ FilePublication.isCompletedCopy($0,job:job,quality:settings.quality) }) {
                entry.status = "existing"; entry.detail = "已完成的同源同质量副本："+existing.path; return entry
            }
        }
        let available = try parent.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let available, available < max(job.bytes*3,128*1024*1024) { throw AppFailure("目标磁盘剩余空间不足") }
        let temporary = parent.appendingPathComponent(".pc-\(UUID().uuidString).\(job.source.pathExtension)")
        var preserveTemporary = false
        defer { if !preserveTemporary { try? fm.removeItem(at:temporary) } }
        let size = try PhotoCodec.encode(job,quality:settings.quality,to:temporary,token:token,allowRecompression:settings.allowRecompression)
        if settings.onlySmaller && size >= job.bytes {
            entry.status = "noSaving"; entry.detail = replacing ? "体积未变小，原件未覆盖" : "体积未变小，不导出副本"; return entry
        }
        try token.check()
        if replacing {
            // Persist intent before any destructive commit. A full audit record survives rescan/relaunch.
            try log.append(LogEntry(path:job.source.path,status:"replacePrepared",detail:"质量 \(settings.quality)，即将原子替换",inputBytes:job.bytes,outputBytes:size))
            try log.flush()
            let note = try FilePublication.replaceOriginal(temporary,job:job,token:token,preserveTemporary:&preserveTemporary)
            entry.status = "replaced"; entry.detail = job.source.path + (note.map { "；"+$0 } ?? "")
        } else if let target = try FilePublication.publishCopy(temporary,candidates:candidates,job:job,quality:settings.quality,token:token) {
            entry.status = "written"; entry.detail = target.path
        } else {
            entry.status = "existing"; entry.detail = "同源同质量副本已经完成"; return entry
        }
        entry.outputBytes = size
        return entry
    }
    static func run(scan:ScanSummary, destination:URL?, settings:CompressionSettings, token:StopToken, reportDirectory:URL? = nil, update:@escaping (BatchProgress)->Void) throws -> (BatchProgress,URL) {
        let fm = FileManager.default
        let target:URL?
        if settings.outputMode == .copy {
            guard let destination else { throw AppFailure("请先选择保存副本的位置") }
            try fm.createDirectory(at:destination,withIntermediateDirectories:true)
            target = destination.resolvingSymlinksInPath()
        } else { target = nil }
        let runDir = reportDirectory ?? target ?? scan.manifest.deletingLastPathComponent()
        try fm.createDirectory(at:runDir,withIntermediateDirectories:true)
        let reportURL = runDir.appendingPathComponent(".photo-compressor-batch-\(UUID().uuidString).jsonl")
        let log = try JSONLines(reportURL)
        defer { try? log.close() }
        let reader = try JobReader(scan.manifest)
        let workers = workerCount(settings:settings,largestPixels:scan.largestPixels)
        let lock = NSLock(), group = DispatchGroup()
        var progress = BatchProgress(workers:workers)
        var fatalError:Error?
        var lastUpdate = 0.0
        for _ in 0..<workers {
            group.enter()
            DispatchQueue.global(qos:.userInitiated).async {
                defer { group.leave() }
                do {
                    while !token.isCancelled, let job = try reader.next() {
                        let entry:LogEntry
                        do {
                            entry = try autoreleasepool { try process(job,destination:target,settings:settings,token:token,log:log) }
                        } catch is CancellationError { break }
                        catch { entry = LogEntry(path:job.source.path,status:"error",detail:friendlyError(error),inputBytes:job.bytes) }
                        try log.append(entry)
                        lock.lock()
                        progress.done += 1; progress.inputBytes += job.bytes; progress.current = job.source.path
                        switch entry.status {
                        case "written","replaced":
                            progress.written += 1; progress.saved += job.bytes-entry.outputBytes
                            if entry.status == "replaced" { progress.replaced += 1 }
                        case "error": progress.failed += 1
                        default: progress.skipped += 1
                        }
                        let now = ProcessInfo.processInfo.systemUptime
                        if now-lastUpdate > 0.15 { update(progress); lastUpdate = now }
                        lock.unlock()
                    }
                } catch {
                    lock.lock(); fatalError = error; lock.unlock(); token.cancel()
                }
            }
        }
        group.wait()
        if let fatalError { throw fatalError }
        try log.close(); update(progress)
        return (progress,reportURL)
    }
}
