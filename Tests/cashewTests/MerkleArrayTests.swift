import Testing
import Foundation
import ArrayTrie
import Crypto
@testable import cashew

typealias StringArray = MerkleArrayImpl<String>
typealias OuterArray = MerkleArrayImpl<HeaderImpl<StringArray>>

@Suite("MerkleArray Basics")
struct MerkleArrayBasicsTests {

    @Test("Empty array has count 0")
    func testEmptyArray() {
        let arr = StringArray()
        #expect(arr.count == 0)
    }

    @Test("Binary key is 256 characters of 0 and 1")
    func testBinaryKeyFormat() {
        let key = StringArray.binaryKey(0)
        #expect(key.count == 256)
        #expect(key.allSatisfy { $0 == "0" || $0 == "1" })
        #expect(key == String(repeating: "0", count: 256))
    }

    @Test("Binary key for 1 has trailing 1")
    func testBinaryKeyOne() {
        let key = StringArray.binaryKey(1)
        #expect(key.count == 256)
        #expect(key.last == "1")
        #expect(key.dropLast() == String(repeating: "0", count: 255)[...])
    }

    @Test("Binary key for 255 is correct")
    func testBinaryKey255() {
        let key = StringArray.binaryKey(255)
        #expect(key.count == 256)
        #expect(key.hasSuffix("11111111"))
        #expect(key.prefix(248) == String(repeating: "0", count: 248)[...])
    }

    @Test("Distinct indices produce distinct keys")
    func testDistinctKeys() {
        let keys = (0..<100).map { StringArray.binaryKey($0) }
        #expect(Set(keys).count == 100)
    }

    @Test("Append single element increments count")
    func testAppendSingle() throws {
        let arr = try StringArray().append("hello")
        #expect(arr.count == 1)
        #expect(try arr.get(at: 0) == "hello")
    }

    @Test("Append multiple elements preserves order")
    func testAppendMultiple() throws {
        var arr = StringArray()
        for i in 0..<10 {
            arr = try arr.append("item\(i)")
        }
        #expect(arr.count == 10)
        for i in 0..<10 {
            #expect(try arr.get(at: i) == "item\(i)")
        }
    }

    @Test("Get at out-of-bounds returns nil")
    func testGetOutOfBounds() throws {
        let arr = try StringArray().append("a").append("b")
        #expect(try arr.get(at: -1) == nil)
        #expect(try arr.get(at: 2) == nil)
        #expect(try arr.get(at: 100) == nil)
    }

    @Test("First and last accessors")
    func testFirstAndLast() throws {
        let arr = try StringArray().append("alpha").append("beta").append("gamma")
        #expect(try arr.first() == "alpha")
        #expect(try arr.last() == "gamma")
    }

    @Test("First and last on empty array return nil")
    func testFirstAndLastEmpty() throws {
        let arr = StringArray()
        #expect(try arr.first() == nil)
        #expect(try arr.last() == nil)
    }

    @Test("Append array to array")
    func testAppendArray() throws {
        var arr1 = StringArray()
        arr1 = try arr1.append("a").append("b")

        var arr2 = StringArray()
        arr2 = try arr2.append("c").append("d").append("e")

        let combined = try arr1.append(contentsOf: arr2)
        #expect(combined.count == 5)
        #expect(try combined.get(at: 0) == "a")
        #expect(try combined.get(at: 1) == "b")
        #expect(try combined.get(at: 2) == "c")
        #expect(try combined.get(at: 3) == "d")
        #expect(try combined.get(at: 4) == "e")
    }

    @Test("Append empty array is identity")
    func testAppendEmptyArray() throws {
        let arr = try StringArray().append("x")
        let combined = try arr.append(contentsOf: StringArray())
        #expect(combined.count == 1)
        #expect(try combined.get(at: 0) == "x")
    }

    @Test("Content addressability: same elements produce same CID")
    func testContentAddressability() throws {
        let arr1 = try StringArray().append("a").append("b").append("c")
        let arr2 = try StringArray().append("a").append("b").append("c")
        let h1 = try HeaderImpl(node: arr1)
        let h2 = try HeaderImpl(node: arr2)
        #expect(h1.rawCID == h2.rawCID)
    }

    @Test("Content addressability: different elements produce different CID")
    func testContentAddressabilityDifferent() throws {
        let arr1 = try StringArray().append("a").append("b")
        let arr2 = try StringArray().append("a").append("c")
        let h1 = try HeaderImpl(node: arr1)
        let h2 = try HeaderImpl(node: arr2)
        #expect(h1.rawCID != h2.rawCID)
    }
}

@Suite("MerkleArray as MerkleDictionary")
struct MerkleArrayAsDictionaryTests {

    @Test("allKeys returns binary keys for all indices")
    func testAllKeys() throws {
        let arr = try StringArray().append("a").append("b").append("c")
        let keys = try arr.allKeys()
        #expect(keys.count == 3)
        #expect(keys.contains(StringArray.binaryKey(0)))
        #expect(keys.contains(StringArray.binaryKey(1)))
        #expect(keys.contains(StringArray.binaryKey(2)))
    }

    @Test("allKeysAndValues returns index-keyed entries")
    func testAllKeysAndValues() throws {
        let arr = try StringArray().append("x").append("y")
        let kv = try arr.allKeysAndValues()
        #expect(kv.count == 2)
        #expect(kv[StringArray.binaryKey(0)] == "x")
        #expect(kv[StringArray.binaryKey(1)] == "y")
    }

    @Test("get(key:) works with binary key directly")
    func testGetByKey() throws {
        let arr = try StringArray().append("hello").append("world")
        let key1 = StringArray.binaryKey(1)
        #expect(try arr.get(key: key1) == "world")
    }

    @Test("inserting(key:value:) works with binary key directly")
    func testInsertByKey() throws {
        let arr = StringArray()
        let key = StringArray.binaryKey(0)
        let result = try arr.inserting(key: key, value: "direct")
        #expect(try result.get(key: key) == "direct")
    }

    @Test("Targeted resolution strategy on array")
    func testTargetedResolution() async throws {
        var arr = StringArray()
        for i in 0..<5 { arr = try arr.append("v\(i)") }
        let header = try HeaderImpl(node: arr)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<StringArray>(rawCID: header.rawCID)
        let resolved = try await unresolved.resolve(fetcher: fetcher)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set([StringArray.binaryKey(2)], value: .targeted)
        let partial = try await resolved.node!.resolve(paths: paths, fetcher: fetcher)
        #expect(try partial.get(at: 2) == "v2")
    }

    @Test("List resolution strategy on array")
    func testListResolution() async throws {
        let arr = try StringArray().append("a").append("b")
        let header = try HeaderImpl(node: arr)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<StringArray>(rawCID: header.rawCID)
        let resolved = try await unresolved.resolve(fetcher: fetcher)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set([""], value: .list)
        let listed = try await resolved.node!.resolve(paths: paths, fetcher: fetcher)
        #expect(listed.count == 2)
    }

    @Test("Recursive resolution strategy on array")
    func testRecursiveResolution() async throws {
        let arr = try StringArray().append("p").append("q").append("r")
        let header = try HeaderImpl(node: arr)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<StringArray>(rawCID: header.rawCID)
        let resolved = try await unresolved.resolve(fetcher: fetcher)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set([""], value: .recursive)
        let full = try await resolved.node!.resolve(paths: paths, fetcher: fetcher)
        #expect(try full.get(at: 0) == "p")
        #expect(try full.get(at: 1) == "q")
        #expect(try full.get(at: 2) == "r")
    }
}

@Suite("MerkleArray Transforms")
struct MerkleArrayTransformTests {

    @Test("Mutate element at index")
    func testMutateAtIndex() throws {
        let arr = try StringArray().append("a").append("b").append("c")
        let mutated = try arr.mutating(at: 1, value: "B")
        #expect(mutated.count == 3)
        #expect(try mutated.get(at: 0) == "a")
        #expect(try mutated.get(at: 1) == "B")
        #expect(try mutated.get(at: 2) == "c")
    }

    @Test("Mutate at invalid index throws")
    func testMutateInvalidIndex() throws {
        let arr = try StringArray().append("a")
        #expect(throws: TransformErrors.self) {
            try arr.mutating(at: 1, value: "nope")
        }
        #expect(throws: TransformErrors.self) {
            try arr.mutating(at: -1, value: "nope")
        }
    }

    @Test("Delete last element")
    func testDeleteLast() throws {
        let arr = try StringArray().append("a").append("b").append("c")
        let deleted = try arr.deleting(at: 2)
        #expect(deleted.count == 2)
        #expect(try deleted.get(at: 0) == "a")
        #expect(try deleted.get(at: 1) == "b")
    }

    @Test("Delete middle element swaps with last")
    func testDeleteMiddle() throws {
        let arr = try StringArray().append("a").append("b").append("c")
        let deleted = try arr.deleting(at: 0)
        #expect(deleted.count == 2)
        #expect(try deleted.get(at: 0) == "c")
        #expect(try deleted.get(at: 1) == "b")
    }

    @Test("Delete at invalid index throws")
    func testDeleteInvalidIndex() throws {
        let arr = try StringArray().append("a")
        #expect(throws: TransformErrors.self) {
            try arr.deleting(at: 1)
        }
    }

    @Test("Transform via ArrayTrie")
    func testTransformViaArrayTrie() throws {
        let arr = try StringArray().append("a").append("b").append("c")
        var transforms = ArrayTrie<Transform>()
        transforms.set([StringArray.binaryKey(1)], value: .update("B"))
        let result = try arr.transform(transforms: transforms)
        #expect(result != nil)
        #expect(try result!.get(at: 1) == "B")
        #expect(result!.count == 3)
    }

    @Test("Range transforms helper builds correct trie")
    func testRangeTransforms() throws {
        let arr = try StringArray().append("a").append("b").append("c").append("d")
        let transforms = StringArray.rangeTransforms(range: 1..<3, transform: .delete)
        let result = try arr.transform(transforms: transforms)
        #expect(result != nil)
        #expect(result!.count == 2)
    }
}

@Suite("MerkleArray Store and Resolve")
struct MerkleArrayStoreResolveTests {

    @Test("Store and resolve round-trip")
    func testStoreResolveRoundTrip() async throws {
        let arr = try StringArray().append("alpha").append("beta").append("gamma")
        let header = try HeaderImpl(node: arr)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<StringArray>(rawCID: header.rawCID)
        let resolved = try await unresolved.resolveRecursive(fetcher: fetcher)
        #expect(resolved.rawCID == header.rawCID)
        #expect(resolved.node!.count == 3)
        #expect(try resolved.node!.get(at: 0) == "alpha")
        #expect(try resolved.node!.get(at: 1) == "beta")
        #expect(try resolved.node!.get(at: 2) == "gamma")
    }

    @Test("Store, transform, re-store, re-resolve")
    func testStoreTransformRestore() async throws {
        let arr = try StringArray().append("x").append("y").append("z")
        let header = try HeaderImpl(node: arr)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let mutated = try arr.mutating(at: 1, value: "Y")
        let mutatedHeader = try HeaderImpl(node: mutated)
        try await mutatedHeader.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<StringArray>(rawCID: mutatedHeader.rawCID).resolveRecursive(fetcher: fetcher)
        #expect(try resolved.node!.get(at: 0) == "x")
        #expect(try resolved.node!.get(at: 1) == "Y")
        #expect(try resolved.node!.get(at: 2) == "z")
    }

    @Test("Large array store and resolve")
    func testLargeArrayStoreResolve() async throws {
        var arr = StringArray()
        for i in 0..<50 {
            arr = try arr.append("item\(i)")
        }
        let header = try HeaderImpl(node: arr)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<StringArray>(rawCID: header.rawCID).resolveRecursive(fetcher: fetcher)
        #expect(resolved.node!.count == 50)
        for i in 0..<50 {
            #expect(try resolved.node!.get(at: i) == "item\(i)")
        }
    }
}

@Suite("MerkleArray Range Resolution")
struct MerkleArrayRangeResolutionTests {

    @Test("Range resolve loads only requested indices")
    func testRangeResolve() async throws {
        var arr = StringArray()
        for i in 0..<10 {
            arr = try arr.append("val\(i)")
        }
        let header = try HeaderImpl(node: arr)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<StringArray>(rawCID: header.rawCID)
        let resolved = try await unresolved.resolve(fetcher: fetcher)
        let rangeResolved = try await resolved.node!.resolve(paths: StringArray.rangePaths(3..<6), fetcher: fetcher)

        #expect(rangeResolved.count == 10)
        #expect(try rangeResolved.get(at: 3) == "val3")
        #expect(try rangeResolved.get(at: 4) == "val4")
        #expect(try rangeResolved.get(at: 5) == "val5")
    }

    @Test("Range resolve with clamping")
    func testRangeResolveClamping() async throws {
        let arr = try StringArray().append("a").append("b").append("c")
        let header = try HeaderImpl(node: arr)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<StringArray>(rawCID: header.rawCID).resolve(fetcher: fetcher)
        let rangeResolved = try await resolved.node!.resolve(paths: StringArray.rangePaths(-5..<100), fetcher: fetcher)
        #expect(rangeResolved.count == 3)
        #expect(try rangeResolved.get(at: 0) == "a")
        #expect(try rangeResolved.get(at: 2) == "c")
    }

    @Test("Empty range returns self")
    func testEmptyRange() async throws {
        let arr = try StringArray().append("a")
        let result = try await arr.resolve(paths: StringArray.rangePaths(5..<5), fetcher: TestStoreFetcher())
        #expect(result.count == 1)
    }

    @Test("Range resolve with recursive inner strategy")
    func testRangeResolveRecursiveStrategy() async throws {
        let inner1 = try StringArray().append("x").append("y")
        let inner2 = try StringArray().append("p").append("q")
        let h1 = try HeaderImpl(node: inner1)
        let h2 = try HeaderImpl(node: inner2)

        var outer = OuterArray()
        outer = try outer.append(h1).append(h2)

        let header = try HeaderImpl(node: outer)
        let fetcher = TestStoreFetcher()
        try await h1.storeAsVolume(storer: fetcher)
        try await h2.storeAsVolume(storer: fetcher)
        try await header.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<OuterArray>(rawCID: header.rawCID)
        let resolved = try await unresolved.resolve(fetcher: fetcher)
        let rangeResolved = try await resolved.node!.resolve(paths: OuterArray.rangePaths(0..<1, innerStrategy: .recursive), fetcher: fetcher)

        let element = try rangeResolved.get(at: 0)
        #expect(element != nil)
        #expect(try element!.node!.get(at: 0) == "x")
        #expect(try element!.node!.get(at: 1) == "y")
    }
}

@Suite("MerkleArray Nested Range Resolution")
struct MerkleArrayNestedRangeTests {

    @Test("Nested range resolve: outer range + inner range")
    func testNestedRangeResolve() async throws {
        let inner1 = try StringArray().append("a0").append("a1").append("a2").append("a3")
        let inner2 = try StringArray().append("b0").append("b1").append("b2").append("b3")
        let inner3 = try StringArray().append("c0").append("c1").append("c2").append("c3")
        let h1 = try HeaderImpl(node: inner1)
        let h2 = try HeaderImpl(node: inner2)
        let h3 = try HeaderImpl(node: inner3)

        let outer = try OuterArray().append(h1).append(h2).append(h3)
        let header = try HeaderImpl(node: outer)
        let fetcher = TestStoreFetcher()
        try await h1.storeAsVolume(storer: fetcher)
        try await h2.storeAsVolume(storer: fetcher)
        try await h3.storeAsVolume(storer: fetcher)
        try await header.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<OuterArray>(rawCID: header.rawCID)
        let resolved = try await unresolved.resolve(fetcher: fetcher)
        let rangeResolved = try await resolved.node!.resolve(paths: OuterArray.rangePaths(0..<2, innerRange: 1..<3), fetcher: fetcher)

        let el0 = try rangeResolved.get(at: 0)
        #expect(el0 != nil)
        #expect(try el0!.node!.get(at: 1) == "a1")
        #expect(try el0!.node!.get(at: 2) == "a2")

        let el1 = try rangeResolved.get(at: 1)
        #expect(el1 != nil)
        #expect(try el1!.node!.get(at: 1) == "b1")
        #expect(try el1!.node!.get(at: 2) == "b2")
    }

    @Test("Nested transforms via ArrayTrie path chaining")
    func testNestedTransformChaining() throws {
        let inner1 = try StringArray().append("a0").append("a1").append("a2")
        let inner2 = try StringArray().append("b0").append("b1").append("b2")
        let h1 = try HeaderImpl(node: inner1)
        let h2 = try HeaderImpl(node: inner2)

        let outer = try OuterArray().append(h1).append(h2)

        let innerKey1 = StringArray.binaryKey(1)

        let innerTransforms: [[String]: Transform] = [
            [innerKey1]: .update("UPDATED")
        ]

        let result = try outer.transformNested(outerRange: 0..<2, innerTransforms: innerTransforms)
        #expect(result != nil)
        #expect(result!.count == 2)

        let r0 = try result!.get(at: 0)!
        #expect(try r0.node!.get(at: 0) == "a0")
        #expect(try r0.node!.get(at: 1) == "UPDATED")
        #expect(try r0.node!.get(at: 2) == "a2")

        let r1 = try result!.get(at: 1)!
        #expect(try r1.node!.get(at: 0) == "b0")
        #expect(try r1.node!.get(at: 1) == "UPDATED")
        #expect(try r1.node!.get(at: 2) == "b2")
    }

    @Test("Nested range transforms: insert into inner arrays across a range")
    func testNestedRangeInsert() throws {
        let inner1 = try StringArray().append("x")
        let inner2 = try StringArray().append("y")
        let h1 = try HeaderImpl(node: inner1)
        let h2 = try HeaderImpl(node: inner2)

        let outer = try OuterArray().append(h1).append(h2)

        let newKey = StringArray.binaryKey(1)
        let innerTransforms: [[String]: Transform] = [
            [newKey]: .insert("new")
        ]

        let result = try outer.transformNested(outerRange: 0..<2, innerTransforms: innerTransforms)
        #expect(result != nil)

        let r0 = try result!.get(at: 0)!
        #expect(r0.node!.count == 2)
        #expect(try r0.node!.get(at: 0) == "x")
        #expect(try r0.node!.get(at: 1) == "new")

        let r1 = try result!.get(at: 1)!
        #expect(r1.node!.count == 2)
        #expect(try r1.node!.get(at: 0) == "y")
        #expect(try r1.node!.get(at: 1) == "new")
    }

    @Test("Build nested transforms manually via ArrayTrie for full control")
    func testManualNestedTransformViaArrayTrie() throws {
        let inner1 = try StringArray().append("a").append("b")
        let inner2 = try StringArray().append("c").append("d")
        let h1 = try HeaderImpl(node: inner1)
        let h2 = try HeaderImpl(node: inner2)
        let outer = try OuterArray().append(h1).append(h2)

        var transforms = ArrayTrie<Transform>()
        transforms.set([OuterArray.binaryKey(0), StringArray.binaryKey(0)], value: .update("A"))
        transforms.set([OuterArray.binaryKey(1), StringArray.binaryKey(1)], value: .update("D"))

        let result = try outer.transform(transforms: transforms)
        #expect(result != nil)

        let r0 = try result!.get(at: 0)!
        #expect(try r0.node!.get(at: 0) == "A")
        #expect(try r0.node!.get(at: 1) == "b")

        let r1 = try result!.get(at: 1)!
        #expect(try r1.node!.get(at: 0) == "c")
        #expect(try r1.node!.get(at: 1) == "D")
    }

    @Test("Nested store, resolve range, verify partial load")
    func testNestedStoreAndRangeResolve() async throws {
        let inner1 = try StringArray().append("a0").append("a1").append("a2")
        let inner2 = try StringArray().append("b0").append("b1").append("b2")
        let inner3 = try StringArray().append("c0").append("c1").append("c2")
        let h1 = try HeaderImpl(node: inner1)
        let h2 = try HeaderImpl(node: inner2)
        let h3 = try HeaderImpl(node: inner3)
        let outer = try OuterArray().append(h1).append(h2).append(h3)

        let header = try HeaderImpl(node: outer)
        let fetcher = TestStoreFetcher()
        try await h1.storeAsVolume(storer: fetcher)
        try await h2.storeAsVolume(storer: fetcher)
        try await h3.storeAsVolume(storer: fetcher)
        try await header.storeAsVolume(storer: fetcher)

        let listResolved = try await HeaderImpl<OuterArray>(rawCID: header.rawCID)
            .resolveRecursive(fetcher: fetcher)

        let partial = try await listResolved.node!.resolve(paths: OuterArray.rangePaths(1..<2, innerStrategy: .recursive), fetcher: fetcher)

        let el1 = try partial.get(at: 1)!
        #expect(try el1.node!.get(at: 0) == "b0")
        #expect(try el1.node!.get(at: 1) == "b1")
        #expect(try el1.node!.get(at: 2) == "b2")
    }
}

@Suite("MerkleArray Structural Sharing")
struct MerkleArrayStructuralSharingTests {

    @Test("Append preserves structural sharing of prefix")
    func testStructuralSharingOnAppend() throws {
        let arr = try StringArray().append("a").append("b").append("c")
        let header1 = try HeaderImpl(node: arr)

        let extended = try arr.append("d")
        let header2 = try HeaderImpl(node: extended)

        #expect(header1.rawCID != header2.rawCID)
        #expect(extended.count == 4)
        #expect(try extended.get(at: 0) == "a")
        #expect(try extended.get(at: 3) == "d")
    }

    @Test("Mutate at index changes CID, preserves other elements")
    func testMutateChangeCID() throws {
        let arr = try StringArray().append("a").append("b").append("c")
        let h1 = try HeaderImpl(node: arr)
        let mutated = try arr.mutating(at: 1, value: "B")
        let h2 = try HeaderImpl(node: mutated)

        #expect(h1.rawCID != h2.rawCID)
        #expect(try mutated.get(at: 0) == "a")
        #expect(try mutated.get(at: 2) == "c")
    }
}

@Suite("MerkleArray Delete Scenarios")
struct MerkleArrayDeleteTests {

    @Test("Delete only element produces empty array")
    func testDeleteOnlyElement() throws {
        let arr = try StringArray().append("solo")
        let deleted = try arr.deleting(at: 0)
        #expect(deleted.count == 0)
        #expect(try deleted.get(at: 0) == nil)
    }

    @Test("Sequential deletes from end shrink array correctly")
    func testSequentialDeletesFromEnd() throws {
        var arr = try StringArray().append("a").append("b").append("c").append("d")
        arr = try arr.deleting(at: 3)
        #expect(arr.count == 3)
        arr = try arr.deleting(at: 2)
        #expect(arr.count == 2)
        arr = try arr.deleting(at: 1)
        #expect(arr.count == 1)
        #expect(try arr.get(at: 0) == "a")
        arr = try arr.deleting(at: 0)
        #expect(arr.count == 0)
    }

    @Test("Delete from front repeatedly")
    func testDeleteFromFrontRepeatedly() throws {
        var arr = try StringArray().append("a").append("b").append("c").append("d")
        arr = try arr.deleting(at: 0)
        #expect(arr.count == 3)
        #expect(try arr.get(at: 0) == "d")
        arr = try arr.deleting(at: 0)
        #expect(arr.count == 2)
        #expect(try arr.get(at: 0) == "c")
    }

    @Test("Delete preserves content addressability")
    func testDeleteContentAddressability() throws {
        let arr1 = try StringArray().append("a").append("b").append("c")
        let deleted1 = try arr1.deleting(at: 2)

        let arr2 = try StringArray().append("a").append("b").append("c")
        let deleted2 = try arr2.deleting(at: 2)

        let h1 = try HeaderImpl(node: deleted1)
        let h2 = try HeaderImpl(node: deleted2)
        #expect(h1.rawCID == h2.rawCID)
    }
}

@Suite("MerkleArray Batch Operations")
struct MerkleArrayBatchTests {

    @Test("Batch insert 100 elements and verify all")
    func testBatchInsert100() throws {
        var arr = StringArray()
        for i in 0..<100 {
            arr = try arr.append("entry_\(i)")
        }
        #expect(arr.count == 100)
        #expect(try arr.get(at: 0) == "entry_0")
        #expect(try arr.get(at: 50) == "entry_50")
        #expect(try arr.get(at: 99) == "entry_99")
    }

    @Test("Batch mutate via transforms")
    func testBatchMutateTransforms() throws {
        var arr = StringArray()
        for i in 0..<20 {
            arr = try arr.append("old_\(i)")
        }

        var transforms = ArrayTrie<Transform>()
        for i in stride(from: 0, to: 20, by: 2) {
            transforms.set([StringArray.binaryKey(i)], value: .update("new_\(i)"))
        }
        let result = try arr.transform(transforms: transforms)!
        #expect(result.count == 20)
        for i in 0..<20 {
            if i % 2 == 0 {
                #expect(try result.get(at: i) == "new_\(i)")
            } else {
                #expect(try result.get(at: i) == "old_\(i)")
            }
        }
    }

    @Test("Append two large arrays")
    func testAppendLargeArrays() throws {
        var arr1 = StringArray()
        for i in 0..<30 { arr1 = try arr1.append("A\(i)") }
        var arr2 = StringArray()
        for i in 0..<30 { arr2 = try arr2.append("B\(i)") }

        let combined = try arr1.append(contentsOf: arr2)
        #expect(combined.count == 60)
        #expect(try combined.get(at: 0) == "A0")
        #expect(try combined.get(at: 29) == "A29")
        #expect(try combined.get(at: 30) == "B0")
        #expect(try combined.get(at: 59) == "B29")
    }

    @Test("Interleaved append and mutate")
    func testInterleavedAppendMutate() throws {
        var arr = try StringArray().append("a").append("b")
        arr = try arr.mutating(at: 0, value: "A")
        arr = try arr.append("c")
        arr = try arr.mutating(at: 1, value: "B")
        arr = try arr.append("d")
        #expect(arr.count == 4)
        #expect(try arr.get(at: 0) == "A")
        #expect(try arr.get(at: 1) == "B")
        #expect(try arr.get(at: 2) == "c")
        #expect(try arr.get(at: 3) == "d")
    }
}

@Suite("MerkleArray with Header Elements")
struct MerkleArrayHeaderElementTests {

    @Test("Array of scalar headers: append, get, mutate")
    func testScalarHeaderArray() throws {
        let h1 = try HeaderImpl(node: TestScalar(val: 10))
        let h2 = try HeaderImpl(node: TestScalar(val: 20))
        let h3 = try HeaderImpl(node: TestScalar(val: 30))

        var arr = try EncryptableArray().append(h1).append(h2).append(h3)
        #expect(arr.count == 3)
        #expect(try arr.get(at: 0)?.node?.val == 10)
        #expect(try arr.get(at: 2)?.node?.val == 30)

        let h4 = try HeaderImpl(node: TestScalar(val: 99))
        arr = try arr.mutating(at: 1, value: h4)
        #expect(try arr.get(at: 1)?.node?.val == 99)
    }

    @Test("Array of scalar headers store and resolve")
    func testScalarHeaderArrayStoreResolve() async throws {
        let h1 = try HeaderImpl(node: TestScalar(val: 1))
        let h2 = try HeaderImpl(node: TestScalar(val: 2))
        let h3 = try HeaderImpl(node: TestScalar(val: 3))

        let arr = try EncryptableArray().append(h1).append(h2).append(h3)
        let header = try HeaderImpl(node: arr)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<EncryptableArray>(rawCID: header.rawCID)
            .resolveRecursive(fetcher: fetcher)
        #expect(resolved.node!.count == 3)
        #expect(try resolved.node!.get(at: 0)?.node?.val == 1)
        #expect(try resolved.node!.get(at: 1)?.node?.val == 2)
        #expect(try resolved.node!.get(at: 2)?.node?.val == 3)
    }

    @Test("Nested array: outer array of inner arrays, full lifecycle")
    func testNestedArrayFullLifecycle() async throws {
        let inner1 = try StringArray().append("row0col0").append("row0col1")
        let inner2 = try StringArray().append("row1col0").append("row1col1")
        let h1 = try HeaderImpl(node: inner1)
        let h2 = try HeaderImpl(node: inner2)

        let outer = try OuterArray().append(h1).append(h2)
        let outerHeader = try HeaderImpl(node: outer)
        let fetcher = TestStoreFetcher()
        try await h1.storeAsVolume(storer: fetcher)
        try await h2.storeAsVolume(storer: fetcher)
        try await outerHeader.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<OuterArray>(rawCID: outerHeader.rawCID)
            .resolveRecursive(fetcher: fetcher)

        #expect(resolved.node!.count == 2)
        let row0 = try resolved.node!.get(at: 0)!
        #expect(try row0.node!.get(at: 0) == "row0col0")
        #expect(try row0.node!.get(at: 1) == "row0col1")
        let row1 = try resolved.node!.get(at: 1)!
        #expect(try row1.node!.get(at: 0) == "row1col0")
        #expect(try row1.node!.get(at: 1) == "row1col1")

        let newInner = try StringArray().append("row0col0_updated").append("row0col1")
        let newH1 = try HeaderImpl(node: newInner)
        let mutatedOuter = try outer.mutating(at: 0, value: newH1)
        let mutatedHeader = try HeaderImpl(node: mutatedOuter)

        #expect(outerHeader.rawCID != mutatedHeader.rawCID)
        let r1Before = try outer.get(at: 1)!
        let r1After = try mutatedOuter.get(at: 1)!
        #expect(r1Before.rawCID == r1After.rawCID)
    }
}

@Suite("MerkleArray Range Query Performance")
struct MerkleArrayRangeQueryPerformanceTests {

    @Test("Range query on 200-element array fetches O(k) nodes, not O(n)")
    func testRangeQueryFetchCount() async throws {
        let n = 200
        let k = 5
        var arr = StringArray()
        for i in 0..<n {
            arr = try arr.append("item\(i)")
        }
        let header = try HeaderImpl(node: arr)
        let fetcher = CountingStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<StringArray>(rawCID: header.rawCID)
        fetcher.resetFetchCount()
        let resolved = try await unresolved.resolve(fetcher: fetcher)
        let topLevelFetches = fetcher.fetchCount

        fetcher.resetFetchCount()
        let rangeResolved = try await resolved.node!.resolve(paths: StringArray.rangePaths(50..<(50 + k)), fetcher: fetcher)
        let rangeFetches = fetcher.fetchCount

        for i in 50..<(50 + k) {
            #expect(try rangeResolved.get(at: i) == "item\(i)")
        }

        fetcher.resetFetchCount()
        _ = try await resolved.node!.resolveRecursive(fetcher: fetcher)
        let fullFetches = fetcher.fetchCount

        #expect(rangeFetches < fullFetches)
        #expect(rangeFetches < n)
        print("n=\(n), k=\(k): topLevel=\(topLevelFetches), range=\(rangeFetches), full=\(fullFetches)")
    }

    @Test("Range query fetch count scales with range size, not array size")
    func testRangeQueryScaling() async throws {
        var small = StringArray()
        for i in 0..<50 {
            small = try small.append("s\(i)")
        }
        var large = StringArray()
        for i in 0..<500 {
            large = try large.append("l\(i)")
        }

        let smallHeader = try HeaderImpl(node: small)
        let largeHeader = try HeaderImpl(node: large)

        let smallFetcher = CountingStoreFetcher()
        let largeFetcher = CountingStoreFetcher()
        try await smallHeader.storeAsVolume(storer: smallFetcher)
        try await largeHeader.storeAsVolume(storer: largeFetcher)

        let smallResolved = try await HeaderImpl<StringArray>(rawCID: smallHeader.rawCID).resolve(fetcher: smallFetcher)
        let largeResolved = try await HeaderImpl<StringArray>(rawCID: largeHeader.rawCID).resolve(fetcher: largeFetcher)

        let rangeSize = 5
        smallFetcher.resetFetchCount()
        let smallRange = try await smallResolved.node!.resolve(paths: StringArray.rangePaths(10..<(10 + rangeSize)), fetcher: smallFetcher)
        let smallFetches = smallFetcher.fetchCount

        largeFetcher.resetFetchCount()
        let largeRange = try await largeResolved.node!.resolve(paths: StringArray.rangePaths(10..<(10 + rangeSize)), fetcher: largeFetcher)
        let largeFetches = largeFetcher.fetchCount

        for i in 10..<(10 + rangeSize) {
            #expect(try smallRange.get(at: i) == "s\(i)")
            #expect(try largeRange.get(at: i) == "l\(i)")
        }

        let ratio = Double(largeFetches) / Double(smallFetches)
        #expect(ratio < 3.0)
        print("Same range(\(rangeSize)) on n=50: \(smallFetches) fetches, n=500: \(largeFetches) fetches, ratio=\(ratio)")
    }

    @Test("Full recursive resolve fetches proportional to n")
    func testFullResolveFetchCountScaling() async throws {
        var arr100 = StringArray()
        for i in 0..<100 { arr100 = try arr100.append("v\(i)") }
        var arr200 = StringArray()
        for i in 0..<200 { arr200 = try arr200.append("v\(i)") }

        let h100 = try HeaderImpl(node: arr100)
        let h200 = try HeaderImpl(node: arr200)
        let f100 = CountingStoreFetcher()
        let f200 = CountingStoreFetcher()
        try await h100.storeAsVolume(storer: f100)
        try await h200.storeAsVolume(storer: f200)

        _ = try await HeaderImpl<StringArray>(rawCID: h100.rawCID).resolveRecursive(fetcher: f100)
        let fetches100 = f100.fetchCount
        _ = try await HeaderImpl<StringArray>(rawCID: h200.rawCID).resolveRecursive(fetcher: f200)
        let fetches200 = f200.fetchCount

        let ratio = Double(fetches200) / Double(fetches100)
        #expect(ratio > 1.5)
        print("Full resolve: n=100 -> \(fetches100) fetches, n=200 -> \(fetches200) fetches, ratio=\(ratio)")
    }

    @Test("Range query fetches far fewer nodes than full resolve on large array")
    func testRangeVsFullOnLargeArray() async throws {
        let n = 500
        var arr = StringArray()
        for i in 0..<n { arr = try arr.append("elem\(i)") }

        let header = try HeaderImpl(node: arr)
        let fetcher = CountingStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<StringArray>(rawCID: header.rawCID).resolve(fetcher: fetcher)

        fetcher.resetFetchCount()
        let rangeResult = try await resolved.node!.resolve(paths: StringArray.rangePaths(0..<10), fetcher: fetcher)
        let rangeFetches = fetcher.fetchCount

        fetcher.resetFetchCount()
        _ = try await resolved.node!.resolveRecursive(fetcher: fetcher)
        let fullFetches = fetcher.fetchCount

        for i in 0..<10 {
            #expect(try rangeResult.get(at: i) == "elem\(i)")
        }

        #expect(Double(rangeFetches) / Double(fullFetches) < 0.25)
        print("n=\(n): range(0..<10)=\(rangeFetches) fetches, full=\(fullFetches) fetches, savings=\(100 - Int(Double(rangeFetches)/Double(fullFetches)*100))%")
    }

    @Test("Nested range query fetches fewer nodes than nested full resolve")
    func testNestedRangePerformance() async throws {
        let outerSize = 20
        let innerSize = 20
        var outer = OuterArray()
        let fetcher = CountingStoreFetcher()

        for i in 0..<outerSize {
            var inner = StringArray()
            for j in 0..<innerSize {
                inner = try inner.append("[\(i),\(j)]")
            }
            let innerHeader = try HeaderImpl(node: inner)
            try await innerHeader.storeAsVolume(storer: fetcher)
            outer = try outer.append(innerHeader)
        }
        let outerHeader = try HeaderImpl(node: outer)
        try await outerHeader.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<OuterArray>(rawCID: outerHeader.rawCID).resolve(fetcher: fetcher)

        fetcher.resetFetchCount()
        let rangeResult = try await resolved.node!.resolve(paths: OuterArray.rangePaths(2..<4, innerRange: 5..<8), fetcher: fetcher)
        let rangeFetches = fetcher.fetchCount

        let el2 = try rangeResult.get(at: 2)!
        #expect(try el2.node!.get(at: 5) == "[2,5]")
        #expect(try el2.node!.get(at: 6) == "[2,6]")
        #expect(try el2.node!.get(at: 7) == "[2,7]")

        fetcher.resetFetchCount()
        _ = try await resolved.node!.resolveRecursive(fetcher: fetcher)
        let fullFetches = fetcher.fetchCount

        #expect(rangeFetches < fullFetches)
        print("Nested \(outerSize)x\(innerSize): range(2..<4, 5..<8)=\(rangeFetches) fetches, full=\(fullFetches) fetches")
    }
}

// MARK: - Encryption

typealias EncryptableArray = MerkleArrayImpl<HeaderImpl<TestScalar>>

@Suite("MerkleArray Targeted Encryption")
struct MerkleArrayTargetedEncryptionTests {

    @Test("Targeted encryption encrypts only specified indices")
    func testTargetedEncryption() throws {
        let key = SymmetricKey(size: .bits256)
        let h0 = try HeaderImpl(node: TestScalar(val: 10))
        let h1 = try HeaderImpl(node: TestScalar(val: 20))
        let h2 = try HeaderImpl(node: TestScalar(val: 30))
        let arr = try EncryptableArray().append(h0).append(h1).append(h2)
        let header = try HeaderImpl(node: arr)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([EncryptableArray.binaryKey(1)], value: .targeted(key))
        let encrypted = try header.encrypt(encryption: encryption)

        let val0 = try encrypted.node!.get(at: 0)!
        #expect(val0.encryptionInfo == nil)

        let val1 = try encrypted.node!.get(at: 1)!
        #expect(val1.encryptionInfo != nil)

        let val2 = try encrypted.node!.get(at: 2)!
        #expect(val2.encryptionInfo == nil)
    }

    @Test("Targeted encryption with multiple indices")
    func testTargetedMultipleIndices() throws {
        let key = SymmetricKey(size: .bits256)
        var arr = EncryptableArray()
        for i in 0..<5 {
            arr = try arr.append(try HeaderImpl(node: TestScalar(val: i)))
        }
        let header = try HeaderImpl(node: arr)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([EncryptableArray.binaryKey(0)], value: .targeted(key))
        encryption.set([EncryptableArray.binaryKey(2)], value: .targeted(key))
        encryption.set([EncryptableArray.binaryKey(4)], value: .targeted(key))
        let encrypted = try header.encrypt(encryption: encryption)

        for i in 0..<5 {
            let val = try encrypted.node!.get(at: i)!
            if i % 2 == 0 {
                #expect(val.encryptionInfo != nil)
            } else {
                #expect(val.encryptionInfo == nil)
            }
        }
    }

    @Test("Targeted encryption store/resolve round-trip with authorized fetcher")
    func testTargetedStoreResolve() async throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        let arr = try EncryptableArray()
            .append(try HeaderImpl(node: TestScalar(val: 100)))
            .append(try HeaderImpl(node: TestScalar(val: 200)))
        let header = try HeaderImpl(node: arr)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([EncryptableArray.binaryKey(1)], value: .targeted(key))
        let encrypted = try header.encrypt(encryption: encryption)
        try await encrypted.storeAsVolume(storer: fetcher)

        let resolved = try await encrypted.removingNode().resolveRecursive(fetcher: fetcher)
        let val0 = try resolved.node!.get(at: 0)!
        let val0Resolved = try await val0.resolve(fetcher: fetcher)
        #expect(val0Resolved.node!.val == 100)

        let val1 = try resolved.node!.get(at: 1)!
        let val1Resolved = try await val1.resolve(fetcher: fetcher)
        #expect(val1Resolved.node!.val == 200)
    }

    @Test("Targeted encryption: unauthorized fetcher cannot read encrypted element")
    func testTargetedUnauthorizedAccess() async throws {
        let key = SymmetricKey(size: .bits256)
        let authorizedFetcher = TestKeyProvidingStoreFetcher()
        authorizedFetcher.registerKey(key)

        let arr = try EncryptableArray()
            .append(try HeaderImpl(node: TestScalar(val: 42)))
        let header = try HeaderImpl(node: arr)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([EncryptableArray.binaryKey(0)], value: .targeted(key))
        let encrypted = try header.encrypt(encryption: encryption)
        try await encrypted.storeAsVolume(storer: authorizedFetcher)

        let encVal = try encrypted.node!.get(at: 0)!
        let cidOnly = HeaderImpl<TestScalar>(rawCID: encVal.rawCID, node: nil, encryptionInfo: encVal.encryptionInfo)
        let unauthorizedFetcher = TestStoreFetcher()
        await #expect(throws: (any Error).self) {
            _ = try await cidOnly.resolve(fetcher: unauthorizedFetcher)
        }
    }
}

@Suite("MerkleArray Recursive Encryption")
struct MerkleArrayRecursiveEncryptionTests {

    @Test("Recursive encryption encrypts all elements")
    func testRecursiveEncryptsAll() throws {
        let key = SymmetricKey(size: .bits256)
        var arr = EncryptableArray()
        for i in 0..<4 {
            arr = try arr.append(try HeaderImpl(node: TestScalar(val: i * 10)))
        }
        let header = try HeaderImpl(node: arr)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)

        for i in 0..<4 {
            let val = try encrypted.node!.get(at: i)!
            #expect(val.encryptionInfo != nil)
        }
    }

    @Test("Recursive encryption store/resolve round-trip")
    func testRecursiveStoreResolve() async throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        let arr = try EncryptableArray()
            .append(try HeaderImpl(node: TestScalar(val: 1)))
            .append(try HeaderImpl(node: TestScalar(val: 2)))
            .append(try HeaderImpl(node: TestScalar(val: 3)))
        let header = try HeaderImpl(node: arr)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)
        try await encrypted.storeAsVolume(storer: fetcher)

        let resolved = try await encrypted.removingNode().resolveRecursive(fetcher: fetcher)
        for i in 0..<3 {
            let val = try resolved.node!.get(at: i)!
            let valResolved = try await val.resolve(fetcher: fetcher)
            #expect(valResolved.node!.val == i + 1)
        }
    }

    @Test("Recursive encryption with key override per index")
    func testRecursiveWithOverride() throws {
        let defaultKey = SymmetricKey(size: .bits256)
        let specialKey = SymmetricKey(size: .bits256)

        let arr = try EncryptableArray()
            .append(try HeaderImpl(node: TestScalar(val: 1)))
            .append(try HeaderImpl(node: TestScalar(val: 2)))
            .append(try HeaderImpl(node: TestScalar(val: 3)))
        let header = try HeaderImpl(node: arr)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(defaultKey))
        encryption.set([EncryptableArray.binaryKey(1)], value: .recursive(specialKey))
        let encrypted = try header.encrypt(encryption: encryption)

        let defaultKeyData = defaultKey.withUnsafeBytes { Data($0) }
        let defaultKeyHash = Data(SHA256.hash(data: defaultKeyData)).base64EncodedString()
        let specialKeyData = specialKey.withUnsafeBytes { Data($0) }
        let specialKeyHash = Data(SHA256.hash(data: specialKeyData)).base64EncodedString()

        let val0 = try encrypted.node!.get(at: 0)!
        #expect(val0.encryptionInfo!.keyHash == defaultKeyHash)

        let val1 = try encrypted.node!.get(at: 1)!
        #expect(val1.encryptionInfo!.keyHash == specialKeyHash)

        let val2 = try encrypted.node!.get(at: 2)!
        #expect(val2.encryptionInfo!.keyHash == defaultKeyHash)
    }
}

@Suite("MerkleArray Encryption with Transforms")
struct MerkleArrayEncryptionTransformTests {

    @Test("Transform preserves encryption on surviving elements")
    func testTransformPreservesEncryption() throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        let arr = try EncryptableArray()
            .append(try HeaderImpl(node: TestScalar(val: 1)))
            .append(try HeaderImpl(node: TestScalar(val: 2)))
            .append(try HeaderImpl(node: TestScalar(val: 3)))
        let header = try HeaderImpl(node: arr)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)

        var transforms = ArrayTrie<Transform>()
        let newVal = try HeaderImpl(node: TestScalar(val: 99), key: key)
        transforms.set([EncryptableArray.binaryKey(0)], value: .update(newVal.description))
        let result = try encrypted.transform(transforms: transforms, keyProvider: fetcher)
        #expect(result != nil)

        let val0 = try result!.node!.get(at: 0)!
        #expect(val0.encryptionInfo != nil)

        let val1 = try result!.node!.get(at: 1)!
        #expect(val1.encryptionInfo != nil)

        let val2 = try result!.node!.get(at: 2)!
        #expect(val2.encryptionInfo != nil)
    }

    @Test("Delete from encrypted array preserves encryption on survivors")
    func testDeletePreservesEncryption() throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        let arr = try EncryptableArray()
            .append(try HeaderImpl(node: TestScalar(val: 1)))
            .append(try HeaderImpl(node: TestScalar(val: 2)))
            .append(try HeaderImpl(node: TestScalar(val: 3)))
        let header = try HeaderImpl(node: arr)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)

        var transforms = ArrayTrie<Transform>()
        transforms.set([EncryptableArray.binaryKey(1)], value: .delete)
        let result = try encrypted.transform(transforms: transforms, keyProvider: fetcher)
        #expect(result != nil)
        #expect(result!.node!.count == 2)

        let val0 = try result!.node!.get(at: 0)!
        #expect(val0.encryptionInfo != nil)
    }

    @Test("Append then encrypt: full lifecycle store/resolve")
    func testAppendEncryptStoreResolve() async throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        var arr = EncryptableArray()
        for i in 0..<5 {
            arr = try arr.append(try HeaderImpl(node: TestScalar(val: i * 10)))
        }
        let header = try HeaderImpl(node: arr)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)

        try await encrypted.storeAsVolume(storer: fetcher)

        let resolved = try await encrypted.removingNode().resolveRecursive(fetcher: fetcher)
        #expect(resolved.node!.count == 5)

        for i in 0..<5 {
            let val = try resolved.node!.get(at: i)!
            #expect(val.encryptionInfo != nil)
            let valResolved = try await val.resolve(fetcher: fetcher)
            #expect(valResolved.node!.val == i * 10)
        }
    }

    @Test("Encrypted array CID differs from plaintext array CID")
    func testEncryptedCIDDiffers() throws {
        let key = SymmetricKey(size: .bits256)
        let arr = try EncryptableArray()
            .append(try HeaderImpl(node: TestScalar(val: 1)))
            .append(try HeaderImpl(node: TestScalar(val: 2)))
        let plainHeader = try HeaderImpl(node: arr)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encryptedHeader = try plainHeader.encrypt(encryption: encryption)

        #expect(plainHeader.rawCID != encryptedHeader.rawCID)
    }
}

@Suite("MerkleArray Encrypted Range Queries")
struct MerkleArrayEncryptedRangeQueryTests {

    @Test("Range query on encrypted array with authorized fetcher")
    func testEncryptedRangeQuery() async throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        var arr = EncryptableArray()
        for i in 0..<20 {
            arr = try arr.append(try HeaderImpl(node: TestScalar(val: i)))
        }
        let header = try HeaderImpl(node: arr)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)
        try await encrypted.storeAsVolume(storer: fetcher)

        let resolved = try await encrypted.removingNode().resolve(fetcher: fetcher)
        let rangeResolved = try await resolved.node!.resolve(
            paths: EncryptableArray.rangePaths(5..<8), fetcher: fetcher
        )

        for i in 5..<8 {
            let val = try rangeResolved.get(at: i)!
            #expect(val.encryptionInfo != nil)
            let valResolved = try await val.resolve(fetcher: fetcher)
            #expect(valResolved.node!.val == i)
        }
    }

    @Test("Selective encryption: only some elements encrypted, range query loads both")
    func testSelectiveEncryptionRangeQuery() async throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        var arr = EncryptableArray()
        for i in 0..<10 {
            arr = try arr.append(try HeaderImpl(node: TestScalar(val: i)))
        }
        let header = try HeaderImpl(node: arr)

        var encryption = ArrayTrie<EncryptionStrategy>()
        for i in stride(from: 0, to: 10, by: 2) {
            encryption.set([EncryptableArray.binaryKey(i)], value: .targeted(key))
        }
        let encrypted = try header.encrypt(encryption: encryption)
        try await encrypted.storeAsVolume(storer: fetcher)

        let resolved = try await encrypted.removingNode().resolveRecursive(fetcher: fetcher)

        for i in 0..<10 {
            let val = try resolved.node!.get(at: i)!
            if i % 2 == 0 {
                #expect(val.encryptionInfo != nil)
            } else {
                #expect(val.encryptionInfo == nil)
            }
            let valResolved = try await val.resolve(fetcher: fetcher)
            #expect(valResolved.node!.val == i)
        }
    }

    @Test("Nested encrypted array: outer encrypted, inner plaintext, range query works")
    func testNestedEncryptedOuterRangeQuery() async throws {
        typealias InnerEncryptableArrayay = MerkleArrayImpl<HeaderImpl<TestScalar>>
        typealias OuterEncryptableArrayay = MerkleArrayImpl<HeaderImpl<InnerEncryptableArrayay>>

        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        var inner0 = InnerEncryptableArrayay()
        inner0 = try inner0.append(try HeaderImpl(node: TestScalar(val: 10)))
            .append(try HeaderImpl(node: TestScalar(val: 11)))
        var inner1 = InnerEncryptableArrayay()
        inner1 = try inner1.append(try HeaderImpl(node: TestScalar(val: 20)))
            .append(try HeaderImpl(node: TestScalar(val: 21)))

        let h0 = try HeaderImpl(node: inner0)
        let h1 = try HeaderImpl(node: inner1)
        let outer = try OuterEncryptableArrayay().append(h0).append(h1)
        let header = try HeaderImpl(node: outer)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([OuterEncryptableArrayay.binaryKey(0)], value: .targeted(key))
        let encrypted = try header.encrypt(encryption: encryption)

        let encVal0 = try encrypted.node!.get(at: 0)!
        #expect(encVal0.encryptionInfo != nil)
        let encVal1 = try encrypted.node!.get(at: 1)!
        #expect(encVal1.encryptionInfo == nil)

        try await encrypted.storeAsVolume(storer: fetcher)
        try await h0.storeAsVolume(storer: fetcher)
        try await h1.storeAsVolume(storer: fetcher)

        let resolved = try await encrypted.removingNode().resolveRecursive(fetcher: fetcher)

        let resolvedInner0 = try resolved.node!.get(at: 0)!
        let r0 = try await resolvedInner0.resolveRecursive(fetcher: fetcher)
        let elem00 = try r0.node!.get(at: 0)!
        let elem00Resolved = try await elem00.resolve(fetcher: fetcher)
        #expect(elem00Resolved.node!.val == 10)

        let resolvedInner1 = try resolved.node!.get(at: 1)!
        #expect(resolvedInner1.node != nil)
        let elem10 = try resolvedInner1.node!.get(at: 0)!
        let elem10Resolved = try await elem10.resolve(fetcher: fetcher)
        #expect(elem10Resolved.node!.val == 20)
    }
}
