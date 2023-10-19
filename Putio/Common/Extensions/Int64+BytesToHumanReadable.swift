import Foundation

extension Int64 {
    public func bytesToHumanReadable() -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: self)
    }
}
