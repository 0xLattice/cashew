import Testing
import Foundation
import ArrayTrie
@testable import cashew

// MARK: - Basic Transforms

@Suite("Basic Transforms")
struct BasicTransformTests {

    @Test("ArrayTrie interface verification")
    func testArrayTrieInterface() throws {
        var transforms = ArrayTrie<Transform>()
        transforms.set(["testkey"], value: .insert("testvalue"))
        transforms.set(["updatekey"], value: .update("updatevalue"))
        transforms.set(["deletekey"], value: .delete)

        #expect(transforms.get(["testkey"]) != nil)
        #expect(transforms.get(["updatekey"]) != nil)
        #expect(transforms.get(["deletekey"]) != nil)

        if let insertValue = transforms.get(["testkey"]) {
            switch insertValue {
            case .insert(let str):
                #expect(str == "testvalue")
            default:
                #expect(Bool(false), "Wrong transform type for insert")
            }
        }

        if let updateValue = transforms.get(["updatekey"]) {
            switch updateValue {
            case .update(let str):
                #expect(str == "updatevalue")
            default:
                #expect(Bool(false), "Wrong transform type for update")
            }
        }

        if let deleteValue = transforms.get(["deletekey"]) {
            switch deleteValue {
            case .delete:
                break
            default:
                #expect(Bool(false), "Wrong transform type for delete")
            }
        }
    }

    @Test("MerkleDictionary manual operations verification")
    func testMerkleDictionaryManualOperations() throws {
        let emptyDict = MerkleDictionaryImpl<String>(children: [:], count: 0)

        let dictWithOne = try emptyDict.inserting(key: "key1", value: "value1")
        #expect(dictWithOne.count == 1)
        #expect(try dictWithOne.get(key: "key1") == "value1")

        let dictWithTwo = try dictWithOne.inserting(key: "key2", value: "value2")
        #expect(dictWithTwo.count == 2)
        #expect(try dictWithTwo.get(key: "key1") == "value1")
        #expect(try dictWithTwo.get(key: "key2") == "value2")

        let dictWithOneDeleted = try dictWithTwo.deleting(key: "key1")
        #expect(dictWithOneDeleted.count == 1)
        #expect(try dictWithOneDeleted.get(key: "key1") == nil)
        #expect(try dictWithOneDeleted.get(key: "key2") == "value2")

        let dictWithMutated = try dictWithTwo.mutating(key: ArraySlice("key1"), value: "mutated_value1")
        #expect(dictWithMutated.count == 2)
        #expect(try dictWithMutated.get(key: "key1") == "mutated_value1")
        #expect(try dictWithMutated.get(key: "key2") == "value2")
    }

    @Test("Simple single insert transform")
    func testSimpleSingleInsertTransform() throws {
        let dict = MerkleDictionaryImpl<String>(children: [:], count: 0)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["newkey"], value: .insert("newvalue"))

        let result = try dict.transform(transforms: transforms)!

        #expect(result.count == 1)
        #expect(try result.get(key: "newkey") == "newvalue")
    }

    @Test("Simple single delete transform")
    func testSimpleSingleDeleteTransform() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "keyToDelete", value: "valueToDelete")

        var transforms = ArrayTrie<Transform>()
        transforms.set(["keyToDelete"], value: .delete)

        let result = try dict.transform(transforms: transforms)!

        #expect(result.count == 0)
        #expect(try result.get(key: "keyToDelete") == nil)
    }

    @Test("Simple single update transform")
    func testSimpleSingleUpdateTransform() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "keyToUpdate", value: "oldValue")

        var transforms = ArrayTrie<Transform>()
        transforms.set(["keyToUpdate"], value: .update("newValue"))

        let result = try dict.transform(transforms: transforms)!

        #expect(result.count == 1)
        #expect(try result.get(key: "keyToUpdate") == "newValue")
    }

    @Test("Transform vs manual - insert comparison")
    func testTransformVsManualInsert() throws {
        let dict = MerkleDictionaryImpl<String>(children: [:], count: 0)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["key1"], value: .insert("value1"))
        let transformResult = try dict.transform(transforms: transforms)!

        let manualResult = try dict.inserting(key: "key1", value: "value1")

        #expect(transformResult.count == manualResult.count)
        let transformValue = try transformResult.get(key: "key1")
        let manualValue = try manualResult.get(key: "key1")
        #expect(transformValue == manualValue)
    }

    @Test("Transform vs manual - delete comparison")
    func testTransformVsManualDelete() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "key1", value: "value1")
            .inserting(key: "key2", value: "value2")

        var transforms = ArrayTrie<Transform>()
        transforms.set(["key1"], value: .delete)
        let transformResult = try dict.transform(transforms: transforms)!

        let manualResult = try dict.deleting(key: "key1")

        #expect(transformResult.count == manualResult.count)
        let transformValue1 = try transformResult.get(key: "key1")
        let manualValue1 = try manualResult.get(key: "key1")
        #expect(transformValue1 == manualValue1)
        let transformValue2 = try transformResult.get(key: "key2")
        let manualValue2 = try manualResult.get(key: "key2")
        #expect(transformValue2 == manualValue2)
    }

    @Test("Transform vs manual - update comparison")
    func testTransformVsManualUpdate() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "key1", value: "oldValue")

        var transforms = ArrayTrie<Transform>()
        transforms.set(["key1"], value: .update("newValue"))
        let transformResult = try dict.transform(transforms: transforms)!

        let manualResult = try dict.mutating(key: ArraySlice("key1"), value: "newValue")

        #expect(transformResult.count == manualResult.count)
        let transformValue = try transformResult.get(key: "key1")
        let manualValue = try manualResult.get(key: "key1")
        #expect(transformValue == manualValue)
    }

    @Test("Empty transform preserves data")
    func testEmptyTransformPreservesData() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "key1", value: "value1")

        let emptyTransforms = ArrayTrie<Transform>()
        let result = try dict.transform(transforms: emptyTransforms)!

        #expect(result.count == dict.count)
        let resultValue = try result.get(key: "key1")
        let dictValue = try dict.get(key: "key1")
        #expect(resultValue == dictValue)
    }

    @Test("Transform with invalid update string throws TransformErrors")
    func testTransformInvalidUpdateThrows() throws {
        let scalar = TestScalar(val: 1)

        var transforms = ArrayTrie<Transform>()
        transforms.set([], value: .update("this-is-not-valid-json"))

        #expect(throws: TransformErrors.self) {
            _ = try scalar.transform(transforms: transforms)
        }
    }

    @Test("Transform with valid update string succeeds")
    func testTransformValidUpdateSucceeds() throws {
        let scalar = TestScalar(val: 1)
        let newScalar = TestScalar(val: 99)

        var transforms = ArrayTrie<Transform>()
        transforms.set([], value: .update(newScalar.description))

        let result = try scalar.transform(transforms: transforms)
        #expect(result != nil)
        #expect(result!.val == 99)
    }

    @Test("transformAfterUpdate is callable (typo fixed)")
    func testTransformAfterUpdateCallable() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "a", value: "1")

        let transforms = ArrayTrie<Transform>()
        let result = try dict.transformAfterUpdate(transforms: transforms)
        #expect(result != nil)
    }

    @Test("Transform operations still work after fixes")
    func testTransformOperationsRegression() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "existing", value: "old")

        var transforms = ArrayTrie<Transform>()
        transforms.set(["existing"], value: .update("new"))
        transforms.set(["added"], value: .insert("fresh"))

        let result = try dict.transform(transforms: transforms)!
        #expect(result.count == 2)
        #expect(try result.get(key: "existing") == "new")
        #expect(try result.get(key: "added") == "fresh")
    }
}

// MARK: - Header Transforms

@Suite("Header Transforms")
struct HeaderTransformTests {

    @Test("Dictionary interface - minimal test")
    func testDictionaryInterfaceMinimal() throws {
        let dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        let header = try HeaderImpl(node: dictionary)

        let transforms: [[String]: Transform] = [:]
        _ = try header.transform(transforms: transforms)
    }

    @Test("Dictionary interface - single key insert test")
    func testDictionaryInterfaceSingleKeyInsert() throws {
        let dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        let header = try HeaderImpl(node: dictionary)

        var trieTransforms = ArrayTrie<Transform>()
        trieTransforms.set(["newkey"], value: .insert("newvalue"))
        let dictResult = try dictionary.transform(transforms: trieTransforms)!
        #expect(try dictResult.get(key: "newkey") == "newvalue")

        let trieResult: HeaderImpl<MerkleDictionaryImpl<String>> = try header.transform(transforms: trieTransforms)!
        #expect(try trieResult.node?.get(key: "newkey") == "newvalue")

        let transforms: [[String]: Transform] = [
            ["newkey"]: .insert("newvalue")
        ]
        let result = try header.transform(transforms: transforms)
        #expect(try result?.node?.get(key: "newkey") == "newvalue")
    }

    @Test("Dictionary interface - single insert transform")
    func testDictionaryInterfaceSingleInsert() throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "existing", value: "value")
        let header = try HeaderImpl(node: dictionary)

        let transforms: [[String]: Transform] = [
            ["newkey"]: .insert("newvalue")
        ]

        let result = try header.transform(transforms: transforms)!
        #expect(try result.node?.get(key: "newkey") == "newvalue")
        #expect(try result.node?.get(key: "existing") == "value")
        #expect(result.node?.count == 2)
    }

    @Test("Dictionary interface - single update transform")
    func testDictionaryInterfaceSingleUpdate() throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "existing", value: "oldvalue")
        let header = try HeaderImpl(node: dictionary)

        let transforms: [[String]: Transform] = [
            ["existing"]: .update("newvalue")
        ]

        let result = try header.transform(transforms: transforms)!
        #expect(try result.node?.get(key: "existing") == "newvalue")
        #expect(result.node?.count == 1)
    }

    @Test("Dictionary interface - single delete transform")
    func testDictionaryInterfaceSingleDelete() throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "toDelete", value: "value")
        dictionary = try dictionary.inserting(key: "toKeep", value: "keepValue")
        let header = try HeaderImpl(node: dictionary)

        let transforms: [[String]: Transform] = [
            ["toDelete"]: .delete
        ]

        let result = try header.transform(transforms: transforms)!
        #expect(try result.node?.get(key: "toDelete") == nil)
        #expect(try result.node?.get(key: "toKeep") == "keepValue")
        #expect(result.node?.count == 1)
    }

    @Test("Dictionary interface - multiple transforms")
    func testDictionaryInterfaceMultipleTransforms() throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "update", value: "oldvalue")
        dictionary = try dictionary.inserting(key: "delete", value: "deletevalue")
        let header = try HeaderImpl(node: dictionary)

        let transforms: [[String]: Transform] = [
            ["update"]: .update("newvalue"),
            ["delete"]: .delete,
            ["insert"]: .insert("insertvalue")
        ]

        let result = try header.transform(transforms: transforms)!
        #expect(try result.node?.get(key: "update") == "newvalue")
        #expect(try result.node?.get(key: "delete") == nil)
        #expect(try result.node?.get(key: "insert") == "insertvalue")
        #expect(result.node?.count == 2)
    }

    @Test("Dictionary interface - empty transforms preserves data")
    func testDictionaryInterfaceEmptyTransforms() throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "key1", value: "value1")
        dictionary = try dictionary.inserting(key: "key2", value: "value2")
        let header = try HeaderImpl(node: dictionary)

        let transforms: [[String]: Transform] = [:]

        let result = try header.transform(transforms: transforms)!
        #expect(try result.node?.get(key: "key1") == "value1")
        #expect(try result.node?.get(key: "key2") == "value2")
        #expect(result.node?.count == 2)
    }

    @Test("Dictionary interface - throws when node not available")
    func testDictionaryInterfaceThrowsWhenNodeNotAvailable() {
        let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: "test-cid")

        let transforms: [[String]: Transform] = [
            ["key"]: .insert("value")
        ]

        #expect(throws: DataErrors.self) {
            try header.transform(transforms: transforms)
        }
    }

    @Test("Dictionary interface - handles failed node transform")
    func testDictionaryInterfaceHandlesFailedNodeTransform() throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "key1", value: "value1")
        let header = try HeaderImpl(node: dictionary)

        let transforms: [[String]: Transform] = [
            ["nonexistent"]: .update("value")
        ]

        #expect(throws: TransformErrors.self) {
            try header.transform(transforms: transforms)
        }
    }

    @Test("Dictionary and ArrayTrie interfaces produce equivalent results - insert")
    func testInterfaceEquivalenceInsert() throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "existing", value: "value")

        let headerForDict = try HeaderImpl(node: dictionary)
        let headerForTrie = try HeaderImpl(node: dictionary)

        let dictTransforms: [[String]: Transform] = [
            ["newkey"]: .insert("newvalue")
        ]
        let dictResult = try headerForDict.transform(transforms: dictTransforms)!

        var trieTransforms = ArrayTrie<Transform>()
        trieTransforms.set(["newkey"], value: .insert("newvalue"))
        let trieResult: HeaderImpl<MerkleDictionaryImpl<String>> = try headerForTrie.transform(transforms: trieTransforms)!

        let dictNewKey = try dictResult.node?.get(key: "newkey")
        let trieNewKey = try trieResult.node?.get(key: "newkey")
        #expect(dictNewKey == trieNewKey)
        let dictExisting = try dictResult.node?.get(key: "existing")
        let trieExisting = try trieResult.node?.get(key: "existing")
        #expect(dictExisting == trieExisting)
        #expect(dictResult.node?.count == trieResult.node?.count)
    }

    @Test("Dictionary and ArrayTrie interfaces produce equivalent results - update")
    func testInterfaceEquivalenceUpdate() throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "update", value: "oldvalue")

        let headerForDict = try HeaderImpl(node: dictionary)
        let headerForTrie = try HeaderImpl(node: dictionary)

        let dictTransforms: [[String]: Transform] = [
            ["update"]: .update("newvalue")
        ]
        let dictResult = try headerForDict.transform(transforms: dictTransforms)!

        var trieTransforms = ArrayTrie<Transform>()
        trieTransforms.set(["update"], value: .update("newvalue"))
        let trieResult: HeaderImpl<MerkleDictionaryImpl<String>> = try headerForTrie.transform(transforms: trieTransforms)!

        let dictUpdate = try dictResult.node?.get(key: "update")
        let trieUpdate = try trieResult.node?.get(key: "update")
        #expect(dictUpdate == trieUpdate)
        #expect(dictResult.node?.count == trieResult.node?.count)
    }

    @Test("Dictionary and ArrayTrie interfaces produce equivalent results - delete")
    func testInterfaceEquivalenceDelete() throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "delete", value: "value")
        dictionary = try dictionary.inserting(key: "keep", value: "keepvalue")

        let headerForDict = try HeaderImpl(node: dictionary)
        let headerForTrie = try HeaderImpl(node: dictionary)

        let dictTransforms: [[String]: Transform] = [
            ["delete"]: .delete
        ]
        let dictResult = try headerForDict.transform(transforms: dictTransforms)!

        var trieTransforms = ArrayTrie<Transform>()
        trieTransforms.set(["delete"], value: .delete)
        let trieResult: HeaderImpl<MerkleDictionaryImpl<String>> = try headerForTrie.transform(transforms: trieTransforms)!

        let dictDelete = try dictResult.node?.get(key: "delete")
        let trieDelete = try trieResult.node?.get(key: "delete")
        #expect(dictDelete == trieDelete)
        let dictKeep = try dictResult.node?.get(key: "keep")
        let trieKeep = try trieResult.node?.get(key: "keep")
        #expect(dictKeep == trieKeep)
        #expect(dictResult.node?.count == trieResult.node?.count)
    }

    @Test("Dictionary and ArrayTrie interfaces produce equivalent results - complex")
    func testInterfaceEquivalenceComplex() throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "update", value: "oldvalue")
        dictionary = try dictionary.inserting(key: "delete", value: "deletevalue")
        dictionary = try dictionary.inserting(key: "keep", value: "keepvalue")

        let headerForDict = try HeaderImpl(node: dictionary)
        let headerForTrie = try HeaderImpl(node: dictionary)

        let dictTransforms: [[String]: Transform] = [
            ["update"]: .update("newvalue"),
            ["delete"]: .delete,
            ["insert"]: .insert("insertvalue")
        ]
        let dictResult = try headerForDict.transform(transforms: dictTransforms)!

        var trieTransforms = ArrayTrie<Transform>()
        trieTransforms.set(["update"], value: .update("newvalue"))
        trieTransforms.set(["delete"], value: .delete)
        trieTransforms.set(["insert"], value: .insert("insertvalue"))
        let trieResult: HeaderImpl<MerkleDictionaryImpl<String>> = try headerForTrie.transform(transforms: trieTransforms)!

        let dictUpdate = try dictResult.node?.get(key: "update")
        let trieUpdate = try trieResult.node?.get(key: "update")
        #expect(dictUpdate == trieUpdate)
        let dictDelete = try dictResult.node?.get(key: "delete")
        let trieDelete = try trieResult.node?.get(key: "delete")
        #expect(dictDelete == trieDelete)
        let dictInsert = try dictResult.node?.get(key: "insert")
        let trieInsert = try trieResult.node?.get(key: "insert")
        #expect(dictInsert == trieInsert)
        let dictKeep = try dictResult.node?.get(key: "keep")
        let trieKeep = try trieResult.node?.get(key: "keep")
        #expect(dictKeep == trieKeep)
        #expect(dictResult.node?.count == trieResult.node?.count)
    }

    @Test("ArrayTrie interface - throws when node not available")
    func testArrayTrieInterfaceThrowsWhenNodeNotAvailable() {
        let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: "test-cid")

        var transforms = ArrayTrie<Transform>()
        transforms.set(["key"], value: .insert("value"))

        #expect(throws: DataErrors.self) {
            try header.transform(transforms: transforms)
        }
    }

    @Test("ArrayTrie interface - empty transforms returns same instance")
    func testArrayTrieInterfaceEmptyTransforms() throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "key1", value: "value1")
        let header = try HeaderImpl(node: dictionary)

        let emptyTransforms = ArrayTrie<Transform>()
        let result: HeaderImpl<MerkleDictionaryImpl<String>> = try header.transform(transforms: emptyTransforms)!

        #expect(try result.node?.get(key: "key1") == "value1")
        #expect(result.node?.count == 1)
    }

    @Test("MerkleDictionary with UInt64 values - insert transform")
    func testUInt64DictionaryInsertTransform() throws {
        let dictionary = MerkleDictionaryImpl<UInt64>(children: [:], count: 0)
        let header = try HeaderImpl(node: dictionary)

        let transforms: [[String]: Transform] = [
            ["count"]: .insert("42")
        ]

        let result = try header.transform(transforms: transforms)!
        #expect(try result.node?.get(key: "count") == 42)
        #expect(result.node?.count == 1)
    }

    @Test("MerkleDictionary with UInt64 values - update transform")
    func testUInt64DictionaryUpdateTransform() throws {
        var dictionary = MerkleDictionaryImpl<UInt64>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "counter", value: 100)
        let header = try HeaderImpl(node: dictionary)

        let transforms: [[String]: Transform] = [
            ["counter"]: .update("200")
        ]

        let result = try header.transform(transforms: transforms)!
        #expect(try result.node?.get(key: "counter") == 200)
        #expect(result.node?.count == 1)
    }

    @Test("MerkleDictionary with UInt64 values - delete transform")
    func testUInt64DictionaryDeleteTransform() throws {
        var dictionary = MerkleDictionaryImpl<UInt64>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "toDelete", value: 123)
        dictionary = try dictionary.inserting(key: "toKeep", value: 456)
        let header = try HeaderImpl(node: dictionary)

        let transforms: [[String]: Transform] = [
            ["toDelete"]: .delete
        ]

        let result = try header.transform(transforms: transforms)!
        #expect(try result.node?.get(key: "toDelete") == nil)
        #expect(try result.node?.get(key: "toKeep") == 456)
        #expect(result.node?.count == 1)
    }

    @Test("MerkleDictionary with UInt64 values - multiple transforms")
    func testUInt64DictionaryMultipleTransforms() throws {
        var dictionary = MerkleDictionaryImpl<UInt64>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "update", value: 10)
        dictionary = try dictionary.inserting(key: "delete", value: 20)
        let header = try HeaderImpl(node: dictionary)

        let transforms: [[String]: Transform] = [
            ["update"]: .update("30"),
            ["delete"]: .delete,
            ["insert"]: .insert("40")
        ]

        let result = try header.transform(transforms: transforms)!
        #expect(try result.node?.get(key: "update") == 30)
        #expect(try result.node?.get(key: "delete") == nil)
        #expect(try result.node?.get(key: "insert") == 40)
        #expect(result.node?.count == 2)
    }
}

// MARK: - Radix Trie Maintenance

@Suite("Radix Trie Maintenance")
struct RadixTrieMaintenanceTests {

    @Test("Transform insert at prefix midpoint preserves existing key")
    func testTransformInsertAtPrefixMidpointPreservesExisting() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "alphabet", value: "val1")

        var transforms = ArrayTrie<Transform>()
        transforms.set(["alice"], value: .insert("val2"))
        transforms.set(["alex"], value: .insert("val3"))

        let result = try dict.transform(transforms: transforms)!
        #expect(result.count == 3)
        #expect(try result.get(key: "alphabet") == "val1")
        #expect(try result.get(key: "alice") == "val2")
        #expect(try result.get(key: "alex") == "val3")
    }

    @Test("Transform insert at prefix midpoint with single new key preserves existing")
    func testTransformInsertSingleKeyAtMidpointPreservesExisting() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "abcde", value: "original")

        var transforms = ArrayTrie<Transform>()
        transforms.set(["abx"], value: .insert("new"))

        let result = try dict.transform(transforms: transforms)!
        #expect(result.count == 2)
        #expect(try result.get(key: "abcde") == "original")
        #expect(try result.get(key: "abx") == "new")
    }

    @Test("Transform insert where existing and new keys share prefix but diverge")
    func testTransformInsertDivergingKeys() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "hello", value: "world")
            .inserting(key: "help", value: "me")

        var transforms = ArrayTrie<Transform>()
        transforms.set(["hero"], value: .insert("new"))

        let result = try dict.transform(transforms: transforms)!
        #expect(result.count == 3)
        #expect(try result.get(key: "hello") == "world")
        #expect(try result.get(key: "help") == "me")
        #expect(try result.get(key: "hero") == "new")
    }

    @Test("Transform delete two keys sharing prefix maintains correct count")
    func testTransformDeleteTwoKeysSharePrefix() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "abc", value: "v1")
            .inserting(key: "abcd", value: "v2")
            .inserting(key: "xyz", value: "v3")
        #expect(dict.count == 3)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["abc"], value: .delete)
        transforms.set(["abcd"], value: .delete)

        let result = try dict.transform(transforms: transforms)!
        #expect(try result.get(key: "abc") == nil)
        #expect(try result.get(key: "abcd") == nil)
        #expect(try result.get(key: "xyz") == "v3")
        #expect(result.count == 1)
    }

    @Test("Transform delete key that is prefix of another key")
    func testTransformDeletePrefixKey() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "app", value: "v1")
            .inserting(key: "apple", value: "v2")
        #expect(dict.count == 2)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["app"], value: .delete)

        let result = try dict.transform(transforms: transforms)!
        #expect(try result.get(key: "app") == nil)
        #expect(try result.get(key: "apple") == "v2")
        #expect(result.count == 1)
    }

    @Test("Transform mixed operations on keys sharing prefix")
    func testTransformMixedOpsSharePrefix() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "apple", value: "v1")
            .inserting(key: "app", value: "v2")
            .inserting(key: "application", value: "v3")
        #expect(dict.count == 3)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["app"], value: .delete)
        transforms.set(["apex"], value: .insert("v4"))
        transforms.set(["apple"], value: .update("updated"))

        let result = try dict.transform(transforms: transforms)!
        #expect(try result.get(key: "app") == nil)
        #expect(try result.get(key: "apple") == "updated")
        #expect(try result.get(key: "application") == "v3")
        #expect(try result.get(key: "apex") == "v4")
        #expect(result.count == 3)
    }

    @Test("Transform delete all entries under same first character")
    func testTransformDeleteAllUnderSameChar() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "abc", value: "v1")
            .inserting(key: "abd", value: "v2")
            .inserting(key: "xyz", value: "v3")
        #expect(dict.count == 3)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["abc"], value: .delete)
        transforms.set(["abd"], value: .delete)

        let result = try dict.transform(transforms: transforms)!
        #expect(try result.get(key: "abc") == nil)
        #expect(try result.get(key: "abd") == nil)
        #expect(try result.get(key: "xyz") == "v3")
        #expect(result.count == 1)
    }

    @Test("Transform insert key that is prefix of existing key")
    func testTransformInsertPrefixOfExistingKey() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "apple", value: "v1")
        #expect(dict.count == 1)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["app"], value: .insert("v2"))

        let result = try dict.transform(transforms: transforms)!
        #expect(try result.get(key: "apple") == "v1")
        #expect(try result.get(key: "app") == "v2")
        #expect(result.count == 2)
    }

    @Test("Transform produces deterministic CIDs regardless of operation order")
    func testTransformDeterministicCIDs() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "a", value: "1")
            .inserting(key: "b", value: "2")
            .inserting(key: "c", value: "3")

        var transforms1 = ArrayTrie<Transform>()
        transforms1.set(["a"], value: .update("10"))
        transforms1.set(["b"], value: .delete)
        transforms1.set(["d"], value: .insert("4"))

        let result1 = try dict.transform(transforms: transforms1)!
        let header1 = try HeaderImpl(node: result1)

        let manualResult = try dict
            .mutating(key: ArraySlice("a"), value: "10")
            .deleting(key: "b")
            .inserting(key: "d", value: "4")
        let header2 = try HeaderImpl(node: manualResult)

        #expect(header1.rawCID == header2.rawCID)
    }

    @Test("Repeated transform + CID verification cycle")
    func testRepeatedTransformCIDCycle() throws {
        var dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "counter", value: "0")
            .inserting(key: "log", value: "initial")

        var previousCIDs: [String] = []

        for i in 1...10 {
            var transforms = ArrayTrie<Transform>()
            transforms.set(["counter"], value: .update("\(i)"))
            transforms.set(["log"], value: .update("step_\(i)"))
            if i % 3 == 0 {
                transforms.set(["marker_\(i)"], value: .insert("milestone"))
            }
            dict = try dict.transform(transforms: transforms)!

            let cid = try HeaderImpl(node: dict).rawCID
            #expect(!previousCIDs.contains(cid))
            previousCIDs.append(cid)
        }

        #expect(try dict.get(key: "counter") == "10")
        #expect(try dict.get(key: "log") == "step_10")
        #expect(try dict.get(key: "marker_3") == "milestone")
        #expect(try dict.get(key: "marker_6") == "milestone")
        #expect(try dict.get(key: "marker_9") == "milestone")
    }

    @Test("Transform on keys that are strict prefixes of each other")
    func testTransformOnPrefixKeys() throws {
        var dict = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dict = try dict.inserting(key: "pre", value: "v1")
        dict = try dict.inserting(key: "prefix", value: "v2")
        dict = try dict.inserting(key: "prefixed", value: "v3")
        dict = try dict.inserting(key: "premium", value: "v4")

        var transforms = ArrayTrie<Transform>()
        transforms.set(["pre"], value: .update("updated_v1"))
        transforms.set(["prefix"], value: .delete)
        transforms.set(["prefixed"], value: .update("updated_v3"))
        transforms.set(["premium"], value: .update("updated_v4"))

        let result = try dict.transform(transforms: transforms)!
        #expect(result.count == 3)
        #expect(try result.get(key: "pre") == "updated_v1")
        #expect(try result.get(key: "prefix") == nil)
        #expect(try result.get(key: "prefixed") == "updated_v3")
        #expect(try result.get(key: "premium") == "updated_v4")
    }

    @Test("Delete all entries via transform results in empty dictionary")
    func testDeleteAllViaTransform() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "a", value: "1")
            .inserting(key: "b", value: "2")
            .inserting(key: "c", value: "3")

        var transforms = ArrayTrie<Transform>()
        transforms.set(["a"], value: .delete)
        transforms.set(["b"], value: .delete)
        transforms.set(["c"], value: .delete)

        let result = try dict.transform(transforms: transforms)!
        #expect(result.count == 0)
        #expect(try result.get(key: "a") == nil)
        #expect(try result.get(key: "b") == nil)
        #expect(try result.get(key: "c") == nil)

        let emptyDict = MerkleDictionaryImpl<String>(children: [:], count: 0)
        #expect(try HeaderImpl(node: result).rawCID == (try HeaderImpl(node: emptyDict).rawCID))
    }

    @Test("Insert into empty dict via transform then delete all back to empty")
    func testInsertThenDeleteBackToEmpty() throws {
        let empty = MerkleDictionaryImpl<String>(children: [:], count: 0)
        let emptyCID = try HeaderImpl(node: empty).rawCID

        var inserts = ArrayTrie<Transform>()
        inserts.set(["x"], value: .insert("1"))
        inserts.set(["y"], value: .insert("2"))
        let withEntries = try empty.transform(transforms: inserts)!
        #expect(withEntries.count == 2)

        var deletes = ArrayTrie<Transform>()
        deletes.set(["x"], value: .delete)
        deletes.set(["y"], value: .delete)
        let backToEmpty = try withEntries.transform(transforms: deletes)!
        #expect(backToEmpty.count == 0)
        #expect(try HeaderImpl(node: backToEmpty).rawCID == emptyCID)
    }
}

// MARK: - Bulk Transforms

@Suite("Bulk Transforms")
struct BulkTransformTests {

    @Test("Multiple simultaneous operations - comprehensive")
    func testMultipleSimultaneousOperationsComprehensive() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "name", value: "Alice")
            .inserting(key: "email", value: "alice@example.com")
            .inserting(key: "age", value: "28")
            .inserting(key: "city", value: "Boston")
            .inserting(key: "country", value: "USA")
            .inserting(key: "status", value: "active")
            .inserting(key: "role", value: "engineer")
            .inserting(key: "salary", value: "75000")
            .inserting(key: "department", value: "backend")
            .inserting(key: "manager", value: "Bob")
            .inserting(key: "startDate", value: "2022-01-15")
            .inserting(key: "lastReview", value: "2023-12-01")

        var transforms = ArrayTrie<Transform>()

        transforms.set(["name"], value: .update("Alice Johnson"))
        transforms.set(["email"], value: .update("alice.johnson@company.com"))
        transforms.set(["age"], value: .update("29"))
        transforms.set(["city"], value: .update("San Francisco"))

        transforms.set(["role"], value: .update("senior_engineer"))
        transforms.set(["salary"], value: .update("95000"))
        transforms.set(["department"], value: .update("frontend"))
        transforms.set(["manager"], value: .update("Carol"))

        transforms.set(["phone"], value: .insert("555-0123"))
        transforms.set(["linkedin"], value: .insert("linkedin.com/in/alice"))
        transforms.set(["skills"], value: .insert("Swift,TypeScript,React"))
        transforms.set(["promotion"], value: .insert("2024-01-15"))
        transforms.set(["newSalaryEffective"], value: .insert("2024-02-01"))

        transforms.set(["country"], value: .delete)
        transforms.set(["lastReview"], value: .delete)

        let result = try dict.transform(transforms: transforms)!

        let manualResult = try dict
            .mutating(key: ArraySlice("name"), value: "Alice Johnson")
            .mutating(key: ArraySlice("email"), value: "alice.johnson@company.com")
            .mutating(key: ArraySlice("age"), value: "29")
            .mutating(key: ArraySlice("city"), value: "San Francisco")
            .mutating(key: ArraySlice("role"), value: "senior_engineer")
            .mutating(key: ArraySlice("salary"), value: "95000")
            .mutating(key: ArraySlice("department"), value: "frontend")
            .mutating(key: ArraySlice("manager"), value: "Carol")
            .inserting(key: "phone", value: "555-0123")
            .inserting(key: "linkedin", value: "linkedin.com/in/alice")
            .inserting(key: "skills", value: "Swift,TypeScript,React")
            .inserting(key: "promotion", value: "2024-01-15")
            .inserting(key: "newSalaryEffective", value: "2024-02-01")
            .deleting(key: "country")
            .deleting(key: "lastReview")

        #expect(result.count == manualResult.count)

        #expect(try result.get(key: "name") == "Alice Johnson")
        #expect(try manualResult.get(key: "name") == "Alice Johnson")
        #expect(try result.get(key: "email") == "alice.johnson@company.com")
        #expect(try manualResult.get(key: "email") == "alice.johnson@company.com")
        #expect(try result.get(key: "role") == "senior_engineer")
        #expect(try manualResult.get(key: "role") == "senior_engineer")

        #expect(try result.get(key: "phone") == "555-0123")
        #expect(try manualResult.get(key: "phone") == "555-0123")
        #expect(try result.get(key: "skills") == "Swift,TypeScript,React")
        #expect(try manualResult.get(key: "skills") == "Swift,TypeScript,React")

        #expect(try result.get(key: "country") == nil)
        #expect(try manualResult.get(key: "country") == nil)
        #expect(try result.get(key: "lastReview") == nil)
        #expect(try manualResult.get(key: "lastReview") == nil)

        #expect(try result.get(key: "status") == "active")
        #expect(try manualResult.get(key: "status") == "active")
        #expect(try result.get(key: "startDate") == "2022-01-15")
        #expect(try manualResult.get(key: "startDate") == "2022-01-15")

        #expect(result.count == 15)
    }

    @Test("Test inserting into MerkleDictionary with value of Header Type")
    func testInsertingIntoMerkleDictionaryWithValueOfHeaderType() async throws {
        typealias BaseDictionary = MerkleDictionaryImpl<UInt64>
        typealias HigherDictionaryType = MerkleDictionaryImpl<HeaderImpl<BaseDictionary>>

        let baseDictionary: BaseDictionary =
        try MerkleDictionaryImpl<UInt64>(children: [:], count: 0)
            .inserting(key: "Hello", value: 1)
            .inserting(key: "World", value: 2)

        let baseDictionaryHeader = try HeaderImpl<BaseDictionary>(node: baseDictionary)
        let fetcher = TestStoreFetcher()
        try! await baseDictionaryHeader.storeAsVolume(storer: fetcher)

        let higherDictionary: HigherDictionaryType = HigherDictionaryType(children: [:], count: 0)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["Foo"], value: .insert(baseDictionaryHeader.rawCID))

        let transformedDictionary = try! higherDictionary.transform(transforms: transforms)

        #expect(try! transformedDictionary!.get(key: "Foo")!.node == nil)

        let finalDictionary = try await transformedDictionary!.resolveRecursive(fetcher: fetcher)

        #expect(try! finalDictionary.get(key: "Foo")!.node!.count == 2)
        #expect(try! finalDictionary.get(key: "Foo")!.node!.get(key: "Hello") == 1)
        #expect(try! finalDictionary.get(key: "Foo")!.node!.get(key: "World") == 2)
    }

    @Test("Sequential state machine-like transforms")
    func testSequentialStateMachineTransforms() throws {
        let initialState = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "state", value: "pending")
            .inserting(key: "submittedAt", value: "2024-01-10T10:00:00Z")
            .inserting(key: "submittedBy", value: "alice")
            .inserting(key: "priority", value: "medium")
            .inserting(key: "assignedTo", value: "unassigned")

        var step1Transforms = ArrayTrie<Transform>()
        step1Transforms.set(["state"], value: .update("in_progress"))
        step1Transforms.set(["assignedTo"], value: .update("bob"))
        step1Transforms.set(["startedAt"], value: .insert("2024-01-10T14:30:00Z"))
        step1Transforms.set(["estimatedCompletion"], value: .insert("2024-01-12T17:00:00Z"))

        let afterStep1 = try initialState.transform(transforms: step1Transforms)!

        var step2Transforms = ArrayTrie<Transform>()
        step2Transforms.set(["progress"], value: .insert("25"))
        step2Transforms.set(["lastUpdate"], value: .insert("2024-01-11T09:15:00Z"))
        step2Transforms.set(["notes"], value: .insert("Initial analysis completed"))
        step2Transforms.set(["estimatedCompletion"], value: .update("2024-01-13T12:00:00Z"))

        let afterStep2 = try afterStep1.transform(transforms: step2Transforms)!

        var step3Transforms = ArrayTrie<Transform>()
        step3Transforms.set(["state"], value: .update("completed"))
        step3Transforms.set(["progress"], value: .update("100"))
        step3Transforms.set(["completedAt"], value: .insert("2024-01-12T16:45:00Z"))
        step3Transforms.set(["lastUpdate"], value: .update("2024-01-12T16:45:00Z"))
        step3Transforms.set(["notes"], value: .update("Work completed successfully"))
        step3Transforms.set(["estimatedCompletion"], value: .delete)

        let finalState = try afterStep2.transform(transforms: step3Transforms)!

        let manualResult = try initialState
            .mutating(key: ArraySlice("state"), value: "in_progress")
            .mutating(key: ArraySlice("assignedTo"), value: "bob")
            .inserting(key: "startedAt", value: "2024-01-10T14:30:00Z")
            .inserting(key: "estimatedCompletion", value: "2024-01-12T17:00:00Z")
            .inserting(key: "progress", value: "25")
            .inserting(key: "lastUpdate", value: "2024-01-11T09:15:00Z")
            .inserting(key: "notes", value: "Initial analysis completed")
            .mutating(key: ArraySlice("estimatedCompletion"), value: "2024-01-13T12:00:00Z")
            .mutating(key: ArraySlice("state"), value: "completed")
            .mutating(key: ArraySlice("progress"), value: "100")
            .inserting(key: "completedAt", value: "2024-01-12T16:45:00Z")
            .mutating(key: ArraySlice("lastUpdate"), value: "2024-01-12T16:45:00Z")
            .mutating(key: ArraySlice("notes"), value: "Work completed successfully")
            .deleting(key: "estimatedCompletion")

        #expect(finalState.count == manualResult.count)

        #expect(try finalState.get(key: "state") == "completed")
        #expect(try manualResult.get(key: "state") == "completed")
        #expect(try finalState.get(key: "progress") == "100")
        #expect(try manualResult.get(key: "progress") == "100")
        #expect(try finalState.get(key: "assignedTo") == "bob")
        #expect(try manualResult.get(key: "assignedTo") == "bob")
        #expect(try finalState.get(key: "completedAt") == "2024-01-12T16:45:00Z")
        #expect(try manualResult.get(key: "completedAt") == "2024-01-12T16:45:00Z")
        #expect(try finalState.get(key: "estimatedCompletion") == nil)
        #expect(try manualResult.get(key: "estimatedCompletion") == nil)

        #expect(try finalState.get(key: "submittedAt") == "2024-01-10T10:00:00Z")
        #expect(try manualResult.get(key: "submittedAt") == "2024-01-10T10:00:00Z")
        #expect(try finalState.get(key: "submittedBy") == "alice")
        #expect(try manualResult.get(key: "submittedBy") == "alice")
    }

    @Test("Bulk operations with systematic patterns")
    func testBulkOperationsWithSystematicPatterns() throws {
        var dict = MerkleDictionaryImpl<String>(children: [:], count: 0)

        for i in 1...30 {
            dict = try dict
                .inserting(key: "item\(i)", value: "value\(i)")
                .inserting(key: "type\(i)", value: i <= 15 ? "typeA" : "typeB")
        }

        dict = try dict
            .inserting(key: "totalCount", value: "30")
            .inserting(key: "version", value: "1.0")

        var transforms = ArrayTrie<Transform>()

        for i in 1...15 {
            transforms.set(["item\(i)"], value: .update("updatedValueA\(i)"))
        }

        for i in [5, 10, 15, 20, 25, 30] {
            transforms.set(["item\(i)"], value: .delete)
            transforms.set(["type\(i)"], value: .delete)
        }

        for i in 31...35 {
            transforms.set(["item\(i)"], value: .insert("newValue\(i)"))
            transforms.set(["type\(i)"], value: .insert("typeC"))
        }

        transforms.set(["totalCount"], value: .update("29"))
        transforms.set(["version"], value: .update("2.0"))
        transforms.set(["lastModified"], value: .insert("2024-01-15"))

        let result = try dict.transform(transforms: transforms)!

        #expect(try result.get(key: "item1") == "updatedValueA1")
        #expect(try result.get(key: "item14") == "updatedValueA14")

        #expect(try result.get(key: "item5") == nil)
        #expect(try result.get(key: "item10") == nil)
        #expect(try result.get(key: "type20") == nil)

        #expect(try result.get(key: "item16") == "value16")
        #expect(try result.get(key: "item19") == "value19")
        #expect(try result.get(key: "type16") == "typeB")

        #expect(try result.get(key: "item33") == "newValue33")
        #expect(try result.get(key: "type35") == "typeC")

        #expect(try result.get(key: "totalCount") == "29")
        #expect(try result.get(key: "version") == "2.0")
        #expect(try result.get(key: "lastModified") == "2024-01-15")

        let expectedCount = 62 - 12 + 11
        #expect(result.count == expectedCount)
    }

    @Test("Complex data with special characters and edge cases")
    func testComplexDataWithSpecialCharacters() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "simpleText", value: "Hello World")
            .inserting(key: "emptyValue", value: "")
            .inserting(key: "numbersOnly", value: "12345")
            .inserting(key: "unicodeText", value: "Hello 世界 🌍")
            .inserting(key: "jsonLike", value: "{\"name\":\"value\"}")
            .inserting(key: "withSpaces", value: "  spaced text  ")
            .inserting(key: "multiline", value: "line1\nline2\nline3")
            .inserting(key: "specialChars", value: "!@#$%^&*()")

        var transforms = ArrayTrie<Transform>()

        transforms.set(["simpleText"], value: .update("Goodbye World"))
        transforms.set(["emptyValue"], value: .update("now has content"))
        transforms.set(["numbersOnly"], value: .update("67890"))
        transforms.set(["unicodeText"], value: .update("Bonjour 🇫🇷 Monde!"))
        transforms.set(["jsonLike"], value: .update("{\"updated\": true, \"timestamp\": \"2024-01-15\"}"))

        transforms.set(["withSpaces"], value: .delete)
        transforms.set(["specialChars"], value: .delete)

        transforms.set(["xmlLike"], value: .insert("<root><item>test</item></root>"))
        transforms.set(["quotesAndEscapes"], value: .insert("He said \"Hello!\" and she replied: 'Hi!'"))
        transforms.set(["tabsAndNewlines"], value: .insert("col1\tcol2\tcol3\nrow1\tdata1\tdata2"))
        transforms.set(["veryLongText"], value: .insert(String(repeating: "Lorem ipsum ", count: 100)))

        let result = try dict.transform(transforms: transforms)!

        let manualResult = try dict
            .mutating(key: ArraySlice("simpleText"), value: "Goodbye World")
            .mutating(key: ArraySlice("emptyValue"), value: "now has content")
            .mutating(key: ArraySlice("numbersOnly"), value: "67890")
            .mutating(key: ArraySlice("unicodeText"), value: "Bonjour 🇫🇷 Monde!")
            .mutating(key: ArraySlice("jsonLike"), value: "{\"updated\": true, \"timestamp\": \"2024-01-15\"}")
            .deleting(key: "withSpaces")
            .deleting(key: "specialChars")
            .inserting(key: "xmlLike", value: "<root><item>test</item></root>")
            .inserting(key: "quotesAndEscapes", value: "He said \"Hello!\" and she replied: 'Hi!'")
            .inserting(key: "tabsAndNewlines", value: "col1\tcol2\tcol3\nrow1\tdata1\tdata2")
            .inserting(key: "veryLongText", value: String(repeating: "Lorem ipsum ", count: 100))

        #expect(result.count == manualResult.count)

        #expect(try result.get(key: "unicodeText") == "Bonjour 🇫🇷 Monde!")
        #expect(try manualResult.get(key: "unicodeText") == "Bonjour 🇫🇷 Monde!")
        #expect(try result.get(key: "jsonLike") == "{\"updated\": true, \"timestamp\": \"2024-01-15\"}")
        #expect(try manualResult.get(key: "jsonLike") == "{\"updated\": true, \"timestamp\": \"2024-01-15\"}")

        #expect(try result.get(key: "xmlLike") == "<root><item>test</item></root>")
        #expect(try manualResult.get(key: "xmlLike") == "<root><item>test</item></root>")
        #expect(try result.get(key: "quotesAndEscapes") == "He said \"Hello!\" and she replied: 'Hi!'")
        #expect(try manualResult.get(key: "quotesAndEscapes") == "He said \"Hello!\" and she replied: 'Hi!'")

        #expect(try result.get(key: "withSpaces") == nil)
        #expect(try manualResult.get(key: "withSpaces") == nil)
        #expect(try result.get(key: "specialChars") == nil)
        #expect(try manualResult.get(key: "specialChars") == nil)

        #expect(try result.get(key: "multiline") == "line1\nline2\nline3")
        #expect(try manualResult.get(key: "multiline") == "line1\nline2\nline3")

        #expect(result.count == 10)
    }

    @Test("Mixed operations with overlapping keys showing ArrayTrie behavior")
    func testMixedOperationsWithOverlappingKeys() throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "key1", value: "original1")
            .inserting(key: "key2", value: "original2")
            .inserting(key: "key3", value: "original3")
            .inserting(key: "key4", value: "original4")

        var transforms = ArrayTrie<Transform>()

        transforms.set(["key1"], value: .update("first_update"))
        transforms.set(["key1"], value: .update("second_update"))
        transforms.set(["key1"], value: .update("final_update"))

        transforms.set(["key2"], value: .update("updated"))
        transforms.set(["key2"], value: .delete)

        transforms.set(["key3"], value: .update("updated3"))
        transforms.set(["key4"], value: .delete)

        transforms.set(["key5"], value: .insert("new5"))
        transforms.set(["key6"], value: .insert("new6"))

        let result = try dict.transform(transforms: transforms)!

        #expect(try result.get(key: "key1") == "final_update")
        #expect(try result.get(key: "key2") == nil)
        #expect(try result.get(key: "key3") == "updated3")
        #expect(try result.get(key: "key4") == nil)
        #expect(try result.get(key: "key5") == "new5")
        #expect(try result.get(key: "key6") == "new6")

        #expect(result.count == 4)
    }

    @Test("100-key dictionary: bulk insert, transform, verify allKeys")
    func test100KeyBulkOperations() throws {
        var dict = MerkleDictionaryImpl<String>(children: [:], count: 0)
        for i in 0..<100 {
            dict = try dict.inserting(key: "key_\(String(format: "%03d", i))", value: "val_\(i)")
        }
        #expect(dict.count == 100)

        let allKeys = try dict.allKeys()
        #expect(allKeys.count == 100)
        for i in 0..<100 {
            #expect(allKeys.contains("key_\(String(format: "%03d", i))"))
        }

        var transforms = ArrayTrie<Transform>()
        for i in stride(from: 0, to: 100, by: 2) {
            transforms.set(["key_\(String(format: "%03d", i))"], value: .update("updated_\(i)"))
        }
        for i in stride(from: 1, to: 50, by: 2) {
            transforms.set(["key_\(String(format: "%03d", i))"], value: .delete)
        }
        for i in 100..<120 {
            transforms.set(["key_\(String(format: "%03d", i))"], value: .insert("new_\(i)"))
        }

        let result = try dict.transform(transforms: transforms)!
        let expectedCount = 100 - 25 + 20
        #expect(result.count == expectedCount)

        #expect(try result.get(key: "key_000") == "updated_0")
        #expect(try result.get(key: "key_001") == nil)
        #expect(try result.get(key: "key_050") == "updated_50")
        #expect(try result.get(key: "key_051") == "val_51")
        #expect(try result.get(key: "key_100") == "new_100")
        #expect(try result.get(key: "key_119") == "new_119")
    }
}
