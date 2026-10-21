import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @FocusState private var editingQuality: Bool
    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment:.top,spacing:20) {
                VStack(spacing:14) {
                    ScrollView {
                        VStack(spacing:14) { sourceCard; qualityCard; outputCard }.padding(1)
                    }
                    actions
                }.frame(width:292)
                ScrollView {
                    VStack(spacing:16) {
                        if let comparison = model.comparison { comparisonPanel(comparison) }
                        else { emptyPanel }
                        if model.scan != nil { summaryCard }
                    }.padding(1)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }.padding(.horizontal,28).padding(.bottom,20)
            footer
        }
        .font(.system(size:13)).foregroundStyle(Theme.ink)
        .background(Theme.background).tint(Theme.accent).preferredColorScheme(.light)
        .frame(minWidth:1020,minHeight:740)
        .onChange(of:model.settings.quality) { model.qualityText = String($0) }
        .alert("提示",isPresented:Binding(get:{model.notice != nil},set:{if !$0 { model.notice = nil }})) {
            Button("知道了") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .sheet(isPresented:$model.confirmStart,onDismiss:{ model.cancelConfirmation() }) { RunConfirmationView(model:model) }
    }
    var header: some View {
        ZStack(alignment:.topTrailing) {
            VStack(spacing:6) {
                AppMark().frame(width:52,height:52)
                Text("照片轻装").font(.system(size:26,weight:.semibold))
                Text("让照片小一点，把细节和回忆留下。")
                    .font(.system(size:12)).foregroundStyle(Theme.secondary)
            }.frame(maxWidth:.infinity)
            VStack(alignment:.trailing,spacing:8) {
                Text(model.demo ? "合成样张 · 临时目录" : model.settings.outputMode == .copy ? "本机处理 · 保留原件" : "危险模式 · 原地覆盖")
                    .font(.system(size:11)).foregroundStyle(Theme.secondary)
                Menu("示例与帮助") {
                    Button("载入合成样张") { model.loadDemo() }
                    Button("关于格式、元数据与加速") { showAbout() }
                    Divider()
                    Button("最小窗口 · 1020 × 740") { resize(1020,740) }
                    Button("默认窗口 · 1220 × 900") { resize(1220,900) }
                }.fixedSize().menuStyle(.borderlessButton).disabled(model.busy || model.previewBusy)
            }
        }.padding(.horizontal,30).padding(.top,16).padding(.bottom,22)
    }
    var sourceCard: some View {
        Card {
            StepHeading(number:"1",title:"照片来源")
            if model.folders.isEmpty {
                Text("添加本机或外置磁盘中的文件夹，可一次选择多个。")
                    .font(.system(size:12)).foregroundStyle(Theme.secondary).fixedSize(horizontal:false,vertical:true)
            } else {
                VStack(spacing:10) {
                    ForEach(model.folders) { folder in
                        HStack(spacing:8) {
                            Image(systemName:"folder").foregroundStyle(Theme.accent)
                            VStack(alignment:.leading,spacing:3) {
                                Text(folder.url.lastPathComponent).font(.system(size:12,weight:.medium))
                                Text(folder.url.path).font(.system(size:10)).foregroundStyle(Theme.secondary)
                            }.lineLimit(1).truncationMode(.middle).frame(maxWidth:.infinity,alignment:.leading).help(folder.url.path)
                            Button { model.removeFolder(folder.id) } label: { Image(systemName:"xmark").font(.system(size:10)) }
                                .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("移除这个来源，不删除照片")
                                .accessibilityLabel("移除文件夹 \(folder.url.lastPathComponent)")
                        }
                    }
                }
            }
            Button { model.chooseFolders() } label: { Label("添加文件夹…",systemImage:"plus") }.buttonStyle(ActionStyle())
            Picker("扫描范围",selection:$model.settings.recursive) {
                Text("仅当前层文件夹").tag(false)
                Text("包含全部子文件夹").tag(true)
            }.pickerStyle(.radioGroup).labelsHidden().onChange(of:model.settings.recursive) { _ in model.sourcesChanged() }
            if !model.folders.isEmpty {
                Divider()
                HStack(spacing:7) {
                    if model.phase == .scanning { ProgressView().controlSize(.mini) }
                    Text(model.countStatus).font(.system(size:12,weight:.medium)).monospacedDigit()
                        .fixedSize(horizontal:false,vertical:true)
                }.accessibilityElement(children:.combine)
                if let scan = model.scan, model.inventoryReady, scan.skipped > 0 || scan.failed > 0 {
                    HStack {
                        Text("跳过 \(scan.skipped) 个 · 需检查 \(scan.failed) 个").font(.system(size:10)).foregroundStyle(Theme.secondary)
                        Spacer(minLength:4)
                        Button("查看原因") { model.showScanIssues() }.buttonStyle(.link).font(.system(size:10))
                    }
                }
            }
        }.disabled(model.phase == .compressing)
    }
    var qualityCard: some View {
        Card {
            StepHeading(number:"2",title:"压缩质量")
            HStack(alignment:.firstTextBaseline) {
                Text("画质").foregroundStyle(Theme.secondary)
                Spacer()
                TextField("1–100",text:$model.qualityText)
                    .textFieldStyle(.roundedBorder).frame(width:50).multilineTextAlignment(.center)
                    .focused($editingQuality).onSubmit { commitQuality() }
                    .onChange(of:editingQuality) { if !$0 { commitQuality() } }
                    .accessibilityLabel("压缩质量，1 到 100")
                Text("/ 100").font(.system(size:12)).foregroundStyle(Theme.secondary)
            }
            VStack(spacing:5) {
                Slider(value:Binding(get:{Double(model.settings.quality)},set:{model.updateQuality($0)}),in:1...100)
                    .accessibilityLabel("压缩质量")
                HStack { Text("更小体积"); Spacer(); Text("更多细节") }.font(.system(size:10)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing:6) {
                qualityButton("轻巧",65); qualityButton("均衡",82); qualityButton("精细",92)
            }
            Divider()
            if let comparison = model.comparison, !model.previewBusy {
                HStack(alignment:.firstTextBaseline) {
                    Text(comparison.reduction >= 0 ? "样张体积减少" : "样张体积增加").font(.system(size:12)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text(String(format:"%.1f%%",abs(comparison.reduction)*100)).font(.system(size:21,weight:.semibold)).monospacedDigit()
                }
                Text("完整编码实测；整批照片的结果会有差异。")
                    .font(.system(size:10)).foregroundStyle(Theme.secondary).fixedSize(horizontal:false,vertical:true)
            } else {
                Text(model.previewBusy ? "正在按当前质量试压缩…" : "准备照片后，用真实样张估算体积。")
                    .font(.system(size:12)).foregroundStyle(Theme.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }.disabled(model.busy)
    }
    func qualityButton(_ label:String,_ quality:Int) -> some View {
        Button(label + " \(quality)") { editingQuality = false; model.updateQuality(Double(quality)) }
            .buttonStyle(.plain).font(.system(size:11,weight:.medium))
            .frame(maxWidth:.infinity).padding(.vertical,7)
            .background(model.settings.quality == quality ? Theme.selected : Theme.track,in:RoundedRectangle(cornerRadius:6))
            .overlay(RoundedRectangle(cornerRadius:6).stroke(model.settings.quality == quality ? Theme.accent.opacity(0.5) : .clear))
    }
    var outputCard: some View {
        Card {
            StepHeading(number:"3",title:"保存方式")
            Picker("保存方式",selection:Binding(get:{model.settings.outputMode},set:{model.setOutputMode($0)})) {
                Text("导出副本").tag(OutputMode.copy)
                Text("原地覆盖原件（危险）").foregroundStyle(Theme.danger).tag(OutputMode.replaceOriginals)
            }.pickerStyle(.radioGroup).labelsHidden()
            if model.settings.outputMode == .copy {
                if let output = model.output {
                    Label(output.lastPathComponent,systemImage:"folder.badge.plus").lineLimit(1).truncationMode(.middle)
                    Text(output.path).font(.system(size:10)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle).help(output.path)
                }
                Button(model.output == nil ? "选择保存位置…" : "更改保存位置…") { model.chooseOutput() }.buttonStyle(ActionStyle())
                Text("直接保存到此文件夹，同名文件自动加后缀。")
                    .font(.system(size:10)).foregroundStyle(Theme.secondary).fixedSize(horizontal:false,vertical:true)
            } else {
                Text("覆盖所选来源中的原照片，不保留原件备份。开始前需要两步确认。")
                    .font(.system(size:11)).foregroundStyle(Theme.danger).fixedSize(horizontal:false,vertical:true)
                if model.needsWriteAuthorization {
                    Button("授权来源文件夹写入…") { model.authorizeSourceWriting() }.buttonStyle(ActionStyle(dangerous:true))
                    Text("旧版本保存的是只读权限，需要重新选择来源来授权写入。")
                        .font(.system(size:10)).foregroundStyle(Theme.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
            DisclosureGroup("危险操作",isExpanded:$model.dangerExpanded) {
                VStack(alignment:.leading,spacing:9) {
                    Toggle("允许重复压缩（第 2 次及以后）",isOn:Binding(get:{model.settings.allowRecompression},set:{model.setAllowRecompression($0)}))
                        .font(.system(size:12,weight:.medium)).foregroundStyle(Theme.danger)
                    Text(model.settings.allowRecompression ? "已压缩照片也会纳入统计。再次有损压缩可能损失更多细节，开始前需两步确认。" : "默认跳过已压缩照片。开启后可在当前文件基础上再次压缩。")
                        .font(.system(size:10)).foregroundStyle(Theme.secondary).fixedSize(horizontal:false,vertical:true)
                }.padding(.top,10)
            }.font(.system(size:12)).foregroundStyle(Theme.danger)
            DisclosureGroup("高级设置",isExpanded:$model.advanced) {
                VStack(alignment:.leading,spacing:12) {
                    Toggle("仅写入体积变小的照片",isOn:$model.settings.onlySmaller).font(.system(size:12))
                    Picker("并行任务",selection:$model.settings.workers) {
                        Text("自动（推荐）").tag(0)
                        ForEach([1,2,4,8],id:\.self) { Text("\($0) 个").tag($0) }
                    }.font(.system(size:12))
                    Text("根据内存和照片像素限制并发。危险选项每次启动默认关闭。")
                        .font(.system(size:10)).foregroundStyle(Theme.secondary).fixedSize(horizontal:false,vertical:true)
                }.padding(.top,10)
            }.font(.system(size:12))
        }.disabled(model.busy)
    }
    var actions: some View {
        VStack(spacing:9) {
            if model.busy {
                Button(model.phase == .scanning ? "停止统计" : "停止处理") { model.stop() }.buttonStyle(ActionStyle())
            } else if !model.inventoryReady || model.comparison == nil {
                Button(model.previewBusy ? "正在生成最大照片样张…" : model.inventoryReady ? "生成最大照片样张" : model.scan != nil ? "重新统计并生成样张" : "准备照片与样张") { editingQuality = false; commitQuality(); model.prepare() }
                    .buttonStyle(ActionStyle(primary:true))
                    .disabled(model.folders.isEmpty || model.previewBusy || (model.inventoryReady && model.scan?.count == 0))
                if model.inventoryReady {
                    Button("重新统计来源") { model.sourcesChanged() }.buttonStyle(.link).font(.system(size:11))
                }
            } else {
                Button(model.settings.outputMode == .replaceOriginals ? "原地覆盖原件…" : model.settings.allowRecompression ? "强制重复压缩并导出…" : model.phase == .cancelled ? "继续压缩…" : "开始压缩…") { editingQuality = false; commitQuality(); model.requestStart() }
                    .buttonStyle(ActionStyle(primary:true,dangerous:model.settings.isDangerous)).disabled(!model.canRun)
                Button("重新统计来源") { model.sourcesChanged() }.buttonStyle(.link).font(.system(size:11))
            }
            Text(model.demo ? "示例仅使用临时目录中的合成照片。" : model.settings.isDangerous ? "危险操作 · 先确认范围，再输入文字确认" : "JPEG / HEIC · 全尺寸 · 本机处理")
                .font(.system(size:10)).foregroundStyle(Theme.secondary)
            if model.needsWriteAuthorization { Text("开始前请在保存方式中授权来源写入。")
                .font(.system(size:10)).foregroundStyle(Theme.danger) }
        }
    }
    var emptyPanel: some View {
        Card {
            VStack(spacing:17) {
                Image(systemName:model.previewError != nil ? "exclamationmark.triangle" : "photo.on.rectangle.angled")
                    .font(.system(size:43,weight:.ultraLight)).foregroundStyle(Theme.accent)
                Text(emptyTitle)
                    .font(.system(size:21,weight:.medium))
                Text(emptyDetail)
                    .font(.system(size:13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth:360)
                if model.previewBusy || model.phase == .scanning { ProgressView().controlSize(.small) }
                else if model.scan == nil {
                    Button("用合成样张试试看") { model.loadDemo() }.buttonStyle(.bordered)
                } else if model.previewError != nil {
                    Button("重试最大照片样张") { model.prepare() }.buttonStyle(.bordered)
                } else if model.inventoryReady && (model.scan?.count ?? 0) > 0 {
                    Button("生成最大照片样张") { model.prepare() }.buttonStyle(.bordered)
                }
                if model.scan == nil {
                    HStack(spacing:24) {
                        reassurance("location", "保留 GPS")
                        reassurance("camera", "保留拍摄信息")
                        reassurance("checkmark.shield", "避免重复压缩")
                    }.padding(.top,20)
                }
            }.frame(maxWidth:.infinity).frame(minHeight:430).padding(.vertical,30)
        }
    }
    var emptyTitle:String {
        if model.previewError != nil { return "这张照片暂时无法预览" }
        if model.previewBusy { return "正在生成最大照片样张" }
        if model.phase == .scanning { return "正在统计待处理照片" }
        if model.resultMode == .replaceOriginals && !model.inventoryReady && [.finished,.cancelled,.failed].contains(model.phase) {
            return model.phase == .failed ? "覆盖处理失败，请检查记录" : model.phase == .cancelled ? "已停止覆盖，已完成部分保留" : "原地覆盖已结束"
        }
        if model.inventoryReady { return model.scan?.count == 0 ? "没有可压缩的照片" : "照片已就绪，看看最大的一张" }
        return "先看看，再放心压缩"
    }
    var emptyDetail: String {
        if let error = model.previewError { return error }
        if model.phase == .scanning { return "添加文件夹后自动统计，数量会实时更新。切换扫描范围会重新统计。" }
        if model.resultMode == .replaceOriginals && !model.inventoryReady && [.finished,.cancelled,.failed].contains(model.phase) {
            return "已覆盖 \(model.progress.replaced) 张。请重新统计来源后继续，原有样张与清单已失效。已完成的覆盖不会撤销。"
        }
        if model.inventoryReady, let scan = model.scan {
            if scan.count == 0 { return scan.issues.first ?? "已压缩或不支持的文件会跳过，可查看来源中的原因与扫描记录。" }
            if let largest = model.selectedJob {
                return "待处理 \(scan.count) 张，共 \(byteString(scan.bytes))。将使用体积最大的 \(largest.source.lastPathComponent)（\(byteString(largest.bytes))）实测压缩效果。"
            }
        }
        return "选好文件夹和画质，在这里对照原图与压缩副本，放大检查你在意的细节。"
    }
    func reassurance(_ icon:String,_ title:String) -> some View {
        VStack(spacing:8) { Image(systemName:icon).font(.system(size:18,weight:.light)); Text(title).font(.system(size:11)) }.foregroundStyle(Theme.secondary)
    }
    func comparisonPanel(_ comparison:Comparison) -> some View {
        Card {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text("画质对比").font(.system(size:18,weight:.semibold))
                    Text(comparison.job.source.lastPathComponent + (comparison.job.previousCompression.map { " · 已压缩 \($0.compressionCount) 次，上次质量 \($0.quality)" } ?? "")).font(.system(size:12)).foregroundStyle(Theme.secondary)
                        .lineLimit(1).truncationMode(.tail).help(comparison.job.source.path)
                }
                Spacer()
                if model.previewBusy { ProgressView().controlSize(.small) }
                Text("最大体积照片样张").font(.system(size:11)).foregroundStyle(Theme.secondary)
            }
            GeometryReader { geo in
                let width = (geo.size.width - 12) / 2
                VStack(spacing:12) {
                    HStack(spacing:12) {
                        photoTile("原图",detail:byteString(comparison.job.bytes),image:comparison.original,actual:false).frame(width:width)
                        photoTile("压缩后",detail:byteString(comparison.outputBytes) + " · 质量 \(comparison.quality)",image:comparison.compressed,actual:false).frame(width:width)
                    }.frame(height:216)
                    HStack(spacing:12) {
                        photoTile("原图 · 100%",detail:"像素级细节",image:comparison.original,actual:true).frame(width:width)
                        photoTile("压缩后 · 100%",detail:"相同位置",image:comparison.compressed,actual:true).frame(width:width)
                    }.frame(height:216)
                }
            }.frame(height:444)
            HStack(spacing:6) {
                Image(systemName:"hand.draw")
                Text("点击上方照片定位；拖动下方细节同步查看。100% 为 1 图像像素对应 1 屏幕像素。")
            }.font(.system(size:10)).foregroundStyle(Theme.secondary).fixedSize(horizontal:false,vertical:true)
            if model.previewBusy {
                Text("质量已更改，正在更新预览；当前仍显示质量 \(comparison.quality) 的结果。")
                    .font(.system(size:11)).foregroundStyle(Theme.accent)
            }
        }
    }
    func photoTile(_ title:String,detail:String,image:CGImage,actual:Bool) -> some View {
        VStack(spacing:0) {
            HStack(spacing:4) {
                Text(title).font(.system(size:12,weight:.medium))
                Spacer(minLength:2)
                Text(detail).font(.system(size:10)).foregroundStyle(Theme.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }.padding(.horizontal,10).frame(height:33)
            PhotoCanvas(image:image,actualPixels:actual,center:$model.center)
                .accessibilityLabel(title + "，可拖动查看细节")
        }.background(Theme.background).clipShape(RoundedRectangle(cornerRadius:7))
            .overlay(RoundedRectangle(cornerRadius:7).stroke(Theme.border,lineWidth:1))
    }
    var summaryCard: some View {
        Card {
            HStack(alignment:.top,spacing:12) {
                stat(!model.inventoryReady && model.resultMode == .replaceOriginals ? "本批照片" : "待处理照片","\(model.scan?.count ?? 0) 张")
                Divider().frame(height:38)
                stat("原始体积",byteString(model.scan?.bytes ?? 0))
                Divider().frame(height:38)
                stat(model.progress.written > 0 ? "已节省" : "样张实测",model.progress.written > 0 ? byteString(model.progress.saved) : model.comparison.map { String(format:"%+.1f%%",-$0.reduction*100) } ?? "—")
            }
            if let scan = model.scan {
                HStack {
                    Text("跳过 \(scan.skipped) 个 · 需检查 \(scan.failed) 个").font(.system(size:11)).foregroundStyle(Theme.secondary)
                    Spacer()
                    if model.reportURL != nil { Button("查看记录") { model.revealReport() }.buttonStyle(.link).font(.system(size:11)) }
                }
            }
            if [.finished,.cancelled].contains(model.phase) {
                Divider()
                HStack {
                    Text((model.resultMode == .replaceOriginals ? "已覆盖" : "已导出") + " \(model.progress.written) 张 · 跳过 \(model.progress.skipped) 张 · 失败 \(model.progress.failed) 张")
                        .font(.system(size:12)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("在 Finder 中查看") { model.revealOutput() }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }
    func stat(_ title:String,_ value:String) -> some View {
        VStack(alignment:.leading,spacing:5) {
            Text(title).font(.system(size:11)).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size:20,weight:.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    var footer: some View {
        VStack(spacing:9) {
            HStack {
                Text(model.stageTitle).font(.system(size:12,weight:.medium))
                    .foregroundStyle(model.phase == .failed ? Color(red:0.65,green:0.28,blue:0.25) : Theme.ink)
                if model.phase == .compressing { Text("\(model.progress.workers) 路并行").font(.system(size:10)).foregroundStyle(Theme.secondary) }
                Spacer()
                Text(model.busy ? "本阶段剩余：\(model.eta)" : model.phase == .finished ? "用时 \(Int(model.elapsed)) 秒" : "")
                    .font(.system(size:11)).foregroundStyle(Theme.secondary).monospacedDigit().frame(width:180,alignment:.trailing)
            }
            if model.phase == .scanning { ProgressView().progressViewStyle(.linear).controlSize(.small).frame(height:7) }
            else { Bar(fraction:model.fraction,muted:model.phase == .cancelled || model.phase == .failed) }
            HStack {
                Text(model.current).lineLimit(1).truncationMode(.middle).help(model.current)
                Spacer(minLength:12)
                Text(model.settings.outputMode == .copy ? "EXIF / GPS 保留 · 原件保留" : "EXIF / GPS 保留 · 原地覆盖")
                    .foregroundStyle(model.settings.outputMode == .copy ? Theme.secondary : Theme.danger).fixedSize()
            }.font(.system(size:10)).foregroundStyle(Theme.secondary)
        }.padding(.horizontal,30).padding(.vertical,15).background(.white)
            .overlay(alignment:.top) { Rectangle().fill(Theme.border).frame(height:1) }
    }
    func commitQuality() {
        let quality = min(100,max(1,Int(model.qualityText) ?? model.settings.quality))
        model.qualityText = String(quality)
        if quality != model.settings.quality { model.updateQuality(Double(quality)) }
    }
    func resize(_ width:CGFloat,_ height:CGFloat) { model.window?.setContentSize(NSSize(width:width,height:height)) }
    func showAbout() {
        model.notice = "支持 8-bit SDR 的 JPEG 与 HEIC/HEIF，全尺寸同格式压缩。支持相机 JPEG 的 MPF 大预览：保留原预览与尾部数据，更新长度和位置索引并回读校验。RAW、PNG、视频、真正的多帧/HDR 与辅助图像安全跳过，原因写入记录。\n\nJPEG 原样保留 EXIF、GPS、ICC、XMP 和相机 MakerNote 数据段，APP15 写入独立质量标记。HEIC 写入 XMP 标记，并逐字段校验元数据；无法完整保留则不导出。创建与修改时间也会复制并校验。\n\n采用 Apple Image I/O 原生编码器，系统决定硬件路径；本版没有强制 GPU / NPU 编码，也不声称已验证硬件使用率。根据像素量和内存限制并发，任务路径存盘。\n\n质量分数不是体积百分比；100 也不保证无损。默认从所有待处理照片中选择体积最大的一张实测，百分比不能代表整批照片。默认导出副本，直接保存到所选文件夹，同名文件加后缀。危险模式支持原地覆盖与重复压缩，必须先确认范围，再输入确认文字。覆盖不会保留原件备份；重复压缩会累加次数。压缩标记可能被其他软件重新导出时移除。"
    }
}

struct AppMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius:13).fill(Theme.selected)
            Image(systemName:"photo").font(.system(size:28,weight:.light)).foregroundStyle(Theme.accent).offset(x:-2,y:-2)
            Image(systemName:"arrow.down.right.and.arrow.up.left").font(.system(size:11,weight:.semibold)).foregroundStyle(Theme.accent)
                .padding(4).background(Theme.selected,in:Circle()).offset(x:15,y:15)
        }.accessibilityLabel("照片轻装图标")
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var model: AppModel!
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.regular)
        if let icon = NSImage(named:"AppIcon") { NSApp.applicationIconImage = icon }
        model = AppModel(restore:!ProcessInfo.processInfo.arguments.contains("--demo"))
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1220,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "照片轻装"; window.contentMinSize = NSSize(width:1020,height:740)
        model.window = window
        window.contentView = NSHostingView(rootView:MainView(model:model)); window.delegate = self
        window.center()
        let menu = NSMenu(), appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle:"关于照片轻装",action:#selector(about),keyEquivalent:"")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"退出照片轻装",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem = NSMenuItem(); menu.addItem(editItem); let edit = NSMenu(title:"编辑"); editItem.submenu = edit
        edit.addItem(withTitle:"撤销",action:Selector(("undo:")),keyEquivalent:"z")
        edit.addItem(withTitle:"剪切",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        edit.addItem(withTitle:"复制",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"粘贴",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"全选",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        NSApp.mainMenu = menu
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        if ProcessInfo.processInfo.arguments.contains("--demo") { model.loadDemo() }
        if ProcessInfo.processInfo.arguments.contains("--minimum") { window.setContentSize(NSSize(width:1020,height:740)) }
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"照片轻装",.applicationVersion:"0.2.0"]) }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        guard model.busy else { model.shutdown(); return .terminateNow }
        let alert = NSAlert(); alert.messageText = "停止任务并退出？"; alert.informativeText = "已完成的副本会保留，已覆盖的照片不会恢复。正在编码且未提交的临时结果不会替换原件。"
        alert.addButton(withTitle:"继续处理"); alert.addButton(withTitle:"停止并退出")
        if alert.runModal() == .alertSecondButtonReturn { model.shutdown(); return .terminateNow }
        return .terminateCancel
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        if model.busy { NSApp.terminate(nil); return false }; return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
}

@main struct Launcher {
    static func main() {
        let app = NSApplication.shared, delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
