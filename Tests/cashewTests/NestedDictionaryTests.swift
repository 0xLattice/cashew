import Testing
import Foundation
import ArrayTrie
@preconcurrency import Multicodec
@testable import cashew

@Suite("Nested Dictionary Operations")
struct NestedDictionaryOperationsTests {

    typealias LeafDict = MerkleDictionaryImpl<String>
    typealias MidDict = MerkleDictionaryImpl<HeaderImpl<LeafDict>>
    typealias TopDict = MerkleDictionaryImpl<HeaderImpl<MidDict>>

    @Test("True nested MerkleDictionary transforms - simple two-level")
    func testTrueNestedMerkleDictionaryTransforms() throws {
        struct TestBaseStructure: Scalar {
            let val: Int
        }

        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>
        typealias NestedDictionaryType = MerkleDictionaryImpl<HeaderImpl<BaseDictionaryType>>

        let userAlice = TestBaseStructure(val: 100)
        let userBob = TestBaseStructure(val: 200)
        let settingTheme = TestBaseStructure(val: 1)
        let settingLang = TestBaseStructure(val: 2)

        let aliceHeader = try HeaderImpl(node: userAlice)
        let bobHeader = try HeaderImpl(node: userBob)
        let themeHeader = try HeaderImpl(node: settingTheme)
        let langHeader = try HeaderImpl(node: settingLang)

        let emptyBaseDictionary = BaseDictionaryType(children: [:], count: 0)
        let usersDictionary = try emptyBaseDictionary
            .inserting(key: "alice", value: aliceHeader)
            .inserting(key: "bob", value: bobHeader)
        let settingsDictionary = try emptyBaseDictionary
            .inserting(key: "theme", value: themeHeader)
            .inserting(key: "language", value: langHeader)

        let usersDictionaryHeader = try HeaderImpl(node: usersDictionary)
        let settingsDictionaryHeader = try HeaderImpl(node: settingsDictionary)

        let emptyNestedDictionary = NestedDictionaryType(children: [:], count: 0)
        let outerDictionary = try emptyNestedDictionary
            .inserting(key: "users", value: usersDictionaryHeader)
            .inserting(key: "settings", value: settingsDictionaryHeader)

        print("=== Initial True Nested Structure ===")
        print("Outer dict count: \(outerDictionary.count)")

        let initialUsers = try outerDictionary.get(key: "users")
        let initialSettings = try outerDictionary.get(key: "settings")
        #expect(initialUsers != nil)
        #expect(initialSettings != nil)
        #expect(initialUsers!.node!.count == 2)
        #expect(initialSettings!.node!.count == 2)

        let initialAlice = try initialUsers!.node!.get(key: "alice")
        let initialTheme = try initialSettings!.node!.get(key: "theme")
        #expect(initialAlice?.node?.val == 100)
        #expect(initialTheme?.node?.val == 1)

        let newAlice = TestBaseStructure(val: 150)
        let newAliceHeader = try HeaderImpl(node: newAlice)
        let newCharlie = TestBaseStructure(val: 300)
        let newCharlieHeader = try HeaderImpl(node: newCharlie)
        let newTheme = TestBaseStructure(val: 3)
        let newThemeHeader = try HeaderImpl(node: newTheme)
        let newNotifications = TestBaseStructure(val: 1)
        let newNotificationsHeader = try HeaderImpl(node: newNotifications)

        let updatedUsersDictionary = try usersDictionary
            .mutating(key: ArraySlice("alice"), value: newAliceHeader)
            .inserting(key: "charlie", value: newCharlieHeader)
            .deleting(key: "bob")

        let updatedSettingsDictionary = try settingsDictionary
            .mutating(key: ArraySlice("theme"), value: newThemeHeader)
            .inserting(key: "notifications", value: newNotificationsHeader)

        let updatedUsersDictionaryHeader = try HeaderImpl(node: updatedUsersDictionary)
        let updatedSettingsDictionaryHeader = try HeaderImpl(node: updatedSettingsDictionary)

        let result = try outerDictionary
            .mutating(key: ArraySlice("users"), value: updatedUsersDictionaryHeader)
            .mutating(key: ArraySlice("settings"), value: updatedSettingsDictionaryHeader)

        print("\n=== After True Nested Transform ===")
        print("Result outer dict count: \(result.count)")

        #expect(result.count == 2)

        let resultUsers = try result.get(key: "users")
        let resultSettings = try result.get(key: "settings")
        #expect(resultUsers != nil)
        #expect(resultSettings != nil)

        #expect(resultUsers!.node!.count == 2)

        let resultAlice = try resultUsers!.node!.get(key: "alice")
        let resultCharlie = try resultUsers!.node!.get(key: "charlie")
        let resultBob = try resultUsers!.node!.get(key: "bob")

        #expect(resultAlice?.node?.val == 150)
        #expect(resultCharlie?.node?.val == 300)
        #expect(resultBob == nil)

        #expect(resultSettings!.node!.count == 3)

        let resultTheme = try resultSettings!.node!.get(key: "theme")
        let resultLang = try resultSettings!.node!.get(key: "language")
        let resultNotifications = try resultSettings!.node!.get(key: "notifications")

        #expect(resultTheme?.node?.val == 3)
        #expect(resultLang?.node?.val == 2)
        #expect(resultNotifications?.node?.val == 1)
    }

    @Test("True nested MerkleDictionary transforms - three levels deep")
    func testTrueDeepNestedMerkleDictionaryTransforms() throws {
        typealias Level1Type = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>
        typealias Level2Type = MerkleDictionaryImpl<HeaderImpl<Level1Type>>
        typealias Level3Type = MerkleDictionaryImpl<HeaderImpl<Level2Type>>

        struct TestBaseStructure: Scalar {
            let val: Int
        }

        let profileName = TestBaseStructure(val: 1)
        let profileEmail = TestBaseStructure(val: 2)
        let configHost = TestBaseStructure(val: 10)
        let configPort = TestBaseStructure(val: 5432)
        let metricsCount = TestBaseStructure(val: 100)

        let profileNameHeader = try HeaderImpl(node: profileName)
        let profileEmailHeader = try HeaderImpl(node: profileEmail)
        let configHostHeader = try HeaderImpl(node: configHost)
        let configPortHeader = try HeaderImpl(node: configPort)
        let metricsCountHeader = try HeaderImpl(node: metricsCount)

        let emptyLevel1 = Level1Type(children: [:], count: 0)
        let profileDict = try emptyLevel1
            .inserting(key: "name", value: profileNameHeader)
            .inserting(key: "email", value: profileEmailHeader)
        let configDict = try emptyLevel1
            .inserting(key: "host", value: configHostHeader)
            .inserting(key: "port", value: configPortHeader)
        let metricsDict = try emptyLevel1
            .inserting(key: "count", value: metricsCountHeader)

        let profileDictHeader = try HeaderImpl(node: profileDict)
        let configDictHeader = try HeaderImpl(node: configDict)
        let metricsDictHeader = try HeaderImpl(node: metricsDict)

        let emptyLevel2 = Level2Type(children: [:], count: 0)
        let userDict = try emptyLevel2
            .inserting(key: "profile", value: profileDictHeader)
        let systemDict = try emptyLevel2
            .inserting(key: "config", value: configDictHeader)
            .inserting(key: "metrics", value: metricsDictHeader)

        let userDictHeader = try HeaderImpl(node: userDict)
        let systemDictHeader = try HeaderImpl(node: systemDict)

        let emptyLevel3 = Level3Type(children: [:], count: 0)
        let rootDict = try emptyLevel3
            .inserting(key: "user", value: userDictHeader)
            .inserting(key: "system", value: systemDictHeader)

        print("=== Initial 3-Level Nested Structure ===")
        print("Root dict count: \(rootDict.count)")

        let initialUser = try rootDict.get(key: "user")
        let initialSystem = try rootDict.get(key: "system")
        #expect(initialUser != nil)
        #expect(initialSystem != nil)

        let initialProfile = try initialUser!.node!.get(key: "profile")
        let initialConfig = try initialSystem!.node!.get(key: "config")
        #expect(initialProfile != nil)
        #expect(initialConfig != nil)

        let initialName = try initialProfile!.node!.get(key: "name")
        let initialHost = try initialConfig!.node!.get(key: "host")
        #expect(initialName?.node?.val == 1)
        #expect(initialHost?.node?.val == 10)

        let newName = TestBaseStructure(val: 5)
        let newNameHeader = try HeaderImpl(node: newName)
        let newAge = TestBaseStructure(val: 25)
        let newAgeHeader = try HeaderImpl(node: newAge)
        let newHost = TestBaseStructure(val: 99)
        let newHostHeader = try HeaderImpl(node: newHost)
        let newSSL = TestBaseStructure(val: 1)
        let newSSLHeader = try HeaderImpl(node: newSSL)
        let newCount = TestBaseStructure(val: 200)
        let newCountHeader = try HeaderImpl(node: newCount)

        let updatedProfileDict = try profileDict
            .mutating(key: ArraySlice("name"), value: newNameHeader)
            .inserting(key: "age", value: newAgeHeader)

        let updatedConfigDict = try configDict
            .mutating(key: ArraySlice("host"), value: newHostHeader)
            .inserting(key: "ssl", value: newSSLHeader)

        let updatedMetricsDict = try metricsDict
            .mutating(key: ArraySlice("count"), value: newCountHeader)

        let updatedProfileDictHeader = try HeaderImpl(node: updatedProfileDict)
        let updatedConfigDictHeader = try HeaderImpl(node: updatedConfigDict)
        let updatedMetricsDictHeader = try HeaderImpl(node: updatedMetricsDict)

        let updatedUserDict = try userDict
            .mutating(key: ArraySlice("profile"), value: updatedProfileDictHeader)

        let updatedSystemDict = try systemDict
            .mutating(key: ArraySlice("config"), value: updatedConfigDictHeader)
            .mutating(key: ArraySlice("metrics"), value: updatedMetricsDictHeader)

        let updatedUserDictHeader = try HeaderImpl(node: updatedUserDict)
        let updatedSystemDictHeader = try HeaderImpl(node: updatedSystemDict)

        let newAppDict = Level2Type(children: [:], count: 0)
        let newAppDictHeader = try HeaderImpl(node: newAppDict)

        let result = try rootDict
            .mutating(key: ArraySlice("user"), value: updatedUserDictHeader)
            .mutating(key: ArraySlice("system"), value: updatedSystemDictHeader)
            .inserting(key: "app", value: newAppDictHeader)

        print("\n=== After 3-Level Deep Transform ===")
        print("Result root dict count: \(result.count)")

        #expect(result.count == 3)

        let resultUser = try result.get(key: "user")
        let resultSystem = try result.get(key: "system")
        let resultApp = try result.get(key: "app")
        #expect(resultUser != nil)
        #expect(resultSystem != nil)
        #expect(resultApp != nil)

        let resultProfile = try resultUser!.node!.get(key: "profile")
        #expect(resultProfile != nil)
        #expect(resultProfile!.node!.count == 3)

        let resultName = try resultProfile!.node!.get(key: "name")
        let resultEmail = try resultProfile!.node!.get(key: "email")
        let resultAge = try resultProfile!.node!.get(key: "age")
        #expect(resultName?.node?.val == 5)
        #expect(resultEmail?.node?.val == 2)
        #expect(resultAge?.node?.val == 25)

        let resultConfig = try resultSystem!.node!.get(key: "config")
        #expect(resultConfig != nil)
        #expect(resultConfig!.node!.count == 3)

        let resultHost = try resultConfig!.node!.get(key: "host")
        let resultPort = try resultConfig!.node!.get(key: "port")
        let resultSSL = try resultConfig!.node!.get(key: "ssl")
        #expect(resultHost?.node?.val == 99)
        #expect(resultPort?.node?.val == 5432)
        #expect(resultSSL?.node?.val == 1)

        let resultMetrics = try resultSystem!.node!.get(key: "metrics")
        #expect(resultMetrics != nil)
        #expect(resultMetrics!.node!.count == 1)

        let resultCount = try resultMetrics!.node!.get(key: "count")
        #expect(resultCount?.node?.val == 200)

        #expect(resultApp?.node?.count == 0)
    }

    @Test("Three-level nested dictionary: build, store, resolve, verify")
    func testThreeLevelNestedBuildStoreResolve() async throws {
        let leaf1 = try LeafDict(children: [:], count: 0)
            .inserting(key: "color", value: "red")
            .inserting(key: "size", value: "large")
        let leaf2 = try LeafDict(children: [:], count: 0)
            .inserting(key: "color", value: "blue")
            .inserting(key: "weight", value: "10kg")
            .inserting(key: "material", value: "steel")

        let mid = try MidDict(children: [:], count: 0)
            .inserting(key: "itemA", value: try HeaderImpl(node: leaf1))
            .inserting(key: "itemB", value: try HeaderImpl(node: leaf2))

        let top = try TopDict(children: [:], count: 0)
            .inserting(key: "warehouse1", value: try HeaderImpl(node: mid))

        let topHeader = try HeaderImpl(node: top)
        let fetcher = TestStoreFetcher()
        try await topHeader.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<TopDict>(rawCID: topHeader.rawCID)
        let resolved = try await unresolved.resolveRecursive(fetcher: fetcher)

        #expect(resolved.rawCID == topHeader.rawCID)
        let w1 = try resolved.node!.get(key: "warehouse1")
        #expect(w1 != nil)
        let itemA = try w1!.node!.get(key: "itemA")
        #expect(itemA != nil)
        #expect(try itemA!.node!.get(key: "color") == "red")
        #expect(try itemA!.node!.get(key: "size") == "large")
        let itemB = try w1!.node!.get(key: "itemB")
        #expect(try itemB!.node!.get(key: "material") == "steel")
    }

    @Test("Three-level nested dictionary: content addressability across levels")
    func testThreeLevelContentAddressability() throws {
        let leaf = try LeafDict(children: [:], count: 0)
            .inserting(key: "x", value: "1")
            .inserting(key: "y", value: "2")
        let leafHeader = try HeaderImpl(node: leaf)

        let mid1 = try MidDict(children: [:], count: 0)
            .inserting(key: "shared", value: leafHeader)
        let mid2 = try MidDict(children: [:], count: 0)
            .inserting(key: "shared", value: leafHeader)

        let midH1 = try HeaderImpl(node: mid1)
        let midH2 = try HeaderImpl(node: mid2)
        #expect(midH1.rawCID == midH2.rawCID)

        let top1 = try TopDict(children: [:], count: 0)
            .inserting(key: "branch", value: midH1)
        let top2 = try TopDict(children: [:], count: 0)
            .inserting(key: "branch", value: midH2)
        let topH1 = try HeaderImpl(node: top1)
        let topH2 = try HeaderImpl(node: top2)
        #expect(topH1.rawCID == topH2.rawCID)
    }

    @Test("Nested dict transform applies child transforms correctly (Bug 1)")
    func testNestedDictTransformAppliesChildTransforms() throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestScalar>>
        typealias NestedDictionaryType = MerkleDictionaryImpl<HeaderImpl<BaseDictionaryType>>

        let scalar1 = TestScalar(val: 1)
        let scalar2 = TestScalar(val: 2)
        let header1 = try HeaderImpl(node: scalar1)
        let header2 = try HeaderImpl(node: scalar2)

        let emptyBase = BaseDictionaryType(children: [:], count: 0)
        let innerDict = try emptyBase
            .inserting(key: "alpha", value: header1)
            .inserting(key: "beta", value: header2)
        let innerHeader = try HeaderImpl(node: innerDict)

        let emptyNested = NestedDictionaryType(children: [:], count: 0)
        let outerDict = try emptyNested
            .inserting(key: "group", value: innerHeader)

        let newScalar = TestScalar(val: 99)
        let newHeader = try HeaderImpl(node: newScalar)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["group", "alpha"], value: .update(newHeader.description))

        let result = try outerDict.transform(transforms: transforms)!
        let resultGroup = try result.get(key: "group")
        #expect(resultGroup != nil)
        let resultAlpha = try resultGroup!.node!.get(key: "alpha")
        #expect(resultAlpha != nil)
    }

    @Test("Nested dict transform with sibling children preserved (Bug 1)")
    func testNestedDictTransformSiblingChildrenPreserved() throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestScalar>>
        typealias NestedDictionaryType = MerkleDictionaryImpl<HeaderImpl<BaseDictionaryType>>

        let scalar1 = TestScalar(val: 10)
        let scalar2 = TestScalar(val: 20)
        let scalar3 = TestScalar(val: 30)
        let header1 = try HeaderImpl(node: scalar1)
        let header2 = try HeaderImpl(node: scalar2)
        let header3 = try HeaderImpl(node: scalar3)

        let emptyBase = BaseDictionaryType(children: [:], count: 0)
        let innerDict1 = try emptyBase
            .inserting(key: "x", value: header1)
            .inserting(key: "y", value: header2)
        let innerDict2 = try emptyBase
            .inserting(key: "z", value: header3)
        let innerHeader1 = try HeaderImpl(node: innerDict1)
        let innerHeader2 = try HeaderImpl(node: innerDict2)

        let emptyNested = NestedDictionaryType(children: [:], count: 0)
        let outerDict = try emptyNested
            .inserting(key: "first", value: innerHeader1)
            .inserting(key: "second", value: innerHeader2)

        let newScalar = TestScalar(val: 999)
        let newHeader = try HeaderImpl(node: newScalar)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["first", "x"], value: .update(newHeader.description))

        let result = try outerDict.transform(transforms: transforms)!
        #expect(result.count == 2)
        let resultSecond = try result.get(key: "second")
        #expect(resultSecond != nil)
        let resultZ = try resultSecond!.node!.get(key: "z")
        #expect(resultZ?.node?.val == 30)
    }
}

@Suite("Nested Transforms")
struct NestedTransformsTests {

    typealias LeafDict = MerkleDictionaryImpl<String>
    typealias MidDict = MerkleDictionaryImpl<HeaderImpl<LeafDict>>
    typealias TopDict = MerkleDictionaryImpl<HeaderImpl<MidDict>>

    @Test("Nested path transforms with dot notation simulation")
    func testNestedPathTransforms() throws {
        let userDict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "profile.name", value: "Alice Johnson")
            .inserting(key: "profile.email", value: "alice@example.com")
            .inserting(key: "profile.age", value: "28")
            .inserting(key: "settings.theme", value: "dark")
            .inserting(key: "settings.notifications", value: "enabled")
            .inserting(key: "settings.language", value: "en")
            .inserting(key: "metadata.created", value: "2024-01-15")
            .inserting(key: "metadata.version", value: "1.0")

        print("=== Initial Nested-Style Structure ===")
        print("Dict count: \(userDict.count)")
        print("profile.name: \(try userDict.get(key: "profile.name") ?? "nil")")
        print("settings.theme: \(try userDict.get(key: "settings.theme") ?? "nil")")
        print("metadata.created: \(try userDict.get(key: "metadata.created") ?? "nil")")

        var transforms = ArrayTrie<Transform>()

        transforms.set(["profile.name"], value: .update("Alice Smith"))
        transforms.set(["profile.email"], value: .update("alice.smith@company.com"))
        transforms.set(["profile.title"], value: .insert("Senior Engineer"))

        transforms.set(["settings.theme"], value: .update("light"))
        transforms.set(["settings.timezone"], value: .insert("EST"))

        transforms.set(["metadata.version"], value: .update("2.0"))
        transforms.set(["metadata.lastModified"], value: .insert("2024-01-20"))
        transforms.set(["metadata.created"], value: .delete)

        transforms.set(["preferences.layout"], value: .insert("sidebar"))
        transforms.set(["preferences.density"], value: .insert("compact"))

        let result = try userDict.transform(transforms: transforms)!

        print("\n=== After Transform ===")
        print("Dict count: \(result.count)")

        let manual = try userDict
            .mutating(key: ArraySlice("profile.name"), value: "Alice Smith")
            .mutating(key: ArraySlice("profile.email"), value: "alice.smith@company.com")
            .inserting(key: "profile.title", value: "Senior Engineer")
            .mutating(key: ArraySlice("settings.theme"), value: "light")
            .inserting(key: "settings.timezone", value: "EST")
            .mutating(key: ArraySlice("metadata.version"), value: "2.0")
            .inserting(key: "metadata.lastModified", value: "2024-01-20")
            .deleting(key: "metadata.created")
            .inserting(key: "preferences.layout", value: "sidebar")
            .inserting(key: "preferences.density", value: "compact")

        #expect(result.count == manual.count)
        #expect(result.count == 12)

        #expect(try result.get(key: "profile.name") == "Alice Smith")
        #expect(try manual.get(key: "profile.name") == "Alice Smith")
        #expect(try result.get(key: "profile.title") == "Senior Engineer")
        #expect(try manual.get(key: "profile.title") == "Senior Engineer")

        #expect(try result.get(key: "settings.theme") == "light")
        #expect(try manual.get(key: "settings.theme") == "light")
        #expect(try result.get(key: "settings.timezone") == "EST")
        #expect(try manual.get(key: "settings.timezone") == "EST")

        #expect(try result.get(key: "metadata.version") == "2.0")
        #expect(try manual.get(key: "metadata.version") == "2.0")
        #expect(try result.get(key: "metadata.created") == nil)
        #expect(try manual.get(key: "metadata.created") == nil)
        #expect(try result.get(key: "metadata.lastModified") == "2024-01-20")
        #expect(try manual.get(key: "metadata.lastModified") == "2024-01-20")

        #expect(try result.get(key: "preferences.layout") == "sidebar")
        #expect(try manual.get(key: "preferences.layout") == "sidebar")
        #expect(try result.get(key: "preferences.density") == "compact")
        #expect(try manual.get(key: "preferences.density") == "compact")

        #expect(try result.get(key: "profile.age") == "28")
        #expect(try manual.get(key: "profile.age") == "28")
        #expect(try result.get(key: "settings.notifications") == "enabled")
        #expect(try manual.get(key: "settings.notifications") == "enabled")
    }

    @Test("Complex nested-style path operations with deletion")
    func testComplexNestedPathOperations() throws {
        let systemDict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "users.admin.name", value: "Administrator")
            .inserting(key: "users.admin.role", value: "admin")
            .inserting(key: "users.admin.lastLogin", value: "2024-01-10")
            .inserting(key: "users.john.name", value: "John Doe")
            .inserting(key: "users.john.role", value: "user")
            .inserting(key: "users.john.lastLogin", value: "2024-01-15")
            .inserting(key: "config.database.host", value: "localhost")
            .inserting(key: "config.database.port", value: "5432")
            .inserting(key: "config.database.name", value: "myapp")
            .inserting(key: "config.redis.host", value: "localhost")
            .inserting(key: "config.redis.port", value: "6379")
            .inserting(key: "logs.error.count", value: "5")
            .inserting(key: "logs.warning.count", value: "12")
            .inserting(key: "logs.info.count", value: "150")

        var transforms = ArrayTrie<Transform>()

        transforms.set(["users.john.name"], value: .delete)
        transforms.set(["users.john.role"], value: .delete)
        transforms.set(["users.john.lastLogin"], value: .delete)

        transforms.set(["users.admin.lastLogin"], value: .update("2024-01-20"))
        transforms.set(["users.admin.email"], value: .insert("admin@company.com"))

        transforms.set(["config.database.host"], value: .update("production-db"))
        transforms.set(["config.database.ssl"], value: .insert("enabled"))

        transforms.set(["users.alice.name"], value: .insert("Alice Smith"))
        transforms.set(["users.alice.role"], value: .insert("moderator"))
        transforms.set(["users.alice.lastLogin"], value: .insert("2024-01-18"))

        transforms.set(["logs.error.count"], value: .update("3"))
        transforms.set(["logs.debug.count"], value: .insert("25"))

        let result = try systemDict.transform(transforms: transforms)!

        let manual = try systemDict
            .deleting(key: "users.john.name")
            .deleting(key: "users.john.role")
            .deleting(key: "users.john.lastLogin")
            .mutating(key: ArraySlice("users.admin.lastLogin"), value: "2024-01-20")
            .inserting(key: "users.admin.email", value: "admin@company.com")
            .mutating(key: ArraySlice("config.database.host"), value: "production-db")
            .inserting(key: "config.database.ssl", value: "enabled")
            .inserting(key: "users.alice.name", value: "Alice Smith")
            .inserting(key: "users.alice.role", value: "moderator")
            .inserting(key: "users.alice.lastLogin", value: "2024-01-18")
            .mutating(key: ArraySlice("logs.error.count"), value: "3")
            .inserting(key: "logs.debug.count", value: "25")

        #expect(result.count == manual.count)
        #expect(result.count == 17)

        #expect(try result.get(key: "users.john.name") == nil)
        #expect(try manual.get(key: "users.john.name") == nil)
        #expect(try result.get(key: "users.john.role") == nil)
        #expect(try manual.get(key: "users.john.role") == nil)

        #expect(try result.get(key: "users.admin.name") == "Administrator")
        #expect(try manual.get(key: "users.admin.name") == "Administrator")
        #expect(try result.get(key: "users.admin.lastLogin") == "2024-01-20")
        #expect(try manual.get(key: "users.admin.lastLogin") == "2024-01-20")
        #expect(try result.get(key: "users.admin.email") == "admin@company.com")
        #expect(try manual.get(key: "users.admin.email") == "admin@company.com")

        #expect(try result.get(key: "users.alice.name") == "Alice Smith")
        #expect(try manual.get(key: "users.alice.name") == "Alice Smith")
        #expect(try result.get(key: "users.alice.role") == "moderator")
        #expect(try manual.get(key: "users.alice.role") == "moderator")

        #expect(try result.get(key: "config.database.host") == "production-db")
        #expect(try manual.get(key: "config.database.host") == "production-db")
        #expect(try result.get(key: "config.database.ssl") == "enabled")
        #expect(try manual.get(key: "config.database.ssl") == "enabled")

        #expect(try result.get(key: "logs.error.count") == "3")
        #expect(try manual.get(key: "logs.error.count") == "3")
        #expect(try result.get(key: "logs.debug.count") == "25")
        #expect(try manual.get(key: "logs.debug.count") == "25")

        #expect(try result.get(key: "config.redis.host") == "localhost")
        #expect(try manual.get(key: "config.redis.host") == "localhost")
        #expect(try result.get(key: "logs.info.count") == "150")
        #expect(try manual.get(key: "logs.info.count") == "150")
    }

    @Test("Hierarchical key structure transforms")
    func testHierarchicalKeyStructureTransforms() throws {
        let hierarchicalDict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "system", value: "online")
            .inserting(key: "system_config", value: "loaded")
            .inserting(key: "system_config_database", value: "connected")
            .inserting(key: "system_config_database_host", value: "db-server")
            .inserting(key: "system_config_database_port", value: "5432")
            .inserting(key: "system_config_cache", value: "enabled")
            .inserting(key: "system_config_cache_redis", value: "connected")
            .inserting(key: "system_status", value: "healthy")
            .inserting(key: "system_status_memory", value: "85%")
            .inserting(key: "system_status_cpu", value: "45%")
            .inserting(key: "user_session", value: "active")
            .inserting(key: "user_session_timeout", value: "30min")
            .inserting(key: "user_permissions", value: "admin")

        print("=== Hierarchical Structure ===")
        print("Dict count: \(hierarchicalDict.count)")

        var transforms = ArrayTrie<Transform>()

        transforms.set(["system_status"], value: .update("degraded"))
        transforms.set(["system_status_memory"], value: .update("95%"))
        transforms.set(["system_status_disk"], value: .insert("78%"))

        transforms.set(["system_config_database_host"], value: .update("new-db-server"))
        transforms.set(["system_config_database_pool"], value: .insert("10"))

        transforms.set(["system_config_cache"], value: .delete)
        transforms.set(["system_config_cache_redis"], value: .delete)

        transforms.set(["system_config_memcached"], value: .insert("enabled"))
        transforms.set(["system_config_memcached_host"], value: .insert("memcache-server"))

        transforms.set(["user_session_timeout"], value: .update("60min"))
        transforms.set(["user_last_activity"], value: .insert("2024-01-20T15:30:00Z"))

        let result = try hierarchicalDict.transform(transforms: transforms)!

        let manual = try hierarchicalDict
            .mutating(key: ArraySlice("system_status"), value: "degraded")
            .mutating(key: ArraySlice("system_status_memory"), value: "95%")
            .inserting(key: "system_status_disk", value: "78%")
            .mutating(key: ArraySlice("system_config_database_host"), value: "new-db-server")
            .inserting(key: "system_config_database_pool", value: "10")
            .deleting(key: "system_config_cache")
            .deleting(key: "system_config_cache_redis")
            .inserting(key: "system_config_memcached", value: "enabled")
            .inserting(key: "system_config_memcached_host", value: "memcache-server")
            .mutating(key: ArraySlice("user_session_timeout"), value: "60min")
            .inserting(key: "user_last_activity", value: "2024-01-20T15:30:00Z")

        #expect(result.count == manual.count)
        #expect(result.count == 16)

        #expect(try result.get(key: "system_status") == "degraded")
        #expect(try manual.get(key: "system_status") == "degraded")
        #expect(try result.get(key: "system_status_memory") == "95%")
        #expect(try manual.get(key: "system_status_memory") == "95%")
        #expect(try result.get(key: "system_status_disk") == "78%")
        #expect(try manual.get(key: "system_status_disk") == "78%")

        #expect(try result.get(key: "system_config_database_host") == "new-db-server")
        #expect(try manual.get(key: "system_config_database_host") == "new-db-server")
        #expect(try result.get(key: "system_config_database_pool") == "10")
        #expect(try manual.get(key: "system_config_database_pool") == "10")

        #expect(try result.get(key: "system_config_cache") == nil)
        #expect(try manual.get(key: "system_config_cache") == nil)
        #expect(try result.get(key: "system_config_cache_redis") == nil)
        #expect(try manual.get(key: "system_config_cache_redis") == nil)

        #expect(try result.get(key: "system_config_memcached") == "enabled")
        #expect(try manual.get(key: "system_config_memcached") == "enabled")
        #expect(try result.get(key: "system_config_memcached_host") == "memcache-server")
        #expect(try manual.get(key: "system_config_memcached_host") == "memcache-server")

        #expect(try result.get(key: "system") == "online")
        #expect(try manual.get(key: "system") == "online")
        #expect(try result.get(key: "system_config") == "loaded")
        #expect(try manual.get(key: "system_config") == "loaded")
        #expect(try result.get(key: "system_config_database") == "connected")
        #expect(try manual.get(key: "system_config_database") == "connected")

        print("\n=== Final Hierarchical Structure ===")
        print("Result count: \(result.count)")
        print("Manual count: \(manual.count)")
    }

    @Test("Bulk nested-style operations with patterns")
    func testBulkNestedOperationsWithPatterns() throws {
        var dict = MerkleDictionaryImpl<String>(children: [:], count: 0)

        for i in 1...20 {
            dict = try dict
                .inserting(key: "users.\(i).name", value: "User\(i)")
                .inserting(key: "users.\(i).email", value: "user\(i)@example.com")
                .inserting(key: "users.\(i).role", value: i <= 5 ? "admin" : "user")
                .inserting(key: "users.\(i).status", value: "active")
        }

        for i in 1...10 {
            dict = try dict
                .inserting(key: "metrics.hour\(i).requests", value: "\(100 + i * 10)")
                .inserting(key: "metrics.hour\(i).errors", value: "\(i)")
        }

        print("Initial bulk dict count: \(dict.count)")
        #expect(dict.count == 100)

        var transforms = ArrayTrie<Transform>()

        for i in 16...20 {
            transforms.set(["users.\(i).status"], value: .update("inactive"))
        }

        for i in 1...3 {
            transforms.set(["users.\(i).role"], value: .update("superadmin"))
        }

        for i in 18...20 {
            transforms.set(["users.\(i).name"], value: .delete)
            transforms.set(["users.\(i).email"], value: .delete)
            transforms.set(["users.\(i).role"], value: .delete)
            transforms.set(["users.\(i).status"], value: .delete)
        }

        for i in [1, 3, 5, 7, 9] {
            transforms.set(["metrics.hour\(i).requests"], value: .update("\(200 + i * 15)"))
        }

        transforms.set(["metrics.hour11.requests"], value: .insert("350"))
        transforms.set(["metrics.hour11.errors"], value: .insert("2"))
        transforms.set(["metrics.hour12.requests"], value: .insert("380"))
        transforms.set(["metrics.hour12.errors"], value: .insert("1"))

        let result = try dict.transform(transforms: transforms)!

        print("Final bulk dict count: \(result.count)")
        #expect(result.count == 92)

        #expect(try result.get(key: "users.1.role") == "superadmin")
        #expect(try result.get(key: "users.2.role") == "superadmin")
        #expect(try result.get(key: "users.3.role") == "superadmin")
        #expect(try result.get(key: "users.4.role") == "admin")

        #expect(try result.get(key: "users.16.status") == "inactive")
        #expect(try result.get(key: "users.17.status") == "inactive")

        #expect(try result.get(key: "users.18.name") == nil)
        #expect(try result.get(key: "users.19.name") == nil)
        #expect(try result.get(key: "users.20.name") == nil)

        #expect(try result.get(key: "metrics.hour1.requests") == "215")
        #expect(try result.get(key: "metrics.hour3.requests") == "245")
        #expect(try result.get(key: "metrics.hour2.requests") == "120")

        #expect(try result.get(key: "metrics.hour11.requests") == "350")
        #expect(try result.get(key: "metrics.hour12.errors") == "1")

        #expect(try result.get(key: "users.10.name") == "User10")
        #expect(try result.get(key: "users.15.status") == "active")
        #expect(try result.get(key: "metrics.hour6.errors") == "6")
    }

    @Test("Three-level nested: transform at leaf level, verify CID change propagates")
    func testThreeLevelTransformCIDPropagation() throws {
        let leaf = try LeafDict(children: [:], count: 0)
            .inserting(key: "key1", value: "val1")
            .inserting(key: "key2", value: "val2")
        let leafHeader = try HeaderImpl(node: leaf)

        let mid = try MidDict(children: [:], count: 0)
            .inserting(key: "child", value: leafHeader)
        let midHeader = try HeaderImpl(node: mid)

        let top = try TopDict(children: [:], count: 0)
            .inserting(key: "root", value: midHeader)
        let topHeader = try HeaderImpl(node: top)

        let newLeaf = try LeafDict(children: [:], count: 0)
            .inserting(key: "key1", value: "CHANGED")
            .inserting(key: "key2", value: "val2")
        let newLeafHeader = try HeaderImpl(node: newLeaf)

        let newMid = try MidDict(children: [:], count: 0)
            .inserting(key: "child", value: newLeafHeader)
        let newMidHeader = try HeaderImpl(node: newMid)

        let newTop = try TopDict(children: [:], count: 0)
            .inserting(key: "root", value: newMidHeader)
        let newTopHeader = try HeaderImpl(node: newTop)

        #expect(leafHeader.rawCID != newLeafHeader.rawCID)
        #expect(midHeader.rawCID != newMidHeader.rawCID)
        #expect(topHeader.rawCID != newTopHeader.rawCID)
    }

    @Test("Transform nested dictionary via header with multi-level path")
    func testNestedDictTransformViaHeader() async throws {
        typealias Inner = MerkleDictionaryImpl<String>
        typealias Outer = MerkleDictionaryImpl<VolumeImpl<Inner>>

        let inner = try Inner(children: [:], count: 0)
            .inserting(key: "name", value: "Alice")
            .inserting(key: "role", value: "engineer")
        let innerHeader = try VolumeImpl(node: inner)

        let outer = try Outer(children: [:], count: 0)
            .inserting(key: "user1", value: innerHeader)

        let outerHeader = try HeaderImpl(node: outer)

        let updatedInner = try Inner(children: [:], count: 0)
            .inserting(key: "name", value: "Bob")
            .inserting(key: "role", value: "manager")
        let updatedInnerHeader = try VolumeImpl(node: updatedInner)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["user1"], value: .update(updatedInnerHeader.description))

        let result = try outerHeader.transform(transforms: transforms)!
        #expect(result.rawCID != outerHeader.rawCID)

        let fetcher = TestStoreFetcher()
        try await updatedInnerHeader.storeRecursively(storer: fetcher)
        try await result.storeAsVolume(storer: fetcher)
        let resolved = try await HeaderImpl<Outer>(rawCID: result.rawCID).resolveRecursive(fetcher: fetcher)
        let user1 = try resolved.node!.get(key: "user1")!
        #expect(try user1.node!.get(key: "name") == "Bob")
        #expect(try user1.node!.get(key: "role") == "manager")
    }

    @Test("Transform nested dict: insert new inner dict alongside existing")
    func testTransformInsertNewInnerDict() async throws {
        typealias Inner = MerkleDictionaryImpl<String>
        typealias Outer = MerkleDictionaryImpl<VolumeImpl<Inner>>

        let inner1 = try Inner(children: [:], count: 0)
            .inserting(key: "a", value: "1")
        let h1 = try VolumeImpl(node: inner1)

        let outer = try Outer(children: [:], count: 0)
            .inserting(key: "existing", value: h1)

        let inner2 = try Inner(children: [:], count: 0)
            .inserting(key: "b", value: "2")
            .inserting(key: "c", value: "3")
        let h2 = try VolumeImpl(node: inner2)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["added"], value: .insert(h2.description))

        let result = try outer.transform(transforms: transforms)!
        #expect(result.count == 2)

        let fetcher = TestStoreFetcher()
        try await h1.storeRecursively(storer: fetcher)
        try await h2.storeRecursively(storer: fetcher)
        let resultHeader = try HeaderImpl(node: result)
        try await resultHeader.storeAsVolume(storer: fetcher)
        let resolved = try await HeaderImpl<Outer>(rawCID: resultHeader.rawCID)
            .resolveRecursive(fetcher: fetcher)

        let existingVal = try resolved.node!.get(key: "existing")!
        #expect(try existingVal.node!.get(key: "a") == "1")

        let addedVal = try resolved.node!.get(key: "added")!
        #expect(try addedVal.node!.get(key: "b") == "2")
        #expect(try addedVal.node!.get(key: "c") == "3")
    }
}
