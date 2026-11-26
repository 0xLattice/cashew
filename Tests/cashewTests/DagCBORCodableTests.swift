import Testing
import Foundation
@testable import cashew

/// A type that reads and writes its own DAG-CBOR must give `Codable`'s
/// answers: the same bytes for every value, and the same verdict and value
/// for every input. These hold cashew's own conformances to that over
/// encoded values and every mutant of them.
@Suite("DagCBORCodable equals the Codable path")
struct DagCBORCodableTests {
    typealias Volume = VolumeImpl<TestScalar>
    typealias Map = FlatDictionary<ScalarHeader>

    static let standard = try! ScalarHeader(node: TestScalar(val: 1)).rawCID
    static let info = EncryptionInfo(keyHash: "a2V5", iv: "aXY=")

    static var headers: [ScalarHeader] {
        [
            ScalarHeader(rawCID: standard),
            ScalarHeader(rawCID: standard, node: nil, encryptionInfo: info),
            ScalarHeader(rawCID: "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG"),
            ScalarHeader(rawCID: "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"),
            ScalarHeader(rawCID: "not a cid"),
            ScalarHeader(rawCID: ""),
            ScalarHeader(rawCID: "café", node: nil, encryptionInfo: EncryptionInfo(keyHash: "", iv: "ü")),
        ]
    }

    static var maps: [Map] {
        let links = headers
        return [
            Map(),
            Map(["a": links[0]]),
            Map(["b": links[0], "a": links[1], "aa": links[2], "": links[3]]),
            Map(["é": links[0], "e\u{301}x": links[4], "日本": links[5], "z": links[6]]),
            Map(Dictionary(uniqueKeysWithValues: (0..<40).map { ("k\($0)", links[$0 % links.count]) })),
        ]
    }

    typealias Dictionary64 = MerkleDictionaryImpl<UInt64>
    typealias VolumeDictionary = VolumeMerkleDictionaryImpl<String>
    typealias Node64 = RadixNodeImpl<UInt64>
    typealias VolumeNode = VolumeRadixNodeImpl<String>

    /// Children keyed by ASCII, accented, combining and multi-byte
    /// characters, which `String` order sorts differently from bytes.
    static func children<Child>(_ link: (String) -> Child) -> [[Character: Child]] {
        [
            [:],
            ["a": link(standard)],
            ["b": link(standard), "a": link("not a cid"), "Z": link(""), "é": link(standard),
             "a\u{308}x".first!: link(standard), "日": link("café"), "😀": link(standard)],
        ]
    }

    static var tries: (dictionaries: [Dictionary64], volumeDictionaries: [VolumeDictionary], nodes: [Node64], volumeNodes: [VolumeNode]) {
        let radix = children { RadixHeaderImpl<UInt64>(rawCID: $0) }
        let volumeRadix = children { VolumeRadixHeaderImpl<String>(rawCID: $0) }
        return (
            radix.flatMap { kids in [0, 1, Int.max, -1].map { Dictionary64(children: kids, count: $0) } },
            volumeRadix.flatMap { kids in [0, 7].map { VolumeDictionary(children: kids, count: $0) } },
            radix.flatMap { kids in [nil, 0, 23, 24, .max].flatMap { value in
                ["", "a", "prefix", "日本"].map { Node64(prefix: $0, value: value, children: kids) }
            } },
            volumeRadix.flatMap { kids in [nil, "", "v", "ü"].map { VolumeNode(prefix: "p", value: $0, children: kids) } }
        )
    }

    static let values: (texts: [String], bools: [Bool], uint64s: [UInt64], uint16s: [UInt16], uint32s: [UInt32], int64s: [Int64], ints: [Int], arrays: [[UInt16]]) = (
        ["", "a", "café", String(repeating: "x", count: 300)],
        [false, true],
        [0, 23, 24, 255, 256, 65_535, 65_536, .max],
        [0, 23, 24, .max],
        [0, 65_536, .max],
        [.min, -1, 0, 24, .max],
        [.min, -25, 0, 1, .max],
        [[], [0], [1, 2, 3], [.max, 0, 24]]
    )

    @Test("Every value is written as Codable writes it")
    func writesCodableBytes() throws {
        for header in Self.headers {
            #expect(try DagCBOR.encode(header) == DagCBOR.encodeThroughCodable(header))
            let volume = Volume(rawCID: header.rawCID, node: nil, encryptionInfo: header.encryptionInfo)
            #expect(try DagCBOR.encode(volume) == DagCBOR.encodeThroughCodable(volume))
        }
        for map in Self.maps {
            #expect(try DagCBOR.encode(map) == DagCBOR.encodeThroughCodable(map))
        }
        #expect(try DagCBOR.encode(Self.info) == DagCBOR.encodeThroughCodable(Self.info))
        func same<T: Codable>(_ values: [T]) throws {
            for value in values {
                #expect(try DagCBOR.encode(value) == DagCBOR.encodeThroughCodable(value), "\(T.self)")
            }
        }
        let tries = Self.tries
        try same(tries.dictionaries)
        try same(tries.volumeDictionaries)
        try same(tries.nodes)
        try same(tries.volumeNodes)
        try same(Self.values.texts)
        try same(Self.values.bools)
        try same(Self.values.uint64s)
        try same(Self.values.uint16s)
        try same(Self.values.uint32s)
        try same(Self.values.int64s)
        try same(Self.values.ints)
        try same(Self.values.arrays)
    }

    @Test("Every input gets Codable's verdict and value")
    func readsWithCodableVerdicts() throws {
        var compared = 0
        var accepted = 0
        func check<T: Codable>(_ type: T.Type, _ input: Data) throws {
            let own = try? DagCBOR.decode(type, from: input)
            let codable = try? DagCBOR.decodeThroughCodable(type, from: input)
            #expect((own == nil) == (codable == nil), "\(T.self): \([UInt8](input))")
            if let own, let codable {
                #expect(try DagCBOR.encodeThroughCodable(own) == DagCBOR.encodeThroughCodable(codable))
                accepted += 1
            }
            compared += 1
        }
        for header in Self.headers {
            for input in Self.mutants(of: try DagCBOR.encodeThroughCodable(header)) {
                try check(ScalarHeader.self, input)
                try check(Volume.self, input)
                try check(EncryptionInfo.self, input)
            }
        }
        for map in Self.maps.prefix(4) {
            for input in Self.mutants(of: try DagCBOR.encodeThroughCodable(map)) {
                try check(Map.self, input)
            }
        }
        // Respellings no byte mutation reaches.
        let link = try DagCBOR.encodeThroughCodable(ScalarHeader(rawCID: Self.standard))
        for input in [
            Self.map([("rawCID", Self.text(Self.standard.uppercased()))]),
            Self.map([("rawCID", Self.text(Self.standard)), ("encryptionInfo", [0xf6])]),
            Self.map([("rawCID", Self.text(Self.standard)), ("rawCID", Self.text(Self.standard))]),
            Self.map([("rawCID", Self.text(Self.standard)), ("extra", [0x01])]),
            Self.map([("encryptionInfo", [UInt8](try DagCBOR.encode(Self.info))), ("rawCID", Self.text(Self.standard))]),
        ] {
            try check(ScalarHeader.self, input)
        }
        for input in [
            Self.map([("b", [UInt8](link)), ("a", [UInt8](link))]),
            Self.map([("a", [UInt8](link)), ("a", [UInt8](link))]),
            Self.map([("é", [UInt8](link)), ("e\u{301}", [UInt8](link))]),
        ] {
            try check(Map.self, input)
        }
        let tries = Self.tries
        // The first and last child sets of each trie type, every node shape.
        for dictionary in tries.dictionaries where dictionary.count != 0 || dictionary.children.count > 1 {
            for input in Self.mutants(of: try DagCBOR.encodeThroughCodable(dictionary)) {
                try check(Dictionary64.self, input)
            }
        }
        for dictionary in tries.volumeDictionaries.suffix(1) {
            for input in Self.mutants(of: try DagCBOR.encodeThroughCodable(dictionary)) {
                try check(VolumeDictionary.self, input)
            }
        }
        for node in tries.nodes where node.prefix == "日本" || node.value == nil {
            for input in Self.mutants(of: try DagCBOR.encodeThroughCodable(node)) {
                try check(Node64.self, input)
            }
        }
        for node in tries.volumeNodes.suffix(2) {
            for input in Self.mutants(of: try DagCBOR.encodeThroughCodable(node)) {
                try check(VolumeNode.self, input)
            }
        }
        func values<T: Codable>(_ type: T.Type, _ values: [T]) throws {
            for value in values {
                for input in Self.mutants(of: try DagCBOR.encodeThroughCodable(value)) {
                    try check(type, input)
                }
            }
        }
        try values(String.self, Self.values.texts.dropLast())
        try values(Bool.self, Self.values.bools)
        try values(UInt64.self, Self.values.uint64s)
        try values(UInt16.self, Self.values.uint16s)
        try values(UInt32.self, Self.values.uint32s)
        try values(Int64.self, Self.values.int64s)
        try values(Int.self, Self.values.ints)
        try values([UInt16].self, Self.values.arrays)
        // Children no byte mutation reaches: out of order, a repeated or
        // equivalent first character, an empty or longer key, a null value.
        func entries(_ list: [(String, [UInt8])]) -> [UInt8] {
            var writer = DagCBORWriter()
            writer.writeHead(major: 4, UInt64(list.count))
            return writer.bytes + list.flatMap { [UInt8](Self.map([("key", Self.text($0.0)), ("value", $0.1)])) }
        }
        let child = [UInt8](link)
        for list in [
            [("b", child), ("a", child)],
            [("a", child), ("a", child)],
            [("é", child), ("e\u{301}", child)],
            [("", child), ("a", child)],
            [("ab", child)],
            [("a", [0xf6])],
        ] {
            try check(Dictionary64.self, Self.map([("count", [0x01]), ("children", entries(list))]))
            try check(Node64.self, Self.map([("prefix", Self.text("p")), ("children", entries(list))]))
        }
        try check(Node64.self, Self.map([("value", [0xf6]), ("prefix", Self.text("p")), ("children", entries([]))]))
        #expect(compared > 10_000)
        #expect(accepted > 10)
    }

    // MARK: - Inputs

    static func text(_ string: String) -> [UInt8] {
        var writer = DagCBORWriter()
        writer.writeText(string)
        return writer.bytes
    }

    /// A map of the entries as given: no sorting, no deduplication.
    static func map(_ entries: [(String, [UInt8])]) -> Data {
        var writer = DagCBORWriter()
        writer.writeHead(major: 5, UInt64(entries.count))
        var bytes = writer.bytes
        for (key, value) in entries {
            bytes += text(key) + value
        }
        return Data(bytes)
    }

    /// Every byte deleted, replaced or preceded by another; every prefix;
    /// every head widened; trailing bytes.
    static func mutants(of data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var out: [Data] = [data, data + [0x00]]
        for index in bytes.indices {
            var deleted = bytes
            deleted.remove(at: index)
            out.append(Data(deleted))
            out.append(Data(bytes[..<index]))
            for replacement in [bytes[index] ^ 0x01, bytes[index] ^ 0x20, bytes[index] ^ 0x80, 0x00, 0xf6, 0xff] {
                var replaced = bytes
                replaced[index] = replacement
                out.append(Data(replaced))
            }
            for inserted in [0x00, 0x60, 0xa0, 0xf6] as [UInt8] {
                var grown = bytes
                grown.insert(inserted, at: index)
                out.append(Data(grown))
            }
            if let widened = widened(bytes, at: index) {
                out.append(Data(widened))
            }
        }
        return out
    }

    /// `bytes` with the byte at `index`, read as a head of major 0–5, written
    /// one width wider: the same value, not in its shortest form.
    static func widened(_ bytes: [UInt8], at index: Int) -> [UInt8]? {
        let initial = bytes[index]
        let major = initial >> 5
        let additional = initial & 0x1f
        guard major <= 5, additional <= 26 else { return nil }
        let width = additional < 24 ? 0 : 1 << Int(additional - 24)
        guard index + width < bytes.count else { return nil }
        var value: UInt64 = additional < 24 ? UInt64(additional) : 0
        for offset in stride(from: 1, through: width, by: 1) {
            value = value << 8 | UInt64(bytes[index + offset])
        }
        let wider = additional < 24 ? 1 : width * 2
        var head: [UInt8] = [major << 5 | UInt8(24 + wider.trailingZeroBitCount)]
        for shift in stride(from: (wider - 1) * 8, through: 0, by: -8) {
            head.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
        return Array(bytes[..<index]) + head + Array(bytes[(index + 1 + width)...])
    }
}
