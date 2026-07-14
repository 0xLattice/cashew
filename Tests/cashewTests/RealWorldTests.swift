import Testing
import Foundation
import ArrayTrie
import Crypto
@testable import cashew

// MARK: - User Profile Store

@Suite("Real-World: User Profile Store")
struct UserProfileStoreTests {

    typealias ProfileDict = MerkleDictionaryImpl<String>
    typealias UserStore = MerkleDictionaryImpl<HeaderImpl<ProfileDict>>

    private func makeProfile(name: String, email: String, role: String) throws -> ProfileDict {
        try ProfileDict()
            .inserting(key: "name", value: name)
            .inserting(key: "email", value: email)
            .inserting(key: "role", value: role)
    }

    @Test("Full user lifecycle: insert, query, update, delete")
    func testUserLifecycle() throws {
        let alice = try makeProfile(name: "Alice", email: "alice@co.com", role: "engineer")
        let bob = try makeProfile(name: "Bob", email: "bob@co.com", role: "designer")
        let charlie = try makeProfile(name: "Charlie", email: "charlie@co.com", role: "manager")

        var store = try UserStore()
            .inserting(key: "u001", value: try HeaderImpl(node: alice))
            .inserting(key: "u002", value: try HeaderImpl(node: bob))
            .inserting(key: "u003", value: try HeaderImpl(node: charlie))
        #expect(store.count == 3)

        let bobProfile = try store.get(key: "u002")!.node!
        #expect(try bobProfile.get(key: "name") == "Bob")
        #expect(try bobProfile.get(key: "role") == "designer")

        let updatedBob = try makeProfile(name: "Bob", email: "bob@co.com", role: "lead designer")
        store = try store.mutating(key: "u002", value: try HeaderImpl(node: updatedBob))
        #expect(try store.get(key: "u002")!.node!.get(key: "role") == "lead designer")

        store = try store.deleting(key: "u003")
        #expect(store.count == 2)
        #expect(try store.allKeys() == Set(["u001", "u002"]))

        let allUsers = try store.allKeysAndValues()
        #expect(allUsers.count == 2)
        #expect(allUsers["u001"] != nil)
        #expect(allUsers["u002"] != nil)
    }

    @Test("Structural sharing: unchanged users keep the same CID across versions")
    func testStructuralSharing() throws {
        let alice = try makeProfile(name: "Alice", email: "alice@co.com", role: "engineer")
        let bob = try makeProfile(name: "Bob", email: "bob@co.com", role: "designer")

        let v1 = try UserStore()
            .inserting(key: "u001", value: try HeaderImpl(node: alice))
            .inserting(key: "u002", value: try HeaderImpl(node: bob))

        let charlie = try makeProfile(name: "Charlie", email: "charlie@co.com", role: "manager")
        let v2 = try v1.inserting(key: "u003", value: try HeaderImpl(node: charlie))

        let aliceCIDv1 = try v1.get(key: "u001")!.rawCID
        let aliceCIDv2 = try v2.get(key: "u001")!.rawCID
        #expect(aliceCIDv1 == aliceCIDv2)

        let bobCIDv1 = try v1.get(key: "u002")!.rawCID
        let bobCIDv2 = try v2.get(key: "u002")!.rawCID
        #expect(bobCIDv1 == bobCIDv2)

        let v1Header = try HeaderImpl(node: v1)
        let v2Header = try HeaderImpl(node: v2)
        #expect(v1Header.rawCID != v2Header.rawCID)
    }

    @Test("Store and resolve user profiles from CID-only references")
    func testStoreAndResolveProfiles() async throws {
        let alice = try makeProfile(name: "Alice", email: "alice@co.com", role: "engineer")
        let bob = try makeProfile(name: "Bob", email: "bob@co.com", role: "designer")

        let store = try UserStore()
            .inserting(key: "u001", value: try HeaderImpl(node: alice))
            .inserting(key: "u002", value: try HeaderImpl(node: bob))

        let header = try HeaderImpl(node: store)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<UserStore>(rawCID: header.rawCID)
            .resolveRecursive(fetcher: fetcher)

        #expect(resolved.rawCID == header.rawCID)
        #expect(try resolved.node!.get(key: "u001")!.node!.get(key: "name") == "Alice")
        #expect(try resolved.node!.get(key: "u002")!.node!.get(key: "email") == "bob@co.com")
    }
}

// MARK: - Version-Controlled Configuration

@Suite("Real-World: Version-Controlled Configuration")
struct VersionedConfigTests {

    typealias Config = MerkleDictionaryImpl<String>

    @Test("Configuration versioning with rollback to previous state")
    func testConfigVersioningAndRollback() async throws {
        let v1 = try Config()
            .inserting(key: "debug", value: "false")
            .inserting(key: "timeout", value: "30")
            .inserting(key: "region", value: "us-east-1")
        let v1Header = try HeaderImpl(node: v1)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["timeout"], value: .update("60"))
        transforms.set(["retries"], value: .insert("3"))
        let v2 = try v1.transform(transforms: transforms)!
        let v2Header = try HeaderImpl(node: v2)

        transforms = ArrayTrie<Transform>()
        transforms.set(["debug"], value: .delete)
        let v3 = try v2.transform(transforms: transforms)!
        let v3Header = try HeaderImpl(node: v3)

        #expect(v1Header.rawCID != v2Header.rawCID)
        #expect(v2Header.rawCID != v3Header.rawCID)

        let fetcher = TestStoreFetcher()
        try await v1Header.storeAsVolume(storer: fetcher)
        try await v2Header.storeAsVolume(storer: fetcher)
        try await v3Header.storeAsVolume(storer: fetcher)

        let rolledBack = try await HeaderImpl<Config>(rawCID: v1Header.rawCID)
            .resolveRecursive(fetcher: fetcher)
        #expect(try rolledBack.node!.get(key: "timeout") == "30")
        #expect(try rolledBack.node!.get(key: "debug") == "false")

        let current = try await HeaderImpl<Config>(rawCID: v3Header.rawCID)
            .resolveRecursive(fetcher: fetcher)
        #expect(try current.node!.get(key: "timeout") == "60")
        #expect(try current.node!.get(key: "retries") == "3")
        #expect(try current.node!.get(key: "debug") == nil)
    }

    @Test("Unchanged config branches share CIDs across versions")
    func testConfigStructuralSharing() throws {
        let v1 = try Config()
            .inserting(key: "region", value: "us-east-1")
            .inserting(key: "timeout", value: "30")
            .inserting(key: "debug", value: "false")

        var transforms = ArrayTrie<Transform>()
        transforms.set(["timeout"], value: .update("60"))
        let v2 = try v1.transform(transforms: transforms)!

        let regionCIDv1 = v1.children["r"]!.rawCID
        let regionCIDv2 = v2.children["r"]!.rawCID
        #expect(regionCIDv1 == regionCIDv2)

        let debugCIDv1 = v1.children["d"]!.rawCID
        let debugCIDv2 = v2.children["d"]!.rawCID
        #expect(debugCIDv1 == debugCIDv2)

        let timeoutCIDv1 = v1.children["t"]!.rawCID
        let timeoutCIDv2 = v2.children["t"]!.rawCID
        #expect(timeoutCIDv1 != timeoutCIDv2)
    }

    @Test("Batch config update via transform preserves count")
    func testBatchConfigUpdate() throws {
        var config = try Config()
            .inserting(key: "feature_a", value: "enabled")
            .inserting(key: "feature_b", value: "disabled")
            .inserting(key: "max_connections", value: "100")
        #expect(config.count == 3)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["feature_b"], value: .update("enabled"))
        transforms.set(["feature_c"], value: .insert("enabled"))
        transforms.set(["max_connections"], value: .update("200"))
        config = try config.transform(transforms: transforms)!

        #expect(config.count == 4)
        #expect(try config.get(key: "feature_b") == "enabled")
        #expect(try config.get(key: "feature_c") == "enabled")
        #expect(try config.get(key: "max_connections") == "200")
        #expect(try config.get(key: "feature_a") == "enabled")
    }
}

// MARK: - Access-Controlled Records with Selective Encryption

@Suite("Real-World: Selective Encryption for Access Control")
struct SelectiveEncryptionTests {

    typealias RecordDict = MerkleDictionaryImpl<HeaderImpl<TestScalar>>

    @Test("Public fields accessible, private fields encrypted")
    func testSelectiveFieldEncryption() throws {
        let patientKey = SymmetricKey(size: .bits256)

        var record = RecordDict(children: [:], count: 0)
        record = try record.inserting(key: "patient_id", value: try HeaderImpl(node: TestScalar(val: 12345)))
        record = try record.inserting(key: "name", value: try HeaderImpl(node: TestScalar(val: 1)))
        record = try record.inserting(key: "ssn", value: try HeaderImpl(node: TestScalar(val: 999)))
        record = try record.inserting(key: "diagnosis", value: try HeaderImpl(node: TestScalar(val: 42)))

        let header = try HeaderImpl(node: record)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["ssn"], value: .targeted(patientKey))
        encryption.set(["diagnosis"], value: .targeted(patientKey))
        let encrypted = try header.encrypt(encryption: encryption)

        let encNode = encrypted.node!
        let publicId = try encNode.get(key: "patient_id")!
        #expect(publicId.encryptionInfo == nil)
        let nameVal = try encNode.get(key: "name")!
        #expect(nameVal.encryptionInfo == nil)

        let ssnVal = try encNode.get(key: "ssn")!
        #expect(ssnVal.encryptionInfo != nil)
        let diagVal = try encNode.get(key: "diagnosis")!
        #expect(diagVal.encryptionInfo != nil)
    }

    @Test("Authorized resolver can read encrypted fields after store/resolve")
    func testAuthorizedAccess() async throws {
        let patientKey = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(patientKey)

        var record = MerkleDictionaryImpl<HeaderImpl<TestScalar>>(children: [:], count: 0)
        record = try record.inserting(key: "public_id", value: try HeaderImpl(node: TestScalar(val: 100)))
        record = try record.inserting(key: "secret_score", value: try HeaderImpl(node: TestScalar(val: 42)))
        let header = try HeaderImpl(node: record)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["secret_score"], value: .targeted(patientKey))
        let encrypted = try header.encrypt(encryption: encryption)

        try await encrypted.storeAsVolume(storer: fetcher)

        let resolved = try await encrypted.removingNode().resolveRecursive(fetcher: fetcher)
        let publicVal = try resolved.node!.get(key: "public_id")!
        let publicResolved = try await publicVal.resolve(fetcher: fetcher)
        #expect(publicResolved.node!.val == 100)

        let secretVal = try resolved.node!.get(key: "secret_score")!
        let secretResolved = try await secretVal.resolve(fetcher: fetcher)
        #expect(secretResolved.node!.val == 42)
    }

    @Test("Unauthorized resolver cannot read encrypted fields")
    func testUnauthorizedAccess() async throws {
        let patientKey = SymmetricKey(size: .bits256)
        let authorizedFetcher = TestKeyProvidingStoreFetcher()
        authorizedFetcher.registerKey(patientKey)

        var record = MerkleDictionaryImpl<HeaderImpl<TestScalar>>(children: [:], count: 0)
        record = try record.inserting(key: "public_id", value: try HeaderImpl(node: TestScalar(val: 100)))
        record = try record.inserting(key: "secret_score", value: try HeaderImpl(node: TestScalar(val: 42)))
        let header = try HeaderImpl(node: record)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["secret_score"], value: .targeted(patientKey))
        let encrypted = try header.encrypt(encryption: encryption)
        try await encrypted.storeAsVolume(storer: authorizedFetcher)

        let unauthorizedFetcher = TestStoreFetcher()
        let encryptedSecretVal = try encrypted.node!.get(key: "secret_score")!
        let cidOnly = HeaderImpl<TestScalar>(rawCID: encryptedSecretVal.rawCID, node: nil, encryptionInfo: encryptedSecretVal.encryptionInfo)

        await #expect(throws: (any Error).self) {
            _ = try await cidOnly.resolve(fetcher: unauthorizedFetcher)
        }
    }

    @Test("Multi-tenant encryption: each tenant's data encrypted with separate key")
    func testMultiTenantIsolation() throws {
        let tenantAKey = SymmetricKey(size: .bits256)
        let tenantBKey = SymmetricKey(size: .bits256)

        typealias TenantStore = MerkleDictionaryImpl<HeaderImpl<TestScalar>>

        var store = TenantStore(children: [:], count: 0)
        store = try store.inserting(key: "tenant_a_data", value: try HeaderImpl(node: TestScalar(val: 1)))
        store = try store.inserting(key: "tenant_b_data", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: store)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["tenant_a_data"], value: .targeted(tenantAKey))
        encryption.set(["tenant_b_data"], value: .targeted(tenantBKey))
        let encrypted = try header.encrypt(encryption: encryption)

        let aVal = try encrypted.node!.get(key: "tenant_a_data")!
        let bVal = try encrypted.node!.get(key: "tenant_b_data")!
        #expect(aVal.encryptionInfo != nil)
        #expect(bVal.encryptionInfo != nil)
        #expect(aVal.encryptionInfo!.keyHash != bVal.encryptionInfo!.keyHash)
    }
}

// MARK: - Lazy-Loading Product Catalog

@Suite("Real-World: Lazy-Loading Product Catalog")
struct LazyCatalogTests {

    typealias Product = MerkleDictionaryImpl<String>
    typealias Category = MerkleDictionaryImpl<HeaderImpl<Product>>
    typealias Catalog = MerkleDictionaryImpl<HeaderImpl<Category>>

    private func buildCatalog() throws -> (Catalog, HeaderImpl<Catalog>) {
        let laptop = try Product()
            .inserting(key: "name", value: "Laptop Pro")
            .inserting(key: "price", value: "999")
            .inserting(key: "sku", value: "ELEC-001")
        let phone = try Product()
            .inserting(key: "name", value: "SmartPhone X")
            .inserting(key: "price", value: "699")
            .inserting(key: "sku", value: "ELEC-002")
        let novel = try Product()
            .inserting(key: "name", value: "The Great Novel")
            .inserting(key: "price", value: "15")
            .inserting(key: "sku", value: "BOOK-001")
        let textbook = try Product()
            .inserting(key: "name", value: "Algorithms 101")
            .inserting(key: "price", value: "85")
            .inserting(key: "sku", value: "BOOK-002")

        let electronics = try Category()
            .inserting(key: "laptop", value: try HeaderImpl(node: laptop))
            .inserting(key: "phone", value: try HeaderImpl(node: phone))
        let books = try Category()
            .inserting(key: "novel", value: try HeaderImpl(node: novel))
            .inserting(key: "textbook", value: try HeaderImpl(node: textbook))

        let catalog = try Catalog()
            .inserting(key: "electronics", value: try HeaderImpl(node: electronics))
            .inserting(key: "books", value: try HeaderImpl(node: books))

        return (catalog, try HeaderImpl(node: catalog))
    }

    @Test("List resolution enumerates keys but values remain CID-only")
    func testListResolution() async throws {
        let (_, catalogHeader) = try buildCatalog()
        let fetcher = TestStoreFetcher()
        try await catalogHeader.storeAsVolume(storer: fetcher)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set([""], value: .list)
        let resolved = try await HeaderImpl<Catalog>(rawCID: catalogHeader.rawCID)
            .resolve(paths: paths, fetcher: fetcher)

        let keys = try resolved.node!.allKeys()
        #expect(keys.contains("electronics"))
        #expect(keys.contains("books"))

        let electronicsHeader = try resolved.node!.get(key: "electronics")!
        #expect(electronicsHeader.node == nil)
    }

    @Test("Targeted resolution loads only the specified category")
    func testTargetedResolution() async throws {
        let (_, catalogHeader) = try buildCatalog()
        let fetcher = TestStoreFetcher()
        try await catalogHeader.storeAsVolume(storer: fetcher)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["electronics"], value: .targeted)
        let resolved = try await HeaderImpl<Catalog>(rawCID: catalogHeader.rawCID)
            .resolve(paths: paths, fetcher: fetcher)

        let electronicsHeader = try resolved.node!.get(key: "electronics")!
        #expect(electronicsHeader.node != nil)

        let booksRawHeader = resolved.node!.children[Character("b")]
        #expect(booksRawHeader?.node == nil)
    }

    @Test("Recursive resolution loads entire subtree")
    func testRecursiveResolution() async throws {
        let (_, catalogHeader) = try buildCatalog()
        let fetcher = TestStoreFetcher()
        try await catalogHeader.storeAsVolume(storer: fetcher)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["electronics"], value: .recursive)
        let resolved = try await HeaderImpl<Catalog>(rawCID: catalogHeader.rawCID)
            .resolve(paths: paths, fetcher: fetcher)

        let electronicsHeader = try resolved.node!.get(key: "electronics")!
        #expect(electronicsHeader.node != nil)

        let laptopHeader = try electronicsHeader.node!.get(key: "laptop")!
        #expect(laptopHeader.node != nil)
        #expect(try laptopHeader.node!.get(key: "name") == "Laptop Pro")
        #expect(try laptopHeader.node!.get(key: "price") == "999")

        let phoneHeader = try electronicsHeader.node!.get(key: "phone")!
        #expect(phoneHeader.node != nil)
        #expect(try phoneHeader.node!.get(key: "name") == "SmartPhone X")

        let booksRawHeader = resolved.node!.children[Character("b")]
        #expect(booksRawHeader?.node == nil)
    }

    @Test("Incremental resolution: list first, then targeted drill-down")
    func testIncrementalResolution() async throws {
        let (_, catalogHeader) = try buildCatalog()
        let fetcher = TestStoreFetcher()
        try await catalogHeader.storeAsVolume(storer: fetcher)

        var listPaths = ArrayTrie<ResolutionStrategy>()
        listPaths.set([""], value: .list)
        let listed = try await HeaderImpl<Catalog>(rawCID: catalogHeader.rawCID)
            .resolve(paths: listPaths, fetcher: fetcher)

        let keys = try listed.node!.allKeys()
        #expect(keys.contains("books"))
        let booksHeader = try listed.node!.get(key: "books")!
        #expect(booksHeader.node == nil)

        let booksResolved = try await booksHeader.resolveRecursive(fetcher: fetcher)
        let novelResolved = try booksResolved.node!.get(key: "novel")!
        #expect(novelResolved.node != nil)
        #expect(try novelResolved.node!.get(key: "name") == "The Great Novel")
    }
}

// MARK: - Event Log with MerkleArray

@Suite("Real-World: Append-Only Event Log")
struct EventLogTests {

    typealias EventLog = MerkleArrayImpl<String>

    private func buildLog(count: Int) throws -> EventLog {
        var log = EventLog()
        for i in 0..<count {
            log = try log.append("event_\(i):ts=\(1000 + i)")
        }
        return log
    }

    @Test("Event log lifecycle: append, query, version")
    func testEventLogLifecycle() throws {
        var log = EventLog()
        log = try log.append("user.signup:id=1")
        log = try log.append("user.login:id=1")
        log = try log.append("order.created:id=100")
        log = try log.append("order.paid:id=100")
        #expect(log.count == 4)

        #expect(try log.first() == "user.signup:id=1")
        #expect(try log.last() == "order.paid:id=100")
        #expect(try log.get(at: 2) == "order.created:id=100")

        let v1 = try HeaderImpl(node: log)

        log = try log.append("user.login:id=1")
        log = try log.append("order.shipped:id=100")
        let v2 = try HeaderImpl(node: log)

        #expect(v1.rawCID != v2.rawCID)
        #expect(log.count == 6)
    }

    @Test("Versioned log: rollback to historical snapshot via CID")
    func testLogRollback() async throws {
        let v1 = try buildLog(count: 10)
        let v1Header = try HeaderImpl(node: v1)

        let v2 = try v1.append("event_10:ts=1010").append("event_11:ts=1011")
        let v2Header = try HeaderImpl(node: v2)

        let fetcher = TestStoreFetcher()
        try await v1Header.storeAsVolume(storer: fetcher)
        try await v2Header.storeAsVolume(storer: fetcher)

        let resolvedV1 = try await HeaderImpl<EventLog>(rawCID: v1Header.rawCID)
            .resolveRecursive(fetcher: fetcher)
        #expect(resolvedV1.node!.count == 10)
        #expect(try resolvedV1.node!.last() == "event_9:ts=1009")

        let resolvedV2 = try await HeaderImpl<EventLog>(rawCID: v2Header.rawCID)
            .resolveRecursive(fetcher: fetcher)
        #expect(resolvedV2.node!.count == 12)
        #expect(try resolvedV2.node!.last() == "event_11:ts=1011")
    }

    @Test("Range query: paginate event log without loading all events")
    func testLogPagination() async throws {
        let log = try buildLog(count: 100)
        let header = try HeaderImpl(node: log)
        let fetcher = CountingStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<EventLog>(rawCID: header.rawCID)
            .resolve(fetcher: fetcher)

        fetcher.resetFetchCount()
        let page1 = try await resolved.node!.resolve(paths: EventLog.rangePaths(0..<10), fetcher: fetcher)
        let page1Fetches = fetcher.fetchCount

        fetcher.resetFetchCount()
        let page5 = try await resolved.node!.resolve(paths: EventLog.rangePaths(40..<50), fetcher: fetcher)
        let page5Fetches = fetcher.fetchCount

        fetcher.resetFetchCount()
        _ = try await resolved.node!.resolveRecursive(fetcher: fetcher)
        let fullFetches = fetcher.fetchCount

        for i in 0..<10 {
            #expect(try page1.get(at: i) == "event_\(i):ts=\(1000 + i)")
        }
        for i in 40..<50 {
            #expect(try page5.get(at: i) == "event_\(i):ts=\(1000 + i)")
        }

        #expect(page1Fetches < fullFetches / 2)
        #expect(page5Fetches < fullFetches / 2)
    }

    @Test("Structural sharing: appending preserves CID of unchanged elements")
    func testLogStructuralSharing() throws {
        let log10 = try buildLog(count: 10)
        let log11 = try log10.append("event_10:ts=1010")

        let h10 = try HeaderImpl(node: log10)
        let h11 = try HeaderImpl(node: log11)
        #expect(h10.rawCID != h11.rawCID)

        #expect(try log10.get(at: 0) == log11.get(at: 0))
        #expect(try log10.get(at: 5) == log11.get(at: 5))
        #expect(try log10.get(at: 9) == log11.get(at: 9))
        #expect(log11.count == 11)
    }

    @Test("Store and resolve log from CID-only reference")
    func testLogStoreAndResolve() async throws {
        let log = try buildLog(count: 25)
        let header = try HeaderImpl(node: log)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<EventLog>(rawCID: header.rawCID)
            .resolveRecursive(fetcher: fetcher)

        #expect(resolved.rawCID == header.rawCID)
        #expect(resolved.node!.count == 25)
        #expect(try resolved.node!.first() == "event_0:ts=1000")
        #expect(try resolved.node!.last() == "event_24:ts=1024")
    }
}

// MARK: - Time-Series with Nested MerkleArrays

@Suite("Real-World: Time-Series Sensor Data")
struct TimeSeriesTests {

    typealias Reading = MerkleArrayImpl<String>
    typealias SensorLog = MerkleArrayImpl<HeaderImpl<Reading>>

    @Test("Multi-sensor time-series: build, store, range query per sensor")
    func testMultiSensorTimeSeries() async throws {
        var sensorLog = SensorLog()
        let fetcher = CountingStoreFetcher()

        for sensor in 0..<5 {
            var readings = Reading()
            for t in 0..<20 {
                readings = try readings.append("s\(sensor)_t\(t)_val=\(sensor * 100 + t)")
            }
            let readingsHeader = try HeaderImpl(node: readings)
            try await readingsHeader.storeAsVolume(storer: fetcher)
            sensorLog = try sensorLog.append(readingsHeader)
        }
        let header = try HeaderImpl(node: sensorLog)
        try await header.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<SensorLog>(rawCID: header.rawCID)
            .resolve(fetcher: fetcher)

        fetcher.resetFetchCount()
        let partial = try await resolved.node!.resolve(
            paths: SensorLog.rangePaths(1..<3, innerRange: 5..<10), fetcher: fetcher
        )
        let partialFetches = fetcher.fetchCount

        let sensor1 = try partial.get(at: 1)!
        #expect(try sensor1.node!.get(at: 5) == "s1_t5_val=105")
        #expect(try sensor1.node!.get(at: 9) == "s1_t9_val=109")

        let sensor2 = try partial.get(at: 2)!
        #expect(try sensor2.node!.get(at: 5) == "s2_t5_val=205")

        fetcher.resetFetchCount()
        _ = try await resolved.node!.resolveRecursive(fetcher: fetcher)
        let fullFetches = fetcher.fetchCount

        #expect(partialFetches < fullFetches)
    }

    @Test("Nested range transforms: update readings across sensors")
    func testNestedRangeTransform() throws {
        var sensorLog = SensorLog()
        for sensor in 0..<3 {
            var readings = Reading()
            for t in 0..<5 {
                readings = try readings.append("s\(sensor)_t\(t)")
            }
            sensorLog = try sensorLog.append(try HeaderImpl(node: readings))
        }

        let innerTransforms: [[String]: Transform] = [
            [Reading.binaryKey(2)]: .update("CALIBRATED")
        ]
        let result = try sensorLog.transformNested(
            outerRange: 0..<3, innerTransforms: innerTransforms
        )!

        for sensor in 0..<3 {
            let sensorData = try result.get(at: sensor)!
            #expect(try sensorData.node!.get(at: 2) == "CALIBRATED")
            #expect(try sensorData.node!.get(at: 0) == "s\(sensor)_t0")
            #expect(try sensorData.node!.get(at: 4) == "s\(sensor)_t4")
        }
    }

    @Test("Append new readings to one sensor, others share structure")
    func testAppendToOneSensor() throws {
        var readings0 = try Reading().append("r0_0").append("r0_1")
        var readings1 = try Reading().append("r1_0").append("r1_1")
        let h0 = try HeaderImpl(node: readings0)
        let h1 = try HeaderImpl(node: readings1)

        let v1 = try SensorLog().append(h0).append(h1)
        let v1Header = try HeaderImpl(node: v1)

        readings0 = try readings0.append("r0_2")
        let newH0 = try HeaderImpl(node: readings0)
        let v2 = try v1.mutating(at: 0, value: newH0)
        let v2Header = try HeaderImpl(node: v2)

        #expect(v1Header.rawCID != v2Header.rawCID)

        let sensor1v1 = try v1.get(at: 1)!
        let sensor1v2 = try v2.get(at: 1)!
        #expect(sensor1v1.rawCID == sensor1v2.rawCID)
    }
}

// MARK: - Chat History with MerkleArray

@Suite("Real-World: Chat Message History")
struct ChatHistoryTests {

    typealias MessageLog = MerkleArrayImpl<String>
    typealias ChannelStore = MerkleDictionaryImpl<HeaderImpl<MessageLog>>

    @Test("Multi-channel chat: append messages, query by channel, range pagination")
    func testMultiChannelChat() async throws {
        var general = MessageLog()
        general = try general.append("alice: hello everyone")
        general = try general.append("bob: hi alice")
        general = try general.append("charlie: hey!")
        general = try general.append("alice: how's the project?")
        general = try general.append("bob: going well")

        var random = MessageLog()
        random = try random.append("dave: anyone for lunch?")
        random = try random.append("eve: sure!")

        let store = try ChannelStore()
            .inserting(key: "general", value: try HeaderImpl(node: general))
            .inserting(key: "random", value: try HeaderImpl(node: random))

        let header = try HeaderImpl(node: store)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<ChannelStore>(rawCID: header.rawCID)
            .resolveRecursive(fetcher: fetcher)

        let generalResolved = try resolved.node!.get(key: "general")!
        #expect(generalResolved.node!.count == 5)
        #expect(try generalResolved.node!.first() == "alice: hello everyone")
        #expect(try generalResolved.node!.last() == "bob: going well")

        let randomResolved = try resolved.node!.get(key: "random")!
        #expect(randomResolved.node!.count == 2)
    }

    @Test("Chat pagination: load only last N messages from a channel")
    func testChatPagination() async throws {
        var messages = MessageLog()
        for i in 0..<50 {
            messages = try messages.append("msg_\(i)")
        }

        let header = try HeaderImpl(node: messages)
        let fetcher = CountingStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<MessageLog>(rawCID: header.rawCID)
            .resolve(fetcher: fetcher)

        fetcher.resetFetchCount()
        let lastPage = try await resolved.node!.resolve(paths: MessageLog.rangePaths(40..<50), fetcher: fetcher)
        let pageFetches = fetcher.fetchCount

        for i in 40..<50 {
            #expect(try lastPage.get(at: i) == "msg_\(i)")
        }

        fetcher.resetFetchCount()
        _ = try await resolved.node!.resolveRecursive(fetcher: fetcher)
        let fullFetches = fetcher.fetchCount

        #expect(pageFetches < fullFetches / 2)
    }

    @Test("Versioned chat: each message append produces new root CID")
    func testVersionedChat() throws {
        let v0 = MessageLog()
        let v1 = try v0.append("first message")
        let v2 = try v1.append("second message")
        let v3 = try v2.append("third message")

        let h0 = try HeaderImpl(node: v0)
        let h1 = try HeaderImpl(node: v1)
        let h2 = try HeaderImpl(node: v2)
        let h3 = try HeaderImpl(node: v3)

        let cids = [h0.rawCID, h1.rawCID, h2.rawCID, h3.rawCID]
        #expect(Set(cids).count == 4)
    }
}

// MARK: - Audit Trail with Merkle Proofs

@Suite("Real-World: Audit Trail with Merkle Proofs")
struct AuditTrailTests {

    typealias Ledger = MerkleDictionaryImpl<String>

    private func buildLedger(count: Int) throws -> Ledger {
        var ledger = Ledger()
        for i in 1...count {
            let txID = String(format: "tx%03d", i)
            ledger = try ledger.inserting(key: txID, value: "\(i * 100)")
        }
        return ledger
    }

    @Test("Existence proof for a specific transaction is minimal")
    func testExistenceProofIsMinimal() async throws {
        var ledger = Ledger()
        ledger = try ledger.inserting(key: "alpha_tx", value: "100")
        ledger = try ledger.inserting(key: "beta_tx", value: "200")
        ledger = try ledger.inserting(key: "gamma_tx", value: "300")
        ledger = try ledger.inserting(key: "delta_tx", value: "400")
        let header = try HeaderImpl(node: ledger)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let cidOnly = HeaderImpl<Ledger>(rawCID: header.rawCID)
        var proofPaths = ArrayTrie<SparseMerkleProof>()
        proofPaths.set(["alpha_tx"], value: .existence)
        let proof = try await cidOnly.proof(paths: proofPaths, fetcher: fetcher)

        #expect(proof.rawCID == header.rawCID)

        let proofNode = proof.node!
        let alphaVal = try proofNode.get(key: "alpha_tx")
        #expect(alphaVal == "100")

        let aHeader = proofNode.children[Character("a")]
        #expect(aHeader?.node != nil)
        let bHeader = proofNode.children[Character("b")]
        #expect(bHeader?.node == nil)
        let gHeader = proofNode.children[Character("g")]
        #expect(gHeader?.node == nil)
    }

    @Test("Insertion proof confirms key does not yet exist")
    func testInsertionProof() async throws {
        let ledger = try buildLedger(count: 5)
        let header = try HeaderImpl(node: ledger)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        var proofPaths = ArrayTrie<SparseMerkleProof>()
        proofPaths.set(["tx999"], value: .insertion)
        let proof = try await header.proof(paths: proofPaths, fetcher: fetcher)
        #expect(proof.rawCID == header.rawCID)
    }

    @Test("Historical audit: prove transaction existed in an older version")
    func testHistoricalVersionProof() async throws {
        let v1 = try buildLedger(count: 10)
        let v1Header = try HeaderImpl(node: v1)
        let fetcher = TestStoreFetcher()
        try await v1Header.storeAsVolume(storer: fetcher)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["tx011"], value: .insert("1100"))
        transforms.set(["tx012"], value: .insert("1200"))
        let v2 = try v1.transform(transforms: transforms)!
        let v2Header = try HeaderImpl(node: v2)
        try await v2Header.storeAsVolume(storer: fetcher)

        #expect(v1Header.rawCID != v2Header.rawCID)

        let resolvedV1 = try await HeaderImpl<Ledger>(rawCID: v1Header.rawCID)
            .resolveRecursive(fetcher: fetcher)

        var proofPaths = ArrayTrie<SparseMerkleProof>()
        proofPaths.set(["tx005"], value: .existence)
        let proof = try await resolvedV1.proof(paths: proofPaths, fetcher: fetcher)
        #expect(proof.rawCID == v1Header.rawCID)
        #expect(try proof.node!.get(key: "tx005") == "500")
    }

    @Test("Deletion proof for removing a transaction")
    func testDeletionProof() async throws {
        let ledger = try buildLedger(count: 5)
        let header = try HeaderImpl(node: ledger)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        var proofPaths = ArrayTrie<SparseMerkleProof>()
        proofPaths.set(["tx003"], value: .deletion)
        let proof = try await header.proof(paths: proofPaths, fetcher: fetcher)

        #expect(proof.rawCID == header.rawCID)
        #expect(try proof.node!.get(key: "tx003") == "300")
    }

    @Test("Proof preserves root CID integrity")
    func testProofPreservesRootCID() async throws {
        let ledger = try buildLedger(count: 20)
        let header = try HeaderImpl(node: ledger)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        var proofPaths = ArrayTrie<SparseMerkleProof>()
        proofPaths.set(["tx010"], value: .existence)
        proofPaths.set(["tx015"], value: .mutation)
        let proof = try await header.proof(paths: proofPaths, fetcher: fetcher)

        #expect(proof.rawCID == header.rawCID)
        #expect(try proof.node!.get(key: "tx010") == "1000")
        #expect(try proof.node!.get(key: "tx015") == "1500")
    }
}

// MARK: - Token Ledger with Auditable Transfers

@Suite("Real-World: Token Ledger")
struct TokenLedgerQueryTests {

    typealias Balances = MerkleDictionaryImpl<String>
    typealias TransferLog = MerkleArrayImpl<String>
    typealias Ledger = MerkleDictionaryImpl<HeaderImpl<Balances>>

    @Test("Mint tokens, transfer between accounts, verify balances via queries")
    func testMintAndTransfer() throws {
        var balances = Balances()
        let (b1, _) = try balances.query(#"insert "treasury" = "1000000""#)
        balances = b1

        let (_, treasuryBal) = try balances.query(#"get "treasury""#)
        #expect(treasuryBal == .value("1000000"))

        let (b2, _) = try balances.query(#"insert "alice" = "0" | insert "bob" = "0""#)
        balances = b2

        let treasuryAmount = Int(try balances.get(key: "treasury")!)!
        let transferAmount = 5000
        let (b3, _) = try balances.query(
            #"update "treasury" = "\#(treasuryAmount - transferAmount)" | update "alice" = "\#(transferAmount)""#
        )
        balances = b3

        let (_, aliceBal) = try balances.query(#"get "alice""#)
        #expect(aliceBal == .value("5000"))
        let (_, newTreasury) = try balances.query(#"get "treasury""#)
        #expect(newTreasury == .value("995000"))
    }

    @Test("Full ledger lifecycle: mint, transfer, audit trail, rollback via CID")
    func testLedgerWithAuditTrail() async throws {
        let store = TestStoreFetcher()

        var balances = try Balances()
            .inserting(key: "alice", value: "100")
            .inserting(key: "bob", value: "50")
            .inserting(key: "carol", value: "200")

        let v1 = try HeaderImpl(node: balances)
        try await v1.storeAsVolume(storer: store)

        let (b2, _) = try balances.query(
            #"update "alice" = "70" | update "bob" = "80""#
        )
        balances = b2
        let v2 = try HeaderImpl(node: balances)
        try await v2.storeAsVolume(storer: store)

        let (b3, _) = try balances.query(
            #"update "bob" = "30" | update "carol" = "250""#
        )
        let v3 = try HeaderImpl(node: b3)
        try await v3.storeAsVolume(storer: store)

        #expect(v1.rawCID != v2.rawCID)
        #expect(v2.rawCID != v3.rawCID)

        let rolledBack = try await HeaderImpl<Balances>(rawCID: v1.rawCID)
            .query(#"get "alice""#, fetcher: store)
        #expect(rolledBack.1 == .value("100"))

        let current = try await HeaderImpl<Balances>(rawCID: v3.rawCID)
            .query("keys sorted", fetcher: store)
        #expect(current.1 == .list(["alice", "bob", "carol"]))

        let (_, carolBal) = try await HeaderImpl<Balances>(rawCID: v3.rawCID)
            .query(#"get "carol""#, fetcher: store)
        #expect(carolBal == .value("250"))
    }

    @Test("Paginated account listing with sorted keys query")
    func testPaginatedAccountListing() throws {
        var balances = Balances()
        for i in 0..<50 {
            let name = String(format: "user_%03d", i)
            balances = try balances.inserting(key: name, value: "\(1000 + i)")
        }

        let (_, page1) = try balances.query(#"keys sorted limit 10"#)
        guard case .list(let p1Keys) = page1 else { Issue.record("Expected list"); return }
        #expect(p1Keys.count == 10)
        #expect(p1Keys.first == "user_000")

        let (_, page2) = try balances.query(#"keys sorted limit 10 after "\#(p1Keys.last!)""#)
        guard case .list(let p2Keys) = page2 else { Issue.record("Expected list"); return }
        #expect(p2Keys.count == 10)
        #expect(p2Keys.first! > p1Keys.last!)
    }
}

// MARK: - Access Control with MerkleSet

@Suite("Real-World: Role-Based Access Control")
struct AccessControlQueryTests {

    typealias Permissions = MerkleSetImpl
    typealias RoleStore = MerkleDictionaryImpl<HeaderImpl<Permissions>>

    @Test("Grant and revoke permissions via queries, verify access")
    func testGrantRevokePermissions() throws {
        let adminPerms = try Permissions()
            .insert("read").insert("write").insert("delete").insert("admin")

        let (_, adminKeys) = try adminPerms.query("keys sorted")
        #expect(adminKeys == .list(["admin", "delete", "read", "write"]))

        let (revoked, _) = try adminPerms.query(#"delete "admin""#)
        let (_, afterRevoke) = try revoked.query(#"contains "admin""#)
        #expect(afterRevoke == .bool(false))
        let (_, stillHasWrite) = try revoked.query(#"contains "write""#)
        #expect(stillHasWrite == .bool(true))
    }

    @Test("Multi-role system: check permissions across roles via headers")
    func testMultiRolePermissionCheck() throws {
        let viewer = try Permissions().insert("read")
        let editor = try Permissions().insert("read").insert("write")
        let admin = try Permissions()
            .insert("read").insert("write").insert("delete").insert("manage_users")

        let roles = try RoleStore()
            .inserting(key: "viewer", value: try HeaderImpl(node: viewer))
            .inserting(key: "editor", value: try HeaderImpl(node: editor))
            .inserting(key: "admin", value: try HeaderImpl(node: admin))

        let (_, roleList) = try roles.query("keys sorted")
        #expect(roleList == .list(["admin", "editor", "viewer"]))

        let editorHeader = try roles.get(key: "editor")!
        let (_, canWrite) = try editorHeader.query(#"contains "write""#)
        #expect(canWrite == .bool(true))
        let (_, canDelete) = try editorHeader.query(#"contains "delete""#)
        #expect(canDelete == .bool(false))

        let adminHeader = try roles.get(key: "admin")!
        let (_, adminCount) = try adminHeader.query("count")
        #expect(adminCount == .count(4))
    }

    @Test("Permission change audit: each mutation produces unique CID")
    func testPermissionAuditTrail() async throws {
        let store = TestStoreFetcher()

        let v1 = try Permissions().insert("read")
        let h1 = try HeaderImpl(node: v1)
        try await h1.storeAsVolume(storer: store)

        let (v2, _) = try v1.query(#"insert "write" = """#)
        let h2 = try HeaderImpl(node: v2)
        try await h2.storeAsVolume(storer: store)

        let (v3, _) = try v2.query(#"delete "read""#)
        let h3 = try HeaderImpl(node: v3)
        try await h3.storeAsVolume(storer: store)

        #expect(Set([h1.rawCID, h2.rawCID, h3.rawCID]).count == 3)

        let (_, v1Members) = try await HeaderImpl<Permissions>(rawCID: h1.rawCID)
            .query("keys sorted", fetcher: store)
        #expect(v1Members == .list(["read"]))

        let (_, v3Members) = try await HeaderImpl<Permissions>(rawCID: h3.rawCID)
            .query("keys sorted", fetcher: store)
        #expect(v3Members == .list(["write"]))
    }

    @Test("Store role hierarchy, resolve from CID, query nested permissions")
    func testStoreResolveRoleHierarchy() async throws {
        let store = TestStoreFetcher()

        let basic = try Permissions().insert("view_dashboard")
        let support = try Permissions()
            .insert("view_dashboard").insert("view_tickets").insert("reply_tickets")
        let engineering = try Permissions()
            .insert("view_dashboard").insert("deploy").insert("view_logs").insert("ssh_access")

        let roles = try RoleStore()
            .inserting(key: "basic", value: try HeaderImpl(node: basic))
            .inserting(key: "support", value: try HeaderImpl(node: support))
            .inserting(key: "engineering", value: try HeaderImpl(node: engineering))

        let header = try HeaderImpl(node: roles)
        try await header.storeAsVolume(storer: store)

        let resolved = try await HeaderImpl<RoleStore>(rawCID: header.rawCID)
            .resolveRecursive(fetcher: store)

        let (_, roleCount) = try resolved.query("count")
        #expect(roleCount == .count(3))

        let engHeader = try resolved.node!.get(key: "engineering")!
        let (_, hasDeploy) = try engHeader.query(#"contains "deploy""#)
        #expect(hasDeploy == .bool(true))
        let (_, engPerms) = try engHeader.query("keys sorted")
        #expect(engPerms == .list(["deploy", "ssh_access", "view_dashboard", "view_logs"]))
    }
}

// MARK: - Package Registry

@Suite("Real-World: Package Registry")
struct PackageRegistryQueryTests {

    typealias PackageMeta = MerkleDictionaryImpl<String>
    typealias VersionLog = MerkleArrayImpl<String>
    typealias Registry = MerkleDictionaryImpl<VolumeImpl<PackageMeta>>

    @Test("Publish packages, query registry, update metadata via queries")
    func testPublishAndQuery() throws {
        let cashew = try PackageMeta()
            .inserting(key: "name", value: "cashew")
            .inserting(key: "version", value: "1.0.0")
            .inserting(key: "license", value: "MIT")
            .inserting(key: "downloads", value: "0")

        let arraytrie = try PackageMeta()
            .inserting(key: "name", value: "arraytrie")
            .inserting(key: "version", value: "2.1.0")
            .inserting(key: "license", value: "Apache-2.0")
            .inserting(key: "downloads", value: "1500")

        var registry = try Registry()
            .inserting(key: "cashew", value: try VolumeImpl(node: cashew))
            .inserting(key: "arraytrie", value: try VolumeImpl(node: arraytrie))

        let (_, packages) = try registry.query("keys sorted")
        #expect(packages == .list(["arraytrie", "cashew"]))
        let (_, count) = try registry.query("count")
        #expect(count == .count(2))

        let cashewHeader = try registry.get(key: "cashew")!
        let (updatedPkg, _) = try cashewHeader.query(
            #"update "version" = "1.1.0" | update "downloads" = "42""#
        )
        registry = try registry.mutating(key: "cashew", value: updatedPkg)

        let newCashewHeader = try registry.get(key: "cashew")!
        let (_, newVersion) = try newCashewHeader.query(#"get "version""#)
        #expect(newVersion == .value("1.1.0"))
        let (_, newDownloads) = try newCashewHeader.query(#"get "downloads""#)
        #expect(newDownloads == .value("42"))
    }

    @Test("Version history: append releases, paginate, verify integrity across store/resolve")
    func testVersionHistory() async throws {
        let store = TestStoreFetcher()
        var versions = VersionLog()
        let releases = ["0.1.0", "0.2.0", "0.3.0", "1.0.0", "1.0.1", "1.1.0", "2.0.0-beta"]
        for release in releases {
            versions = try versions.append(release)
        }

        let header = try HeaderImpl(node: versions)
        try await header.storeAsVolume(storer: store)

        let resolved = try await HeaderImpl<VersionLog>(rawCID: header.rawCID)
            .query("count", fetcher: store)
        #expect(resolved.1 == .count(7))

        let (_, first) = try await HeaderImpl<VersionLog>(rawCID: header.rawCID)
            .query("first", fetcher: store)
        #expect(first == .value("0.1.0"))

        let (_, last) = try await HeaderImpl<VersionLog>(rawCID: header.rawCID)
            .query("last", fetcher: store)
        #expect(last == .value("2.0.0-beta"))

        let (appended, _) = try await HeaderImpl<VersionLog>(rawCID: header.rawCID)
            .query(#"append "2.0.0""#, fetcher: store)
        #expect(appended.node!.count == 8)
        let (_, newLast) = try appended.query("last")
        #expect(newLast == .value("2.0.0"))

        #expect(appended.rawCID != header.rawCID)
    }

    @Test("Registry with store/resolve: search and update remote packages")
    func testRegistryStoreResolve() async throws {
        let store = TestStoreFetcher()

        let pkgA = try PackageMeta()
            .inserting(key: "name", value: "swift-nio")
            .inserting(key: "version", value: "2.0.0")
            .inserting(key: "author", value: "apple")
        let pkgB = try PackageMeta()
            .inserting(key: "name", value: "vapor")
            .inserting(key: "version", value: "4.0.0")
            .inserting(key: "author", value: "vapor")
        let pkgC = try PackageMeta()
            .inserting(key: "name", value: "perfect")
            .inserting(key: "version", value: "3.0.0")
            .inserting(key: "author", value: "perfect")

        let pkgAVolume = try VolumeImpl(node: pkgA)
        let pkgBVolume = try VolumeImpl(node: pkgB)
        let pkgCVolume = try VolumeImpl(node: pkgC)
        let registry = try Registry()
            .inserting(key: "swift-nio", value: pkgAVolume)
            .inserting(key: "vapor", value: pkgBVolume)
            .inserting(key: "perfect", value: pkgCVolume)

        try await pkgAVolume.store(storer: store)
        try await pkgBVolume.store(storer: store)
        try await pkgCVolume.store(storer: store)

        let regHeader = try HeaderImpl(node: registry)
        try await regHeader.storeAsVolume(storer: store)

        let resolved = try await HeaderImpl<Registry>(rawCID: regHeader.rawCID)
            .resolveRecursive(fetcher: store)
        let (_, hasPkg) = try resolved.query(#"contains "vapor""#)
        #expect(hasPkg == .bool(true))

        let vaporHeader = try resolved.node!.get(key: "vapor")!
        let (updatedVapor, _) = try await vaporHeader
            .query(#"update "version" = "4.1.0""#, fetcher: store)
        try await updatedVapor.store(storer: store)

        let updatedRegistry = try resolved.node!.mutating(key: "vapor", value: updatedVapor)
        let newRegHeader = try HeaderImpl(node: updatedRegistry)
        try await newRegHeader.storeAsVolume(storer: store)

        let (_, vaporVersion) = try await HeaderImpl<Registry>(rawCID: newRegHeader.rawCID)
            .resolveRecursive(fetcher: store).node!
            .get(key: "vapor")!.query(#"get "version""#)
        #expect(vaporVersion == .value("4.1.0"))

        let nioHeader = try await HeaderImpl<Registry>(rawCID: newRegHeader.rawCID)
            .resolveRecursive(fetcher: store).node!
            .get(key: "swift-nio")!
        let origNioHeader = try registry.get(key: "swift-nio")!
        #expect(nioHeader.rawCID == origNioHeader.rawCID)
    }
}

// MARK: - Supply Chain Tracking

@Suite("Real-World: Supply Chain Tracking")
struct SupplyChainQueryTests {

    typealias EventLog = MerkleArrayImpl<String>
    typealias ProductTracker = MerkleDictionaryImpl<HeaderImpl<EventLog>>

    @Test("Track products through supply chain stages via queries")
    func testProductTracking() throws {
        let appleLog = try EventLog()
            .append("2024-01-15:harvested:farm_a")
            .append("2024-01-16:inspected:qa_station_1")
            .append("2024-01-17:shipped:truck_42")

        let orangeLog = try EventLog()
            .append("2024-01-10:harvested:farm_b")
            .append("2024-01-12:inspected:qa_station_2")

        var tracker = try ProductTracker()
            .inserting(key: "apple_batch_001", value: try HeaderImpl(node: appleLog))
            .inserting(key: "orange_batch_001", value: try HeaderImpl(node: orangeLog))

        let (_, products) = try tracker.query("keys sorted")
        #expect(products == .list(["apple_batch_001", "orange_batch_001"]))

        let appleHeader = try tracker.get(key: "apple_batch_001")!
        let (_, appleCount) = try appleHeader.query("count")
        #expect(appleCount == .count(3))
        let (_, firstEvent) = try appleHeader.query("first")
        #expect(firstEvent == .value("2024-01-15:harvested:farm_a"))
        let (_, lastEvent) = try appleHeader.query("last")
        #expect(lastEvent == .value("2024-01-17:shipped:truck_42"))

        let (updatedApple, _) = try appleHeader.query(#"append "2024-01-18:delivered:warehouse_7""#)
        tracker = try tracker.mutating(key: "apple_batch_001", value: updatedApple)

        let newAppleHeader = try tracker.get(key: "apple_batch_001")!
        let (_, newCount) = try newAppleHeader.query("count")
        #expect(newCount == .count(4))
        let (_, delivered) = try newAppleHeader.query("last")
        #expect(delivered == .value("2024-01-18:delivered:warehouse_7"))
    }

    @Test("Supply chain audit: store, resolve, verify full history from CID")
    func testSupplyChainAudit() async throws {
        let store = TestStoreFetcher()

        let widget = try EventLog()
            .append("manufactured:factory_cn")
            .append("quality_check:pass")
            .append("shipped:port_shanghai")
            .append("customs:cleared")
            .append("received:warehouse_la")
            .append("dispatched:truck_99")
            .append("delivered:store_42")

        let gadget = try EventLog()
            .append("manufactured:factory_de")
            .append("quality_check:pass")
            .append("shipped:rail_frankfurt")

        let tracker = try ProductTracker()
            .inserting(key: "widget_x100", value: try HeaderImpl(node: widget))
            .inserting(key: "gadget_z50", value: try HeaderImpl(node: gadget))

        let header = try HeaderImpl(node: tracker)
        try await header.storeAsVolume(storer: store)

        let (resolved, productCount) = try await HeaderImpl<ProductTracker>(rawCID: header.rawCID)
            .query("count", fetcher: store)
        #expect(productCount == .count(2))

        let widgetHeader = try resolved.node!.get(key: "widget_x100")!
        let (_, widgetSteps) = try await widgetHeader.query("count", fetcher: store)
        #expect(widgetSteps == .count(7))

        let (_, origin) = try await widgetHeader.query("first", fetcher: store)
        #expect(origin == .value("manufactured:factory_cn"))
        let (_, destination) = try await widgetHeader.query("last", fetcher: store)
        #expect(destination == .value("delivered:store_42"))

        let (_, step3) = try await widgetHeader.query("get at 2", fetcher: store)
        #expect(step3 == .value("shipped:port_shanghai"))
    }

    @Test("Tamper evidence: modifying a past event changes the product CID")
    func testTamperEvidence() throws {
        let log = try EventLog()
            .append("manufactured:factory_a")
            .append("inspected:pass")
            .append("shipped:truck_1")

        let original = try HeaderImpl(node: log)
        let tampered = try log.mutating(at: 1, value: "inspected:FORGED_PASS")
        let tamperedHeader = try HeaderImpl(node: tampered)

        #expect(original.rawCID != tamperedHeader.rawCID)

        let (_, originalInspection) = try original.query("get at 1")
        let (_, tamperedInspection) = try tamperedHeader.query("get at 1")
        #expect(originalInspection == .value("inspected:pass"))
        #expect(tamperedInspection == .value("inspected:FORGED_PASS"))
    }
}

// MARK: - Collaborative Document Versioning

@Suite("Real-World: Document Versioning")
struct DocumentVersioningQueryTests {

    typealias DocMeta = MerkleDictionaryImpl<String>
    typealias FileTree = MerkleDictionaryImpl<HeaderImpl<DocMeta>>

    @Test("Git-like workflow: create tree, commit, modify, diff via CIDs")
    func testGitLikeWorkflow() async throws {
        let store = TestStoreFetcher()

        let readme = try DocMeta()
            .inserting(key: "content", value: "# My Project")
            .inserting(key: "author", value: "alice")
        let config = try DocMeta()
            .inserting(key: "content", value: "debug=false")
            .inserting(key: "author", value: "bob")

        let tree = try FileTree()
            .inserting(key: "README.md", value: try HeaderImpl(node: readme))
            .inserting(key: "config.yml", value: try HeaderImpl(node: config))
        let commit1 = try HeaderImpl(node: tree)
        try await commit1.storeAsVolume(storer: store)

        let (resolved1, _) = try await commit1.query("keys sorted", fetcher: store)
        let readmeHeader = try resolved1.node!.get(key: "README.md")!
        let (updatedReadme, _) = try await readmeHeader.query(
            "update \"content\" = \"# My Project - With new description\"",
            fetcher: store
        )
        let tree2 = try resolved1.node!.mutating(key: "README.md", value: updatedReadme)
        let commit2 = try HeaderImpl(node: tree2)
        try await commit2.storeAsVolume(storer: store)

        let configCID1 = try tree.get(key: "config.yml")!.rawCID
        let configCID2 = try tree2.get(key: "config.yml")!.rawCID
        #expect(configCID1 == configCID2)

        let readmeCID1 = try tree.get(key: "README.md")!.rawCID
        let readmeCID2 = try tree2.get(key: "README.md")!.rawCID
        #expect(readmeCID1 != readmeCID2)

        #expect(commit1.rawCID != commit2.rawCID)

        let (_, resolvedContent) = try await HeaderImpl<FileTree>(rawCID: commit2.rawCID)
            .resolveRecursive(fetcher: store).node!
            .get(key: "README.md")!
            .query(#"get "content""#)
        #expect(resolvedContent == .value("# My Project - With new description"))
    }

    @Test("Branch and merge: two independent edits from same base")
    func testBranchAndMerge() throws {
        let base = try DocMeta()
            .inserting(key: "title", value: "Draft")
            .inserting(key: "body", value: "initial content")
            .inserting(key: "status", value: "draft")

        let tree = try FileTree()
            .inserting(key: "doc.md", value: try HeaderImpl(node: base))

        let docHeader = try tree.get(key: "doc.md")!
        let (branchA, _) = try docHeader.query(#"update "title" = "Final Title""#)
        let (branchB, _) = try docHeader.query(#"update "status" = "review""#)

        let treeA = try tree.mutating(key: "doc.md", value: branchA)
        let treeB = try tree.mutating(key: "doc.md", value: branchB)

        #expect(try HeaderImpl(node: treeA).rawCID != (try HeaderImpl(node: treeB).rawCID))

        let mergedDoc = try base
            .mutating(key: "title", value: "Final Title")
            .mutating(key: "status", value: "review")
        let mergedTree = try tree.mutating(key: "doc.md", value: try HeaderImpl(node: mergedDoc))

        let (_, mergedTitle) = try mergedTree.get(key: "doc.md")!.query(#"get "title""#)
        let (_, mergedStatus) = try mergedTree.get(key: "doc.md")!.query(#"get "status""#)
        let (_, mergedBody) = try mergedTree.get(key: "doc.md")!.query(#"get "body""#)
        #expect(mergedTitle == .value("Final Title"))
        #expect(mergedStatus == .value("review"))
        #expect(mergedBody == .value("initial content"))
    }

    @Test("File tree operations: add, rename (delete+insert), list sorted")
    func testFileTreeOperations() throws {
        var tree = try FileTree()
            .inserting(key: "src/main.swift", value: try HeaderImpl(node:
                try DocMeta().inserting(key: "content", value: "import Foundation")))
            .inserting(key: "src/utils.swift", value: try HeaderImpl(node:
                try DocMeta().inserting(key: "content", value: "func helper() {}")))
            .inserting(key: "tests/test.swift", value: try HeaderImpl(node:
                try DocMeta().inserting(key: "content", value: "import XCTest")))

        let (_, files) = try tree.query("keys sorted")
        #expect(files == .list(["src/main.swift", "src/utils.swift", "tests/test.swift"]))

        let utilsHeader = try tree.get(key: "src/utils.swift")!
        let (tree2, _) = try tree.query(#"delete "src/utils.swift""#)
        tree = try tree2.inserting(key: "src/helpers.swift", value: utilsHeader)

        let (_, renamedFiles) = try tree.query("keys sorted")
        #expect(renamedFiles == .list(["src/helpers.swift", "src/main.swift", "tests/test.swift"]))

        let helpersContent = try tree.get(key: "src/helpers.swift")!
        let (_, content) = try helpersContent.query(#"get "content""#)
        #expect(content == .value("func helper() {}"))
    }
}

// MARK: - Custom Node Types

struct NFTMetadata: Scalar {
    let name: String
    let rarity: String
    let creator: String
    let edition: Int
}

struct SensorReading: Scalar {
    let temperature: Double
    let humidity: Double
    let timestamp: Int
    let sensorId: String
}

struct BondInstrument: Scalar {
    let cusip: String
    let couponRate: Double
    let maturityYear: Int
    let faceValue: Int
    let issuer: String
}

// MARK: - NFT Marketplace with Custom Nodes

@Suite("Real-World: NFT Marketplace (Custom Nodes)")
struct NFTMarketplaceQueryTests {

    typealias Collection = MerkleDictionaryImpl<HeaderImpl<NFTMetadata>>
    typealias Marketplace = MerkleDictionaryImpl<HeaderImpl<Collection>>

    @Test("Mint NFTs into collections, query marketplace, verify content-addressed uniqueness")
    func testMintAndQueryMarketplace() throws {
        let punk1 = NFTMetadata(name: "Punk #1", rarity: "legendary", creator: "larvalabs", edition: 1)
        let punk2 = NFTMetadata(name: "Punk #2", rarity: "common", creator: "larvalabs", edition: 2)
        let punk3 = NFTMetadata(name: "Punk #3", rarity: "rare", creator: "larvalabs", edition: 3)

        let ape1 = NFTMetadata(name: "Ape #1", rarity: "epic", creator: "yuga", edition: 1)
        let ape2 = NFTMetadata(name: "Ape #2", rarity: "common", creator: "yuga", edition: 2)

        let punks = try Collection()
            .inserting(key: "punk_001", value: try HeaderImpl(node: punk1))
            .inserting(key: "punk_002", value: try HeaderImpl(node: punk2))
            .inserting(key: "punk_003", value: try HeaderImpl(node: punk3))

        let apes = try Collection()
            .inserting(key: "ape_001", value: try HeaderImpl(node: ape1))
            .inserting(key: "ape_002", value: try HeaderImpl(node: ape2))

        let marketplace = try Marketplace()
            .inserting(key: "cryptopunks", value: try HeaderImpl(node: punks))
            .inserting(key: "boredapes", value: try HeaderImpl(node: apes))

        let (_, collections) = try marketplace.query("keys sorted")
        #expect(collections == .list(["boredapes", "cryptopunks"]))

        let (_, marketCount) = try marketplace.query("count")
        #expect(marketCount == .count(2))

        let (_, hasPunks) = try marketplace.query(#"contains "cryptopunks""#)
        #expect(hasPunks == .bool(true))

        let punkCollection = try marketplace.get(key: "cryptopunks")!
        let (_, punkCount) = try punkCollection.query("count")
        #expect(punkCount == .count(3))

        let (_, punkIds) = try punkCollection.query("keys sorted")
        #expect(punkIds == .list(["punk_001", "punk_002", "punk_003"]))

        let punk1Header = try punks.get(key: "punk_001")!
        let punk1Duplicate = try HeaderImpl(node: NFTMetadata(name: "Punk #1", rarity: "legendary", creator: "larvalabs", edition: 1))
        #expect(punk1Header.rawCID == punk1Duplicate.rawCID)

        let punk1Fake = try HeaderImpl(node: NFTMetadata(name: "Punk #1", rarity: "legendary", creator: "forger", edition: 1))
        #expect(punk1Header.rawCID != punk1Fake.rawCID)
    }

    @Test("Transfer NFT between collections, verify structural sharing via CIDs")
    func testTransferNFT() throws {
        let art1 = NFTMetadata(name: "Starry Night #7", rarity: "legendary", creator: "artblocks", edition: 7)
        let art2 = NFTMetadata(name: "Chromie #42", rarity: "rare", creator: "artblocks", edition: 42)

        let aliceCollection = try Collection()
            .inserting(key: "starry_7", value: try HeaderImpl(node: art1))
            .inserting(key: "chromie_42", value: try HeaderImpl(node: art2))

        let bobCollection = Collection()

        let marketplace = try Marketplace()
            .inserting(key: "alice", value: try HeaderImpl(node: aliceCollection))
            .inserting(key: "bob", value: try HeaderImpl(node: bobCollection))

        let transferredItem = try aliceCollection.get(key: "chromie_42")!
        let newAlice = try aliceCollection.deleting(key: "chromie_42")
        let newBob = try bobCollection.inserting(key: "chromie_42", value: transferredItem)

        let newMarketplace = try marketplace
            .mutating(key: "alice", value: try HeaderImpl(node: newAlice))
            .mutating(key: "bob", value: try HeaderImpl(node: newBob))

        let (_, aliceCount) = try HeaderImpl(node: newAlice).query("count")
        #expect(aliceCount == .count(1))

        let (_, bobItems) = try HeaderImpl(node: newBob).query("keys sorted")
        #expect(bobItems == .list(["chromie_42"]))

        let originalStarry = try aliceCollection.get(key: "starry_7")!
        let postTransferStarry = try newAlice.get(key: "starry_7")!
        #expect(originalStarry.rawCID == postTransferStarry.rawCID)

        #expect(try HeaderImpl(node: marketplace).rawCID != (try HeaderImpl(node: newMarketplace).rawCID))
    }

    @Test("Store marketplace to CID, resolve, query across nesting levels")
    func testStoreResolveQuery() async throws {
        let store = TestStoreFetcher()

        let nft = NFTMetadata(name: "Genesis", rarity: "mythic", creator: "satoshi", edition: 0)
        let collection = try Collection()
            .inserting(key: "genesis_0", value: try HeaderImpl(node: nft))

        let marketplace = try Marketplace()
            .inserting(key: "founders", value: try HeaderImpl(node: collection))

        let root = try HeaderImpl(node: marketplace)
        try await root.storeAsVolume(storer: store)

        let (resolved, hasFounders) = try await HeaderImpl<Marketplace>(rawCID: root.rawCID)
            .query(#"contains "founders""#, fetcher: store)
        #expect(hasFounders == .bool(true))

        let foundersHeader = try resolved.node!.get(key: "founders")!
        let (resolvedFounders, _) = try await foundersHeader.query("count", fetcher: store)
        let (_, genesisCount) = try resolvedFounders.query("count")
        #expect(genesisCount == .count(1))
    }
}

// MARK: - IoT Sensor Network with Custom Nodes

@Suite("Real-World: IoT Sensor Network (Custom Nodes)")
struct IoTSensorQueryTests {

    typealias TimeSeries = MerkleArrayImpl<HeaderImpl<SensorReading>>
    typealias DeviceRegistry = MerkleDictionaryImpl<HeaderImpl<TimeSeries>>

    @Test("Ingest sensor data, query device registry, paginate time series")
    func testSensorIngestion() throws {
        let readings = [
            SensorReading(temperature: 22.5, humidity: 45.0, timestamp: 1700000000, sensorId: "temp_01"),
            SensorReading(temperature: 23.1, humidity: 44.2, timestamp: 1700000060, sensorId: "temp_01"),
            SensorReading(temperature: 23.8, humidity: 43.5, timestamp: 1700000120, sensorId: "temp_01"),
            SensorReading(temperature: 24.2, humidity: 42.8, timestamp: 1700000180, sensorId: "temp_01"),
            SensorReading(temperature: 24.0, humidity: 43.0, timestamp: 1700000240, sensorId: "temp_01"),
        ]

        var series = TimeSeries()
        for reading in readings {
            series = try series.append(try HeaderImpl(node: reading))
        }

        let outdoorReadings = [
            SensorReading(temperature: 5.2, humidity: 78.0, timestamp: 1700000000, sensorId: "outdoor_01"),
            SensorReading(temperature: 4.8, humidity: 80.1, timestamp: 1700000060, sensorId: "outdoor_01"),
        ]

        var outdoorSeries = TimeSeries()
        for reading in outdoorReadings {
            outdoorSeries = try outdoorSeries.append(try HeaderImpl(node: reading))
        }

        let registry = try DeviceRegistry()
            .inserting(key: "building_a/floor_2/temp_01", value: try HeaderImpl(node: series))
            .inserting(key: "building_a/outdoor/outdoor_01", value: try HeaderImpl(node: outdoorSeries))

        let (_, deviceCount) = try registry.query("count")
        #expect(deviceCount == .count(2))

        let (_, devices) = try registry.query("keys sorted")
        #expect(devices == .list(["building_a/floor_2/temp_01", "building_a/outdoor/outdoor_01"]))

        let tempSensor = try registry.get(key: "building_a/floor_2/temp_01")!
        let (_, readingCount) = try tempSensor.query("count")
        #expect(readingCount == .count(5))

        let (_, firstReading) = try tempSensor.query("first")
        #expect(firstReading != .value(nil))

        let (_, lastReading) = try tempSensor.query("last")
        #expect(lastReading != .value(nil))
    }

    @Test("Detect tampered sensor reading via CID mismatch")
    func testTamperDetection() throws {
        let legitimate = SensorReading(temperature: 22.5, humidity: 45.0, timestamp: 1700000000, sensorId: "temp_01")
        let tampered = SensorReading(temperature: 99.9, humidity: 45.0, timestamp: 1700000000, sensorId: "temp_01")

        let legitimateHeader = try HeaderImpl(node: legitimate)
        let tamperedHeader = try HeaderImpl(node: tampered)
        #expect(legitimateHeader.rawCID != tamperedHeader.rawCID)

        var series = TimeSeries()
        series = try series.append(legitimateHeader)
        let originalCID = try HeaderImpl(node: series).rawCID

        var tamperedSeries = TimeSeries()
        tamperedSeries = try tamperedSeries.append(tamperedHeader)
        let tamperedCID = try HeaderImpl(node: tamperedSeries).rawCID

        #expect(originalCID != tamperedCID)
    }

    @Test("Store device registry, resolve from CID, query nested custom nodes")
    func testStoreResolveNestedCustom() async throws {
        let store = TestStoreFetcher()

        let r1 = SensorReading(temperature: 20.0, humidity: 50.0, timestamp: 1700000000, sensorId: "s1")
        let r2 = SensorReading(temperature: 21.0, humidity: 49.0, timestamp: 1700000060, sensorId: "s1")

        var series = TimeSeries()
        series = try series.append(try HeaderImpl(node: r1))
        series = try series.append(try HeaderImpl(node: r2))

        let registry = try DeviceRegistry()
            .inserting(key: "sensor_1", value: try HeaderImpl(node: series))

        let root = try HeaderImpl(node: registry)
        try await root.storeAsVolume(storer: store)

        let (resolved, count) = try await HeaderImpl<DeviceRegistry>(rawCID: root.rawCID)
            .query("count", fetcher: store)
        #expect(count == .count(1))

        let sensorHeader = try resolved.node!.get(key: "sensor_1")!
        let (resolvedSensor, seriesCount) = try await sensorHeader.query("count", fetcher: store)
        #expect(seriesCount == .count(2))

        let (_, first) = try resolvedSensor.query("first")
        #expect(first != .value(nil))
    }
}

// MARK: - Fixed Income Portfolio with Custom Nodes

@Suite("Real-World: Bond Portfolio (Custom Nodes)")
struct BondPortfolioQueryTests {

    typealias Holdings = MerkleDictionaryImpl<HeaderImpl<BondInstrument>>
    typealias AccountBook = MerkleDictionaryImpl<HeaderImpl<Holdings>>

    @Test("Build multi-account bond portfolio, query holdings across accounts")
    func testPortfolioConstruction() throws {
        let treasury10y = BondInstrument(cusip: "912828ZT6", couponRate: 3.5, maturityYear: 2033, faceValue: 1000, issuer: "US Treasury")
        let treasury30y = BondInstrument(cusip: "912810SV1", couponRate: 4.0, maturityYear: 2053, faceValue: 1000, issuer: "US Treasury")
        let apple2028 = BondInstrument(cusip: "037833DX5", couponRate: 2.65, maturityYear: 2028, faceValue: 1000, issuer: "Apple Inc")
        let msft2030 = BondInstrument(cusip: "594918BW3", couponRate: 2.4, maturityYear: 2030, faceValue: 1000, issuer: "Microsoft")

        let pensionFund = try Holdings()
            .inserting(key: "912828ZT6", value: try HeaderImpl(node: treasury10y))
            .inserting(key: "912810SV1", value: try HeaderImpl(node: treasury30y))
            .inserting(key: "037833DX5", value: try HeaderImpl(node: apple2028))

        let hedgeFund = try Holdings()
            .inserting(key: "037833DX5", value: try HeaderImpl(node: apple2028))
            .inserting(key: "594918BW3", value: try HeaderImpl(node: msft2030))

        let book = try AccountBook()
            .inserting(key: "pension_fund_a", value: try HeaderImpl(node: pensionFund))
            .inserting(key: "hedge_fund_x", value: try HeaderImpl(node: hedgeFund))

        let (_, accounts) = try book.query("keys sorted")
        #expect(accounts == .list(["hedge_fund_x", "pension_fund_a"]))

        let (_, accountCount) = try book.query("count")
        #expect(accountCount == .count(2))

        let pensionHeader = try book.get(key: "pension_fund_a")!
        let (_, pensionCount) = try pensionHeader.query("count")
        #expect(pensionCount == .count(3))

        let (_, pensionBonds) = try pensionHeader.query("keys sorted")
        #expect(pensionBonds == .list(["037833DX5", "912810SV1", "912828ZT6"]))

        let hedgeHeader = try book.get(key: "hedge_fund_x")!
        let (_, hasApple) = try hedgeHeader.query(#"contains "037833DX5""#)
        #expect(hasApple == .bool(true))

        let pensionApple = try pensionFund.get(key: "037833DX5")!
        let hedgeApple = try hedgeFund.get(key: "037833DX5")!
        #expect(pensionApple.rawCID == hedgeApple.rawCID)
    }

    @Test("Rebalance portfolio: move bond between accounts, verify structural sharing")
    func testRebalance() throws {
        let bond = BondInstrument(cusip: "912828ZT6", couponRate: 3.5, maturityYear: 2033, faceValue: 1000, issuer: "US Treasury")
        let other = BondInstrument(cusip: "594918BW3", couponRate: 2.4, maturityYear: 2030, faceValue: 1000, issuer: "Microsoft")

        let accountA = try Holdings()
            .inserting(key: "912828ZT6", value: try HeaderImpl(node: bond))
            .inserting(key: "594918BW3", value: try HeaderImpl(node: other))
        let accountB = Holdings()

        let book = try AccountBook()
            .inserting(key: "account_a", value: try HeaderImpl(node: accountA))
            .inserting(key: "account_b", value: try HeaderImpl(node: accountB))

        let bookCID = try HeaderImpl(node: book).rawCID

        let movedBond = try accountA.get(key: "912828ZT6")!
        let newAccountA = try accountA.deleting(key: "912828ZT6")
        let newAccountB = try accountB.inserting(key: "912828ZT6", value: movedBond)

        let newBook = try book
            .mutating(key: "account_a", value: try HeaderImpl(node: newAccountA))
            .mutating(key: "account_b", value: try HeaderImpl(node: newAccountB))

        let newBookCID = try HeaderImpl(node: newBook).rawCID
        #expect(bookCID != newBookCID)

        let (_, aCount) = try HeaderImpl(node: newAccountA).query("count")
        #expect(aCount == .count(1))

        let (_, bBonds) = try HeaderImpl(node: newAccountB).query("keys sorted")
        #expect(bBonds == .list(["912828ZT6"]))

        let originalOther = try accountA.get(key: "594918BW3")!
        let postMoveOther = try newAccountA.get(key: "594918BW3")!
        #expect(originalOther.rawCID == postMoveOther.rawCID)
    }

    @Test("Store portfolio to CID, resolve, query across three nesting levels")
    func testStoreResolveThreeLevels() async throws {
        let store = TestStoreFetcher()

        let bond = BondInstrument(cusip: "912828ZT6", couponRate: 3.5, maturityYear: 2033, faceValue: 1000, issuer: "US Treasury")
        let holdings = try Holdings()
            .inserting(key: "912828ZT6", value: try HeaderImpl(node: bond))

        let book = try AccountBook()
            .inserting(key: "sovereign_fund", value: try HeaderImpl(node: holdings))

        let root = try HeaderImpl(node: book)
        try await root.storeAsVolume(storer: store)

        let (resolved, hasFund) = try await HeaderImpl<AccountBook>(rawCID: root.rawCID)
            .query(#"contains "sovereign_fund""#, fetcher: store)
        #expect(hasFund == .bool(true))

        let fundHeader = try resolved.node!.get(key: "sovereign_fund")!
        let (resolvedFund, bondCount) = try await fundHeader.query("count", fetcher: store)
        #expect(bondCount == .count(1))

        let (_, hasBond) = try resolvedFund.query(#"contains "912828ZT6""#)
        #expect(hasBond == .bool(true))

        let bondHeader = try resolvedFund.node!.get(key: "912828ZT6")!
        #expect(bondHeader.rawCID == (try HeaderImpl(node: bond).rawCID))
    }
}

// MARK: - Custom Node Default Query Behavior

@Suite("Real-World: Custom Node Query Defaults")
struct CustomNodeQueryDefaultsTests {

    @Test("Scalar node returns correct defaults from Node query methods")
    func testScalarQueryDefaults() throws {
        let sensor = SensorReading(temperature: 22.5, humidity: 45.0, timestamp: 1700000000, sensorId: "temp_01")

        let (_, count) = try sensor.query("count")
        #expect(count == .count(0))

        let (_, keys) = try sensor.query("keys")
        #expect(keys == .list([]))

        let (_, sorted) = try sensor.query("keys sorted")
        #expect(sorted == .list([]))

        let (_, contains) = try sensor.query(#"contains "anything""#)
        #expect(contains == .bool(false))
    }

    @Test("Custom node CID is deterministic and content-dependent")
    func testCustomNodeContentAddressing() throws {
        let a = try HeaderImpl(node: BondInstrument(cusip: "X", couponRate: 3.5, maturityYear: 2033, faceValue: 1000, issuer: "Treasury"))
        let b = try HeaderImpl(node: BondInstrument(cusip: "X", couponRate: 3.5, maturityYear: 2033, faceValue: 1000, issuer: "Treasury"))
        let c = try HeaderImpl(node: BondInstrument(cusip: "Y", couponRate: 3.5, maturityYear: 2033, faceValue: 1000, issuer: "Treasury"))

        #expect(a.rawCID == b.rawCID)
        #expect(a.rawCID != c.rawCID)
    }

    @Test("MerkleSet of custom node CIDs: deduplicated ownership registry")
    func testSetOfCustomNodeCIDs() throws {
        let nft1 = try HeaderImpl(node: NFTMetadata(name: "Alpha", rarity: "rare", creator: "artist_a", edition: 1))
        let nft2 = try HeaderImpl(node: NFTMetadata(name: "Beta", rarity: "common", creator: "artist_b", edition: 1))
        let nft3 = try HeaderImpl(node: NFTMetadata(name: "Gamma", rarity: "epic", creator: "artist_a", edition: 1))

        var ownership = try MerkleSetImpl()
            .insert(nft1.rawCID)
            .insert(nft2.rawCID)
            .insert(nft3.rawCID)

        let (_, count) = try ownership.query("count")
        #expect(count == .count(3))

        let (_, ownsNft1) = try ownership.query("contains \"\(nft1.rawCID)\"")
        #expect(ownsNft1 == .bool(true))

        ownership = try ownership.remove(nft2.rawCID)
        let (_, newCount) = try ownership.query("count")
        #expect(newCount == .count(2))

        let (_, stillOwnsNft1) = try ownership.query("contains \"\(nft1.rawCID)\"")
        #expect(stillOwnsNft1 == .bool(true))

        let (_, ownsNft2) = try ownership.query("contains \"\(nft2.rawCID)\"")
        #expect(ownsNft2 == .bool(false))
    }

    @Test("Mixed nesting: MerkleArray of custom nodes inside MerkleDictionary with MerkleSet index")
    func testMixedNesting() throws {
        typealias SensorLog = MerkleArrayImpl<HeaderImpl<SensorReading>>
        typealias AlertSet = MerkleSetImpl
        typealias FloorMonitor = MerkleDictionaryImpl<HeaderImpl<SensorLog>>

        let highTemp = SensorReading(temperature: 85.0, humidity: 20.0, timestamp: 1700000000, sensorId: "s1")
        let normalTemp = SensorReading(temperature: 22.0, humidity: 45.0, timestamp: 1700000060, sensorId: "s1")

        var sensorLog = SensorLog()
        sensorLog = try sensorLog.append(try HeaderImpl(node: highTemp))
        sensorLog = try sensorLog.append(try HeaderImpl(node: normalTemp))

        let floor = try FloorMonitor()
            .inserting(key: "zone_a/sensor_1", value: try HeaderImpl(node: sensorLog))

        let alerts = try AlertSet()
            .insert("zone_a/sensor_1")

        let (_, floorDevices) = try floor.query("keys sorted")
        #expect(floorDevices == .list(["zone_a/sensor_1"]))

        let (_, alertCount) = try alerts.query("count")
        #expect(alertCount == .count(1))

        let (_, isAlerting) = try alerts.query(#"contains "zone_a/sensor_1""#)
        #expect(isAlerting == .bool(true))

        let sensorHeader = try floor.get(key: "zone_a/sensor_1")!
        let (_, readingCount) = try sensorHeader.query("count")
        #expect(readingCount == .count(2))

        let (_, firstReading) = try sensorHeader.query("first")
        #expect(firstReading != .value(nil))
    }
}

// MARK: - Custom Node with Children (Org Chart)

typealias Department = MerkleDictionaryImpl<String>
typealias AuditLog = MerkleArrayImpl<String>

struct OrgUnit: Node {
    typealias PathSegment = String

    let team: HeaderImpl<Department>
    let history: HeaderImpl<AuditLog>

    init(team: HeaderImpl<Department>, history: HeaderImpl<AuditLog>) {
        self.team = team
        self.history = history
    }

    func get(property: PathSegment) -> (any Header)? {
        switch property {
        case "team": return team
        case "history": return history
        default: return nil
        }
    }

    func properties() -> Set<PathSegment> {
        return ["team", "history"]
    }

    func set(properties: [PathSegment: any Header]) -> Self {
        return OrgUnit(
            team: (properties["team"] as? HeaderImpl<Department>) ?? team,
            history: (properties["history"] as? HeaderImpl<AuditLog>) ?? history
        )
    }
}

@Suite("Real-World: Custom Node with Nested MerkleDictionary (Org Chart)")
struct OrgChartQueryTests {

    typealias OrgRegistry = MerkleDictionaryImpl<HeaderImpl<OrgUnit>>

    private func makeOrgUnit(members: [(String, String)], events: [String]) throws -> OrgUnit {
        var dept = Department()
        for (name, role) in members {
            dept = try dept.inserting(key: name, value: role)
        }
        var log = AuditLog()
        for event in events {
            log = try log.append(event)
        }
        return OrgUnit(team: try HeaderImpl(node: dept), history: try HeaderImpl(node: log))
    }

    @Test("Query custom node properties via default Node evaluate")
    func testCustomNodeDefaultQuery() throws {
        let unit = try makeOrgUnit(
            members: [("alice", "lead"), ("bob", "engineer")],
            events: ["created", "alice_promoted"]
        )

        let (_, count) = try unit.query("count")
        #expect(count == .count(2))

        let (_, keys) = try unit.query("keys sorted")
        #expect(keys == .list(["history", "team"]))

        let (_, hasTeam) = try unit.query(#"contains "team""#)
        #expect(hasTeam == .bool(true))

        let (_, hasPayroll) = try unit.query(#"contains "payroll""#)
        #expect(hasPayroll == .bool(false))
    }

    @Test("Query nested MerkleDictionary through custom node's children")
    func testQueryNestedDictThroughCustom() throws {
        let unit = try makeOrgUnit(
            members: [("alice", "lead"), ("bob", "engineer"), ("charlie", "designer")],
            events: ["unit_formed"]
        )

        let (_, teamCount) = try unit.team.query("count")
        #expect(teamCount == .count(3))

        let (_, teamMembers) = try unit.team.query("keys sorted")
        #expect(teamMembers == .list(["alice", "bob", "charlie"]))

        let (_, aliceRole) = try unit.team.query(#"get "alice""#)
        #expect(aliceRole == .value("lead"))

        let (_, historyCount) = try unit.history.query("count")
        #expect(historyCount == .count(1))

        let (_, firstEvent) = try unit.history.query("first")
        #expect(firstEvent == .value("unit_formed"))
    }

    @Test("Transform flows through custom node to nested MerkleDictionary")
    func testTransformThroughCustomNode() throws {
        let unit = try makeOrgUnit(
            members: [("alice", "engineer"), ("bob", "engineer")],
            events: ["created"]
        )

        var trie = ArrayTrie<Transform>()
        trie.set(["team", "alice"], value: .update("lead"))
        let transformed = try unit.transform(transforms: trie)!

        let (_, aliceRole) = try transformed.team.query(#"get "alice""#)
        #expect(aliceRole == .value("lead"))

        let (_, bobRole) = try transformed.team.query(#"get "bob""#)
        #expect(bobRole == .value("engineer"))
    }

    @Test("Transform adds new member to nested team via custom node")
    func testTransformInsertThroughCustomNode() throws {
        let unit = try makeOrgUnit(
            members: [("alice", "lead")],
            events: ["created"]
        )

        var trie = ArrayTrie<Transform>()
        trie.set(["team", "dave"], value: .insert("intern"))
        let transformed = try unit.transform(transforms: trie)!

        let (_, count) = try transformed.team.query("count")
        #expect(count == .count(2))

        let (_, daveRole) = try transformed.team.query(#"get "dave""#)
        #expect(daveRole == .value("intern"))
    }

    @Test("Transform deletes member from nested team via custom node")
    func testTransformDeleteThroughCustomNode() throws {
        let unit = try makeOrgUnit(
            members: [("alice", "lead"), ("bob", "engineer"), ("charlie", "designer")],
            events: ["created"]
        )

        var trie = ArrayTrie<Transform>()
        trie.set(["team", "bob"], value: .delete)
        let transformed = try unit.transform(transforms: trie)!

        let (_, count) = try transformed.team.query("count")
        #expect(count == .count(2))

        let (_, hasBob) = try transformed.team.query(#"contains "bob""#)
        #expect(hasBob == .bool(false))

        let (_, hasAlice) = try transformed.team.query(#"contains "alice""#)
        #expect(hasAlice == .bool(true))
    }

    @Test("Custom node inside MerkleDictionary: full org registry lifecycle")
    func testOrgRegistryLifecycle() throws {
        let engineering = try makeOrgUnit(
            members: [("alice", "vp"), ("bob", "staff"), ("charlie", "senior")],
            events: ["dept_created", "alice_hired", "bob_hired", "charlie_hired"]
        )
        let marketing = try makeOrgUnit(
            members: [("eve", "director"), ("frank", "manager")],
            events: ["dept_created", "eve_hired", "frank_hired"]
        )

        let org = try OrgRegistry()
            .inserting(key: "engineering", value: try HeaderImpl(node: engineering))
            .inserting(key: "marketing", value: try HeaderImpl(node: marketing))

        let (_, deptCount) = try org.query("count")
        #expect(deptCount == .count(2))

        let (_, depts) = try org.query("keys sorted")
        #expect(depts == .list(["engineering", "marketing"]))

        let engHeader = try org.get(key: "engineering")!
        let (_, engProps) = try engHeader.query("keys sorted")
        #expect(engProps == .list(["history", "team"]))

        let (_, engTeamCount) = try engHeader.node!.team.query("count")
        #expect(engTeamCount == .count(3))

        let (_, engMembers) = try engHeader.node!.team.query("keys sorted")
        #expect(engMembers == .list(["alice", "bob", "charlie"]))

        let (_, engHistoryCount) = try engHeader.node!.history.query("count")
        #expect(engHistoryCount == .count(4))

        let (_, firstEvent) = try engHeader.node!.history.query("first")
        #expect(firstEvent == .value("dept_created"))
    }

    @Test("Transform nested team inside org registry via outer MerkleDictionary")
    func testTransformThroughOrgRegistry() throws {
        let unit = try makeOrgUnit(
            members: [("alice", "engineer")],
            events: ["created"]
        )
        let org = try OrgRegistry()
            .inserting(key: "platform", value: try HeaderImpl(node: unit))

        var trie = ArrayTrie<Transform>()
        trie.set(["platform", "team", "alice"], value: .update("staff_engineer"))
        let newOrg = try org.transform(transforms: trie)!

        let platformHeader = try newOrg.get(key: "platform")!
        let (_, role) = try platformHeader.node!.team.query(#"get "alice""#)
        #expect(role == .value("staff_engineer"))
    }

    @Test("Store custom node org to CID, resolve, query all levels")
    func testStoreResolveCustomNodeOrg() async throws {
        let store = TestStoreFetcher()

        let unit = try makeOrgUnit(
            members: [("alice", "cto"), ("bob", "vp_eng")],
            events: ["founded", "series_a", "bob_joined"]
        )
        let org = try OrgRegistry()
            .inserting(key: "leadership", value: try HeaderImpl(node: unit))

        let root = try HeaderImpl(node: org)
        try await root.storeAsVolume(storer: store)

        let (resolved, hasLeadership) = try await HeaderImpl<OrgRegistry>(rawCID: root.rawCID)
            .query(#"contains "leadership""#, fetcher: store)
        #expect(hasLeadership == .bool(true))

        let leaderHeader = try resolved.node!.get(key: "leadership")!
        let resolvedLeader = try await leaderHeader.resolve(fetcher: store)
        let resolvedUnit = resolvedLeader.node!

        let resolvedTeam = try await resolvedUnit.team.query("count", fetcher: store)
        #expect(resolvedTeam.1 == .count(2))

        let (_, aliceRole) = try resolvedTeam.0.query(#"get "alice""#)
        #expect(aliceRole == .value("cto"))

        let resolvedHistory = try await resolvedUnit.history.query("count", fetcher: store)
        #expect(resolvedHistory.1 == .count(3))

        let (_, lastEvent) = try resolvedHistory.0.query("last")
        #expect(lastEvent == .value("bob_joined"))
    }

    @Test("CID changes propagate through custom node to org registry root")
    func testCIDPropagation() throws {
        let unit = try makeOrgUnit(
            members: [("alice", "lead")],
            events: ["created"]
        )
        let org = try OrgRegistry()
            .inserting(key: "team_x", value: try HeaderImpl(node: unit))
        let originalCID = try HeaderImpl(node: org).rawCID

        var trie = ArrayTrie<Transform>()
        trie.set(["team_x", "team", "alice"], value: .update("director"))
        let newOrg = try org.transform(transforms: trie)!
        let newCID = try HeaderImpl(node: newOrg).rawCID

        #expect(originalCID != newCID)

        let originalUnit = try org.get(key: "team_x")!
        let newUnit = try newOrg.get(key: "team_x")!
        #expect(originalUnit.rawCID != newUnit.rawCID)

        #expect(originalUnit.node!.history.rawCID == newUnit.node!.history.rawCID)
        #expect(originalUnit.node!.team.rawCID != newUnit.node!.team.rawCID)
    }
}
