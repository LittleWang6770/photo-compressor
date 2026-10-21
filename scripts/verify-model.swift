import AppKit
import Foundation
import CryptoKit

@main struct ModelVerification {
    @MainActor static var checks = 0
    @MainActor static func require(_ condition:@autoclosure () throws -> Bool,_ message:String) throws {
        checks += 1
        if try !condition() { throw AppFailure("Model verification: " + message) }
    }
    @MainActor static func waitUntil(_ predicate:() -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime+15
        while !predicate() {
            if ProcessInfo.processInfo.systemUptime > deadline { throw AppFailure("等待扫描/预览超时") }
            try await Task.sleep(nanoseconds:20_000_000)
        }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let base = URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("build/model-verification-\(UUID().uuidString)")
        let root = base.appendingPathComponent("来源"), nested = root.appendingPathComponent("子文件夹")
        try fm.createDirectory(at:nested,withIntermediateDirectories:true)
        let small = root.appendingPathComponent("small.jpg"), large = nested.appendingPathComponent("large.jpg")
        try DemoFactory.make(at:small,width:400,height:300)
        try DemoFactory.make(at:large,width:1800,height:1200)
        let camera = root.appendingPathComponent("camera.jpg")
        try makeMPFFixture(primary:small,preview:small,to:camera)
        let suite = "PhotoCompressor.ModelVerification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let model = AppModel(restore:false,defaults:defaults)
        defer { model.shutdown() }
        model.addFolders([root])
        try require(model.phase == .scanning,"添加后必须立即开始统计，不能等待准备按钮")
        try await waitUntil { model.inventoryReady }
        try require(model.scan?.count == 3 && model.comparison == nil,"自动统计不应提前全尺寸试压缩")
        try require(model.selectedJob?.source == large,"递归范围从全部候选选择最大体积照片")
        model.settings.recursive = false; model.sourcesChanged()
        model.settings.recursive = true; model.sourcesChanged()
        model.settings.recursive = false; model.sourcesChanged()
        model.output = root // An invalid export destination must never block a read-only count or preview.
        model.prepare()
        try await waitUntil { model.comparison != nil || model.previewError != nil }
        try require(model.inventoryReady && model.scan?.count == 2,"快速切换范围不能被过期回调覆盖")
        try require(model.comparison?.job.source == camera && model.previewError == nil,"扫描期间请求准备样张必须在完成后生效，MPF 最大照片可预览")
        try require(model.previewBusy == false && model.notice == nil,"样张不依赖导出目录且不能卡在忙碌状态")
        model.settings.recursive = true; model.sourcesChanged()
        try await waitUntil { model.inventoryReady }
        try require(model.scan?.count == 3 && model.selectedJob?.source == large,"再次切换递归立即重新统计")
        model.prepare()
        try await waitUntil { model.comparison != nil || model.previewError != nil }
        try require(model.comparison?.job.source == large,"准备按钮使用最新范围的最大照片")
        model.updateQuality(65)
        try await waitUntil { !model.previewBusy }
        try require(model.comparison?.quality == 65 && model.comparison?.job.source == large,"质量滑块继续使用同一张最大照片")
        let id = model.folders[0].id
        model.settings.recursive = false; model.sourcesChanged(); model.removeFolder(id)
        try await Task.sleep(nanoseconds:200_000_000)
        try require(model.folders.isEmpty && model.scan == nil && model.phase == .empty && !model.previewBusy,"移除来源取消扫描和预览，过期结果不得恢复")
        let invalid = base.appendingPathComponent("不支持")
        try fm.createDirectory(at:invalid,withIntermediateDirectories:true)
        try makeMPFFixture(primary:small,preview:small,to:invalid.appendingPathComponent("HDR.jpg"),kind:0x050000)
        model.addFolders([invalid])
        try await waitUntil { model.inventoryReady }
        model.prepare()
        try require(model.scan?.count == 0 && model.notice?.contains("HDR 增益图") == true,"无可处理照片时明确显示原因，不能静默无反应")
        let dangerRoot = base.appendingPathComponent("danger-source"), copies = base.appendingPathComponent("direct-copies")
        try fm.createDirectory(at:dangerRoot,withIntermediateDirectories:true)
        let source = dangerRoot.appendingPathComponent("original.jpg")
        try fm.copyItem(at:large,to:source)
        let rawHash = SHA256.hash(data:try Data(contentsOf:source))
        let danger = AppModel(restore:false,defaults:defaults)
        defer { danger.shutdown() }
        danger.addFolders([dangerRoot]); danger.output = copies; danger.prepare()
        try await waitUntil { danger.comparison != nil || danger.previewError != nil }
        try require(danger.canRun,"新选择的来源可以导出和授权覆盖")
        danger.requestStart()
        try require(danger.confirmStart && danger.confirmationStep == 1 && (try SHA256.hash(data:Data(contentsOf:source))) == rawHash,"副本确认阶段尚未写入")
        danger.cancelConfirmation()
        try require(danger.pendingRun == nil && !danger.confirmStart,"取消会丢弃待确认任务")
        danger.requestStart(); danger.confirmFirstStep()
        try await waitUntil { danger.phase == .finished || danger.phase == .failed }
        try require(danger.progress.written == 1 && fm.fileExists(atPath:copies.appendingPathComponent("original.jpg").path),"普通副本一次范围确认即可开始，直接导出")
        try require(try SHA256.hash(data:Data(contentsOf:source)) == rawHash,"普通副本保留原件")
        danger.setOutputMode(.replaceOriginals); danger.requestStart()
        danger.confirmFinalStep()
        try require(danger.phase != .compressing && danger.confirmationStep == 1,"不能绕过第一步直接覆盖")
        danger.confirmFirstStep()
        try require(danger.confirmationStep == 2 && !danger.canConfirmDanger,"危险任务必须进入第二步且没有默认确认文字")
        danger.confirmationText = "错误文字"; danger.confirmFinalStep()
        try require(danger.phase != .compressing && (try SHA256.hash(data:Data(contentsOf:source))) == rawHash,"错误文字不能执行覆盖")
        danger.cancelConfirmation(); danger.requestStart(); danger.confirmFirstStep()
        try require(danger.confirmationText.isEmpty,"每次新的危险任务必须重新输入")
        danger.cancelConfirmation()
        danger.requestStart(); danger.settings.quality = 65; danger.confirmFirstStep()
        try require(danger.pendingRun == nil && !danger.confirmStart && danger.notice != nil,"设置变化使旧确认失效")
        danger.notice = nil; danger.updateQuality(82)
        try await waitUntil { !danger.previewBusy }
        danger.requestStart(); danger.confirmFirstStep(); danger.confirmationText = "覆盖原件"
        try require(danger.canConfirmDanger,"正确的确认文字可以继续")
        danger.confirmFinalStep()
        try await waitUntil { danger.phase == .finished || danger.phase == .failed }
        try require(danger.progress.replaced == 1 && danger.progress.failed == 0,"两步确认之后才原地覆盖")
        try require(!danger.inventoryReady && danger.comparison == nil,"原地覆盖之后必须重新统计，不能使用旧清单重压")
        try require(try PhotoCodec.marker(source)?.compressionCount == 1,"首次覆盖记录次数 1")
        danger.prepare(); try await waitUntil { danger.inventoryReady }
        try require(danger.scan?.count == 0 && !danger.canRun,"未开启重复压缩时覆盖后的文件自动跳过")
        danger.setAllowRecompression(true); danger.prepare()
        try await waitUntil { danger.comparison != nil || danger.previewError != nil }
        try require(danger.scan?.previouslyCompressed == 1 && danger.comparison?.job.previousCompression?.compressionCount == 1,"重复压缩重新纳入已标记源，并用当前文件预览")
        danger.setOutputMode(.copy); danger.updateQuality(65)
        try await waitUntil { !danger.previewBusy }
        let compressedHash = SHA256.hash(data:try Data(contentsOf:source))
        danger.requestStart(); danger.confirmFirstStep()
        try require(danger.confirmationStep == 2 && danger.pendingRun?.keyword == "重复压缩","即使只导出副本，重复压缩也需要第二步")
        danger.confirmationText = "重复压缩"; danger.confirmFinalStep()
        try await waitUntil { danger.phase == .finished || danger.phase == .failed }
        try require(danger.progress.written == 1 && danger.progress.replaced == 0 && danger.progress.failed == 0,"强制重复压缩可导出新副本")
        try require(try SHA256.hash(data:Data(contentsOf:source)) == compressedHash,"强制重复压缩的副本模式不覆盖输入")
        let exported = try fm.contentsOfDirectory(at:copies,includingPropertiesForKeys:nil).filter { $0.pathExtension.lowercased() == "jpg" }
        try require(try exported.contains(where:{ try PhotoCodec.marker($0)?.compressionCount == 2 }),"重复压缩副本的次数更新为 2")
        danger.setOutputMode(.replaceOriginals)
        danger.folders = [FolderSource(url:dangerRoot,writeAuthorized:false)]
        try require(danger.needsWriteAuthorization && !danger.canRun,"旧的只读来源权限不能静默升级为覆盖权限")
        danger.requestStart()
        try require(!danger.confirmStart && danger.notice?.contains("授权") == true,"未授权写入时明确提示，不能执行危险任务")
        danger.folders = [FolderAccess.make(dangerRoot,writable:true)]
        try FolderAccess.save(danger.folders,defaults:defaults)
        try require(try FolderAccess.restore(defaults:defaults).first?.writeAuthorized == true,"明确选择的写入权限可以恢复")
        struct OldFolder:Codable { let id:UUID; let path:String; let bookmark:Data? }
        defaults.set(try JSONEncoder().encode([OldFolder(id:UUID(),path:dangerRoot.path,bookmark:try FolderAccess.bookmark(dangerRoot))]),forKey:FolderAccess.listKey)
        try require(try FolderAccess.restore(defaults:defaults).first?.writeAuthorized == false,"旧书签迁移继续保持只读")
        danger.loadDemo()
        try await waitUntil { danger.demo && danger.comparison != nil }
        try require(danger.settings.outputMode == .copy && !danger.settings.allowRecompression && danger.comparison.map { FolderAccess.identity($0.job.source.deletingLastPathComponent()) } == FolderAccess.identity(danger.folders[0].url),"载入合成示例清除危险模式和旧真实来源清单")
        print("PASS: \(checks) model flow checks; synthetic fixtures: \(base.path)")
    }
}
