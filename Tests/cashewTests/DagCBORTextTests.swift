import Testing
import Foundation
@testable import cashew

/// Text decodes as exactly its UTF-8 bytes on every host. Foundation's
/// `String(data:encoding: .utf8)` drops a leading U+FEFF on Darwin and
/// keeps it on Linux; these vectors pin the one answer every platform gives.
@Suite("DagCBOR text is byte-exact")
struct DagCBORTextTests {
    struct TextScalar: Scalar {
        let text: String
    }

    /// The CBOR map {"text": <text string of `utf8`>}.
    static func textMap(_ utf8: [UInt8]) -> Data {
        precondition(utf8.count < 24)
        return Data([0xa1, 0x64] + Array("text".utf8) + [0x60 | UInt8(utf8.count)] + utf8)
    }

    static let bom: [UInt8] = [0xef, 0xbb, 0xbf]

    /// Well-formed UTF-8 a decoder must keep scalar for scalar.
    static let wellFormed: [(String, [UInt8])] = [
        ("leading BOM", bom + Array("abc".utf8)),
        ("lone BOM", bom),
        ("two BOMs", bom + bom),
        ("BOM mid-string", Array("a".utf8) + bom + Array("b".utf8)),
        ("trailing BOM", Array("ab".utf8) + bom),
        ("NUL", [0x61, 0x00, 0x62]),
        ("lone NUL", [0x00]),
        ("U+FFFD", [0xef, 0xbf, 0xbd]),
        ("U+10FFFF", [0xf4, 0x8f, 0xbf, 0xbf]),
        ("empty", []),
    ]

    /// Byte strings that are not UTF-8: refused, never repaired.
    static let illFormed: [(String, [UInt8])] = [
        ("overlong '/'", [0xc0, 0xaf]),
        ("overlong NUL", [0xc0, 0x80]),
        ("overlong 3-byte", [0xe0, 0x80, 0xaf]),
        ("UTF-16 surrogate", [0xed, 0xa0, 0x80]),
        ("CESU-8 pair", [0xed, 0xa0, 0xbd, 0xed, 0xb8, 0x80]),
        ("above U+10FFFF", [0xf4, 0x90, 0x80, 0x80]),
        ("truncated", [0xe2, 0x82]),
        ("lone continuation", [0x80]),
        ("0xFF", [0xff]),
        ("UTF-16LE BOM", [0xff, 0xfe, 0x61, 0x00]),
        ("BOM then invalid", bom + [0xc0, 0x80]),
    ]

    @Test("well-formed text decodes to exactly its bytes and re-encodes to them",
          arguments: wellFormed)
    func wellFormedText(_ name: String, _ utf8: [UInt8]) throws {
        let bytes = Self.textMap(utf8)
        let decoded = try DagCBOR.decode(TextScalar.self, from: bytes)
        #expect(Array(decoded.text.utf8) == utf8, "\(name)")
        #expect(try DagCBOR.encode(decoded) == bytes, "\(name)")
        #expect(TextScalar(data: bytes)?.text == decoded.text, "\(name)")
    }

    @Test("ill-formed text is refused as invalid CBOR", arguments: illFormed)
    func illFormedText(_ name: String, _ utf8: [UInt8]) {
        #expect(throws: DagCBORError.invalidCBOR, "\(name)") {
            try DagCBOR.decode(TextScalar.self, from: Self.textMap(utf8))
        }
        #expect(TextScalar(data: Self.textMap(utf8)) == nil, "\(name)")
    }

    @Test("a BOM is a character, not a marker")
    func bomIsACharacter() throws {
        let decoded = try DagCBOR.decode(TextScalar.self, from: Self.textMap(Self.bom + Array("abc".utf8)))
        #expect(decoded.text.unicodeScalars.first == "\u{FEFF}")
        #expect(decoded.text == "\u{FEFF}abc")
        #expect(decoded.text != "abc")
    }

    @Test("a BOM in a map key is kept")
    func bomInMapKey() throws {
        let key = "\u{FEFF}k"
        var bytes = Data([0xa1, 0x64]) + Data(key.utf8)
        bytes.append(0x01)
        let decoded = try DagCBOR.decode([String: Int].self, from: bytes)
        #expect(decoded == [key: 1])
        #expect(try DagCBOR.encode(decoded) == bytes)
    }

    /// One value, one CID, on every host: these goldens are the same on Darwin
    /// and Linux, and a host that dropped the BOM could not reproduce them.
    @Test("a value holding a BOM has one CID everywhere")
    func bomCIDGolden() throws {
        let withBOM = try DagCBOR.decode(TextScalar.self, from: Self.textMap(Self.bom + Array("abc".utf8)))
        let without = try DagCBOR.decode(TextScalar.self, from: Self.textMap(Array("abc".utf8)))
        #expect(try HeaderImpl(node: withBOM).rawCID
                == "bafyreieoxvb3az3fy475rkc74gwjnutpibvipht3yvvpn6uniw4irtql3e")
        #expect(try HeaderImpl(node: without).rawCID
                == "bafyreielyuku77u4ytxbfltuappuhpon27bgbzx76eoaipwwpxblfebs5m")
    }

    @Test("LosslessStringConvertible init(data:) keeps a BOM and refuses ill-formed bytes")
    func losslessStringData() {
        #expect(String(data: Data(Self.bom + Array("a".utf8))) == "\u{FEFF}a")
        #expect(String(data: Data(Self.bom)) == "\u{FEFF}")
        #expect(String(data: Data([0xc0, 0x80])) == nil)
        #expect(String(data: Data([0xed, 0xa0, 0x80])) == nil)
        #expect(Int(data: Data(Self.bom + Array("7".utf8))) == nil)
        #expect(Int(data: Data("7".utf8)) == 7)
    }
}
