import Testing
import Foundation
import Crypto
@testable import cashew

@Suite("MerkleSet")
struct MerkleSetTests {

    @Suite("Basics")
    struct BasicsTests {

        @Test("Empty set has count 0 and no members")
        func testEmptySet() throws {
            let set = MerkleSetImpl()
            #expect(set.count == 0)
            #expect(try set.members().isEmpty)
        }

        @Test("Insert adds a member")
        func testInsert() throws {
            let set = try MerkleSetImpl().insert("alice")
            #expect(set.count == 1)
            #expect(try set.contains("alice"))
        }

        @Test("Contains returns false for missing member")
        func testContainsMissing() throws {
            let set = try MerkleSetImpl().insert("alice")
            #expect(try !set.contains("bob"))
        }

        @Test("Remove deletes a member")
        func testRemove() throws {
            let set = try MerkleSetImpl()
                .insert("alice")
                .insert("bob")
                .remove("alice")
            #expect(set.count == 1)
            #expect(try !set.contains("alice"))
            #expect(try set.contains("bob"))
        }

        @Test("Members returns all inserted keys")
        func testMembers() throws {
            let set = try MerkleSetImpl()
                .insert("alice")
                .insert("bob")
                .insert("charlie")
            let m = try set.members()
            #expect(m == Set(["alice", "bob", "charlie"]))
        }

        @Test("Count tracks insertions and removals")
        func testCount() throws {
            var set = MerkleSetImpl()
            set = try set.insert("a")
            #expect(set.count == 1)
            set = try set.insert("b")
            #expect(set.count == 2)
            set = try set.remove("a")
            #expect(set.count == 1)
        }
    }

    @Suite("Set Operations")
    struct OperationsTests {

        @Test("Union combines members from both sets")
        func testUnion() throws {
            let a = try MerkleSetImpl().insert("alice").insert("bob")
            let b = try MerkleSetImpl().insert("bob").insert("charlie")
            let result = try a.union(b)
            #expect(try result.members() == Set(["alice", "bob", "charlie"]))
            #expect(result.count == 3)
        }

        @Test("Intersection keeps only common members")
        func testIntersection() throws {
            let a = try MerkleSetImpl().insert("alice").insert("bob").insert("charlie")
            let b = try MerkleSetImpl().insert("bob").insert("charlie").insert("dave")
            let result = try a.intersection(b)
            #expect(try result.members() == Set(["bob", "charlie"]))
            #expect(result.count == 2)
        }

        @Test("Subtracting removes other's members")
        func testSubtracting() throws {
            let a = try MerkleSetImpl().insert("alice").insert("bob").insert("charlie")
            let b = try MerkleSetImpl().insert("bob").insert("dave")
            let result = try a.subtracting(b)
            #expect(try result.members() == Set(["alice", "charlie"]))
            #expect(result.count == 2)
        }

        @Test("Symmetric difference keeps members in exactly one set")
        func testSymmetricDifference() throws {
            let a = try MerkleSetImpl().insert("alice").insert("bob")
            let b = try MerkleSetImpl().insert("bob").insert("charlie")
            let result = try a.symmetricDifference(b)
            #expect(try result.members() == Set(["alice", "charlie"]))
            #expect(result.count == 2)
        }

        @Test("Union with empty set returns same members")
        func testUnionEmpty() throws {
            let a = try MerkleSetImpl().insert("alice")
            let b = MerkleSetImpl()
            let result = try a.union(b)
            #expect(try result.members() == Set(["alice"]))
        }

        @Test("Intersection with empty set returns empty")
        func testIntersectionEmpty() throws {
            let a = try MerkleSetImpl().insert("alice")
            let b = MerkleSetImpl()
            let result = try a.intersection(b)
            #expect(try result.members().isEmpty)
        }
    }

    @Suite("Content Addressability")
    struct ContentAddressabilityTests {

        @Test("Same members produce same CID regardless of insertion order")
        func testSameMembersSameCID() throws {
            let a = try MerkleSetImpl().insert("alice").insert("bob").insert("charlie")
            let b = try MerkleSetImpl().insert("charlie").insert("alice").insert("bob")
            let cidA = try HeaderImpl(node: a).rawCID
            let cidB = try HeaderImpl(node: b).rawCID
            #expect(cidA == cidB)
        }

        @Test("Different members produce different CID")
        func testDifferentMembersDifferentCID() throws {
            let a = try MerkleSetImpl().insert("alice").insert("bob")
            let b = try MerkleSetImpl().insert("alice").insert("charlie")
            let cidA = try HeaderImpl(node: a).rawCID
            let cidB = try HeaderImpl(node: b).rawCID
            #expect(cidA != cidB)
        }
    }

    @Suite("Store and Resolve")
    struct StoreAndResolveTests {

        @Test("Round-trip through store and fetch")
        func testStoreAndResolve() async throws {
            let set = try MerkleSetImpl()
                .insert("alice")
                .insert("bob")
                .insert("charlie")

            let store = TestStoreFetcher()
            let header = try HeaderImpl(node: set)
            try await header.storeAsVolume(storer: store)

            let cidOnly = HeaderImpl<MerkleSetImpl>(rawCID: header.rawCID)
            let resolved = try await cidOnly.resolveRecursive(fetcher: store)

            let resolvedSet = resolved.node!
            #expect(try resolvedSet.contains("alice"))
            #expect(try resolvedSet.contains("bob"))
            #expect(try resolvedSet.contains("charlie"))
            #expect(resolvedSet.count == 3)
        }
    }

    @Suite("Encryption")
    struct EncryptionTests {

        @Test("Targeted encryption on set member values")
        func testTargetedEncryption() throws {
            let key = SymmetricKey(size: .bits256)

            typealias SetWithHeaders = MerkleDictionaryImpl<HeaderImpl<MerkleSetImpl>>

            var dict = SetWithHeaders()
            let innerSet = try MerkleSetImpl().insert("x").insert("y")
            dict = try dict.inserting(key: "public", value: try HeaderImpl(node: innerSet))
            dict = try dict.inserting(key: "secret", value: try HeaderImpl(node: innerSet))
            let header = try HeaderImpl(node: dict)

            var encryption = ArrayTrie<EncryptionStrategy>()
            encryption.set(["secret"], value: .targeted(key))
            let encrypted = try header.encrypt(encryption: encryption)

            let pub = try encrypted.node!.get(key: "public")!
            let sec = try encrypted.node!.get(key: "secret")!
            #expect(pub.encryptionInfo == nil)
            #expect(sec.encryptionInfo != nil)
        }
    }

    @Suite("MerkleSet as MerkleDictionary")
    struct InheritedMethodsTests {

        @Test("allKeys works on MerkleSet")
        func testAllKeys() throws {
            let set = try MerkleSetImpl().insert("x").insert("y").insert("z")
            let keys = try set.allKeys()
            #expect(keys == Set(["x", "y", "z"]))
        }

        @Test("get(key:) returns empty string sentinel for members")
        func testGetKey() throws {
            let set = try MerkleSetImpl().insert("hello")
            #expect(try set.get(key: "hello") == "")
            #expect(try set.get(key: "missing") == nil)
        }

        @Test("sortedKeys works on MerkleSet")
        func testSortedKeys() throws {
            let set = try MerkleSetImpl()
                .insert("cherry")
                .insert("apple")
                .insert("banana")
            let sorted = try set.sortedKeys()
            #expect(sorted == ["apple", "banana", "cherry"])
        }

        @Test("properties returns first characters")
        func testProperties() throws {
            let set = try MerkleSetImpl().insert("alice").insert("bob")
            let props = set.properties()
            #expect(props.contains("a"))
            #expect(props.contains("b"))
        }

        @Test("Transform operations work on MerkleSet")
        func testTransform() throws {
            var transforms = ArrayTrie<Transform>()
            transforms.set(["newmember"], value: .insert(""))
            transforms.set(["oldmember"], value: .delete)

            let set = try MerkleSetImpl().insert("oldmember").insert("kept")
            let result = try set.transform(transforms: transforms)!
            #expect(try result.contains("newmember"))
            #expect(try !result.contains("oldmember"))
            #expect(try result.contains("kept"))
        }
    }
}

import ArrayTrie
