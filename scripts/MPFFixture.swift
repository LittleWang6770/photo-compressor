import Foundation

// Test-only camera JPEG: baseline primary, padding, an unchanged large preview,
// plus an opaque trailer. Tests exercise both TIFF byte orders.
func makeMPFFixture(primary:URL, preview:URL, to output:URL, little:Bool = true, kind:UInt32 = 0x010002, corruptOffset:Bool = false) throws {
    let a = try Data(contentsOf:primary), b = try Data(contentsOf:preview)
    let padding = Data(repeating:0,count:97), footer = Data("opaque original trailer".utf8)
    let segmentSize = 4+4+82
    let primarySize = a.count+segmentSize
    var tiff = Data(little ? [0x49,0x49] : [0x4d,0x4d])
    func integer(_ value:UInt32,_ bytes:Int) { for i in 0..<bytes { tiff.append(UInt8((value >> (little ? i*8 : (bytes-1-i)*8)) & 255)) } }
    integer(42,2); integer(8,4); integer(3,2)
    integer(0xb000,2); integer(7,2); integer(4,4); tiff.append(contentsOf:[0x30,0x31,0x30,0x30])
    integer(0xb001,2); integer(4,2); integer(1,4); integer(2,4)
    integer(0xb002,2); integer(7,2); integer(32,4); integer(50,4)
    integer(0,4)
    integer(0xa0030000,4); integer(UInt32(primarySize),4); integer(0,4); integer(2,2); integer(0,2)
    integer(0x40000000 | kind,4); integer(UInt32(b.count),4)
    integer(corruptOffset ? UInt32.max : UInt32(primarySize+padding.count-10),4); integer(0,2); integer(0,2)
    let payload = Data("MPF\0".utf8)+tiff
    let n = payload.count+2
    let segment = Data([0xff,0xe2,UInt8(n >> 8),UInt8(n & 255)])+payload
    try (Data([0xff,0xd8])+segment+a.dropFirst(2)+padding+b+footer).write(to:output)
}
