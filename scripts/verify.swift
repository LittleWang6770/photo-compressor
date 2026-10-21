import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@main struct Verification {
    static var assertions = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw AppFailure("验证失败：" + message) }
    }
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("build/verification-\(UUID().uuidString)")
        try fm.createDirectory(at:base,withIntermediateDirectories:true)
        let root = base.appendingPathComponent("来源"), child = root.appendingPathComponent("子文件夹")
        let output = base.appendingPathComponent("输出")
        try fm.createDirectory(at:child,withIntermediateDirectories:true)
        try fm.createDirectory(at:output,withIntermediateDirectories:true)
        let jpeg = root.appendingPathComponent("元数据.jpg"), heic = root.appendingPathComponent("元数据.heic")
        try DemoFactory.make(at:jpeg,width:1200,height:800)
        try DemoFactory.make(at:heic,width:1200,height:800,type:.heic)
        let rotated = child.appendingPathComponent("方向6.jpg")
        try DemoFactory.make(at:rotated,width:800,height:600,orientation:6)
        try Data("not a jpeg".utf8).write(to:root.appendingPathComponent("损坏.jpg"))
        try Data("raw placeholder".utf8).write(to:root.appendingPathComponent("原始.RAW"))
        try fm.createSymbolicLink(at:child.appendingPathComponent("loop"),withDestinationURL:root)
        try fm.createSymbolicLink(at:root.appendingPathComponent("link.jpg"),withDestinationURL:jpeg)
        try DemoFactory.make(at:root.appendingPathComponent(".hidden.jpg"),width:64,height:64)
        let originalHash = SHA256.hash(data:try Data(contentsOf:jpeg))
        let settings = CompressionSettings()
        let shallow = try Scanner.scan(roots:[root],settings:CompressionSettings(recursive:false),workspace:base.appendingPathComponent("scan-shallow"),token:StopToken()) { _,_ in }
        try check(shallow.count == 2 && shallow.failed == 1 && shallow.skipped == 1,"当前层范围与损坏文件计数：\(shallow.count), \(shallow.failed), \(shallow.skipped)")
        let scan = try Scanner.scan(roots:[root,child,root],settings:settings,workspace:base.appendingPathComponent("scan-deep"),token:StopToken()) { _,_ in }
        try check(scan.count == 3 && scan.failed == 1,"递归、重叠来源与符号链接去重")
        let reader = try JobReader(scan.manifest)
        var jobs: [PhotoJob] = []
        while let job = try reader.next() { jobs.append(job) }
        try check(jobs.count == scan.count,"磁盘清单完整回读")
        try check(scan.samples.count == 1 && scan.samples.first?.bytes == jobs.map(\.bytes).max(),"默认样张是所有待处理照片中体积最大的一张")
        let jpegJob = jobs.first { $0.source == jpeg }!, heicJob = jobs.first { $0.source == heic }!
        let temp = base.appendingPathComponent("encoded.jpg")
        let encodedBytes = try PhotoCodec.encode(jpegJob,quality:62,to:temp,token:StopToken())
        try check(encodedBytes < jpegJob.bytes,"JPEG 真实压缩收益")
        let stamp = try PhotoCodec.marker(temp)
        try check(stamp?.quality == 62 && stamp?.compressed == true && stamp?.sourceID == jpegJob.sourceID,"JPEG 独立标记回读")
        let originalSegments = try JPEGSegments.header(jpeg).metadata
        let encodedSegments = try JPEGSegments.header(temp).metadata
        try check(Array(encodedSegments.prefix(originalSegments.count)) == originalSegments,"EXIF/GPS/ICC/XMP 数据段逐字节不变")
        try check(SHA256.hash(data:try Data(contentsOf:jpeg)) == originalHash,"源文件逐字节不变")
        let originalProps = try PhotoCodec.properties(PhotoCodec.open(jpeg)), resultProps = try PhotoCodec.properties(PhotoCodec.open(temp))
        for key in [kCGImagePropertyExifDictionary,kCGImagePropertyGPSDictionary,kCGImagePropertyTIFFDictionary] {
            try check((originalProps[key as String] as! NSDictionary).isEqual(resultProps[key as String] as! NSDictionary),"JPEG \(key) 保留")
        }
        let originalAttrs = try fm.attributesOfItem(atPath:jpeg.path), resultAttrs = try fm.attributesOfItem(atPath:temp.path)
        for key in [FileAttributeKey.creationDate,.modificationDate] {
            try check(abs((originalAttrs[key] as! Date).timeIntervalSince(resultAttrs[key] as! Date)) < 0.01,"文件 \(key) 保留")
        }
        try check(try PhotoCodec.inspect(temp,root:base) == nil,"标记副本不能作为新源二次压缩")
        let htemp = base.appendingPathComponent("encoded.heic")
        let hbytes = try PhotoCodec.encode(heicJob,quality:62,to:htemp,token:StopToken())
        try check(hbytes > 0 && PhotoCodec.marker(htemp)?.quality == 62,"HEIC 元数据与 XMP 标记")
        let rotJob = jobs.first { $0.source == rotated }!
        let rtemp = base.appendingPathComponent("rotated.jpg")
        _ = try PhotoCodec.encode(rotJob,quality:82,to:rtemp,token:StopToken())
        let image = try PhotoCodec.displayImage(rtemp)
        try check(image.width == 600 && image.height == 800,"方向 6 的全尺寸预览正确旋转")
        let low = base.appendingPathComponent("low.jpg"), high = base.appendingPathComponent("high.jpg")
        let lowSize = try PhotoCodec.encode(jpegJob,quality:1,to:low,token:StopToken())
        let highSize = try PhotoCodec.encode(jpegJob,quality:100,to:high,token:StopToken())
        try check(lowSize < highSize,"质量 1 与 100 控制实际编码")
        let singleManifest = base.appendingPathComponent("single.jsonl")
        let singleWriter = try JSONLines(singleManifest); try singleWriter.append(jpegJob); try singleWriter.close()
        let singleScan = ScanSummary(count:1,bytes:jpegJob.bytes,largestPixels:jpegJob.pixels,samples:[jpegJob],manifest:singleManifest,report:scan.report)
        let (noSaving,_) = try BatchEngine.run(scan:singleScan,destination:base.appendingPathComponent("无收益"),settings:CompressionSettings(quality:100),token:StopToken()) { _ in }
        try check(noSaving.skipped == 1 && noSaving.written == 0 && noSaving.failed == 0,"变大时不导出副本")
        let (allowedLarger,_) = try BatchEngine.run(scan:singleScan,destination:base.appendingPathComponent("允许变大"),settings:CompressionSettings(quality:100,onlySmaller:false),token:StopToken()) { _ in }
        try check(allowedLarger.written == 1,"高级开关允许用户选择导出变大副本")
        let (batch,report) = try BatchEngine.run(scan:scan,destination:output,settings:settings,token:StopToken()) { _ in }
        try check(batch.done == 3 && batch.written == 3 && batch.failed == 0,"并行批处理结果：\(batch)")
        try check(try String(contentsOf:report,encoding:.utf8).split(separator:"\n").count == 3,"每张照片有持久记录")
        let (resumed,_) = try BatchEngine.run(scan:scan,destination:output,settings:settings,token:StopToken()) { _ in }
        try check(resumed.written == 0 && resumed.skipped == 3 && resumed.failed == 0,"断点续跑跳过完成副本")
        let midwayToken = StopToken()
        let (midway,_) = try BatchEngine.run(scan:scan,destination:base.appendingPathComponent("中途取消"),settings:CompressionSettings(workers:1),token:midwayToken) { result in
            if result.done >= 1 { midwayToken.cancel() }
        }
        try check(midway.done == 1 && midway.written == 1,"中途取消仅保留已完成且已校验的输出")
        let cancelled = StopToken(); cancelled.cancel()
        let cancelledOut = base.appendingPathComponent("取消输出")
        let (stopped,_) = try BatchEngine.run(scan:scan,destination:cancelledOut,settings:settings,token:cancelled) { _ in }
        try check(stopped.done == 0 && stopped.written == 0,"取消不发布输出")
        let target = output.appendingPathComponent(jpegJob.source.lastPathComponent)
        try fm.removeItem(at:target)
        let sentinel = Data("existing user file".utf8); try sentinel.write(to:target)
        let (conflict,_) = try BatchEngine.run(scan:scan,destination:output,settings:settings,token:StopToken()) { _ in }
        try check(conflict.written == 1 && conflict.skipped == 2 && conflict.failed == 0 && (try Data(contentsOf:target)) == sentinel,"同名已有文件不覆盖，自动使用备用文件名")
        let attrs = try fm.attributesOfItem(atPath:jpeg.path)
        try fm.setAttributes([.modificationDate:Date()],ofItemAtPath:jpeg.path)
        do { _ = try PhotoCodec.encode(jpegJob,quality:80,to:base.appendingPathComponent("changed.jpg"),token:StopToken()); throw AppFailure("源文件变化未被拒绝") }
        catch { try check(error.localizedDescription.contains("扫描后发生变化"),"扫描后变化保护") }
        try fm.setAttributes([.modificationDate:attrs[.modificationDate]!],ofItemAtPath:jpeg.path)
        let constrained = BatchEngine.workerCount(settings:CompressionSettings(workers:8),largestPixels:150_000_000)
        try check(constrained == 1,"大照片限制并行内存")
        let fresh = try Scanner.scan(roots:[base.appendingPathComponent("不存在"),root],settings:settings,workspace:base.appendingPathComponent("partial"),token:StopToken()) { _,_ in }
        try check(fresh.count == 3 && fresh.failed == 2,"不可访问来源不阻止其他来源")
        try check(fresh.issues.count > 0 && fresh.issues.count <= 3,"无效照片原因直接用于界面反馈，条目数受限")
        let mpfDir = base.appendingPathComponent("MPF-cameras")
        try fm.createDirectory(at:mpfDir,withIntermediateDirectories:true)
        for little in [true,false] {
            let camera = mpfDir.appendingPathComponent(little ? "little.jpg" : "big.jpg")
            try makeMPFFixture(primary:jpeg,preview:rotated,to:camera,little:little)
            let job = try PhotoCodec.inspect(camera,root:mpfDir)
            try check(job != nil,"普通相机 MPF 大预览 JPEG 不能被当成 HDR 拒绝")
            let encoded = base.appendingPathComponent(little ? "mpf-little-out.jpg" : "mpf-big-out.jpg")
            _ = try PhotoCodec.encode(job!,quality:62,to:encoded,token:StopToken())
            let before = try JPEGSegments.header(camera), after = try JPEGSegments.header(encoded)
            try check(before.mpf?.entries.count == 2 && after.mpf?.entries.count == 2,"重编码后 MPF 预览索引仍能读取")
            try check(before.mpf!.primarySize != after.mpf!.primarySize,"MPF 主图长度随压缩结果更新")
            let src = try Data(contentsOf:camera), out = try Data(contentsOf:encoded)
            try check(src.dropFirst(Int(before.mpf!.primarySize)) == out.dropFirst(Int(after.mpf!.primarySize)),"原有大预览、间隙和尾部数据逐字节保留")
            for i in before.metadata.indices where i != before.mpf!.segmentIndex {
                try check(before.metadata[i] == after.metadata[i],"MPF 相机的其他 EXIF/ICC 段保持原样")
            }
            try check(try PhotoCodec.marker(encoded)?.quality == 62,"MPF JPEG 压缩标记有效")
            try check(SHA256.hash(data:try Data(contentsOf:camera)) == SHA256.hash(data:src),"MPF 源文件没有被改写")
        }
        let gain = mpfDir.appendingPathComponent("gain-map.jpg")
        try makeMPFFixture(primary:jpeg,preview:rotated,to:gain,kind:0x050000)
        do { _ = try PhotoCodec.inspect(gain,root:mpfDir); throw AppFailure("HDR 增益图被误当作普通预览") }
        catch { try check(error.localizedDescription.contains("HDR 增益图"),"真正的 HDR / 多视角 MPF 仍保护") }
        let invalid = mpfDir.appendingPathComponent("invalid-index.jpg")
        try makeMPFFixture(primary:jpeg,preview:rotated,to:invalid,corruptOffset:true)
        do { _ = try PhotoCodec.inspect(invalid,root:mpfDir); throw AppFailure("损坏 MPF 偏移被放行") }
        catch { try check(error.localizedDescription.contains("MPF 预览索引无效"),"越界 MPF 偏移必须安全失败") }
        print("PASS: \(assertions) checks; fixtures and reports: \(base.path)")
        print("JPEG Q62: \(jpegJob.bytes) → \(encodedBytes) bytes; HEIC Q62: \(heicJob.bytes) → \(hbytes) bytes")
    }
}
