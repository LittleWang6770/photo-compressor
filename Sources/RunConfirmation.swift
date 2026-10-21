import SwiftUI

struct RunConfirmationView:View {
    @ObservedObject var model:AppModel
    @FocusState private var focused:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            if let review = model.pendingRun {
                let dangerous = review.settings.isDangerous
                let final = model.confirmationStep == 2
                HStack(spacing:10) {
                    Image(systemName:dangerous ? "exclamationmark.triangle" : "photo.on.rectangle").font(.system(size:24,weight:.light)).foregroundStyle(dangerous ? Theme.danger : Theme.accent)
                    VStack(alignment:.leading,spacing:4) {
                        Text(final ? "最后确认：\(review.keyword)" : "确认处理范围").font(.system(size:20,weight:.semibold))
                        Text(dangerous ? "第 \(model.confirmationStep) 步，共 2 步" : "确认后开始生成副本").font(.system(size:12)).foregroundStyle(Theme.secondary)
                    }
                }
                HStack {
                    Text(review.settings.outputMode.title).fontWeight(.semibold)
                    Spacer()
                    Text("\(review.count) 张 · 质量 \(review.settings.quality) / 100").monospacedDigit()
                }
                Text("来源：\(review.roots.count) 个文件夹 · \(review.settings.recursive ? "包含全部子文件夹" : "仅当前层")")
                    .font(.system(size:12)).foregroundStyle(Theme.secondary)
                ScrollView {
                    Text(review.targetDescription).font(.system(size:12)).textSelection(.enabled)
                        .frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:90)
                    .padding(12).background(Theme.track,in:RoundedRectangle(cornerRadius:7))
                VStack(alignment:.leading,spacing:9) {
                    if review.settings.outputMode == .replaceOriginals {
                        Text("将逐张替换来源路径上的照片。成功覆盖后不保留原件备份，无法通过本 App 撤销。")
                        Text("停止只会停止后续文件，已覆盖的照片不会恢复。")
                    } else { Text("照片直接保存到所选文件夹。同名文件自动加后缀区分，不覆盖已有副本。") }
                    if review.settings.allowRecompression {
                        Text("已开启重复压缩，包含 \(review.markedCount) 张有压缩标记的照片。新标记会记录最新质量和累计次数。")
                        Text("再次有损压缩可能继续损失细节；提高质量分数无法恢复已经丢失的细节。")
                    } else { Text("已压缩的照片会自动跳过。") }
                    Text(review.settings.onlySmaller ? "仅在体积变小时写入；未变小的照片保留当前文件。" : "即使体积变大也会写入。")
                }.font(.system(size:12)).foregroundStyle(dangerous ? Theme.danger : Theme.secondary)
                    .fixedSize(horizontal:false,vertical:true)
                if final {
                    VStack(alignment:.leading,spacing:8) {
                        Text("请输入「\(review.keyword)」以确认").font(.system(size:13,weight:.semibold))
                        TextField(review.keyword,text:$model.confirmationText).textFieldStyle(.roundedBorder)
                            .focused($focused).accessibilityLabel("危险操作确认文字")
                    }.padding(14).background(Theme.dangerBackground,in:RoundedRectangle(cornerRadius:8))
                }
                HStack(spacing:12) {
                    Button("取消") { model.cancelConfirmation() }.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
                    if final {
                        Button(review.settings.outputMode == .replaceOriginals ? "确认覆盖原件" : "确认重复压缩") { model.confirmFinalStep() }
                            .buttonStyle(ActionStyle(primary:true,dangerous:true)).disabled(!model.canConfirmDanger)
                    } else {
                        Button(dangerous ? "下一步：确认危险操作…" : "开始导出副本") { model.confirmFirstStep() }
                            .buttonStyle(ActionStyle(primary:true,dangerous:dangerous))
                    }
                }
            }
        }.padding(26).frame(width:520).font(.system(size:13)).foregroundStyle(Theme.ink)
            .background(Theme.background).preferredColorScheme(.light)
            .onChange(of:model.confirmationStep) { if $0 == 2 { focused = true } }
    }
}
