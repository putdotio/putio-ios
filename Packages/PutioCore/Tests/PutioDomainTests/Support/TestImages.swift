import Foundation

func isTestPNG(_ data: Data) -> Bool {
  let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  let bytes = [UInt8](data)
  guard bytes.count >= 24, Array(bytes[0..<8]) == signature,
    Array(bytes[12..<16]) == Array("IHDR".utf8)
  else { return false }
  let width = bytes[16..<20].reduce(0) { $0 << 8 | UInt32($1) }
  let height = bytes[20..<24].reduce(0) { $0 << 8 | UInt32($1) }
  return width > 0 && height > 0
}
