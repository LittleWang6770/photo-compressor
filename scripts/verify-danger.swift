import Foundation
import CryptoKit
import Darwin
import UniformTypeIdentifiers

@main struct DangerousVerification {
    static var checks = 0
    static func check(_ value:@autoclosure () throws -> Bool,_ message:String) throws {
        checks += 1; if try !value() { throw AppFailure("Danger verification: "+message) }
    }
    static func hash(_ url:URL) throws -> String { SHA256.hash(data:try Data(contentsOf:url)).map { String(format:"%02x",$0) }.joined() }
    static func scan(_ roots:[URL],_ base:URL,_ settings:CompressionSettings = CompressionSettings()) throws -> ScanSummary {
        try Scanner.scan(roots:roots,settings:settings,workspace:base.appendingPathComponent("scan-\(UUID().uuidString)"),token:StopToken()) { _,_ in }
    }
    static func images(_ root:URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter { PhotoCodec.supportedExtensions.contains($0.pathExtension.lowercased()) }
    }
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("build/danger-verification-\(UUID().uuidString)")
        let a = base.appendingPathComponent("a"), nested = a.appendingPathComponent("nested"), b = base.appendingPathComponent("b"), output = base.appendingPathComponent("flat")
        for dir in [nested,b,output] { try fm.createDirectory(at:dir,withIntermediateDirectories:true) }
        let primary = base.appendingPathComponent("fixture.jpg"), thumbnail = base.appendingPathComponent("thumbnail.jpg")
        try DemoFactory.make(at:primary,width:1200,height:800); try DemoFactory.make(at:thumbnail,width:320,height:240)
        for root in [a,nested,b] { try fm.copyItem(at:primary,to:root.appendingPathComponent("SAME.JPG")) }
        let inventory = try scan([a,b],base)
        let settings = CompressionSettings(quality:90,workers:4)
        let (first,_) = try BatchEngine.run(scan:inventory,destination:output,settings:settings,token:StopToken()) { _ in }
        try check(first.written == 3 && first.failed == 0,"并行同名源全部直接导出")
        let files = try images(output)
        try check(files.count == 3 && Set(files.map(\.lastPathComponent)).count == 3,"同名文件自动后缀且没有丢失")
        let directories = try fm.contentsOfDirectory(at:output,includingPropertiesForKeys:[.isDirectoryKey]).filter { (try? $0.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true }
        try check(directories.isEmpty,"副本位置不得出现 Qxx 或来源包装目录，包括递归输入")
        let hashes = try Dictionary(uniqueKeysWithValues:files.map { ($0,try hash($0)) })
        let (resumed,_) = try BatchEngine.run(scan:inventory,destination:output,settings:settings,token:StopToken()) { _ in }
        try check(resumed.skipped == 3 && resumed.written == 0,"带冲突后缀的副本也能断点跳过")
        let (changedQuality,_) = try BatchEngine.run(scan:inventory,destination:output,settings:CompressionSettings(quality:65),token:StopToken()) { _ in }
        try check(changedQuality.written == 3 && changedQuality.failed == 0 && images(output).count == 6,"新质量通过文件后缀区分，不需要新目录")
        for (url,old) in hashes { try check(try hash(url) == old,"不同质量不得覆盖之前的副本") }
        let prior = files[0]
        try check(try PhotoCodec.inspect(prior,root:output) == nil,"默认继续跳过已压缩源")
        let secondJob = try PhotoCodec.inspect(prior,root:output,allowRecompression:true)!
        let round2 = base.appendingPathComponent("round2.jpg"), before = try hash(prior)
        do { _ = try PhotoCodec.encode(secondJob,quality:65,to:round2,token:StopToken()); throw AppFailure("未开启重复压缩就写入") }
        catch { try check(error.localizedDescription.contains("允许重复压缩"),"编码层也强制要求重复压缩开关") }
        try check(!fm.fileExists(atPath:round2.path) && (try hash(prior)) == before,"被拒绝的二次压缩没有任何写入")
        _ = try PhotoCodec.encode(secondJob,quality:65,to:round2,token:StopToken(),allowRecompression:true)
        let secondStamp = try PhotoCodec.marker(round2)!
        try check(secondStamp.compressionCount == 2 && secondStamp.quality == 65 && secondStamp.previousQuality == 90,"二次压缩记录最新质量与次数")
        try check(secondStamp.firstOriginalBytes == secondJob.previousCompression?.originalBytes,"保留最初原始体积")
        try check(try JPEGSegments.header(round2).metadata.filter(JPEGSegments.isOwnStamp).count == 1,"JPEG 只保留一个最新应用标记")
        let round3 = base.appendingPathComponent("round3.jpg"), thirdJob = try PhotoCodec.inspect(round2,root:base,allowRecompression:true)!
        _ = try PhotoCodec.encode(thirdJob,quality:50,to:round3,token:StopToken(),allowRecompression:true)
        try check(try PhotoCodec.marker(round3)?.compressionCount == 3 && PhotoCodec.marker(round3)?.previousQuality == 65,"第三次和 N 次压缩在当前文件基础上累计")
        let markedScan = try scan([output],base,CompressionSettings(allowRecompression:true))
        try check(markedScan.count == 6 && markedScan.previouslyCompressed == 6,"开启重复压缩后重新统计所有已标记照片")

        let legacy = base.appendingPathComponent("legacy.jpg")
        let oldStamp = CompressionStamp(app:"local.photo-compressor",version:1,compressed:true,quality:90,sourceID:"legacy-id",originalBytes:123456,date:Date())
        try JPEGSegments.transplant(original:JPEGSegments.header(primary),source:primary,encoded:primary,output:legacy,stamp:oldStamp,token:StopToken())
        let legacyJob = try PhotoCodec.inspect(legacy,root:base,allowRecompression:true)!
        let migrated = base.appendingPathComponent("legacy-round2.jpg")
        _ = try PhotoCodec.encode(legacyJob,quality:65,to:migrated,token:StopToken(),allowRecompression:true)
        try check(try PhotoCodec.marker(migrated)?.compressionCount == 2 && PhotoCodec.marker(migrated)?.firstOriginalBytes == 123456,"兼容旧版本没有次数字段的标记")

        let mpf = base.appendingPathComponent("camera.jpg")
        try makeMPFFixture(primary:primary,preview:thumbnail,to:mpf)
        var currentMPF = mpf
        for (index,quality) in [90,65,50].enumerated() {
            let job = try PhotoCodec.inspect(currentMPF,root:base,allowRecompression:true)!
            let next = base.appendingPathComponent("camera-round\(index+1).jpg")
            _ = try PhotoCodec.encode(job,quality:quality,to:next,token:StopToken(),allowRecompression:index > 0)
            let originalHeader = try JPEGSegments.header(mpf), resultHeader = try JPEGSegments.header(next)
            try JPEGSegments.verifyTrailer(original:originalHeader,source:mpf,result:resultHeader,output:next,token:StopToken())
            try check(resultHeader.metadata.filter(JPEGSegments.isOwnStamp).count == 1 && PhotoCodec.marker(next)?.compressionCount == index+1,"MPF 连续压缩索引、预览和唯一标记有效")
            currentMPF = next
        }
        let heic = base.appendingPathComponent("fixture.heic")
        try DemoFactory.make(at:heic,width:800,height:600,type:.heic)
        var currentHEIC = heic
        for (index,quality) in [90,65,50].enumerated() {
            let job = try PhotoCodec.inspect(currentHEIC,root:base,allowRecompression:true)!
            let next = base.appendingPathComponent("heic-round\(index+1).heic")
            _ = try PhotoCodec.encode(job,quality:quality,to:next,token:StopToken(),allowRecompression:index > 0)
            try check(try PhotoCodec.marker(next)?.compressionCount == index+1,"HEIC 连续压缩可更新 XMP，不误报原应用标记变化")
            currentHEIC = next
        }

        let inPlace = base.appendingPathComponent("in-place")
        try fm.createDirectory(at:inPlace,withIntermediateDirectories:true)
        for url in [primary,mpf,heic] { try fm.copyItem(at:url,to:inPlace.appendingPathComponent(url.lastPathComponent)) }
        let inPlaceFiles = try images(inPlace), originals = try Dictionary(uniqueKeysWithValues:inPlaceFiles.map { ($0,try hash($0)) })
        let tagged = inPlace.appendingPathComponent(primary.lastPathComponent), xattr = "local.photo-compressor.fixture"
        let tag = Data("preserved tag".utf8)
        let setResult = tag.withUnsafeBytes { setxattr(tagged.path,xattr,$0.baseAddress,$0.count,0,0) }
        try check(setResult == 0,"合成 xattr 已建立")
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:tagged.path)
        let initialAttrs = try fm.attributesOfItem(atPath:tagged.path)
        let replacementScan = try scan([inPlace],base)
        let (replaced,report) = try BatchEngine.run(scan:replacementScan,destination:nil,settings:CompressionSettings(quality:82,outputMode:.replaceOriginals),token:StopToken()) { _ in }
        try check(replaced.replaced == 3 && replaced.written == 3 && replaced.failed == 0,"JPEG、MPF、HEIC 原地覆盖")
        for url in inPlaceFiles {
            try check(try hash(url) != originals[url] && PhotoCodec.marker(url)?.compressionCount == 1,"原路径成为校验后的压缩文件")
        }
        let finalAttrs = try fm.attributesOfItem(atPath:tagged.path)
        try check((initialAttrs[.posixPermissions] as? NSNumber) == (finalAttrs[.posixPermissions] as? NSNumber),"原地替换保留权限")
        for key in [FileAttributeKey.creationDate,.modificationDate] { try check(abs((initialAttrs[key] as! Date).timeIntervalSince(finalAttrs[key] as! Date)) < 0.01,"原地替换保留文件时间") }
        var buffer = Data(count:tag.count)
        let tagLength = buffer.withUnsafeMutableBytes { getxattr(tagged.path,xattr,$0.baseAddress,$0.count,0,0) }
        try check(tagLength == tag.count && buffer == tag,"原地替换保留 Finder 类扩展属性")
        let audit = try String(contentsOf:report,encoding:.utf8)
        try check(audit.components(separatedBy:"replacePrepared").count == 4 && audit.components(separatedBy:"replaced").count == 4,"破坏性提交前后均有审计记录")
        try check(try fm.contentsOfDirectory(atPath:inPlace.path).filter { $0.hasPrefix(".pc-") }.isEmpty,"成功后不遗留永久备份或临时原件")
        let skipped = try scan([inPlace],base)
        try check(skipped.count == 0 && skipped.skipped == 3,"原地覆盖后默认跳过，避免意外 N 次压缩")
        let repeatScan = try scan([inPlace],base,CompressionSettings(allowRecompression:true))
        let (twice,_) = try BatchEngine.run(scan:repeatScan,destination:nil,settings:CompressionSettings(quality:65,outputMode:.replaceOriginals,allowRecompression:true),token:StopToken()) { _ in }
        try check(twice.replaced == 3 && twice.failed == 0,"强制二次压缩并原地覆盖")
        for url in inPlaceFiles { try check(try PhotoCodec.marker(url)?.compressionCount == 2 && PhotoCodec.marker(url)?.quality == 65,"二次覆盖次数和质量回读") }

        let noGain = base.appendingPathComponent("no-gain")
        try fm.createDirectory(at:noGain,withIntermediateDirectories:true)
        let noGainFile = noGain.appendingPathComponent("original.jpg"); try fm.copyItem(at:primary,to:noGainFile)
        let noGainHash = try hash(noGainFile), noGainScan = try scan([noGain],base)
        let (noGainResult,_) = try BatchEngine.run(scan:noGainScan,destination:nil,settings:CompressionSettings(quality:100,outputMode:.replaceOriginals),token:StopToken()) { _ in }
        try check(noGainResult.skipped == 1 && noGainResult.replaced == 0 && (try hash(noGainFile)) == noGainHash,"无收益时原件完全不变")
        let stop = StopToken(); stop.cancel()
        let (cancelled,_) = try BatchEngine.run(scan:noGainScan,destination:nil,settings:CompressionSettings(outputMode:.replaceOriginals),token:stop) { _ in }
        try check(cancelled.replaced == 0 && (try hash(noGainFile)) == noGainHash,"开始前取消不会覆盖")
        let partialRoot = base.appendingPathComponent("partial")
        try fm.createDirectory(at:partialRoot,withIntermediateDirectories:true)
        for i in 0..<3 { try fm.copyItem(at:primary,to:partialRoot.appendingPathComponent("\(i).jpg")) }
        let partialScan = try scan([partialRoot],base), midway = StopToken()
        let (partial,_) = try BatchEngine.run(scan:partialScan,destination:nil,settings:CompressionSettings(workers:1,outputMode:.replaceOriginals),token:midway) { p in if p.done == 1 { midway.cancel() } }
        try check(partial.replaced == 1 && partial.done == 1,"中途停止仅保留已完成的一张覆盖")
        try check(try scan([partialRoot],base).count == 2,"中途停止的其他源照片仍可正常首次处理")

        let raceRoot = base.appendingPathComponent("race")
        try fm.createDirectory(at:raceRoot,withIntermediateDirectories:true)
        let raceSource = raceRoot.appendingPathComponent("race.jpg"), raceTemp = raceRoot.appendingPathComponent(".encoded.jpg")
        try fm.copyItem(at:primary,to:raceSource)
        let raceJob = try PhotoCodec.inspect(raceSource,root:raceRoot)!
        _ = try PhotoCodec.encode(raceJob,quality:65,to:raceTemp,token:StopToken())
        try fm.setAttributes([.modificationDate:Date()],ofItemAtPath:raceSource.path)
        let changedHash = try hash(raceSource); var preserve = false
        do { _ = try FilePublication.replaceOriginal(raceTemp,job:raceJob,token:StopToken(),preserveTemporary:&preserve); throw AppFailure("覆盖了被修改的来源") }
        catch { try check(error.localizedDescription.contains("扫描后发生变化"),"最终提交前再次检查源文件") }
        try check((try hash(raceSource)) == changedHash && !preserve,"拒绝覆盖时现有原文件保留")
        let freshJob = try PhotoCodec.inspect(raceSource,root:raceRoot)!
        _ = try PhotoCodec.encode(freshJob,quality:65,to:raceTemp,token:StopToken())
        let beforeDenied = try hash(raceSource)
        try fm.setAttributes([.posixPermissions:0o555],ofItemAtPath:raceRoot.path)
        do { _ = try FilePublication.replaceOriginal(raceTemp,job:freshJob,token:StopToken(),preserveTemporary:&preserve); throw AppFailure("不可写目录居然被覆盖") }
        catch { try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:raceRoot.path); try check((try hash(raceSource)) == beforeDenied && !preserve,"原子提交失败保留原件") }
        let readOnly = base.appendingPathComponent("read-only")
        try fm.createDirectory(at:readOnly,withIntermediateDirectories:true)
        let locked = readOnly.appendingPathComponent("locked.jpg"); try fm.copyItem(at:primary,to:locked)
        try fm.setAttributes([.posixPermissions:0o444],ofItemAtPath:locked.path)
        let lockedHash = try hash(locked)
        let (denied,_) = try BatchEngine.run(scan:scan([readOnly],base),destination:nil,settings:CompressionSettings(outputMode:.replaceOriginals),token:StopToken()) { _ in }
        try check(denied.failed == 1 && denied.replaced == 0 && (try hash(locked)) == lockedHash,"只读照片不被绕过权限覆盖")
        let linked = base.appendingPathComponent("linked")
        try fm.createDirectory(at:linked,withIntermediateDirectories:true)
        let linkedSource = linked.appendingPathComponent("one.jpg")
        try fm.copyItem(at:primary,to:linkedSource)
        try fm.linkItem(at:linkedSource,to:linked.appendingPathComponent("two.jpg"))
        let linkedHash = try hash(linkedSource)
        let (hardlinks,_) = try BatchEngine.run(scan:scan([linked],base),destination:nil,settings:CompressionSettings(outputMode:.replaceOriginals),token:StopToken()) { _ in }
        try check(hardlinks.failed == 2 && hardlinks.replaced == 0 && (try hash(linkedSource)) == linkedHash,"原地覆盖拒绝硬链接，避免与其他位置的原件脱离")
        print("PASS: \(checks) dangerous / flat-output checks; synthetic fixtures: \(base.path)")
    }
}
