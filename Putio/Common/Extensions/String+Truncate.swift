import Foundation

extension String {
    func truncate(length: Int, trailing: String = "...") -> String {
         return (self.count > length) ? self.prefix(length) + trailing : self
    }
}
