import Testing
import Foundation
import CID
@preconcurrency import Multicodec
import Multihash
import Multibase
@testable import cashew

/// Checking content against a CID by its digest alone must accept and refuse
/// exactly what parsing the CID did, with the same error: which content a
/// CID names is consensus.
@Suite("Content address check: digest comparison agrees with CID parsing")
struct ContentAddressDifferentialTests {
    /// The check as cashew 5.0.6 shipped it, verbatim, kept only to test against.
    static func verifyByParsing(_ data: Data, matches rawCID: String) throws {
        let expectedCID = try CID(rawCID)
        guard expectedCID.multihash.algorithm == .sha2_256,
              expectedCID.multihash.length == 32 else {
            throw DataErrors.cidCreationFailed
        }
        let actualMultihash = try Multihash(raw: data, hashedWith: .sha2_256)
        let actualCID = try CID(
            version: expectedCID.version,
            codec: expectedCID.codec,
            multihash: actualMultihash
        )
        guard actualCID == expectedCID else { throw DataErrors.cidMismatch }
    }

    static func answer(_ body: () throws -> Void) -> String {
        do { try body(); return "ok" } catch { return "error " + String(reflecting: error) }
    }

    struct Tally { var cases = 0; var accepted = 0; var fast = 0; var disagreements: [String] = [] }

    static func check(_ data: Data, _ cid: String, _ tally: inout Tally) {
        let old = answer { try verifyByParsing(data, matches: cid) }
        let new = answer { try verifyContentAddress(data, matches: cid) }
        tally.cases += 1
        if old == "ok" { tally.accepted += 1 }
        if isCanonicalDagCBORSHA256CID(cid) { tally.fast += 1 }
        if old != new, tally.disagreements.count < 20 {
            tally.disagreements.append("\(cid) [\(data.count) B]: old \(old) new \(new)")
        }
    }

    static func bytes(_ count: Int, _ rng: inout SplitMix64) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    /// A CID of `data` in some shape cashew can parse, in some spelling.
    static func cid(of data: Data, _ rng: inout SplitMix64) throws -> String {
        let codecs: [Codecs] = [.dag_cbor, .dag_cbor, .dag_cbor, .raw, .dag_json, .dag_pb]
        let hashes: [(Codecs, Int?)] = [(.sha2_256, nil), (.sha2_256, nil), (.sha2_256, nil), (.sha2_256, 16),
                                        (.sha2_256, 31), (.sha2_512, nil), (.sha2_512, 32), (.sha1, nil), (.identity, nil)]
        let (hash, length) = hashes.randomElement(using: &rng)!
        // An identity "digest" of long content is refused; hash that content instead.
        let multihash = try (try? Multihash(raw: data, hashedWith: hash, customByteLength: length))
            ?? Multihash(raw: data, hashedWith: .sha2_256)
        if Int.random(in: 0..<8, using: &rng) == 0, hash == .sha2_256, length == nil {
            return try CID(v0WithMultihash: multihash).toBaseEncodedString
        }
        let cid = try CID(version: .v1, codec: codecs.randomElement(using: &rng)!, multihash: multihash)
        let spellings: [BaseEncoding] = [.base32, .base32, .base32, .base32Upper, .base58btc, .base64, .base16, .base32Pad]
        let base = spellings.randomElement(using: &rng)!
        return base == .base32 ? cid.toBaseEncodedString : base.encode(data: cid.rawData)
    }

    static func mutate(_ text: String, _ rng: inout SplitMix64) -> String {
        var utf8 = Array(text.utf8)
        guard !utf8.isEmpty else { return "b" }
        let i = Int.random(in: 0..<utf8.count, using: &rng)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567ABCDEFGHIJKLMNOPQRSTUVWXYZ0189=+/-_ Qmzfu".utf8)
        switch Int.random(in: 0..<8, using: &rng) {
        case 0: utf8[i] = alphabet.randomElement(using: &rng)!
        case 1: // one letter's case
            if (0x41...0x5a).contains(utf8[i]) || (0x61...0x7a).contains(utf8[i]) { utf8[i] ^= 0x20 }
        case 2: utf8.removeLast(Int.random(in: 1...min(3, utf8.count), using: &rng))
        case 3: utf8.append(alphabet.randomElement(using: &rng)!)
        case 4: utf8 += Array("=".utf8)
        case 5: utf8[0] = Array("bBzfFmMuUk".utf8).randomElement(using: &rng)!
        case 6: // the last digit, whose low bits are padding
            utf8[utf8.count - 1] = Array("abcdefghijklmnopqrstuvwxyz234567".utf8).randomElement(using: &rng)!
        default: utf8 = Array(String(decoding: utf8, as: UTF8.self).uppercased().utf8)
        }
        return String(decoding: utf8, as: UTF8.self)
    }

    @Test("Fixed texts get the same answer")
    func fixed() throws {
        var tally = Tally()
        let data = Data("content-addressed payload".utf8)
        let standard = try HeaderImpl(node: TestScalar(val: 7)).rawCID
        let standardData = try DagCBOR.encode(TestScalar(val: 7))
        for text in ["", "b", "B", "z", "Qm", "bafy", standard, standard.uppercased(), "B" + standard.dropFirst().uppercased(),
                     standard + "=", String(standard.dropLast()), String(standard.dropLast()) + "b",
                     String(standard.dropLast()) + "r", " " + standard, standard + "\n",
                     "b" + String(repeating: "a", count: 58), "b" + String(repeating: "7", count: 58)] {
            for content in [data, standardData, Data()] { Self.check(content, text, &tally) }
        }
        #expect(tally.disagreements.isEmpty, "\(tally.disagreements.joined(separator: "\n"))")
        #expect(tally.accepted > 0)
    }

    @Test("Random CIDs of every shape, and their mutations, get the same answer", arguments: 0..<4)
    func randomized(_ shard: Int) throws {
        var rng = SplitMix64(seed: UInt64(0xD16E57 &+ shard))
        var tally = Tally()
        for _ in 0..<12_000 {
            let data = Self.bytes(Int.random(in: 0..<300, using: &rng), &rng)
            let other = Self.bytes(Int.random(in: 0..<300, using: &rng), &rng)
            // Half in the standard shape and spelling, which takes the digest path.
            let text = Bool.random(using: &rng)
                ? try HeaderImpl<TestScalar>.standardCID(of: data) : try Self.cid(of: data, &rng)
            Self.check(data, text, &tally)
            Self.check(other, text, &tally)
            for _ in 0..<3 {
                let mutated = Self.mutate(text, &rng)
                Self.check(data, mutated, &tally)
                Self.check(other, mutated, &tally)
            }
        }
        print("shard \(shard): \(tally.cases) cases, \(tally.accepted) accepted, \(tally.fast) on the digest path")
        #expect(tally.disagreements.isEmpty, "\(tally.disagreements.joined(separator: "\n"))")
        #expect(tally.cases >= 90_000)
        #expect(tally.fast > tally.cases / 8)
    }
}

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

extension HeaderImpl {
    /// CIDv1, dag-cbor, sha2-256 of `data`, as cashew spells it.
    static func standardCID(of data: Data) throws -> String {
        cidText(try CID(version: .v1, codec: .dag_cbor, multihash: try Multihash(raw: data, hashedWith: .sha2_256)))
    }
}
