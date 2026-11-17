import Foundation

/// UTF-8 `Data` serialization for any `LosslessStringConvertible` type.
public extension LosslessStringConvertible {
    func toData() -> Data? {
        return description.data(using: .utf8)
    }

    init?(data: Data) {
        guard let str = String(exactUTF8: data) else { return nil }
        self.init(str)
    }
}

extension String {
    /// The text `bytes` spell as UTF-8, scalar for scalar: nil unless every
    /// byte is well-formed UTF-8. A leading U+FEFF (byte-order mark) is kept
    /// as the character it is. Foundation's `String(data:encoding: .utf8)`
    /// drops it on Darwin but keeps it on Linux, so the same bytes would
    /// decode to different values on different hosts.
    init?(exactUTF8 bytes: some Collection<UInt8>) {
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.utf8.elementsEqual(bytes) else { return nil }
        self = text
    }
}
