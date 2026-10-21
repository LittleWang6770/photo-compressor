import AppKit
import SwiftUI

enum Phase: String { case empty, scanning, ready, compressing, finished, cancelled, failed }

struct Comparison {
    let original: CGImage
    let compressed: CGImage
    let job: PhotoJob
    let outputBytes: Int64
    let quality: Int
    var reduction: Double { 1 - Double(outputBytes) / Double(max(1, job.bytes)) }
}

struct RunReview {
    let settings:CompressionSettings
    let manifest:URL
    let output:URL?
    let roots:[URL]
    let count:Int
    let markedCount:Int
    var keyword:String { settings.outputMode == .replaceOriginals ? "覆盖原件" : "重复压缩" }
    var targetDescription:String { settings.outputMode == .replaceOriginals ? roots.map(\.path).joined(separator:"\n") : output?.path ?? "未选择" }
}

@MainActor final class AppModel: ObservableObject {
    weak var window: NSWindow?
    @Published var folders: [FolderSource] = []
    @Published var qualityText = "82"
    @Published var confirmStart = false
    @Published var confirmationStep = 1
    @Published var confirmationText = ""
    @Published var pendingRun:RunReview?
    @Published var dangerExpanded = false
    @Published var output: URL?
    @Published var settings = CompressionSettings()
    @Published var phase: Phase = .empty
    @Published var scan: ScanSummary?
    @Published var inventoryReady = false
    @Published var progress = BatchProgress()
    @Published var comparison: Comparison?
    @Published var previewBusy = false
    @Published var previewError: String?
    @Published var current = "添加文件夹，开始准备照片。"
    @Published var notice: String?
    @Published var advanced = false
    @Published var demo = false
    @Published var center = CGPoint(x: 0.5, y: 0.5)
    @Published var reportURL: URL?
    @Published var elapsed = 0.0
    @Published var eta: String = "估算中"
    private var activeToken = StopToken()
    private var previewToken = StopToken()
    private var debounce: DispatchWorkItem?
    private let previewQueue = DispatchQueue(label: "local.photo-compressor.preview", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let scanQueue = DispatchQueue(label:"local.photo-compressor.inventory",qos:.userInitiated,autoreleaseFrequency:.workItem)
    private var scopes: [URL] = []
    private var workspace: URL?
    private var timer: Timer?
    private var startTime = 0.0
    private var lastProgressTime = 0.0
    private var oldBytes: Int64 = 0
    private var rate = 0.0
    private var previewAfterScan = false
    private var preferences: UserDefaults
    private var reportsRoot:URL
    @Published var resultMode:OutputMode = .copy
    var busy: Bool { phase == .scanning || phase == .compressing }
    var needsWriteAuthorization:Bool { settings.outputMode == .replaceOriginals && folders.contains { !$0.writeAuthorized } }
    var canRun: Bool { inventoryReady && (scan?.count ?? 0) > 0 && (settings.outputMode == .replaceOriginals || output != nil) && !needsWriteAuthorization && !busy && !previewBusy && comparison?.quality == settings.quality }
    var canConfirmDanger:Bool { pendingRun != nil && confirmationStep == 2 && confirmationText == pendingRun?.keyword }
    var fraction: Double { guard let scan, scan.count > 0 else { return 0 }; return Double(progress.done) / Double(scan.count) }
    var samples: [PhotoJob] { scan?.samples ?? [] }
    var selectedJob: PhotoJob? { samples.first }
    var countStatus: String {
        if phase == .scanning { return "正在统计 · 已找到 \(scan?.count ?? 0) 张" }
        if inventoryReady, let scan { return "待处理 \(scan.count) 张 · \(byteString(scan.bytes))" }
        if resultMode == .replaceOriginals && scan != nil && [.finished,.cancelled,.failed].contains(phase) { return "已覆盖 \(progress.replaced) 张 · 请重新统计来源" }
        return phase == .failed ? "统计失败，请检查来源" : phase == .cancelled ? "统计已停止" : "等待统计照片"
    }
    var stageTitle: String {
        switch phase {
        case .empty: return "等待准备照片"
        case .scanning: return "正在统计照片"
        case .ready: return previewBusy ? "正在准备最大照片样张" : previewError != nil ? "样张未就绪" : comparison != nil ? "样张已就绪" : "照片统计完成"
        case .compressing: return "正在压缩 · \(progress.done) / \(scan?.count ?? 0) 张"
        case .finished: return progress.failed > 0 ? "处理结束 · 有文件失败" : "处理完成"
        case .cancelled: return "已停止"
        case .failed: return "任务失败"
        }
    }
    init(restore: Bool = true, defaults: UserDefaults? = nil) {
        preferences = defaults ?? (ProcessInfo.processInfo.arguments.contains("--ui-test") ? UserDefaults(suiteName: "PhotoCompressor.UITest")! : .standard)
        reportsRoot = defaults != nil || ProcessInfo.processInfo.arguments.contains("--ui-test") ? FileManager.default.temporaryDirectory.appendingPathComponent("pc-test-reports-\(UUID().uuidString)") : FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("照片轻装/处理记录")
        if restore && !ProcessInfo.processInfo.arguments.contains("--ui-test") {
            folders = (try? FolderAccess.restore(defaults: preferences)) ?? []
            for folder in folders { retainScope(folder.url) }
            if let data = preferences.data(forKey: "compressor.output") {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) { output = url; retainScope(url) }
            }
            if !folders.isEmpty { Task { @MainActor [weak self] in self?.sourcesChanged() } }
        }
    }
    func retainScope(_ url: URL) { if url.startAccessingSecurityScopedResource() { scopes.append(url) } }
    func setOutputMode(_ mode:OutputMode) {
        guard !busy else { return }
        cancelConfirmation(); settings.outputMode = mode
        if mode == .replaceOriginals { dangerExpanded = true }
    }
    func setAllowRecompression(_ enabled:Bool) {
        guard phase != .compressing, enabled != settings.allowRecompression else { return }
        settings.allowRecompression = enabled; dangerExpanded = enabled || dangerExpanded
        sourcesChanged()
    }
    func authorizeSourceWriting() {
        guard !busy, let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.title = "授权原地覆盖的来源文件夹"; panel.prompt = "授权此来源"
        panel.message = "请选择列表中需要原地覆盖的来源文件夹。授权后，仍需确认范围并输入确认文字才会写入照片。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.directoryURL = folders.first(where:{ !$0.writeAuthorized })?.url
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                for url in panel.urls {
                    guard let i = self.folders.firstIndex(where:{ FolderAccess.identity($0.url) == FolderAccess.identity(url) }) else { continue }
                    var authorized = FolderAccess.make(url,writable:true); authorized = FolderSource(url:authorized.url,id:self.folders[i].id,bookmark:authorized.bookmark,accessIssue:authorized.accessIssue,writeAuthorized:true)
                    self.retainScope(url); self.folders[i] = authorized
                }
                if !self.demo { try? FolderAccess.save(self.folders,defaults:self.preferences) }
                if self.needsWriteAuthorization { self.notice = "仍有来源未获得写入授权，请选择列表中需要覆盖的来源文件夹。" }
            }
        }
    }
    func chooseFolders() {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.title = "添加照片文件夹"; panel.prompt = "添加文件夹"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.addFolders(panel.urls) }
        }
    }
    func addFolders(_ urls: [URL]) {
        guard phase != .compressing else { return }
        if demo { folders = []; demo = false; output = nil }
        for url in urls where !folders.contains(where: { FolderAccess.identity($0.url) == FolderAccess.identity(url) }) {
            let folder = FolderAccess.make(url); retainScope(url); folders.append(folder)
        }
        try? FolderAccess.save(folders, defaults: preferences); sourcesChanged()
    }
    func removeFolder(_ id: UUID) {
        guard phase != .compressing else { return }
        folders.removeAll { $0.id == id }
        if !demo { try? FolderAccess.save(folders, defaults: preferences) }
        sourcesChanged()
    }
    func chooseOutput() {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.title = "选择副本的保存位置"; panel.prompt = "保存到这里"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                if let problem = self.outputProblem(url) { self.notice = problem; return }
                self.retainScope(url); self.output = url
                if !self.demo, let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) { self.preferences.set(bookmark, forKey: "compressor.output") }
            }
        }
    }
    func outputProblem(_ url: URL) -> String? {
        let dest = FolderAccess.identity(url)
        if folders.contains(where: { let root = FolderAccess.identity($0.url); return dest == root || dest.hasPrefix(root + "/") }) { return "请把输出位置选在来源文件夹之外，避免下次扫描混入副本。" }
        return nil
    }
    func sourcesChanged() {
        guard phase != .compressing else { return }
        cancelConfirmation()
        activeToken.cancel(); activeToken = StopToken(); stopClock(); previewAfterScan = false
        cancelPreview()
        scan = nil; inventoryReady = false; comparison = nil; phase = .empty; progress = BatchProgress(); reportURL = nil
        previewError = nil; current = "来源已更新，正在统计照片。"; eta = "估算中"
        if !folders.isEmpty { scanSources(generatePreview:false) }
        else { current = "添加文件夹后自动统计待处理照片。" }
    }
    func updateQuality(_ value: Double) {
        let quality = min(100, max(1, Int(value.rounded())))
        settings.quality = quality
        cancelConfirmation()
        if [.finished, .cancelled, .failed].contains(phase), scan != nil {
            phase = .ready; progress = BatchProgress(); current = "画质已更新，请检查新的样张。"
        }
        requestPreview()
    }
    private func cancelPreview() {
        previewToken.cancel(); previewToken = StopToken()
        debounce?.cancel(); debounce = nil; previewBusy = false
    }
    func requestPreview(immediate: Bool = false) {
        cancelPreview()
        guard inventoryReady, let job = selectedJob, !busy else { return }
        let token = StopToken(); previewToken = token
        let quality = settings.quality
        let allowRecompression = settings.allowRecompression
        previewBusy = true; previewError = nil
        current = "正在试压缩最大照片：\(job.source.lastPathComponent) · 质量 \(quality)"
        let work = DispatchWorkItem { [weak self] in
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pc-preview-\(UUID().uuidString).\(job.source.pathExtension)")
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                try token.check()
                let bytes = try PhotoCodec.encode(job, quality: quality, to: temp, token: token,allowRecompression:allowRecompression)
                let original = try PhotoCodec.displayImage(job.source), compressed = try PhotoCodec.displayImage(temp)
                try token.check()
                let result = Comparison(original: original, compressed: compressed, job: job, outputBytes: bytes, quality: quality)
                DispatchQueue.main.async {
                    guard let self, self.previewToken === token else { return }
                    self.comparison = result; self.previewBusy = false; self.center = CGPoint(x: 0.5,y: 0.5)
                    self.current = "最大照片样张：\(job.source.lastPathComponent) · 质量 \(quality) · \(self.scan?.count ?? 0) 张待处理"
                }
            } catch is CancellationError { }
            catch {
                DispatchQueue.main.async {
                    guard let self, self.previewToken === token else { return }
                    self.previewBusy = false; self.previewError = friendlyError(error); self.comparison = nil
                    self.current = "最大照片样张生成失败：\(friendlyError(error))"
                }
            }
        }
        debounce = work
        previewQueue.asyncAfter(deadline: .now() + (immediate ? 0 : 0.35), execute: work)
    }
    func prepare() {
        guard phase != .compressing else { return }
        guard !folders.isEmpty else { notice = "请先添加照片文件夹。"; return }
        if phase == .scanning {
            previewAfterScan = true; current = "正在统计照片，完成后将生成体积最大的照片样张…"; return
        }
        if inventoryReady, let scan {
            guard scan.count > 0 else { showScanIssues(); return }
            phase = .ready; requestPreview(immediate:true); return
        }
        scanSources(generatePreview:true)
    }
    func showScanIssues() {
        guard let scan else { notice = current; return }
        let reasons = scan.issues.isEmpty ? "没有找到尚未压缩的 JPEG / HEIC 照片，请检查扫描范围。" : scan.issues.joined(separator:"\n")
        notice = "待处理 \(scan.count) 张 · 跳过 \(scan.skipped) 个 · 需检查 \(scan.failed) 个\n\n\(reasons)\n\n可通过「查看记录」定位具体文件。"
    }
    private func scanSources(generatePreview:Bool) {
        activeToken.cancel(); previewAfterScan = generatePreview
        cancelPreview(); comparison = nil; previewError = nil
        inventoryReady = false; phase = .scanning; progress = BatchProgress(); current = "正在统计 JPEG / HEIC 照片…"; scan = nil; reportURL = nil
        let token = StopToken(); activeToken = token
        let roots = folders.map(\.url), settings = settings
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("photo-compressor-\(UUID().uuidString)")
        let previous = workspace; workspace = work
        startClock()
        scanQueue.async { [weak self] in
            // Scans are serial: the previous worker has closed its manifest before cleanup.
            if let previous { try? FileManager.default.removeItem(at:previous) }
            do {
                let result = try Scanner.scan(roots: roots, settings: settings, workspace: work, token: token) { summary, path in
                    DispatchQueue.main.async {
                        guard let self, self.activeToken === token else { return }
                        self.scan = summary; self.current = path
                    }
                }
                try token.check()
                DispatchQueue.main.async {
                    guard let self, self.activeToken === token else { return }
                    self.scan = result; self.inventoryReady = true; self.phase = .ready; self.stopClock()
                    self.reportURL = result.report
                    self.current = "\(result.count) 张可压缩 · \(result.skipped) 个跳过 · \(result.failed) 个需检查"
                    if self.previewAfterScan && result.count > 0 { self.requestPreview(immediate: true) }
                    else if result.count > 0 { self.current += " · 点击生成最大照片样张" }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.activeToken === token else { return }
                    self.phase = error is CancellationError ? .cancelled : .failed; self.stopClock(); self.inventoryReady = false
                    self.current = error is CancellationError ? "统计已停止，请重新统计照片。" : friendlyError(error)
                }
            }
            if token.isCancelled { try? FileManager.default.removeItem(at:work) }
        }
    }
    func requestStart() {
        guard canRun, let scan else { notice = needsWriteAuthorization ? "请先授权需要覆盖的来源文件夹。" : "请先生成当前质量的样张并选择保存位置。"; return }
        if settings.outputMode == .copy, let output, let problem = outputProblem(output) { notice = problem; return }
        pendingRun = RunReview(settings:settings,manifest:scan.manifest,output:output,roots:folders.map(\.url),count:scan.count,markedCount:scan.previouslyCompressed)
        confirmationStep = 1; confirmationText = ""; confirmStart = true
    }
    func cancelConfirmation() { confirmStart = false; confirmationStep = 1; confirmationText = ""; pendingRun = nil }
    private func reviewIsCurrent(_ review:RunReview) -> Bool {
        canRun && settings == review.settings && scan?.manifest == review.manifest && output == review.output && folders.map(\.url) == review.roots
    }
    func confirmFirstStep() {
        guard let review = pendingRun, confirmationStep == 1, reviewIsCurrent(review) else { cancelConfirmation(); notice = "任务设置已变化，请重新检查样张与处理范围。"; return }
        if review.settings.isDangerous { confirmationStep = 2; confirmationText = "" }
        else { start(review) }
    }
    func confirmFinalStep() {
        guard let review = pendingRun, canConfirmDanger else { return }
        guard reviewIsCurrent(review) else { cancelConfirmation(); notice = "任务设置已变化，请重新检查样张与处理范围。"; return }
        start(review)
    }
    private func start(_ review:RunReview) {
        guard reviewIsCurrent(review), let scan else { return }
        let settings = review.settings, output = review.output, reportsRoot = reportsRoot, token = StopToken(); activeToken = token
        cancelConfirmation(); resultMode = settings.outputMode
        progress = BatchProgress(); phase = .compressing; reportURL = nil; current = settings.outputMode == .copy ? "正在创建经过校验的副本…" : "正在编码并校验，完成后逐张原子替换原件…"; startClock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let (result, report) = try BatchEngine.run(scan: scan, destination: output, settings: settings, token: token,reportDirectory:reportsRoot) { progress in
                    DispatchQueue.main.async {
                        guard let self, self.activeToken === token else { return }
                        self.progress = progress; self.current = progress.current; self.updateRate()
                    }
                }
                DispatchQueue.main.async {
                    guard let self, self.activeToken === token else { return }
                    self.progress = result; self.reportURL = report; self.phase = token.isCancelled ? .cancelled : .finished
                    self.stopClock()
                    let action = settings.outputMode == .copy ? "导出" : "覆盖"
                    self.current = (token.isCancelled ? "已停止 · " : "") + "\(action) \(result.written) 张 · 跳过 \(result.skipped) 张 · 失败 \(result.failed) 张"
                    if settings.outputMode == .replaceOriginals {
                        self.inventoryReady = false; self.comparison = nil
                        self.current += " · 已覆盖部分不会撤销，请重新统计来源后继续。"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.activeToken === token else { return }
                    self.phase = .failed; self.stopClock(); self.current = friendlyError(error)
                    if settings.outputMode == .replaceOriginals { self.inventoryReady = false; self.comparison = nil; self.current += " · 请检查记录并重新统计来源。" }
                }
            }
        }
    }
    func stop() { activeToken.cancel(); current = "正在停止，等待当前编码安全结束…"; timer?.invalidate(); eta = "正在停止" }
    func startClock() {
        timer?.invalidate(); startTime = ProcessInfo.processInfo.systemUptime; elapsed = 0
        oldBytes = 0; rate = 0; lastProgressTime = startTime; eta = "估算中"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func updateRate() {
        let now = ProcessInfo.processInfo.systemUptime, dt = now - lastProgressTime
        if dt >= 0.5 && progress.inputBytes > oldBytes {
            let sample = Double(progress.inputBytes - oldBytes) / dt
            rate = rate == 0 ? sample : rate * 0.7 + sample * 0.3
            oldBytes = progress.inputBytes; lastProgressTime = now
        }
    }
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime; elapsed = now - startTime
        guard phase == .compressing, rate > 0, progress.done >= 2, let scan else { eta = "估算中"; return }
        if now - lastProgressTime > 20 { eta = "重新估算中"; return }
        let remaining = max(1, Int(Double(max(0,scan.bytes - progress.inputBytes)) / rate))
        eta = remaining >= 60 ? "约 \(remaining / 60) 分 \(remaining % 60) 秒" : "约 \(remaining) 秒"
    }
    func stopClock() { timer?.invalidate(); timer = nil; elapsed = startTime > 0 ? ProcessInfo.processInfo.systemUptime - startTime : 0; eta = "—" }
    func loadDemo() {
        guard !busy else { return }
        cancelConfirmation(); cancelPreview(); activeToken.cancel(); activeToken = StopToken()
        scan = nil; inventoryReady = false; comparison = nil; previewError = nil; phase = .empty
        let demoToken = StopToken(); previewToken = demoToken; previewBusy = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-compressor-demo-\(UUID().uuidString)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let source = root.appendingPathComponent("示例照片")
                try FileManager.default.createDirectory(at: source,withIntermediateDirectories: true)
                try DemoFactory.make(at: source.appendingPathComponent("山间来信.jpg"))
                DispatchQueue.main.async {
                    guard let self, self.previewToken === demoToken, !demoToken.isCancelled else { return }
                    self.demo = true; self.folders = [FolderSource(url:source,writeAuthorized:true)]
                    self.output = root.appendingPathComponent("压缩副本"); self.settings = CompressionSettings(); self.qualityText = "82"
                    self.previewBusy = false; self.sourcesChanged(); self.prepare()
                }
            } catch { DispatchQueue.main.async { guard let self, self.previewToken === demoToken else { return }; self.previewBusy = false; self.notice = friendlyError(error) } }
        }
    }
    func revealOutput() { if resultMode == .replaceOriginals { if let first = folders.first { NSWorkspace.shared.open(first.url) } } else if let output { NSWorkspace.shared.open(output) } }
    func revealReport() { if let reportURL { NSWorkspace.shared.activateFileViewerSelecting([reportURL]) } }
    func shutdown() { activeToken.cancel(); previewToken.cancel(); timer?.invalidate() }
}
