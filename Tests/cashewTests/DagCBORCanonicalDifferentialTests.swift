import Testing
import Foundation
@testable import cashew

/// The one-pass canonical check must accept and refuse exactly what the
/// re-encode check of 5.0.6 did, with the same error: which content is valid
/// is consensus. Every input here goes through both, and their answers
/// (the value's bytes, or the error) must be identical.
@Suite("DAG-CBOR canonical check: one pass agrees with re-encode")
struct DagCBORCanonicalDifferentialTests {

    // MARK: - Types decoded

    /// Any tree, read through the Codable API alone.
    indirect enum Dyn: Codable {
        case null, bool(Bool), uint(UInt64), int(Int64), double(Double), string(String)
        case array([Dyn]), map([String: Dyn])

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            if var items = try? decoder.unkeyedContainer() {
                var array: [Dyn] = []
                while !items.isAtEnd { array.append(try items.decode(Dyn.self)) }
                self = .array(array)
                return
            }
            if let keyed = try? decoder.container(keyedBy: Key.self) {
                var map: [String: Dyn] = [:]
                for key in keyed.allKeys { map[key.stringValue] = try keyed.decode(Dyn.self, forKey: key) }
                self = .map(map)
                return
            }
            let single = try decoder.singleValueContainer()
            if single.decodeNil() { self = .null }
            else if let value = try? single.decode(Bool.self) { self = .bool(value) }
            else if let value = try? single.decode(UInt64.self) { self = .uint(value) }
            else if let value = try? single.decode(Int64.self) { self = .int(value) }
            else if let value = try? single.decode(Double.self) { self = .double(value) }
            else { self = .string(try single.decode(String.self)) }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
            case .bool(let v): var c = encoder.singleValueContainer(); try c.encode(v)
            case .uint(let v): var c = encoder.singleValueContainer(); try c.encode(v)
            case .int(let v): var c = encoder.singleValueContainer(); try c.encode(v)
            case .double(let v): var c = encoder.singleValueContainer(); try c.encode(v)
            case .string(let v): var c = encoder.singleValueContainer(); try c.encode(v)
            case .array(let items):
                var c = encoder.unkeyedContainer()
                for item in items { try c.encode(item) }
            case .map(let entries):
                var c = encoder.container(keyedBy: Key.self)
                for (key, value) in entries { try c.encode(value, forKey: Key(stringValue: key)) }
            }
        }
    }

    /// A record with every kind of field: optionals written only when present,
    /// a narrowed float, base64 `Data`, small and wide integers, nesting.
    struct Rec: Codable {
        var id: Int
        var name: String
        var note: String?
        var ratio: Double
        var weight: Float?
        var blob: Data?
        var small: Int8
        var big: UInt64
        var neg: Int32
        var tags: [String]
        var attrs: [String: Int]
        var flag: Bool
        var children: [Rec]?
    }

    /// Writes an absent optional as an explicit null, so a null is canonical here.
    struct ExplicitNull: Codable {
        var a: Int?
        var b: String
        enum CodingKeys: String, CodingKey { case a, b }
        init(a: Int?, b: String) { self.a = a; self.b = b }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            a = try c.decodeIfPresent(Int.self, forKey: .a)
            b = try c.decode(String.self, forKey: .b)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(a, forKey: .a)
            try c.encode(b, forKey: .b)
        }
    }

    /// Keys and text that Swift's String equality matches across Unicode
    /// spellings: a fixed key "é" (precomposed) finds "e" + U+0301 when
    /// decoding, and text is precomposed on the way in. Either way the value
    /// written back is spelled differently from the bytes it was read from.
    struct Spellings: Codable {
        var accented: Int
        var text: String
        enum CodingKeys: String, CodingKey { case accented = "\u{e9}", text }
        init(accented: Int, text: String) { self.accented = accented; self.text = text }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accented = try c.decode(Int.self, forKey: .accented)
            text = try c.decode(String.self, forKey: .text).precomposedStringWithCanonicalMapping
        }
    }

    @available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
    struct Wide: Codable {
        var u: UInt128
        var i: Int128
    }

    // MARK: - Driver

    struct Tally {
        var cases = 0
        var accepted = 0
        var disagreements: [String] = []
    }

    /// Both checks' answer for `data` as `T`: the bytes of the value, or the error.
    static func answers<T: Codable>(_ type: T.Type, _ data: Data) -> (old: String, new: String) {
        func answer(_ body: () throws -> T) -> String {
            do { return "ok " + (try DagCBOR.encode(body())).map { String(format: "%02x", $0) }.joined() }
            catch { return "error " + describe(error) }
        }
        return (answer { try ReencodeOracle.decode(type, from: data) },
                answer { try DagCBOR.decode(type, from: data) })
    }

    /// An error, as far as it is the same from one run to the next. Where two
    /// fields both fail to decode, which failure is thrown follows a
    /// dictionary's iteration order, which differs from one dictionary to the
    /// next even within the old check alone: so a field's failure to decode
    /// (a decoding error or an integer out of range) is one answer.
    static func describe(_ error: Error) -> String {
        if error is DecodingError { return "undecodable" }
        if let error = error as? DagCBORError, case .integerOverflow = error { return "undecodable" }
        return String(reflecting: error)
    }

    static func check<T: Codable>(_ type: T.Type, _ data: Data, _ tally: inout Tally) {
        let (old, new) = answers(type, data)
        tally.cases += 1
        if old.hasPrefix("ok ") { tally.accepted += 1 }
        if old != new, tally.disagreements.count < 20 {
            tally.disagreements.append("\(T.self) \(data.map { String(format: "%02x", $0) }.joined()): old \(old) new \(new)")
        }
    }

    /// Decodes `data` as every type here.
    static func checkAll(_ data: Data, _ tally: inout Tally) {
        check(Dyn.self, data, &tally)
        check(Rec.self, data, &tally)
        check(ExplicitNull.self, data, &tally)
        check(Spellings.self, data, &tally)
        check(ScalarHeader.self, data, &tally)
        check(ScalarDict.self, data, &tally)
        check(RadixNodeImpl<ScalarHeader>.self, data, &tally)
        check(MerkleDictionaryImpl<String>.self, data, &tally)
        check(FlatDictionary<ScalarHeader>.self, data, &tally)
        check([String: Int].self, data, &tally)
        check([Int].self, data, &tally)
        check(String.self, data, &tally)
        check(Double.self, data, &tally)
        check(Float.self, data, &tally)
        check(Data.self, data, &tally)
        check(Int8.self, data, &tally)
        check(UInt64.self, data, &tally)
        check(Int?.self, data, &tally)
        if #available(macOS 15, iOS 18, watchOS 11, tvOS 18, *) { check(Wide.self, data, &tally) }
    }

    // MARK: - Fixed vectors

    /// The byte vectors the other DAG-CBOR tests spell out, and the edge of
    /// every rule: each head width at its boundary, every simple value, every
    /// float width, key order and repeats, trailing and missing bytes.
    static var vectors: [[UInt8]] {
        var v: [[UInt8]] = [
            [0xa2, 0x61, 0x61, 0x01, 0x61, 0x61, 0x02],
            [0xa2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x02],
            [0xa2, 0x61, 0x62, 0x01, 0x61, 0x61, 0x02],
            [0xa2, 0x62, 0x62, 0x62, 0x01, 0x61, 0x61, 0x02],
            [0xa2, 0x61, 0x61, 0x01, 0x62, 0x61, 0x61, 0x02],
            [], [0x00], [0x00, 0x00], [0x17], [0x18, 0x17], [0x18, 0x18], [0x19, 0x00, 0xff], [0x19, 0x01, 0x00],
            [0x1a, 0x00, 0x00, 0xff, 0xff], [0x1a, 0x00, 0x01, 0x00, 0x00],
            [0x1b, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff], [0x1b, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00],
            [0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], [0x3b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            [0x3b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], [0x20], [0x38, 0x17], [0x38, 0x18],
            [0x1c], [0x1f], [0x5f, 0xff], [0x9f, 0xff], [0xbf, 0xff], [0x7f, 0xff],
            [0x40], [0x41, 0x00], [0x60], [0x61, 0x61], [0x78, 0x01, 0x61], [0x79, 0x00, 0x01, 0x61],
            [0x80], [0x98, 0x00], [0x81, 0x00], [0x98, 0x01, 0x00], [0xa0], [0xb8, 0x00],
            [0xf4], [0xf5], [0xf6], [0xf7], [0xf0], [0xf8, 0x20], [0xff],
            [0xf9, 0x3c, 0x00], [0xf9, 0x7e, 0x00], [0xfa, 0x3f, 0x80, 0x00, 0x00],
            [0xfb, 0x3f, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], [0xfb, 0x7f, 0xf8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01],
            [0xfb, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], [0xfb, 0x3f, 0xb9, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a],
            [0xd8, 0x2a, 0x41, 0x00], [0xc0, 0x60],
            [0xa1, 0x01, 0x02], [0xa1, 0x41, 0x61, 0x02], [0xa1, 0x61, 0x61], [0x81],
            [0xa1, 0x61, 0x62, 0xf6], [0xa2, 0x61, 0x61, 0xf6, 0x61, 0x62, 0x61, 0x78],
            [0xa1, 0x61, 0x62, 0x61, 0x78], [0xa2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x61, 0x78],
            [0xa2, 0x61, 0x61, 0xf7, 0x61, 0x62, 0x61, 0x78],
            // "é" precomposed and decomposed: canonically equivalent, different bytes.
            [0xa2, 0x62, 0xc3, 0xa9, 0x01, 0x63, 0x65, 0xcc, 0x81, 0x02],
            [0xa1, 0x62, 0xc3, 0xa9, 0x01], [0xa1, 0x63, 0x65, 0xcc, 0x81, 0x01],
            [0x62, 0xc3, 0xa9], [0x63, 0x65, 0xcc, 0x81],
            // {"é": 1, "text": "é"} with each "é" in either spelling.
            [0xa2, 0x62, 0xc3, 0xa9, 0x01, 0x64, 0x74, 0x65, 0x78, 0x74, 0x62, 0xc3, 0xa9],
            [0xa2, 0x63, 0x65, 0xcc, 0x81, 0x01, 0x64, 0x74, 0x65, 0x78, 0x74, 0x62, 0xc3, 0xa9],
            [0xa2, 0x62, 0xc3, 0xa9, 0x01, 0x64, 0x74, 0x65, 0x78, 0x74, 0x63, 0x65, 0xcc, 0x81],
            [0x64, 0x51, 0x51, 0x3d, 0x3d], [0x64, 0x51, 0x52, 0x3d, 0x3d], [0x63, 0x51, 0x51, 0x3d], [0x62, 0x51, 0x51],
        ]
        // Text the UTF-8 tests spell: well- and ill-formed, inside a map.
        let texts: [[UInt8]] = [[0xc0, 0xaf], [0xc0, 0x80], [0xe0, 0x80, 0xaf], [0xed, 0xa0, 0x80],
                                [0xf4, 0x90, 0x80, 0x80], [0xe2, 0x82], [0x80], [0xff], [0xef, 0xbb, 0xbf, 0x61],
                                [0xf0, 0x9f, 0x98, 0x80], [0x00]]
        for text in texts {
            v.append([0xa1, 0x64] + Array("text".utf8) + [0x60 | UInt8(text.count)] + text)
            v.append([0xa1, 0x60 | UInt8(text.count)] + text + [0x01])
        }
        // Nesting at and beyond the depth limit.
        for depth in [63, 64, 65] {
            v.append([UInt8](repeating: 0x81, count: depth) + [0x00])
        }
        return v
    }

    @Test("Fixed vectors at the edge of every rule get the same answer")
    func fixedVectors() throws {
        var tally = Tally()
        for vector in Self.vectors { Self.checkAll(Data(vector), &tally) }
        // And every value the generators can make, each as written.
        var rng = SplitMix64(seed: 1)
        for _ in 0..<200 { Self.checkAll(Gen.anyCanonical(&rng), &tally) }
        #expect(tally.disagreements.isEmpty, "\(tally.disagreements.joined(separator: "\n"))")
        #expect(tally.accepted > 0)
    }

    // MARK: - Randomized corpus and mutations

    @Test("Random values and their mutations get the same answer", arguments: 0..<8)
    func randomized(_ shard: Int) throws {
        var rng = SplitMix64(seed: UInt64(0xC0FFEE &+ shard))
        var tally = Tally()
        var mutated = 0
        let iterations = 1_000
        for _ in 0..<iterations {
            let (bytes, decodeAs) = Gen.typed(&rng)
            decodeAs(bytes, &tally)
            Self.check(Dyn.self, bytes, &tally)
            for _ in 0..<6 {
                let input = Mutate.any(bytes, &rng)
                mutated += 1
                decodeAs(input, &tally)
                Self.checkAll(input, &tally)
            }
        }
        print("shard \(shard): \(tally.cases) cases, \(tally.accepted) accepted, \(mutated) mutated inputs")
        #expect(tally.disagreements.isEmpty, "\(tally.disagreements.joined(separator: "\n"))")
        #expect(tally.cases > 100_000)
        #expect(tally.accepted > tally.cases / 50)
    }
}

// MARK: - Generators

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

typealias Diff = DagCBORCanonicalDifferentialTests

enum Gen {
    typealias Decode = (Data, inout Diff.Tally) -> Void

    static let keyPool = ["a", "b", "c", "aa", "ab", "id", "name", "note", "ratio", "weight", "blob", "small",
                          "big", "neg", "tags", "attrs", "flag", "children", "count", "rawCID", "encryptionInfo",
                          "key", "value", "u", "i", "", "\u{e9}", "e\u{301}", "\u{FEFF}k", "zz", "Index 0"]

    static func string(_ rng: inout SplitMix64) -> String {
        switch Int.random(in: 0..<6, using: &rng) {
        case 0: return keyPool.randomElement(using: &rng)!
        case 1: return ""
        case 2: return String((0..<Int.random(in: 1..<40, using: &rng)).map { _ in
            Character(UnicodeScalar(UInt8.random(in: 0x20...0x7e, using: &rng))) })
        case 3: return ["\u{e9}", "e\u{301}", "\u{1F600}", "\u{FEFF}", "\u{0}", "\u{10FFFF}", "日本"]
            .randomElement(using: &rng)!
        case 4: return Data((0..<Int.random(in: 0..<12, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            .base64EncodedString()
        default: return cid(&rng)
        }
    }

    static func cid(_ rng: inout SplitMix64) -> String {
        let node = TestScalar(val: Int.random(in: -1000...1000, using: &rng))
        return (try? ScalarHeader(node: node).rawCID) ?? "bafy"
    }

    static func double(_ rng: inout SplitMix64) -> Double {
        switch Int.random(in: 0..<8, using: &rng) {
        case 0: return Double(Int.random(in: -1000...1000, using: &rng))
        case 1: return Double(Float(Double.random(in: -1e6...1e6, using: &rng)))
        case 2: return [0.0, -0.0, .infinity, -.infinity, .nan, .leastNonzeroMagnitude, .greatestFiniteMagnitude,
                        Double(bitPattern: 0x7ff0_0000_0000_0001), Double(bitPattern: 0xfff8_0000_0000_1234)]
            .randomElement(using: &rng)!
        case 3: return Double(bitPattern: rng.next())
        default: return Double.random(in: -1e9...1e9, using: &rng)
        }
    }

    static func uint(_ rng: inout SplitMix64) -> UInt64 {
        // Near each head-width boundary, and anywhere.
        let edges: [UInt64] = [0, 23, 24, 255, 256, 65_535, 65_536, 4_294_967_295, 4_294_967_296, .max, UInt64(Int64.max)]
        switch Int.random(in: 0..<3, using: &rng) {
        case 0: return edges.randomElement(using: &rng)! &+ UInt64.random(in: 0...2, using: &rng) &- 1
        case 1: return UInt64.random(in: 0...300, using: &rng)
        default: return rng.next() >> UInt64.random(in: 0...63, using: &rng)
        }
    }

    static func dyn(_ rng: inout SplitMix64, depth: Int = 0) -> Diff.Dyn {
        let leaf = depth > 3 || Int.random(in: 0..<3, using: &rng) > 0
        if leaf {
            switch Int.random(in: 0..<7, using: &rng) {
            case 0: return .null
            case 1: return .bool(Bool.random(using: &rng))
            case 2: return .uint(uint(&rng))
            case 3: return .int(-1 - Int64(uint(&rng) >> 1))
            case 4: return .double(double(&rng))
            default: return .string(string(&rng))
            }
        }
        if Bool.random(using: &rng) {
            return .array((0..<Int.random(in: 0..<5, using: &rng)).map { _ in dyn(&rng, depth: depth + 1) })
        }
        var map: [String: Diff.Dyn] = [:]
        for _ in 0..<Int.random(in: 0..<5, using: &rng) { map[string(&rng)] = dyn(&rng, depth: depth + 1) }
        return .map(map)
    }

    static func rec(_ rng: inout SplitMix64, depth: Int = 0) -> Diff.Rec {
        Diff.Rec(
            id: Int(truncatingIfNeeded: uint(&rng)) &* (Bool.random(using: &rng) ? 1 : -1),
            name: string(&rng),
            note: Bool.random(using: &rng) ? string(&rng) : nil,
            ratio: double(&rng),
            weight: Bool.random(using: &rng) ? Float(double(&rng)) : nil,
            blob: Bool.random(using: &rng) ? Data((0..<Int.random(in: 0..<20, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }) : nil,
            small: Int8.random(in: .min ... .max, using: &rng),
            big: uint(&rng),
            neg: Int32.random(in: .min ... .max, using: &rng),
            tags: (0..<Int.random(in: 0..<4, using: &rng)).map { _ in string(&rng) },
            attrs: Dictionary((0..<Int.random(in: 0..<4, using: &rng)).map { _ in (string(&rng), Int.random(in: -500...500, using: &rng)) },
                              uniquingKeysWith: { a, _ in a }),
            flag: Bool.random(using: &rng),
            children: depth < 2 && Bool.random(using: &rng)
                ? (0..<Int.random(in: 0..<3, using: &rng)).map { _ in rec(&rng, depth: depth + 1) } : nil
        )
    }

    static func header(_ rng: inout SplitMix64) -> ScalarHeader {
        let info = Int.random(in: 0..<4, using: &rng) == 0 ? EncryptionInfo(keyHash: string(&rng), iv: string(&rng)) : nil
        return ScalarHeader(rawCID: cid(&rng), node: nil, encryptionInfo: info)
    }

    static func children(_ rng: inout SplitMix64) -> [Character: RadixHeaderImpl<ScalarHeader>] {
        var children: [Character: RadixHeaderImpl<ScalarHeader>] = [:]
        for _ in 0..<Int.random(in: 0..<6, using: &rng) {
            let h = header(&rng)
            children[Character(UnicodeScalar(UInt8.random(in: 0x61...0x7a, using: &rng)))] =
                RadixHeaderImpl(rawCID: h.rawCID, node: nil, encryptionInfo: h.encryptionInfo)
        }
        return children
    }

    static func scalarDict(_ rng: inout SplitMix64) -> ScalarDict {
        ScalarDict(children: children(&rng), count: Int.random(in: 0...1000, using: &rng))
    }

    static func radixNode(_ rng: inout SplitMix64) -> RadixNodeImpl<ScalarHeader> {
        RadixNodeImpl(prefix: string(&rng), value: Bool.random(using: &rng) ? header(&rng) : nil, children: children(&rng))
    }

    /// A value of some type, written canonically, and how to decode it as that type.
    static func typed(_ rng: inout SplitMix64) -> (Data, Decode) {
        func make<T: Codable>(_ value: T) -> (Data, Decode) {
            ((try? DagCBOR.encode(value)) ?? Data([0xf6]), { data, tally in Diff.check(T.self, data, &tally) })
        }
        switch Int.random(in: 0..<10, using: &rng) {
        case 0, 1: return make(dyn(&rng))
        case 2, 3: return make(rec(&rng))
        case 4: return make(header(&rng))
        case 5: return Bool.random(using: &rng) ? make(scalarDict(&rng)) : make(radixNode(&rng))
        case 6:
            var entries: [String: ScalarHeader] = [:]
            for _ in 0..<Int.random(in: 0..<5, using: &rng) { entries[string(&rng)] = header(&rng) }
            return make(FlatDictionary(entries))
        case 8: return make(Diff.Spellings(accented: Int.random(in: -9...9, using: &rng),
                                           text: ["\u{e9}t\u{e9}", "plain", string(&rng)].randomElement(using: &rng)!))
        case 7: return make(Diff.ExplicitNull(a: Bool.random(using: &rng) ? Int.random(in: -99...99, using: &rng) : nil,
                                              b: string(&rng)))
        default:
            if #available(macOS 15, iOS 18, watchOS 11, tvOS 18, *) {
                return make(Diff.Wide(u: UInt128(uint(&rng)), i: Int128(Int64(bitPattern: rng.next()))))
            }
            return make(dyn(&rng))
        }
    }

    static func anyCanonical(_ rng: inout SplitMix64) -> Data { typed(&rng).0 }
}

// MARK: - Mutations

enum Mutate {
    typealias V = DagCBOR.CBORValue

    static func any(_ data: Data, _ rng: inout SplitMix64) -> Data {
        var bytes = [UInt8](data)
        switch Int.random(in: 0..<10, using: &rng) {
        case 0: // flip bytes
            guard !bytes.isEmpty else { return data }
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
        case 1: // truncate
            bytes = Array(bytes.prefix(Int.random(in: 0...max(0, bytes.count - 1), using: &rng)))
        case 2: // trailing bytes
            bytes += (0..<Int.random(in: 1...3, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        case 3: // insert or delete a byte
            if Bool.random(using: &rng) || bytes.isEmpty {
                bytes.insert(UInt8.random(in: 0...255, using: &rng), at: Int.random(in: 0...bytes.count, using: &rng))
            } else {
                bytes.remove(at: Int.random(in: 0..<bytes.count, using: &rng))
            }
        case 4, 5, 6: // respell the same tree in a way the encoder would not
            guard let tree = try? ReencodeOracle.parse(data) else { return data }
            var out: [UInt8] = []
            var writer = Writer(rng: rng, deviation: Double.random(in: 0.02...0.3, using: &rng))
            writer.write(tree, to: &out)
            _ = rng.next()
            bytes = out
        default: // change the value, then write it canonically
            guard let tree = try? ReencodeOracle.parse(data) else { return data }
            var out: [UInt8] = []
            var writer = Writer(rng: rng, deviation: 0)
            writer.write(change(tree, &rng), to: &out)
            bytes = out
        }
        return Data(bytes)
    }

    /// The tree with one node somewhere changed in value.
    static func change(_ value: V, _ rng: inout SplitMix64) -> V {
        let here = Int.random(in: 0..<3, using: &rng) == 0
        switch value {
        case .array(var items) where !items.isEmpty && !here:
            let i = Int.random(in: 0..<items.count, using: &rng)
            items[i] = change(items[i], &rng)
            return .array(items)
        case .map(var entries) where !entries.isEmpty && !here:
            let i = Int.random(in: 0..<entries.count, using: &rng)
            switch Int.random(in: 0..<8, using: &rng) {
            case 0: entries[i].0 = Gen.string(&rng) // rename
            case 1: entries.append((Gen.string(&rng), leaf(&rng))) // extra key
            case 2: entries.remove(at: i) // drop key
            case 3: entries[i].1 = .null // explicit null
            case 4: entries.append(entries[i]) // repeat key
            case 5: entries[i].0 = entries[i].0 + String(entries[i].0.prefix(1)) // longer key
            default: entries[i].1 = change(entries[i].1, &rng)
            }
            return .map(entries)
        default:
            switch value {
            case .string(let s):
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: return .string(s.uppercased())
                case 1: return .string("B" + s.dropFirst().uppercased()) // base32upper CID spelling
                case 2: return .string(s.replacingOccurrences(of: "=", with: ""))
                case 3: return .string(s.decomposedStringWithCanonicalMapping)
                default: return .string(s + "x")
                }
            case .uint(let u):
                return Bool.random(using: &rng) ? .uint(u &+ 1) : .nint(u)
            case .double(let d):
                return Bool.random(using: &rng) ? .double(Double(Float(d))) : .double(d + 1e-300)
            default:
                return leaf(&rng)
            }
        }
    }

    static func leaf(_ rng: inout SplitMix64) -> V {
        switch Int.random(in: 0..<7, using: &rng) {
        case 0: return .null
        case 1: return .bool(Bool.random(using: &rng))
        case 2: return .uint(Gen.uint(&rng))
        case 3: return .nint(Gen.uint(&rng))
        case 4: return .double(Gen.double(&rng))
        case 5: return .array([])
        default: return .string(Gen.string(&rng))
        }
    }

    /// Writes a tree as CBOR; with probability `deviation` per node, in a
    /// spelling the encoder would not use.
    struct Writer {
        var rng: SplitMix64
        let deviation: Double

        mutating func deviate() -> Bool { deviation > 0 && Double.random(in: 0..<1, using: &rng) < deviation }

        mutating func head(_ major: UInt8, _ value: UInt64, to out: inout [UInt8]) {
            var width = value < 24 ? 0 : value <= 0xff ? 1 : value <= 0xffff ? 2 : value <= 0xffff_ffff ? 4 : 8
            if deviate(), width < 8 {
                width = [1, 2, 4, 8].filter { $0 > width }.randomElement(using: &rng)!
            }
            switch width {
            case 0: out.append(major << 5 | UInt8(value))
            case 1: out.append(major << 5 | 24)
            case 2: out.append(major << 5 | 25)
            case 4: out.append(major << 5 | 26)
            default: out.append(major << 5 | 27)
            }
            for i in stride(from: width - 1, through: 0, by: -1) where width > 0 {
                out.append(UInt8(truncatingIfNeeded: value >> (UInt64(i) * 8)))
            }
        }

        mutating func write(_ value: V, to out: inout [UInt8]) {
            switch value {
            case .uint(let u): head(0, u, to: &out)
            case .nint(let u): head(1, u, to: &out)
            case .bytes(let d): head(2, UInt64(d.count), to: &out); out += d
            case .string(let s):
                let utf8 = Array(s.utf8)
                if deviate() {
                    switch Int.random(in: 0..<3, using: &rng) {
                    case 0: head(2, UInt64(utf8.count), to: &out); out += utf8; return // as bytes
                    case 1: out.append(0x7f); head(3, UInt64(utf8.count), to: &out); out += utf8; out.append(0xff); return
                    default: out += [0xd8, 0x2a] // tagged
                    }
                }
                head(3, UInt64(utf8.count), to: &out); out += utf8
            case .bool(let b): out.append(b ? 0xf5 : 0xf4)
            case .null: out.append(deviate() ? 0xf7 : 0xf6)
            case .double(let d):
                if deviate() {
                    let f = Float(d)
                    if Double(f).bitPattern == d.bitPattern || d.isNaN {
                        out.append(0xfa)
                        let bits = f.bitPattern
                        out += [UInt8(bits >> 24), UInt8(bits >> 16 & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits & 0xff)]
                        return
                    }
                    if d == 1.0 || d == 0.0 { out += [0xf9, d == 1.0 ? 0x3c : 0x00, 0x00]; return }
                }
                out.append(0xfb)
                let bits = d.bitPattern
                for i in stride(from: 7, through: 0, by: -1) { out.append(UInt8(truncatingIfNeeded: bits >> (UInt64(i) * 8))) }
            case .array(var items):
                if deviate(), !items.isEmpty {
                    switch Int.random(in: 0..<3, using: &rng) {
                    case 0: items.append(items[0])
                    case 1: items.removeLast()
                    default:
                        out.append(0x9f); for item in items { write(item, to: &out) }; out.append(0xff); return
                    }
                }
                head(4, UInt64(items.count), to: &out)
                for item in items { write(item, to: &out) }
            case .map(var entries):
                entries.sort { DagCBOR.keyPrecedes($0.0, $1.0) }
                var count = UInt64(entries.count)
                if deviate(), !entries.isEmpty {
                    switch Int.random(in: 0..<5, using: &rng) {
                    case 0: entries.shuffle(using: &rng)
                    case 1 where entries.count > 1:
                        let i = Int.random(in: 0..<(entries.count - 1), using: &rng)
                        entries.swapAt(i, i + 1)
                    case 2: entries.insert(entries[0], at: 1); count += 1
                    case 3: count += 1 // declares more than it holds
                    default:
                        out.append(0xbf)
                        for (k, v) in entries { write(.string(k), to: &out); write(v, to: &out) }
                        out.append(0xff); return
                    }
                }
                head(5, count, to: &out)
                for (k, v) in entries { write(.string(k), to: &out); write(v, to: &out) }
            }
        }
    }
}
