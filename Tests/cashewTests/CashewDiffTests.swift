import Testing
import Foundation
@testable import cashew

@Suite("CashewDiff")
struct CashewDiffTests {

    typealias Dict = MerkleDictionaryImpl<String>
    typealias DictOfDicts = MerkleDictionaryImpl<HeaderImpl<Dict>>

    // MARK: - Basic structural diff (Node level)

    @Test("Identical CIDs produce empty diff")
    func testIdenticalCID() throws {
        let dict = try Dict().inserting(key: "a", value: "1")
        let h = try HeaderImpl(node: dict)
        #expect(try h.diff(from: h).isEmpty)
        #expect(try h.diff(from: h).changeCount == 0)
    }

    // MARK: - MerkleDictionary key-level diff

    @Test("Dict diff shows inserted keys with values")
    func testDictInserted() throws {
        let old = try Dict().inserting(key: "a", value: "1")
        let new = try old.inserting(key: "b", value: "2")
        let diff = try new.diff(from: old)

        #expect(diff.inserted == ["b": "2"])
        #expect(diff.deleted.isEmpty)
        #expect(diff.modified.isEmpty)
        #expect(diff.changeCount == 1)
    }

    @Test("Dict diff shows deleted keys with old values")
    func testDictDeleted() throws {
        let old = try Dict()
            .inserting(key: "a", value: "1")
            .inserting(key: "b", value: "2")
        let new = try old.deleting(key: "b")
        let diff = try new.diff(from: old)

        #expect(diff.deleted == ["b": "2"])
        #expect(diff.inserted.isEmpty)
        #expect(diff.modified.isEmpty)
        #expect(diff.changeCount == 1)
    }

    @Test("Dict diff shows modified keys with old and new values")
    func testDictModified() throws {
        let old = try Dict().inserting(key: "a", value: "1")
        let new = try old.deleting(key: "a").inserting(key: "a", value: "999")
        let diff = try new.diff(from: old)

        #expect(diff.inserted.isEmpty)
        #expect(diff.deleted.isEmpty)
        #expect(diff.modified.count == 1)
        #expect(diff.modified["a"]?.old == "1")
        #expect(diff.modified["a"]?.new == "999")
        #expect(diff.changeCount == 1)
    }

    @Test("Dict diff with multiple changes")
    func testDictMultipleChanges() throws {
        let old = try Dict()
            .inserting(key: "a", value: "1")
            .inserting(key: "b", value: "2")
            .inserting(key: "c", value: "3")
        let new = try old
            .deleting(key: "a")                                  // delete a
            .deleting(key: "b").inserting(key: "b", value: "22") // modify b
            .inserting(key: "d", value: "4")                     // insert d
        // c unchanged
        let diff = try new.diff(from: old)

        #expect(diff.deleted == ["a": "1"])
        #expect(diff.inserted == ["d": "4"])
        #expect(diff.modified["b"]?.old == "2")
        #expect(diff.modified["b"]?.new == "22")
        #expect(diff.changeCount == 3)
    }

    @Test("Dict diff: empty to populated")
    func testDictEmptyToPopulated() throws {
        let old = Dict()
        let new = try Dict().inserting(key: "x", value: "1").inserting(key: "y", value: "2")
        let diff = try new.diff(from: old)

        #expect(diff.inserted.count == 2)
        #expect(diff.deleted.isEmpty)
        #expect(diff.changeCount == 2)
    }

    @Test("Dict diff: populated to empty")
    func testDictPopulatedToEmpty() throws {
        let old = try Dict().inserting(key: "x", value: "1").inserting(key: "y", value: "2")
        let new = Dict()
        let diff = try new.diff(from: old)

        #expect(diff.deleted.count == 2)
        #expect(diff.inserted.isEmpty)
        #expect(diff.changeCount == 2)
    }

    // MARK: - Nested dict diff

    @Test("Dict of dicts: inner change shows CID diff with recursive children")
    func testNestedDictModified() throws {
        let inner1 = try Dict().inserting(key: "x", value: "1")
        let inner2 = try Dict().inserting(key: "x", value: "1").inserting(key: "y", value: "2")
        let old = try DictOfDicts().inserting(key: "child", value: try HeaderImpl(node: inner1))
        let new = try DictOfDicts().inserting(key: "child", value: try HeaderImpl(node: inner2))

        let diff = try new.diff(from: old)

        #expect(diff.inserted.isEmpty)
        #expect(diff.deleted.isEmpty)
        #expect(diff.modified.count == 1)

        let childEntry = diff.modified["child"]!
        #expect(childEntry.old == (try HeaderImpl(node: inner1).rawCID))
        #expect(childEntry.new == (try HeaderImpl(node: inner2).rawCID))
        #expect(!childEntry.children.isEmpty)
    }

    @Test("Dict of dicts: unchanged child is not in diff")
    func testNestedUnchanged() throws {
        let shared = try HeaderImpl(node: try Dict().inserting(key: "x", value: "1"))
        let old = try DictOfDicts()
            .inserting(key: "same", value: shared)
            .inserting(key: "changed", value: try HeaderImpl(node: try Dict().inserting(key: "k", value: "v1")))
        let new = try DictOfDicts()
            .inserting(key: "same", value: shared)
            .inserting(key: "changed", value: try HeaderImpl(node: try Dict().inserting(key: "k", value: "v2")))

        let diff = try new.diff(from: old)

        #expect(!diff.modified.keys.contains("same"))
        #expect(diff.modified.keys.contains("changed"))
    }

    // MARK: - Header diff

    @Test("Header diff delegates to MerkleDictionary key-level diff")
    func testHeaderDictDiff() throws {
        let old = try HeaderImpl(node: try Dict().inserting(key: "a", value: "1"))
        let new = try HeaderImpl(node: try Dict().inserting(key: "a", value: "1").inserting(key: "b", value: "2"))
        let diff = try new.diff(from: old)

        #expect(diff.inserted == ["b": "2"])
    }

    @Test("Header diff with fetcher resolves before diffing")
    func testHeaderDiffWithFetcher() async throws {
        let inner1 = try Dict().inserting(key: "x", value: "1")
        let inner2 = try Dict().inserting(key: "x", value: "2")
        let old = try DictOfDicts().inserting(key: "child", value: try HeaderImpl(node: inner1))
        let new = try DictOfDicts().inserting(key: "child", value: try HeaderImpl(node: inner2))

        let store = TestStoreFetcher()
        let hOld = try HeaderImpl(node: old)
        let hNew = try HeaderImpl(node: new)
        try await hOld.storeAsVolume(storer: store)
        try await hNew.storeAsVolume(storer: store)

        let diff = try await HeaderImpl<DictOfDicts>(rawCID: hNew.rawCID)
            .diff(from: HeaderImpl<DictOfDicts>(rawCID: hOld.rawCID), fetcher: store)
        #expect(!diff.isEmpty)
        #expect(diff.modified.keys.contains("child"))
    }

    // MARK: - Custom node diff

    @Test("Custom node diff: fleet scenario with change count")
    func testFleetDiff() throws {
        typealias ServiceConfig = MerkleDictionaryImpl<String>

        struct Server: Node, Sendable {
            var services: [String: HeaderImpl<ServiceConfig>] = [:]
            func properties() -> Set<String> { Set(services.keys) }
            func get(property: String) -> (any Header)? { services[property] }
            func set(properties: [String: any Header]) -> Server {
                var copy = self
                for (k, v) in properties { copy.services[k] = v as? HeaderImpl<ServiceConfig> }
                return copy
            }
            func toData() -> Data? { nil }
            init?(data: Data) { nil }
            init(services: [String: HeaderImpl<ServiceConfig>] = [:]) { self.services = services }
        }

        struct Fleet: Node, Sendable {
            var hosts: [String: HeaderImpl<Server>] = [:]
            func properties() -> Set<String> { Set(hosts.keys) }
            func get(property: String) -> (any Header)? { hosts[property] }
            func set(properties: [String: any Header]) -> Fleet {
                var copy = self
                for (k, v) in properties { copy.hosts[k] = v as? HeaderImpl<Server> }
                return copy
            }
            func toData() -> Data? { nil }
            init?(data: Data) { nil }
            init(hosts: [String: HeaderImpl<Server>] = [:]) { self.hosts = hosts }
        }

        func config(_ kvs: (String, String)...) throws -> HeaderImpl<ServiceConfig> {
            var dict = ServiceConfig()
            for (k, v) in kvs { dict = try dict.inserting(key: k, value: v) }
            return try HeaderImpl(node: dict)
        }

        let dbServer = Server(services: [
            "postgres": try config(("role", "primary"), ("port", "5432")),
        ])
        let oldFleet = Fleet(hosts: [
            "web-1": try HeaderImpl(node: Server(services: [
                "nginx": try config(("status", "healthy"), ("port", "443")),
            ])),
            "db-1": try HeaderImpl(node: dbServer),
        ])
        let newFleet = Fleet(hosts: [
            "web-1": try HeaderImpl(node: Server(services: [
                "nginx": try config(("status", "degraded"), ("port", "443")),
            ])),
            "db-1": try HeaderImpl(node: dbServer),
            "cache-1": try HeaderImpl(node: Server(services: [
                "redis": try config(("port", "6379")),
            ])),
        ])

        let diff = newFleet.diff(from: oldFleet)

        #expect(diff.inserted.keys.contains("cache-1"))
        #expect(diff.modified.keys.contains("web-1"))
        #expect(!diff.modified.keys.contains("db-1"))
        #expect(diff.deleted.isEmpty)
        #expect(diff.changeCount >= 2)
    }

    // MARK: - Description output

    @Test("Description is human-readable")
    func testDescription() throws {
        let old = try Dict()
            .inserting(key: "alice", value: "engineer")
            .inserting(key: "bob", value: "designer")
        let new = try Dict()
            .inserting(key: "alice", value: "lead")
            .inserting(key: "carol", value: "intern")
        let diff = try new.diff(from: old)
        let desc = diff.description

        #expect(desc.contains("+ carol: intern"))
        #expect(desc.contains("- bob: designer"))
        #expect(desc.contains("~ alice: engineer → lead"))
    }
}
