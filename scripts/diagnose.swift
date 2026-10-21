import Foundation

@main struct Diagnose {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw AppFailure("Usage: diagnose <source folder>") }
        let root = URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL
        let workspace = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/diagnosis-\(UUID().uuidString)")
        for recursive in [false,true] {
            let result = try Scanner.scan(roots:[root],settings:CompressionSettings(recursive:recursive),workspace:workspace.appendingPathComponent(recursive ? "deep" : "shallow"),token:StopToken()) { _,_ in }
            print("\(recursive ? "recursive" : "current level"): \(result.count) photos, \(result.bytes) bytes, \(result.skipped) skipped, \(result.failed) issues")
            for reason in result.issues { print("reason: \(reason)") }
            if let largest = result.samples.first {
                print("largest: \(largest.source.lastPathComponent), \(largest.bytes) bytes")
                do {
                    let preview = workspace.appendingPathComponent(recursive ? "largest-deep-Q82.jpg" : "largest-current-Q82.jpg")
                    let size = try PhotoCodec.encode(largest,quality:82,to:preview,token:StopToken())
                    print("Q82 verified preview: \(largest.bytes) → \(size) bytes (\(String(format:"%.1f",100*(1-Double(size)/Double(largest.bytes))))% smaller)")
                }
            }
        }
        print("Reports and temporary preview: \(workspace.path)")
    }
}
