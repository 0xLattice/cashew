import Testing
import Foundation
import CID
@preconcurrency import Multicodec
import Multihash
import Multibase
@testable import cashew

/// `canonicalCID` and the CID text cashew produces skip the multiformats
/// libraries' string round-trip; these pin them to what that round-trip gives.
@Suite("CID text")
struct CIDTextTests {
    /// `canonicalCID` as the libraries spell it: parse, rebuild, re-encode.
    private func libraryCanonicalCID(_ rawCID: String) -> String {
        guard let cid = try? CID(rawCID),
              let canonical = try? CID(version: cid.version, codec: cid.codec, multihash: cid.multihash)
        else { return rawCID }
        return canonical.toBaseEncodedString
    }

    private func randomBytes(_ count: Int, _ rng: inout some RandomNumberGenerator) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }

    private func standardText(_ digest: [UInt8]) -> String {
        "b" + BaseEncoding.base32.encode(data: Data([0x01, 0x71, 0x12, 0x20] + digest)).dropFirst()
    }

    @Test("The local base32 encoder is the library's v1 CID text, at every tail length")
    func base32MatchesTheLibrary() throws {
        var rng = SystemRandomNumberGenerator()
        // (codec, hash, digest length): binary lengths cover every byte count mod 5.
        let shapes: [(Codecs, Codecs, Int)] = [
            (.dag_cbor, .sha2_256, 32), (.raw, .sha2_256, 32), (.dag_json, .sha2_256, 32),
            (.dag_cbor, .sha2_512, 64), (.raw, .sha1, 20), (.dag_json, .sha1, 20),
            (.dag_cbor, .sha2_256, 1), (.dag_cbor, .sha2_256, 2), (.raw, .sha2_256, 3), (.raw, .sha2_256, 0),
        ]
        for (codec, hash, length) in shapes {
            for _ in 0..<200 {
                let multihash = try Multihash(raw: Data(randomBytes(64, &rng)), hashedWith: hash, customByteLength: length)
                let cid = try CID(version: .v1, codec: codec, multihash: multihash)
                #expect(base32Multibase(cid.rawBuffer) == cid.toBaseEncodedString)
                #expect(cidText(cid) == cid.toBaseEncodedString)
            }
        }
        let v0 = try CID(v0WithMultihash: try Multihash(raw: Data("v0".utf8), hashedWith: .sha2_256))
        #expect(cidText(v0) == v0.toBaseEncodedString)
    }

    @Test("Canonical dag-cbor sha2-256 text maps to itself, as the full round-trip says")
    func canonicalStandardTextIsItsOwnCanonicalForm() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let text = standardText(randomBytes(32, &rng))
            #expect(isCanonicalDagCBORSHA256CID(text))
            #expect(libraryCanonicalCID(text) == text)
            #expect(canonicalCID(text) == text)
        }
    }

    @Test("Every other spelling takes the full round-trip and gets its answer")
    func otherSpellingsMatchTheLibrary() throws {
        var rng = SystemRandomNumberGenerator()
        let digits = Array("abcdefghijklmnopqrstuvwxyz234567")
        for _ in 0..<200 {
            let digest = randomBytes(32, &rng)
            let bytes = Data([0x01, 0x71, 0x12, 0x20] + digest)
            let text = standardText(digest)
            let last = digits.firstIndex(of: text.last!)!
            func base32(_ bytes: [UInt8]) -> String {
                "b" + BaseEncoding.base32.encode(data: Data(bytes)).dropFirst()
            }
            let chopped = String(text.dropLast())
            var spellings: [String] = [text.uppercased(), "B" + text.dropFirst().uppercased()]
            for base: BaseEncoding in [.base32Pad, .base16, .base58btc, .base64, .base36, .base32Hex] {
                spellings.append(base.encode(data: bytes))
            }
            spellings.append(base32([0x01, 0x55, 0x12, 0x20] + digest))        // raw codec
            spellings.append(base32([0x01, 0x70, 0x12, 0x20] + digest))        // dag-pb
            spellings.append(base32([0x01, 0xf1, 0x00, 0x12, 0x20] + digest))  // non-minimal codec varint
            spellings.append(base32([0x01, 0x71, 0x12, 0x20] + digest + [0]))  // trailing byte
            spellings += [chopped, text + "a", text + "=", " " + text, chopped + "1", chopped + "\u{212A}"]
            spellings.append(try CID(v0WithMultihash: try Multihash(raw: Data(digest), hashedWith: .sha2_256)).toBaseEncodedString)
            spellings += ["", "b", "not-a-cid"]
            for pad in 1...3 { spellings.append(chopped + String(digits[(last & ~3) | pad])) }
            for spelling in spellings {
                #expect(!isCanonicalDagCBORSHA256CID(spelling), "\(spelling)")
                #expect(canonicalCID(spelling) == libraryCanonicalCID(spelling), "\(spelling)")
            }
        }
    }

    @Test("Random texts get the library's answer")
    func randomTextsMatchTheLibrary() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567ABCXYZ019=b")
        for _ in 0..<5_000 {
            let length = Bool.random(using: &rng) ? 59 : Int.random(in: 0...80, using: &rng)
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
            #expect(canonicalCID(text) == libraryCanonicalCID(text), "\(text)")
            #expect(canonicalCID("b" + text.dropFirst()) == libraryCanonicalCID("b" + text.dropFirst()))
        }
    }
}
