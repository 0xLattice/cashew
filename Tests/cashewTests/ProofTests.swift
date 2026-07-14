import Testing
import Foundation
import ArrayTrie
@preconcurrency import Multicodec
@testable import cashew

@Suite("Proof Tests")
struct ProofTests {

    // MARK: - Header Proofs

    @Suite("Header Proofs")
    struct HeaderProofs {

        @Test("SparseMerkleProof enum has correct cases")
        func testSparseMerkleProofCases() {
            #expect(SparseMerkleProof.insertion.rawValue == 1)
            #expect(SparseMerkleProof.mutation.rawValue == 2)
            #expect(SparseMerkleProof.deletion.rawValue == 3)
            #expect(SparseMerkleProof.existence.rawValue == 4)
        }

        @Test("SparseMerkleProof is codable")
        func testSparseMerkleProofCodable() throws {
            let proofs: [SparseMerkleProof] = [.insertion, .mutation, .deletion, .existence]

            for proof in proofs {
                let encoded = try JSONEncoder().encode(proof)
                let decoded = try JSONDecoder().decode(SparseMerkleProof.self, from: encoded)
                #expect(decoded == proof)
            }
        }

        @Test("ProofErrors enum has correct cases")
        func testProofErrorsCases() {
            let invalidType = ProofErrors.invalidProofType("test")
            let proofFailed = ProofErrors.proofFailed("test")

            #expect(invalidType as Error is ProofErrors)
            #expect(proofFailed as Error is ProofErrors)
        }

        @Test("Header proof with empty paths returns self unchanged")
        func testHeaderProofEmptyPaths() async throws {
            let radixNode = RadixNodeImpl<String>(prefix: "test", value: "test-value", children: [:])
            let radixHeader = try RadixHeaderImpl(node: radixNode)
            let children: [Character: RadixHeaderImpl<String>] = ["t": radixHeader]
            let dictionary = MerkleDictionaryImpl<String>(children: children, count: 1)
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            let emptyPaths = ArrayTrie<SparseMerkleProof>()
            let result = try await header.proof(paths: emptyPaths, fetcher: fetcher)

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node == nil)
        }

        @Test("Header proof validates existing property")
        func testHeaderProofExistingProperty() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "existing-prop", value: "test-value")
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["existing-prop"], value: .existence)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node?.count == 1)
        }

        @Test("Header proof validates mutation on property")
        func testHeaderProofMutationProperty() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "mutable-prop", value: "original-value")
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["mutable-prop"], value: .mutation)

            let result = try await header.proof(paths: paths, fetcher: fetcher)
            let resultAfterMutation = try result.node!.mutating(key: "mutable-prop", value: "new-value")

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node?.count == 1)
            #expect(try resultAfterMutation.get(key: "mutable-prop") == "new-value")
        }

        @Test("Header proof succeeds for non-existing property with existence proof")
        func testHeaderProofNonExistingProperty() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "existing-prop", value: "value")
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["non-existing-prop"], value: .existence)

            let result = try await header.proof(paths: paths, fetcher: fetcher)
            #expect(result.rawCID == headerWithNode.rawCID)
        }

        @Test("Header proof with nested properties")
        func testHeaderProofNestedProperties() async throws {
            let leafNode = RadixNodeImpl<String>(prefix: "leaf", value: "leaf-value", children: [:])
            let leafHeader = try RadixHeaderImpl(node: leafNode)

            let branchChildren: [Character: RadixHeaderImpl<String>] = ["l": leafHeader]
            let branchNode = RadixNodeImpl<String>(prefix: "branch", value: nil, children: branchChildren)
            let branchHeader = try RadixHeaderImpl(node: branchNode)

            let rootChildren: [Character: RadixHeaderImpl<String>] = ["b": branchHeader]
            let dictionary = MerkleDictionaryImpl<String>(children: rootChildren, count: 1)
            let headerWithNode = try HeaderImpl(node: dictionary)
            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)

            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["b", "branch"], value: .existence)
            paths.set(["b", "branch", "l", "leaf"], value: .existence)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node?.count == 1)
        }

        @Test("Header proof with missing fetcher data throws error")
        func testHeaderProofMissingDataThrows() async throws {
            let radixNode = RadixNodeImpl<String>(prefix: "test", value: "value", children: [:])
            let radixHeader = try RadixHeaderImpl(node: radixNode)
            let children: [Character: RadixHeaderImpl<String>] = ["t": radixHeader]
            let dictionary = MerkleDictionaryImpl<String>(children: children, count: 1)
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["t", "test"], value: .existence)

            await #expect(throws: Error.self) {
                _ = try await header.proof(paths: paths, fetcher: fetcher)
            }
        }

        @Test("Header proof with dictionary paths")
        func testHeaderProofWithDictionary() async throws {
            let radixNode = RadixNodeImpl<String>(prefix: "key1", value: "dict-value", children: [:])
            let radixHeader = try RadixHeaderImpl(node: radixNode)
            let children: [Character: RadixHeaderImpl<String>] = ["k": radixHeader]
            let dictionary = MerkleDictionaryImpl<String>(children: children, count: 1)
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            let paths = [["k", "key1"]: SparseMerkleProof.existence]
            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node?.count == 1)
        }

        @Test("Header CID is deterministic")
        func testHeaderCIDDeterministic() async throws {
            let radixNode1 = RadixNodeImpl<String>(prefix: "same", value: "same-value", children: [:])
            let radixHeader1 = try RadixHeaderImpl(node: radixNode1)
            let children1: [Character: RadixHeaderImpl<String>] = ["s": radixHeader1]
            let dictionary1 = MerkleDictionaryImpl<String>(children: children1, count: 1)

            let radixNode2 = RadixNodeImpl<String>(prefix: "same", value: "same-value", children: [:])
            let radixHeader2 = try RadixHeaderImpl(node: radixNode2)
            let children2: [Character: RadixHeaderImpl<String>] = ["s": radixHeader2]
            let dictionary2 = MerkleDictionaryImpl<String>(children: children2, count: 1)

            let header1 = try HeaderImpl(node: dictionary1)
            let header2 = try HeaderImpl(node: dictionary2)

            #expect(header1.rawCID == header2.rawCID)
        }

        @Test("Header CID differs for different content")
        func testHeaderCIDDifferentContent() async throws {
            let radixNode1 = RadixNodeImpl<String>(prefix: "content1", value: "value1", children: [:])
            let radixHeader1 = try RadixHeaderImpl(node: radixNode1)
            let children1: [Character: RadixHeaderImpl<String>] = ["c": radixHeader1]
            let dictionary1 = MerkleDictionaryImpl<String>(children: children1, count: 1)

            let radixNode2 = RadixNodeImpl<String>(prefix: "content2", value: "value2", children: [:])
            let radixHeader2 = try RadixHeaderImpl(node: radixNode2)
            let children2: [Character: RadixHeaderImpl<String>] = ["c": radixHeader2]
            let dictionary2 = MerkleDictionaryImpl<String>(children: children2, count: 1)

            let header1 = try HeaderImpl(node: dictionary1)
            let header2 = try HeaderImpl(node: dictionary2)

            #expect(header1.rawCID != header2.rawCID)
        }

        @Test("Header proof maintains content addressability")
        func testHeaderProofContentAddressability() async throws {
            let radixNode = RadixNodeImpl<String>(prefix: "test-prop", value: "test-value", children: [:])
            let radixHeader = try RadixHeaderImpl(node: radixNode)
            let children: [Character: RadixHeaderImpl<String>] = ["t": radixHeader]
            let dictionary = MerkleDictionaryImpl<String>(children: children, count: 1)
            let originalHeader = try HeaderImpl(node: dictionary)
            let originalCID = originalHeader.rawCID

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: originalCID)
            let fetcher = TestStoreFetcher()
            try await originalHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["t", "test-prop"], value: .existence)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == originalCID)
            #expect(result.node?.count == 1)
        }

        @Test("Header proof validates deletion on property")
        func testHeaderProofDeletionProperty() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "deletable", value: "to-delete")
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["deletable"], value: .deletion)

            let result = try await header.proof(paths: paths, fetcher: fetcher)
            let resultAfterDeletion = try result.node!.deleting(key: "deletable")

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node?.count == 1)
            #expect(resultAfterDeletion.count == 0)
            #expect(try resultAfterDeletion.get(key: "deletable") == nil)
        }

        @Test("Header proof validates insertion on property")
        func testHeaderProofInsertionProperty() async throws {
            let dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["insertable"], value: .insertion)

            let result = try await header.proof(paths: paths, fetcher: fetcher)
            let resultAfterInsertion = try result.node!.inserting(key: "insertable", value: "inserted-value")

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node?.count == 0)
            #expect(resultAfterInsertion.count == 1)
            #expect(try resultAfterInsertion.get(key: "insertable") == "inserted-value")
        }

        @Test("Header proof mixed proof types on same header")
        func testHeaderProofMixedTypes() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "existing", value: "existing-value")
            dictionary = try dictionary.inserting(key: "mutable", value: "original-value")
            dictionary = try dictionary.inserting(key: "deletable", value: "to-delete")
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["existing"], value: .existence)
            paths.set(["mutable"], value: .mutation)
            paths.set(["deletable"], value: .deletion)
            paths.set(["insertable"], value: .insertion)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node?.count == 3)
        }
    }

    // MARK: - Dictionary Proofs

    @Suite("Dictionary Proofs")
    struct DictionaryProofs {

        @Test("Dictionary proof with empty paths returns self")
        func testDictionaryProofEmptyPaths() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "test", value: "test-value")
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            let emptyPaths = ArrayTrie<SparseMerkleProof>()
            let result = try await header.proof(paths: emptyPaths, fetcher: fetcher)

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node == nil)
        }

        @Test("Dictionary proof validates existence on property")
        func testDictionaryProofExistenceProperty() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "parent", value: "parent-value")
            dictionary = try dictionary.inserting(key: "parentchild", value: "child-value")
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["parentchild"], value: .existence)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node?.count == 2)
        }

        @Test("Dictionary proof validates mutation on property")
        func testDictionaryProofMutationProperty() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "mutable-prop", value: "original-value")
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["mutable-prop"], value: .mutation)

            let result = try await header.proof(paths: paths, fetcher: fetcher)
            let resultAfterMutation = try result.node!.mutating(key: "mutable-prop", value: "new-value")


            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node?.count == 1)
            #expect(try resultAfterMutation.get(key: "mutable-prop") == "new-value")
        }

        @Test("Dictionary proof validates mutation on existing value")
        func testDictionaryProofMutationValidation() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "test", value: "existing-value")
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["test"], value: .mutation)

            let result = try await header.proof(paths: paths, fetcher: fetcher)
            let resultAfterMutation = try result.node!.mutating(key: "test", value: "new-value")

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node?.count == 1)
            #expect(try resultAfterMutation.get(key: "test") == "new-value")
        }

        @Test("Dictionary proof validates insertion on new property")
        func testDictionaryProofInsertionProperty() async throws {
            let dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["new-key"], value: .insertion)

            let result = try await header.proof(paths: paths, fetcher: fetcher)
            let resultAfterInsertion = try result.node!.inserting(key: "new-key", value: "new-value")

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node?.count == 0)
            #expect(resultAfterInsertion.count == 1)
            #expect(try resultAfterInsertion.get(key: "new-key") == "new-value")
        }

        @Test("Dictionary proof insertion validation throws error for existing value")
        func testDictionaryProofInsertionValidation() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "test", value: "existing-value")
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["test"], value: .insertion)

            await #expect(throws: ProofErrors.self) {
                _ = try await header.proof(paths: paths, fetcher: fetcher)
            }
        }

        @Test("Dictionary proof mutation validation throws error for nil value")
        func testDictionaryProofMutationValidationNilValue() async throws {
            let node = RadixNodeImpl<String>(prefix: "test", value: nil, children: [:])
            let radixHeader = try RadixHeaderImpl(node: node)
            let children: [Character: RadixHeaderImpl<String>] = ["t": radixHeader]
            let dictionary = MerkleDictionaryImpl<String>(children: children, count: 1)
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["t", "test"], value: .mutation)

            await #expect(throws: ProofErrors.self) {
                let header = try await header.proof(paths: paths, fetcher: fetcher)
                print(header)
            }
        }

        @Test("Dictionary proof with children processing")
        func testDictionaryProofWithChildren() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "parent", value: "parent-value")
            dictionary = try dictionary.inserting(key: "parentchild", value: "child-value")
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["parentchild"], value: .existence)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node?.count == 2)
        }

        @Test("Dictionary proof deletion processing")
        func testDictionaryProofDeletion() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "deletable", value: "to-delete")
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["deletable"], value: .deletion)

            let result = try await header.proof(paths: paths, fetcher: fetcher)
            let resultAfterDeletion = try result.node!.deleting(key: "deletable")

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node?.count == 1)
            #expect(resultAfterDeletion.count == 0)
            #expect(try resultAfterDeletion.get(key: "deletable") == nil)
        }

        @Test("Dictionary proof with missing data throws error")
        func testDictionaryProofMissingData() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "test", value: "test-value")
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["test"], value: .existence)

            await #expect(throws: Error.self) {
                _ = try await header.proof(paths: paths, fetcher: fetcher)
            }
        }

        @Test("Dictionary CID is deterministic")
        func testDictionaryCIDDeterministic() async throws {
            var dictionary1 = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary1 = try dictionary1.inserting(key: "same", value: "same-value")

            var dictionary2 = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary2 = try dictionary2.inserting(key: "same", value: "same-value")

            let header1 = try HeaderImpl(node: dictionary1)
            let header2 = try HeaderImpl(node: dictionary2)

            #expect(header1.rawCID == header2.rawCID)
        }

        @Test("Dictionary CID differs for different content")
        func testDictionaryCIDDifferentContent() async throws {
            var dictionary1 = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary1 = try dictionary1.inserting(key: "content1", value: "value1")

            var dictionary2 = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary2 = try dictionary2.inserting(key: "content2", value: "value2")

            let header1 = try HeaderImpl(node: dictionary1)
            let header2 = try HeaderImpl(node: dictionary2)

            #expect(header1.rawCID != header2.rawCID)
        }

        @Test("Dictionary proof maintains content addressability")
        func testDictionaryProofContentAddressability() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "content", value: "test-value")
            let originalHeader = try HeaderImpl(node: dictionary)
            let originalCID = originalHeader.rawCID

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: originalCID)
            let fetcher = TestStoreFetcher()
            try await originalHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["content"], value: .existence)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == originalCID)
            #expect(result.node?.count == 1)
        }

        @Test("Dictionary proof validates multiple proof types in single call")
        func testDictionaryProofMultipleProofTypes() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "existing-key", value: "existing-value")
            dictionary = try dictionary.inserting(key: "mutable-key", value: "original-value")
            dictionary = try dictionary.inserting(key: "deletable-key", value: "to-be-deleted")
            let headerWithNode = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
            let fetcher = TestStoreFetcher()
            try await headerWithNode.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["existing-key"], value: .existence)
            paths.set(["mutable-key"], value: .mutation)
            paths.set(["new-key"], value: .insertion)
            paths.set(["deletable-key"], value: .deletion)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == headerWithNode.rawCID)
            #expect(result.node?.count == 3)

            var modifiedDict = result.node!

            #expect(try modifiedDict.get(key: "existing-key") == "existing-value")

            modifiedDict = try modifiedDict.mutating(key: "mutable-key", value: "updated-value")
            #expect(try modifiedDict.get(key: "mutable-key") == "updated-value")

            modifiedDict = try modifiedDict.inserting(key: "new-key", value: "inserted-value")
            #expect(try modifiedDict.get(key: "new-key") == "inserted-value")

            modifiedDict = try modifiedDict.deleting(key: "deletable-key")
            #expect(try modifiedDict.get(key: "deletable-key") == nil)

            #expect(modifiedDict.count == 3)
            #expect(try modifiedDict.get(key: "existing-key") == "existing-value")
            #expect(try modifiedDict.get(key: "mutable-key") == "updated-value")
            #expect(try modifiedDict.get(key: "new-key") == "inserted-value")
            #expect(try modifiedDict.get(key: "deletable-key") == nil)
        }
    }

    // MARK: - MerkleDictionary Proofs

    @Suite("MerkleDictionary Proofs")
    struct MerkleDictionaryProofs {

        @Test("MerkleDictionary deletion proof validates removal of existing key")
        func testMerkleDictionaryDeletionProof() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "test", value: "to-be-deleted")
            let dictHeader = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: dictHeader.rawCID)
            let fetcher = TestStoreFetcher()
            try await dictHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["test"], value: .deletion)

            let result = try await header.proof(paths: paths, fetcher: fetcher)
            let resultAfterDeletion = try result.node!.deleting(key: "test")

            #expect(result.rawCID == dictHeader.rawCID)
            #expect(result.node?.count == 1)
            #expect(resultAfterDeletion.count == 0)
            #expect(try resultAfterDeletion.get(key: "test") == nil)
        }

        @Test("MerkleDictionary proof succeeds for non-existence value")
        func testMerkleDictionaryProofSucceedsForNonExistenceValue() async throws {
            typealias BaseDictionary = MerkleDictionaryImpl<UInt64>
            typealias HigherDictionaryType = MerkleDictionaryImpl<HeaderImpl<BaseDictionary>>

            let baseDictionary: BaseDictionary =
            try MerkleDictionaryImpl<UInt64>(children: [:], count: 0)
                .inserting(key: "Hello", value: 1)
                .inserting(key: "World", value: 2)

            let baseDictionaryHeader = try HeaderImpl<BaseDictionary>(node: baseDictionary)

            let higherDictionary: HigherDictionaryType = try HigherDictionaryType(children: [:], count: 0).inserting(key: "Foo", value: baseDictionaryHeader)

            var proofs = ArrayTrie<SparseMerkleProof>()
            proofs.set(["Bar", "Hello"], value: .insertion)
            proofs.set(["Foo", "Helli"], value: .insertion)

            let higherDictionaryHeader = try HeaderImpl<HigherDictionaryType>(node: higherDictionary)

            let fetcher = TestStoreFetcher()
            try! await higherDictionaryHeader.storeAsVolume(storer: fetcher)

            let emptyHigherDictionaryHeader = HeaderImpl<HigherDictionaryType>(rawCID: higherDictionaryHeader.rawCID)

            let proofOfInsertion = try await emptyHigherDictionaryHeader.proof(paths: proofs, fetcher: fetcher)
            #expect(proofOfInsertion.node != nil)

            var transforms = ArrayTrie<Transform>()
            transforms.set(["Bar"], value: .insert(baseDictionaryHeader.rawCID))
            transforms.set(["Foo", "Helli"], value: .insert("3"))

            let resolvedHeader = try await emptyHigherDictionaryHeader.resolveRecursive(fetcher: fetcher)
            let transformed = try resolvedHeader.transform(transforms: transforms)!
            #expect(try transformed.node?.get(key: "Foo")?.node?.get(key: "Helli") == 3)
            #expect(try transformed.node?.get(key: "Bar")?.rawCID == baseDictionaryHeader.rawCID)
        }

        @Test("MerkleDictionary deletion proof fails for non-existing key")
        func testMerkleDictionaryDeletionProofFailsForNonExisting() async throws {
            let radixNode = RadixNodeImpl<String>(prefix: "existing-key", value: "value", children: [:])
            let radixHeader = try RadixHeaderImpl(node: radixNode)
            let children: [Character: RadixHeaderImpl<String>] = ["e": radixHeader]
            let dictionary = MerkleDictionaryImpl<String>(children: children, count: 1)
            let dictHeader = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: dictHeader.rawCID)
            let fetcher = TestStoreFetcher()
            try await dictHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["n", "non-existing-key"], value: .deletion)

            await #expect(throws: ProofErrors.self) {
                _ = try await header.proof(paths: paths, fetcher: fetcher)
            }
        }

        @Test("MerkleDictionary deletion proof with nested radix structure")
        func testMerkleDictionaryDeletionProofNested() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "common-suffix1", value: "value1")
            dictionary = try dictionary.inserting(key: "common-suffix2", value: "value2")
            let dictHeader = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: dictHeader.rawCID)
            let fetcher = TestStoreFetcher()
            try await dictHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["common-suffix1"], value: .deletion)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == dictHeader.rawCID)
            #expect(result.node?.count == 2)
        }

        @Test("MerkleDictionary insertion proof validates adding new key")
        func testMerkleDictionaryInsertionProof() async throws {
            let dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            let dictHeader = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: dictHeader.rawCID)
            let fetcher = TestStoreFetcher()
            try await dictHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["test"], value: .insertion)

            let result = try await header.proof(paths: paths, fetcher: fetcher)
            let resultAfterInsertion = try result.node!.inserting(key: "test", value: "inserted-value")

            #expect(result.rawCID == dictHeader.rawCID)
            #expect(result.node?.count == 0)
            #expect(resultAfterInsertion.count == 1)
            #expect(try resultAfterInsertion.get(key: "test") == "inserted-value")
        }

        @Test("MerkleDictionary insertion proof fails for existing key")
        func testMerkleDictionaryInsertionProofFailsForExisting() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "existing-key", value: "value")
            let dictHeader = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: dictHeader.rawCID)
            let fetcher = TestStoreFetcher()
            try await dictHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["existing-key"], value: .insertion)

            await #expect(throws: ProofErrors.self) {
                _ = try await header.proof(paths: paths, fetcher: fetcher)
            }
        }

        @Test("MerkleDictionary mutation proof fails for non-existing key")
        func testMerkleDictionaryMutationProofFailsForNonExistingKeysAlongPath() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "existing-key", value: "value")
            let dictHeader = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: dictHeader.rawCID)
            let fetcher = TestStoreFetcher()
            try await dictHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["existing"], value: .mutation)

            await #expect(throws: ProofErrors.self) {
                _ = try await header.proof(paths: paths, fetcher: fetcher)
            }
        }

        @Test("MerkleDictionary insertion proof with complex radix splitting")
        func testMerkleDictionaryInsertionProofRadixSplit() async throws {
            let existingNode = RadixNodeImpl<String>(prefix: "commonprefix", value: "existing-value", children: [:])
            let existingHeader = try RadixHeaderImpl(node: existingNode)

            let children: [Character: RadixHeaderImpl<String>] = ["c": existingHeader]
            let dictionary = MerkleDictionaryImpl<String>(children: children, count: 1)
            let dictHeader = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: dictHeader.rawCID)
            let fetcher = TestStoreFetcher()
            try await dictHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["c", "commondifferent"], value: .insertion)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == dictHeader.rawCID)
            #expect(result.node?.count == 1)
        }

        @Test("MerkleDictionary mutation proof validates updating existing key")
        func testMerkleDictionaryMutationProof() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "mutable-key", value: "original-value")
            let dictHeader = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: dictHeader.rawCID)
            let fetcher = TestStoreFetcher()
            try await dictHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["mutable-key"], value: .mutation)

            let result = try await header.proof(paths: paths, fetcher: fetcher)
            let resultAfterMutation = try result.node!.mutating(key: "mutable-key", value: "updated-value")

            #expect(result.rawCID == dictHeader.rawCID)
            #expect(result.node?.count == 1)
            #expect(try resultAfterMutation.get(key: "mutable-key") == "updated-value")
        }

        @Test("MerkleDictionary mutation proof fails for non-existing key")
        func testMerkleDictionaryMutationProofFailsForNonExisting() async throws {
            let existingNode = RadixNodeImpl<String>(prefix: "existing", value: "value", children: [:])
            let existingHeader = try RadixHeaderImpl(node: existingNode)

            let children: [Character: RadixHeaderImpl<String>] = ["e": existingHeader]
            let dictionary = MerkleDictionaryImpl<String>(children: children, count: 1)
            let dictHeader = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: dictHeader.rawCID)
            let fetcher = TestStoreFetcher()
            try await dictHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["non-existing"], value: .mutation)

            await #expect(throws: ProofErrors.self) {
                _ = try await header.proof(paths: paths, fetcher: fetcher)
            }
        }

        @Test("MerkleDictionary mutation proof with deep nesting")
        func testMerkleDictionaryMutationProofDeepNesting() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "deep-nested-key", value: "deep-value")
            let dictHeader = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: dictHeader.rawCID)
            let fetcher = TestStoreFetcher()
            try await dictHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["deep-nested-key"], value: .mutation)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == dictHeader.rawCID)
            #expect(result.node?.count == 1)
        }

        @Test("MerkleDictionary existence proof validates present key")
        func testMerkleDictionaryExistenceProof() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "existing-key", value: "existing-value")
            let dictHeader = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: dictHeader.rawCID)
            let fetcher = TestStoreFetcher()
            try await dictHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["existing-key"], value: .existence)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == dictHeader.rawCID)
            #expect(result.node?.count == 1)
            #expect(try result.node!.get(key: "existing-key") == "existing-value")
        }

        @Test("MerkleDictionary existence proof with multiple concurrent validations")
        func testMerkleDictionaryExistenceProofMultiple() async throws {
            let node1 = RadixNodeImpl<String>(prefix: "key1", value: "value1", children: [:])
            let header1 = try RadixHeaderImpl(node: node1)

            let node2 = RadixNodeImpl<String>(prefix: "key2", value: "value2", children: [:])
            let header2 = try RadixHeaderImpl(node: node2)

            let node3 = RadixNodeImpl<String>(prefix: "key3", value: "value3", children: [:])
            let header3 = try RadixHeaderImpl(node: node3)

            let children: [Character: RadixHeaderImpl<String>] = [
                "k": header1,
                "l": header2,
                "m": header3
            ]
            let dictionary = MerkleDictionaryImpl<String>(children: children, count: 3)
            let dictHeader = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: dictHeader.rawCID)
            let fetcher = TestStoreFetcher()
            try await dictHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["k", "key1"], value: .existence)
            paths.set(["l", "key2"], value: .existence)
            paths.set(["m", "key3"], value: .existence)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == dictHeader.rawCID)
            #expect(result.node?.count == 3)
        }

        @Test("MerkleDictionary mixed proof types in single validation")
        func testMerkleDictionaryMixedProofTypes() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "existing", value: "value")
            dictionary = try dictionary.inserting(key: "mutable", value: "original")
            dictionary = try dictionary.inserting(key: "deletable", value: "to-delete")
            let dictHeader = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: dictHeader.rawCID)
            let fetcher = TestStoreFetcher()
            try await dictHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["existing"], value: .existence)
            paths.set(["mutable"], value: .mutation)
            paths.set(["deletable"], value: .deletion)
            paths.set(["new-insertion"], value: .insertion)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == dictHeader.rawCID)
            #expect(result.node?.count == 3)
        }

        @Test("MerkleDictionary proof with missing storage data throws error")
        func testMerkleDictionaryProofMissingData() async throws {
            let node = RadixNodeImpl<String>(prefix: "test", value: "value", children: [:])
            let radixHeader = try RadixHeaderImpl(node: node)

            let children: [Character: RadixHeaderImpl<String>] = ["t": radixHeader]
            let dictionary = MerkleDictionaryImpl<String>(children: children, count: 1)
            let dictHeader = try HeaderImpl(node: dictionary)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: dictHeader.rawCID)
            let fetcher = TestStoreFetcher()

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["t", "test"], value: .existence)

            await #expect(throws: Error.self) {
                _ = try await header.proof(paths: paths, fetcher: fetcher)
            }
        }

        @Test("MerkleDictionary proof maintains content addressability")
        func testMerkleDictionaryProofContentAddressability() async throws {
            let node = RadixNodeImpl<String>(prefix: "content-test", value: "test-value", children: [:])
            let radixHeader = try RadixHeaderImpl(node: node)

            let children: [Character: RadixHeaderImpl<String>] = ["c": radixHeader]
            let dictionary = MerkleDictionaryImpl<String>(children: children, count: 1)
            let originalHeader = try HeaderImpl(node: dictionary)
            let originalCID = originalHeader.rawCID

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: originalCID)
            let fetcher = TestStoreFetcher()
            try await originalHeader.storeAsVolume(storer: fetcher)

            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["c", "content-test"], value: .existence)

            let result = try await header.proof(paths: paths, fetcher: fetcher)

            #expect(result.rawCID == originalCID)
            #expect(result.node?.count == 1)
        }

        @Test("Proof on nested dictionary: existence at multiple levels")
        func testProofNestedExistence() async throws {
            typealias Inner = MerkleDictionaryImpl<String>
            typealias Outer = MerkleDictionaryImpl<HeaderImpl<Inner>>

            let inner = try Inner(children: [:], count: 0)
                .inserting(key: "deepKey", value: "deepVal")
                .inserting(key: "otherKey", value: "otherVal")
            let innerH = try HeaderImpl(node: inner)

            let outer = try Outer(children: [:], count: 0)
                .inserting(key: "container", value: innerH)
                .inserting(key: "sibling", value: try HeaderImpl(node:
                    try Inner(children: [:], count: 0).inserting(key: "z", value: "26")
                ))

            let outerH = try HeaderImpl(node: outer)
            let fetcher = TestStoreFetcher()
            try await outerH.storeAsVolume(storer: fetcher)

            let unresolved = HeaderImpl<Outer>(rawCID: outerH.rawCID)
            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["container"], value: .existence)

            let proofResult = try await unresolved.proof(paths: paths, fetcher: fetcher)
            #expect(proofResult.rawCID == outerH.rawCID)
            #expect(proofResult.node != nil)
            let container = try proofResult.node!.get(key: "container")
            #expect(container != nil)
        }

        @Test("Mutation proof then mutate preserves content addressability")
        func testMutationProofThenMutate() async throws {
            let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "mutableKey", value: "original")
                .inserting(key: "immutableKey", value: "fixed")

            let header = try HeaderImpl(node: dict)
            let fetcher = TestStoreFetcher()
            try await header.storeAsVolume(storer: fetcher)

            let unresolved = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: header.rawCID)
            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["mutableKey"], value: .mutation)

            let proofResult = try await unresolved.proof(paths: paths, fetcher: fetcher)
            let mutated = try proofResult.node!.mutating(key: "mutableKey", value: "changed")

            #expect(try mutated.get(key: "mutableKey") == "changed")
            #expect(mutated.count == 2)

            let mutatedHeader = try HeaderImpl(node: mutated)
            #expect(mutatedHeader.rawCID != header.rawCID)
        }

        @Test("Deletion proof then delete then verify CID")
        func testDeletionProofFullCycle() async throws {
            let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "keep", value: "kept")
                .inserting(key: "remove", value: "doomed")

            let header = try HeaderImpl(node: dict)
            let fetcher = TestStoreFetcher()
            try await header.storeAsVolume(storer: fetcher)

            let unresolved = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: header.rawCID)
            var paths = ArrayTrie<SparseMerkleProof>()
            paths.set(["remove"], value: .deletion)

            let proofResult = try await unresolved.proof(paths: paths, fetcher: fetcher)
            let afterDelete = try proofResult.node!.deleting(key: "remove")
            #expect(afterDelete.count == 1)

            let sameDict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "keep", value: "kept")
            let sameHeader = try HeaderImpl(node: sameDict)
            #expect(try HeaderImpl(node: afterDelete).rawCID == sameHeader.rawCID)
        }
    }
}
