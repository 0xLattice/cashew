import Testing
import Foundation
import ArrayTrie
@testable import cashew

@Suite("Cashew Query Language")
struct CashewQueryTests {

    typealias Dict = MerkleDictionaryImpl<String>
    typealias Arr = MerkleArrayImpl<String>

    @Suite("Parser")
    struct ParserTests {

        @Test("Parses get with quoted key")
        func testParseGet() throws {
            let exprs = try CashewParser.parse(#"get "alice""#)
            #expect(exprs == [.get("alice")])
        }

        @Test("Parses get at index")
        func testParseGetAt() throws {
            let exprs = try CashewParser.parse("get at 5")
            #expect(exprs == [.getAt(5)])
        }

        @Test("Parses keys and keys sorted")
        func testParseKeys() throws {
            #expect(try CashewParser.parse("keys") == [.keys])
            #expect(try CashewParser.parse("keys sorted") == [.sortedKeys(limit: nil, after: nil)])
            #expect(try CashewParser.parse("keys sorted limit 10") == [.sortedKeys(limit: 10, after: nil)])
            #expect(try CashewParser.parse(#"keys sorted limit 5 after "bob""#) == [.sortedKeys(limit: 5, after: "bob")])
            #expect(try CashewParser.parse(#"keys sorted after "z""#) == [.sortedKeys(limit: nil, after: "z")])
        }

        @Test("Parses values and values sorted")
        func testParseValues() throws {
            #expect(try CashewParser.parse("values") == [.values])
            #expect(try CashewParser.parse("values sorted") == [.sortedValues(limit: nil, after: nil)])
            #expect(try CashewParser.parse("values sorted limit 3") == [.sortedValues(limit: 3, after: nil)])
        }

        @Test("Parses count and contains")
        func testParseCountContains() throws {
            #expect(try CashewParser.parse("count") == [.count])
            #expect(try CashewParser.parse(#"contains "alice""#) == [.contains("alice")])
        }

        @Test("Parses insert, update, set, delete")
        func testParseTransforms() throws {
            #expect(try CashewParser.parse(#"insert "alice" = "engineer""#) == [.insert(key: "alice", value: "engineer")])
            #expect(try CashewParser.parse(#"update "alice" = "lead""#) == [.update(key: "alice", value: "lead")])
            #expect(try CashewParser.parse(#"set "alice" = "cto""#) == [.set(key: "alice", value: "cto")])
            #expect(try CashewParser.parse(#"delete "alice""#) == [.delete("alice")])
        }

        @Test("Parses append, first, last")
        func testParseArrayOps() throws {
            #expect(try CashewParser.parse(#"append "hello""#) == [.append("hello")])
            #expect(try CashewParser.parse("first") == [.first])
            #expect(try CashewParser.parse("last") == [.last])
        }

        @Test("Parses pipeline with pipe operator")
        func testParsePipeline() throws {
            let exprs = try CashewParser.parse(#"insert "a" = "1" | insert "b" = "2" | keys sorted"#)
            #expect(exprs == [
                .insert(key: "a", value: "1"),
                .insert(key: "b", value: "2"),
                .sortedKeys(limit: nil, after: nil)
            ])
        }

        @Test("Parses command aliases")
        func testAliases() throws {
            #expect(try CashewParser.parse("members") == [.keys])
            #expect(try CashewParser.parse("size") == [.count])
            #expect(try CashewParser.parse(#"has "x""#) == [.contains("x")])
            #expect(try CashewParser.parse(#"add "x" = "y""#) == [.insert(key: "x", value: "y")])
            #expect(try CashewParser.parse(#"remove "x""#) == [.delete("x")])
            #expect(try CashewParser.parse(#"put "x" = "y""#) == [.set(key: "x", value: "y")])
        }

        @Test("Case insensitive commands")
        func testCaseInsensitive() throws {
            #expect(try CashewParser.parse("COUNT") == [.count])
            #expect(try CashewParser.parse("Keys Sorted") == [.sortedKeys(limit: nil, after: nil)])
        }

        @Test("Supports single-quoted strings")
        func testSingleQuotes() throws {
            #expect(try CashewParser.parse("get 'alice'") == [.get("alice")])
        }

        @Test("Handles escaped quotes in strings")
        func testEscapedQuotes() throws {
            let exprs = try CashewParser.parse(#"get "say \"hi\"""#)
            #expect(exprs == [.get(#"say "hi""#)])
        }

        @Test("Empty input throws emptyExpression")
        func testEmptyInput() {
            #expect(throws: CashewQueryError.emptyExpression) {
                try CashewParser.parse("")
            }
            #expect(throws: CashewQueryError.emptyExpression) {
                try CashewParser.parse("   ")
            }
        }

        @Test("Unknown command throws parseError")
        func testUnknownCommand() {
            #expect(throws: CashewQueryError.self) {
                try CashewParser.parse("foobar")
            }
        }

        @Test("Unterminated string throws parseError")
        func testUnterminatedString() {
            #expect(throws: CashewQueryError.self) {
                try CashewParser.parse(#"get "unterminated"#)
            }
        }

        @Test("Empty pipeline segment throws parseError")
        func testEmptyPipelineSegment() {
            #expect(throws: CashewQueryError.self) {
                try CashewParser.parse("keys | | count")
            }
        }
    }

    @Suite("Dictionary Queries")
    struct DictionaryQueryTests {

        @Test("get returns a value")
        func testGet() throws {
            let dict = try Dict()
                .inserting(key: "alice", value: "engineer")
            let (_, result) = try dict.query(#"get "alice""#)
            #expect(result == .value("engineer"))
        }

        @Test("get missing key returns nil")
        func testGetMissing() throws {
            let dict = Dict()
            let (_, result) = try dict.query(#"get "missing""#)
            #expect(result == .value(nil))
        }

        @Test("keys returns all keys")
        func testKeys() throws {
            let dict = try Dict()
                .inserting(key: "alice", value: "1")
                .inserting(key: "bob", value: "2")
            let (_, result) = try dict.query("keys")
            if case .list(let keys) = result {
                #expect(Set(keys) == Set(["alice", "bob"]))
            } else {
                Issue.record("Expected .list result")
            }
        }

        @Test("keys sorted returns lexicographic order")
        func testKeysSorted() throws {
            let dict = try Dict()
                .inserting(key: "cherry", value: "3")
                .inserting(key: "apple", value: "1")
                .inserting(key: "banana", value: "2")
            let (_, result) = try dict.query("keys sorted")
            #expect(result == .list(["apple", "banana", "cherry"]))
        }

        @Test("keys sorted with limit and after")
        func testKeysSortedLimitAfter() throws {
            let dict = try Dict()
                .inserting(key: "a", value: "1")
                .inserting(key: "b", value: "2")
                .inserting(key: "c", value: "3")
                .inserting(key: "d", value: "4")
            let (_, result) = try dict.query(#"keys sorted limit 2 after "a""#)
            #expect(result == .list(["b", "c"]))
        }

        @Test("values sorted returns ordered entries")
        func testValuesSorted() throws {
            let dict = try Dict()
                .inserting(key: "banana", value: "yellow")
                .inserting(key: "apple", value: "red")
            let (_, result) = try dict.query("values sorted")
            #expect(result == .entries([(key: "apple", value: "red"), (key: "banana", value: "yellow")]))
        }

        @Test("count returns number of entries")
        func testCount() throws {
            let dict = try Dict()
                .inserting(key: "a", value: "1")
                .inserting(key: "b", value: "2")
            let (_, result) = try dict.query("count")
            #expect(result == .count(2))
        }

        @Test("contains returns bool")
        func testContains() throws {
            let dict = try Dict().inserting(key: "alice", value: "1")
            let (_, yes) = try dict.query(#"contains "alice""#)
            let (_, no) = try dict.query(#"contains "bob""#)
            #expect(yes == .bool(true))
            #expect(no == .bool(false))
        }
    }

    @Suite("Dictionary Transforms")
    struct DictionaryTransformTests {

        @Test("insert adds a new key")
        func testInsert() throws {
            let dict = Dict()
            let (updated, result) = try dict.query(#"insert "alice" = "engineer""#)
            #expect(result == .ok)
            #expect(try updated.get(key: "alice") == "engineer")
            #expect(updated.count == 1)
        }

        @Test("update changes an existing key")
        func testUpdate() throws {
            let dict = try Dict().inserting(key: "alice", value: "engineer")
            let (updated, _) = try dict.query(#"update "alice" = "lead""#)
            #expect(try updated.get(key: "alice") == "lead")
        }

        @Test("set inserts or updates")
        func testSet() throws {
            let dict = Dict()
            let (d1, _) = try dict.query(#"set "alice" = "engineer""#)
            #expect(try d1.get(key: "alice") == "engineer")
            let (d2, _) = try d1.query(#"set "alice" = "lead""#)
            #expect(try d2.get(key: "alice") == "lead")
            #expect(d2.count == 1)
        }

        @Test("delete removes a key")
        func testDelete() throws {
            let dict = try Dict().inserting(key: "alice", value: "1")
            let (updated, _) = try dict.query(#"delete "alice""#)
            #expect(updated.count == 0)
        }
    }

    @Suite("Pipeline")
    struct PipelineTests {

        @Test("Pipeline builds up data then queries")
        func testBuildAndQuery() throws {
            let (_, result) = try Dict().query(
                #"insert "cherry" = "3" | insert "apple" = "1" | insert "banana" = "2" | keys sorted"#
            )
            #expect(result == .list(["apple", "banana", "cherry"]))
        }

        @Test("Pipeline with transforms and count")
        func testTransformAndCount() throws {
            let (_, result) = try Dict().query(
                #"insert "a" = "1" | insert "b" = "2" | insert "c" = "3" | delete "b" | count"#
            )
            #expect(result == .count(2))
        }

        @Test("Pipeline set then get")
        func testSetThenGet() throws {
            let (_, result) = try Dict().query(
                #"set "name" = "alice" | set "name" = "bob" | get "name""#
            )
            #expect(result == .value("bob"))
        }

        @Test("Pipeline preserves data through transforms")
        func testPipelinePreservesData() throws {
            let (dict, _) = try Dict().query(
                #"insert "x" = "1" | insert "y" = "2" | insert "z" = "3""#
            )
            #expect(dict.count == 3)
            #expect(try dict.get(key: "x") == "1")
            #expect(try dict.get(key: "y") == "2")
            #expect(try dict.get(key: "z") == "3")
        }

        @Test("Long pipeline paginated query")
        func testPaginatedPipeline() throws {
            var q = (0..<20).map { String(format: #"insert "key_%02d" = "v""#, $0) }.joined(separator: " | ")
            q += #" | keys sorted limit 5"#
            let (_, result) = try Dict().query(q)
            #expect(result == .list(["key_00", "key_01", "key_02", "key_03", "key_04"]))
        }
    }

    @Suite("MerkleSet Queries")
    struct MerkleSetQueryTests {

        @Test("Insert and contains on set")
        func testSetInsertContains() throws {
            let (set, _) = try MerkleSetImpl().query(
                #"insert "alice" = "" | insert "bob" = """#
            )
            let (_, result) = try set.query(#"contains "alice""#)
            #expect(result == .bool(true))
        }

        @Test("Members via keys sorted")
        func testSetMembers() throws {
            let set = try MerkleSetImpl().insert("cherry").insert("apple").insert("banana")
            let (_, result) = try set.query("keys sorted")
            #expect(result == .list(["apple", "banana", "cherry"]))
        }

        @Test("Delete from set")
        func testSetDelete() throws {
            let set = try MerkleSetImpl().insert("a").insert("b").insert("c")
            let (updated, _) = try set.query(#"delete "b""#)
            #expect(updated.count == 2)
            let (_, result) = try updated.query(#"contains "b""#)
            #expect(result == .bool(false))
        }
    }

    @Suite("MerkleArray Queries")
    struct MerkleArrayQueryTests {

        @Test("Append and get at index")
        func testAppendAndGetAt() throws {
            let (arr, _) = try Arr().query(#"append "hello" | append "world""#)
            let (_, result) = try arr.query("get at 0")
            #expect(result == .value("hello"))
            let (_, result2) = try arr.query("get at 1")
            #expect(result2 == .value("world"))
        }

        @Test("First and last")
        func testFirstLast() throws {
            let arr = try Arr().append("alpha").append("beta").append("gamma")
            let (_, first) = try arr.query("first")
            #expect(first == .value("alpha"))
            let (_, last) = try arr.query("last")
            #expect(last == .value("gamma"))
        }

        @Test("Count on array")
        func testArrayCount() throws {
            let arr = try Arr().append("a").append("b").append("c")
            let (_, result) = try arr.query("count")
            #expect(result == .count(3))
        }

        @Test("Append pipeline then count")
        func testAppendPipelineCount() throws {
            let (_, result) = try Arr().query(
                #"append "x" | append "y" | append "z" | count"#
            )
            #expect(result == .count(3))
        }

        @Test("Array operations throw on dictionary")
        func testArrayOpsOnDict() {
            let dict = Dict()
            #expect(throws: CashewQueryError.self) {
                try dict.query("get at 0")
            }
            #expect(throws: CashewQueryError.self) {
                try dict.query("first")
            }
            #expect(throws: CashewQueryError.self) {
                try dict.query(#"append "x""#)
            }
        }
    }

    @Suite("Error Handling")
    struct ErrorHandlingTests {

        @Test("Insert duplicate key throws")
        func testInsertDuplicate() {
            let dict = try! Dict().inserting(key: "alice", value: "1")
            #expect(throws: (any Error).self) {
                try dict.query(#"insert "alice" = "2""#)
            }
        }

        @Test("Update missing key throws")
        func testUpdateMissing() {
            #expect(throws: (any Error).self) {
                try Dict().query(#"update "missing" = "value""#)
            }
        }

        @Test("Delete missing key throws")
        func testDeleteMissing() {
            #expect(throws: (any Error).self) {
                try Dict().query(#"delete "missing""#)
            }
        }
    }

    @Suite("Result Description")
    struct ResultDescriptionTests {

        @Test("Result descriptions are human-readable")
        func testDescriptions() {
            #expect(CashewResult.value("hello").description == "hello")
            #expect(CashewResult.value(nil).description == "nil")
            #expect(CashewResult.bool(true).description == "true")
            #expect(CashewResult.count(42).description == "42")
            #expect(CashewResult.list(["a", "b"]).description == "a\nb")
            #expect(CashewResult.ok.description == "ok")
            #expect(CashewResult.entries([(key: "a", value: "1")]).description == "a: 1")
        }
    }

    @Suite("Plan Compilation")
    struct PlanCompilationTests {

        @Test("Consecutive inserts batch into one transform step")
        func testBatchInserts() throws {
            let exprs = try CashewParser.parse(
                #"insert "a" = "1" | insert "b" = "2" | insert "c" = "3""#
            )
            let plan = CashewPlan.compile(exprs)
            #expect(plan.steps.count == 1)
            if case .transform(let trie) = plan.steps[0] {
                #expect(trie.get(["a"]) == .insert("1"))
                #expect(trie.get(["b"]) == .insert("2"))
                #expect(trie.get(["c"]) == .insert("3"))
            } else {
                Issue.record("Expected .transform step")
            }
        }

        @Test("Mixed insert/update/delete batch into one step")
        func testBatchMixed() throws {
            let exprs = try CashewParser.parse(
                #"insert "a" = "1" | update "b" = "2" | delete "c""#
            )
            let plan = CashewPlan.compile(exprs)
            #expect(plan.steps.count == 1)
            if case .transform(let trie) = plan.steps[0] {
                #expect(trie.get(["a"]) == .insert("1"))
                #expect(trie.get(["b"]) == .update("2"))
                #expect(trie.get(["c"]) == .delete)
            } else {
                Issue.record("Expected .transform step")
            }
        }

        @Test("Read flushes pending transforms into separate steps")
        func testReadFlushes() throws {
            let exprs = try CashewParser.parse(
                #"insert "a" = "1" | insert "b" = "2" | keys sorted"#
            )
            let plan = CashewPlan.compile(exprs)
            #expect(plan.steps.count == 2)
            if case .transform = plan.steps[0] {} else {
                Issue.record("Expected .transform as first step")
            }
            if case .evaluate(.sortedKeys) = plan.steps[1] {} else {
                Issue.record("Expected .evaluate(.sortedKeys) as second step")
            }
        }

        @Test("Same key used twice splits into two transform batches")
        func testConflictingSplits() throws {
            let exprs = try CashewParser.parse(
                #"insert "a" = "1" | insert "b" = "2" | delete "a""#
            )
            let plan = CashewPlan.compile(exprs)
            #expect(plan.steps.count == 2)
            if case .transform(let t1) = plan.steps[0] {
                #expect(t1.get(["a"]) == .insert("1"))
                #expect(t1.get(["b"]) == .insert("2"))
            } else {
                Issue.record("Expected first .transform step")
            }
            if case .transform(let t2) = plan.steps[1] {
                #expect(t2.get(["a"]) == .delete)
            } else {
                Issue.record("Expected second .transform step")
            }
        }

        @Test("Set flushes pending transforms and becomes evaluate step")
        func testSetFlushesBatch() throws {
            let exprs = try CashewParser.parse(
                #"insert "a" = "1" | set "b" = "2""#
            )
            let plan = CashewPlan.compile(exprs)
            #expect(plan.steps.count == 2)
            if case .transform = plan.steps[0] {} else {
                Issue.record("Expected .transform step")
            }
            if case .evaluate(.set(let key, let value)) = plan.steps[1] {
                #expect(key == "b")
                #expect(value == "2")
            } else {
                Issue.record("Expected .evaluate(.set) step")
            }
        }

        @Test("Pure reads produce only evaluate steps")
        func testPureReads() throws {
            let exprs = try CashewParser.parse(#"count | keys sorted | get "x""#)
            let plan = CashewPlan.compile(exprs)
            #expect(plan.steps.count == 3)
            for step in plan.steps {
                if case .evaluate = step {} else {
                    Issue.record("Expected all steps to be .evaluate")
                }
            }
        }
    }

    @Suite("Resolution Paths")
    struct ResolutionPathTests {

        @Test("get builds targeted resolution path")
        func testGetResolutionPath() throws {
            let exprs = try CashewParser.parse(#"get "alice""#)
            let plan = CashewPlan.compile(exprs)
            let paths = plan.resolutionPaths()
            #expect(paths.get(["alice"]) == .targeted)
        }

        @Test("contains builds targeted resolution path")
        func testContainsResolutionPath() throws {
            let exprs = try CashewParser.parse(#"contains "key""#)
            let plan = CashewPlan.compile(exprs)
            let paths = plan.resolutionPaths()
            #expect(paths.get(["key"]) == .targeted)
        }

        @Test("keys sorted builds recursive resolution")
        func testKeysSortedResolution() throws {
            let exprs = try CashewParser.parse("keys sorted")
            let plan = CashewPlan.compile(exprs)
            let paths = plan.resolutionPaths()
            #expect(paths.get([""]) == .recursive)
        }

        @Test("count builds list resolution")
        func testCountResolution() throws {
            let exprs = try CashewParser.parse("count")
            let plan = CashewPlan.compile(exprs)
            let paths = plan.resolutionPaths()
            #expect(paths.get([""]) == .list)
        }

        @Test("setKey builds targeted resolution for key existence check")
        func testSetKeyResolution() throws {
            let exprs = try CashewParser.parse(#"set "mykey" = "val""#)
            let plan = CashewPlan.compile(exprs)
            let paths = plan.resolutionPaths()
            #expect(paths.get(["mykey"]) == .targeted)
        }

        @Test("Multiple reads merge resolution paths")
        func testMergedResolution() throws {
            let exprs = try CashewParser.parse(#"get "a" | get "b" | contains "c""#)
            let plan = CashewPlan.compile(exprs)
            let paths = plan.resolutionPaths()
            #expect(paths.get(["a"]) == .targeted)
            #expect(paths.get(["b"]) == .targeted)
            #expect(paths.get(["c"]) == .targeted)
        }

        @Test("Transform-only pipeline produces empty resolution paths")
        func testTransformOnlyNoResolution() throws {
            let exprs = try CashewParser.parse(
                #"insert "a" = "1" | insert "b" = "2""#
            )
            let plan = CashewPlan.compile(exprs)
            let paths = plan.resolutionPaths()
            #expect(paths.get(["a"]) == nil)
            #expect(paths.get(["b"]) == nil)
        }
    }

    @Suite("Async Query with Resolution")
    struct AsyncQueryTests {

        @Test("Async query resolves then reads")
        func testAsyncQueryResolve() async throws {
            let dict = try Dict()
                .inserting(key: "alice", value: "engineer")
                .inserting(key: "bob", value: "designer")

            let store = TestStoreFetcher()
            let header = try HeaderImpl(node: dict)
            try await header.storeAsVolume(storer: store)

            let unresolved = HeaderImpl<Dict>(rawCID: header.rawCID)
            let resolvedHeader = try await unresolved.resolveRecursive(fetcher: store)
            let resolvedDict = resolvedHeader.node!

            let (_, result) = try await resolvedDict.query(#"get "alice""#, fetcher: store)
            #expect(result == .value("engineer"))
        }

        @Test("Async query with pipeline: transforms then read")
        func testAsyncPipelineTransformRead() async throws {
            let dict = try Dict()
                .inserting(key: "existing", value: "old")

            let store = TestStoreFetcher()
            let header = try HeaderImpl(node: dict)
            try await header.storeAsVolume(storer: store)

            let resolved = try await HeaderImpl<Dict>(rawCID: header.rawCID)
                .resolveRecursive(fetcher: store).node!

            let (updated, result) = try await resolved.query(
                #"insert "new" = "fresh" | keys sorted"#,
                fetcher: store
            )
            #expect(result == .list(["existing", "new"]))
            #expect(updated.count == 2)
        }
    }

    @Suite("Batched Transform Correctness")
    struct BatchedTransformTests {

        @Test("Batched inserts produce same result as sequential inserts")
        func testBatchedMatchesSequential() throws {
            let sequential = try Dict()
                .inserting(key: "a", value: "1")
                .inserting(key: "b", value: "2")
                .inserting(key: "c", value: "3")

            let (batched, _) = try Dict().query(
                #"insert "a" = "1" | insert "b" = "2" | insert "c" = "3""#
            )

            #expect(batched.count == sequential.count)
            #expect(try batched.get(key: "a") == "1")
            #expect(try batched.get(key: "b") == "2")
            #expect(try batched.get(key: "c") == "3")
            #expect(try HeaderImpl(node: batched).rawCID == (try HeaderImpl(node: sequential).rawCID))
        }

        @Test("Batched transforms produce same CID as manual ArrayTrie transform")
        func testBatchedMatchesArrayTrie() throws {
            let dict = try Dict()
                .inserting(key: "a", value: "old_a")
                .inserting(key: "b", value: "old_b")
                .inserting(key: "c", value: "old_c")

            var trie = ArrayTrie<Transform>()
            trie.set(["a"], value: .update("new_a"))
            trie.set(["b"], value: .delete)
            let manual = try dict.transform(transforms: trie)!

            let (queried, _) = try dict.query(
                #"update "a" = "new_a" | delete "b""#
            )

            #expect(try HeaderImpl(node: queried).rawCID == (try HeaderImpl(node: manual).rawCID))
        }

        @Test("20 inserts batch into single transform step")
        func testLargeBatch() throws {
            let exprs = (0..<20).map {
                CashewExpression.insert(key: "key_\($0)", value: "val_\($0)")
            }
            let plan = CashewPlan.compile(exprs)
            #expect(plan.steps.count == 1)

            let dict = Dict()
            let (result, _) = try dict.execute(plan: plan)
            #expect(result.count == 20)
        }
    }

    @Suite("Multi-Round Dictionary Workflows")
    struct MultiRoundDictionaryTests {

        @Test("Build a user directory over multiple rounds")
        func testUserDirectory() throws {
            let (d1, _) = try Dict().query(
                #"insert "alice" = "engineer" | insert "bob" = "designer" | insert "carol" = "manager""#
            )
            #expect(d1.count == 3)

            let (d2, _) = try d1.query(#"update "alice" = "senior engineer" | insert "dave" = "intern""#)
            #expect(d2.count == 4)
            #expect(try d2.get(key: "alice") == "senior engineer")

            let (d3, result) = try d2.query(#"delete "bob" | keys sorted"#)
            #expect(result == .list(["alice", "carol", "dave"]))
            #expect(d3.count == 3)

            let (_, lookup) = try d3.query(#"get "carol""#)
            #expect(lookup == .value("manager"))
        }

        @Test("Repeated set on same key across rounds")
        func testRepeatedSet() throws {
            let (d1, _) = try Dict().query(#"set "counter" = "0""#)
            let (d2, _) = try d1.query(#"set "counter" = "1""#)
            let (d3, _) = try d2.query(#"set "counter" = "2""#)
            let (_, result) = try d3.query(#"get "counter""#)
            #expect(result == .value("2"))
            #expect(d3.count == 1)
        }

        @Test("Interleaved transforms and reads across multiple queries")
        func testInterleavedTransformsReads() throws {
            let (d1, r1) = try Dict().query(
                #"insert "a" = "1" | insert "b" = "2" | count"#
            )
            #expect(r1 == .count(2))

            let (d2, r2) = try d1.query(
                #"insert "c" = "3" | delete "a" | keys sorted"#
            )
            #expect(r2 == .list(["b", "c"]))

            let (d3, r3) = try d2.query(
                #"update "b" = "20" | insert "d" = "4" | values sorted"#
            )
            #expect(r3 == .entries([
                (key: "b", value: "20"),
                (key: "c", value: "3"),
                (key: "d", value: "4")
            ]))
            #expect(d3.count == 3)
        }

        @Test("CID changes with each mutation round")
        func testCIDEvolution() throws {
            let d0 = Dict()
            let (d1, _) = try d0.query(#"insert "x" = "1""#)
            let (d2, _) = try d1.query(#"insert "y" = "2""#)
            let (d3, _) = try d2.query(#"delete "x""#)

            let cid0 = try HeaderImpl(node: d0).rawCID
            let cid1 = try HeaderImpl(node: d1).rawCID
            let cid2 = try HeaderImpl(node: d2).rawCID
            let cid3 = try HeaderImpl(node: d3).rawCID

            #expect(cid0 != cid1)
            #expect(cid1 != cid2)
            #expect(cid2 != cid3)
        }

        @Test("Paginated cursor across multiple query rounds")
        func testPaginatedCursor() throws {
            let insertParts = (0..<26).map { i -> String in
                let letter = String(UnicodeScalar(UInt8(65 + i)))
                return #"insert "\#(letter)" = "\#(i)""#
            }
            let (dict, _) = try Dict().query(insertParts.joined(separator: " | "))
            #expect(dict.count == 26)

            let (_, page1) = try dict.query("keys sorted limit 10")
            guard case .list(let p1) = page1 else { Issue.record("Expected list"); return }
            #expect(p1.count == 10)
            #expect(p1.first == "A")

            let lastKey = p1.last!
            let (_, page2) = try dict.query(#"keys sorted limit 10 after "\#(lastKey)""#)
            guard case .list(let p2) = page2 else { Issue.record("Expected list"); return }
            #expect(p2.count == 10)
            #expect(p2.first! > lastKey)

            let lastKey2 = p2.last!
            let (_, page3) = try dict.query(#"keys sorted limit 10 after "\#(lastKey2)""#)
            guard case .list(let p3) = page3 else { Issue.record("Expected list"); return }
            #expect(p3.count == 6)

            let all = p1 + p2 + p3
            #expect(all.count == 26)
            #expect(all == all.sorted())
        }

        @Test("Large pipeline: 50 inserts, selective deletes, then query")
        func testLargePipeline() throws {
            let inserts = (0..<50).map { i in
                #"insert "item_\#(String(format: "%02d", i))" = "\#(i)""#
            }.joined(separator: " | ")
            let (d1, _) = try Dict().query(inserts)
            #expect(d1.count == 50)

            let deletes = stride(from: 0, to: 50, by: 2).map { i in
                #"delete "item_\#(String(format: "%02d", i))""#
            }.joined(separator: " | ")
            let (d2, _) = try d1.query(deletes)
            #expect(d2.count == 25)

            let (_, result) = try d2.query("keys sorted limit 5")
            guard case .list(let keys) = result else { Issue.record("Expected list"); return }
            #expect(keys == ["item_01", "item_03", "item_05", "item_07", "item_09"])
        }
    }

    @Suite("Multi-Round MerkleArray Workflows")
    struct MultiRoundArrayTests {

        @Test("Build array over multiple rounds, verify order")
        func testArrayBuildUp() throws {
            let (a1, _) = try Arr().query(#"append "first" | append "second""#)
            let (a2, _) = try a1.query(#"append "third""#)
            let (a3, _) = try a2.query(#"append "fourth" | append "fifth""#)

            #expect(a3.count == 5)
            let (_, first) = try a3.query("first")
            #expect(first == .value("first"))
            let (_, last) = try a3.query("last")
            #expect(last == .value("fifth"))

            for i in 0..<5 {
                let (_, val) = try a3.query("get at \(i)")
                let expected = ["first", "second", "third", "fourth", "fifth"][i]
                #expect(val == .value(expected))
            }
        }

        @Test("Array append then count across rounds")
        func testArrayCountAcrossRounds() throws {
            let (a1, r1) = try Arr().query(#"append "a" | append "b" | count"#)
            #expect(r1 == .count(2))

            let (a2, r2) = try a1.query(#"append "c" | append "d" | append "e" | count"#)
            #expect(r2 == .count(5))

            let (_, r3) = try a2.query("count")
            #expect(r3 == .count(5))
        }

        @Test("Array CID changes with appends")
        func testArrayCIDEvolution() throws {
            let a0 = Arr()
            let (a1, _) = try a0.query(#"append "x""#)
            let (a2, _) = try a1.query(#"append "y""#)

            let cid0 = try HeaderImpl(node: a0).rawCID
            let cid1 = try HeaderImpl(node: a1).rawCID
            let cid2 = try HeaderImpl(node: a2).rawCID

            #expect(cid0 != cid1)
            #expect(cid1 != cid2)
        }
    }

    @Suite("Multi-Round MerkleSet Workflows")
    struct MultiRoundSetTests {

        typealias MSet = MerkleSetImpl

        @Test("Build set over multiple rounds, check membership")
        func testSetBuildUp() throws {
            let (s1, _) = try MSet().query(#"insert "apple" = "" | insert "banana" = """#)
            let (s2, _) = try s1.query(#"insert "cherry" = "" | insert "date" = """#)

            #expect(s2.count == 4)
            let (_, has) = try s2.query(#"contains "cherry""#)
            #expect(has == .bool(true))
            let (_, missing) = try s2.query(#"contains "elderberry""#)
            #expect(missing == .bool(false))
        }

        @Test("Set insert and delete across rounds")
        func testSetInsertDelete() throws {
            let (s1, _) = try MSet().query(
                #"insert "a" = "" | insert "b" = "" | insert "c" = "" | insert "d" = """#
            )
            #expect(s1.count == 4)

            let (s2, _) = try s1.query(#"delete "b" | delete "d""#)
            #expect(s2.count == 2)

            let (_, result) = try s2.query("keys sorted")
            #expect(result == .list(["a", "c"]))
        }

        @Test("Set CID is deterministic regardless of insertion order")
        func testSetCIDDeterminism() throws {
            let (s1, _) = try MSet().query(
                #"insert "x" = "" | insert "y" = "" | insert "z" = """#
            )
            let (s2, _) = try MSet().query(
                #"insert "z" = "" | insert "x" = "" | insert "y" = """#
            )
            #expect(try HeaderImpl(node: s1).rawCID == (try HeaderImpl(node: s2).rawCID))
        }
    }

    @Suite("Content Addressability Through Queries")
    struct ContentAddressabilityTests {

        @Test("Same operations produce same CID regardless of pipeline grouping")
        func testPipelineGroupingInvariance() throws {
            let (d1, _) = try Dict().query(
                #"insert "a" = "1" | insert "b" = "2" | insert "c" = "3""#
            )
            var d2 = Dict()
            (d2, _) = try d2.query(#"insert "a" = "1""#)
            (d2, _) = try d2.query(#"insert "b" = "2""#)
            (d2, _) = try d2.query(#"insert "c" = "3""#)

            #expect(try HeaderImpl(node: d1).rawCID == (try HeaderImpl(node: d2).rawCID))
        }

        @Test("Query via set produces same CID as insert for new key")
        func testSetMatchesInsertForNew() throws {
            let (d1, _) = try Dict().query(#"insert "key" = "val""#)
            let (d2, _) = try Dict().query(#"set "key" = "val""#)
            #expect(try HeaderImpl(node: d1).rawCID == (try HeaderImpl(node: d2).rawCID))
        }

        @Test("Query via set produces same CID as update for existing key")
        func testSetMatchesUpdateForExisting() throws {
            let base = try Dict().inserting(key: "key", value: "old")
            let (d1, _) = try base.query(#"update "key" = "new""#)
            let (d2, _) = try base.query(#"set "key" = "new""#)
            #expect(try HeaderImpl(node: d1).rawCID == (try HeaderImpl(node: d2).rawCID))
        }

        @Test("Delete then re-insert same key/value restores original CID")
        func testDeleteReinsertRestoresCID() throws {
            let (original, _) = try Dict().query(#"insert "a" = "1" | insert "b" = "2""#)
            let cidOriginal = try HeaderImpl(node: original).rawCID

            let (deleted, _) = try original.query(#"delete "b""#)
            let cidDeleted = try HeaderImpl(node: deleted).rawCID
            #expect(cidOriginal != cidDeleted)

            let (restored, _) = try deleted.query(#"insert "b" = "2""#)
            let cidRestored = try HeaderImpl(node: restored).rawCID
            #expect(cidOriginal == cidRestored)
        }
    }

    @Suite("Store Round-Trip with Queries")
    struct StoreRoundTripTests {

        @Test("Store, resolve, then query modified dictionary")
        func testStoreResolveQuery() async throws {
            let (dict, _) = try Dict().query(
                #"insert "name" = "alice" | insert "role" = "engineer" | insert "team" = "platform""#
            )
            let store = TestStoreFetcher()
            let header = try HeaderImpl(node: dict)
            try await header.storeAsVolume(storer: store)

            let resolved = try await HeaderImpl<Dict>(rawCID: header.rawCID)
                .resolveRecursive(fetcher: store).node!

            let (_, result) = try await resolved.query(
                #"update "role" = "lead" | insert "level" = "senior" | keys sorted"#,
                fetcher: store
            )
            #expect(result == .list(["level", "name", "role", "team"]))
        }

        @Test("Multiple store-resolve-query cycles")
        func testMultipleCycles() async throws {
            let store = TestStoreFetcher()

            let (d1, _) = try Dict().query(#"insert "a" = "1" | insert "b" = "2""#)
            let h1 = try HeaderImpl(node: d1)
            try await h1.storeAsVolume(storer: store)

            let r1 = try await HeaderImpl<Dict>(rawCID: h1.rawCID)
                .resolveRecursive(fetcher: store).node!
            let (d2, _) = try r1.query(#"insert "c" = "3" | delete "a""#)

            let h2 = try HeaderImpl(node: d2)
            try await h2.storeAsVolume(storer: store)

            let r2 = try await HeaderImpl<Dict>(rawCID: h2.rawCID)
                .resolveRecursive(fetcher: store).node!
            let (_, result) = try r2.query("keys sorted")
            #expect(result == .list(["b", "c"]))
        }
    }
}

@Suite("Query on All Data Structure Types")
struct QueryAllTypesTests {

    typealias Dict = MerkleDictionaryImpl<String>
    typealias Arr = MerkleArrayImpl<String>
    typealias Set_ = MerkleSetImpl

    @Suite("MerkleSet Queries")
    struct MerkleSetQueryTests {

        @Test("Set: keys returns members")
        func testSetKeys() throws {
            let set = try MerkleSetImpl().insert("alice").insert("bob").insert("carol")
            let (_, result) = try set.query("keys sorted")
            #expect(result == .list(["alice", "bob", "carol"]))
        }

        @Test("Set: count returns member count")
        func testSetCount() throws {
            let set = try MerkleSetImpl().insert("x").insert("y").insert("z")
            let (_, result) = try set.query("count")
            #expect(result == .count(3))
        }

        @Test("Set: contains checks membership")
        func testSetContains() throws {
            let set = try MerkleSetImpl().insert("alice").insert("bob")
            let (_, yes) = try set.query(#"contains "alice""#)
            let (_, no) = try set.query(#"contains "eve""#)
            #expect(yes == .bool(true))
            #expect(no == .bool(false))
        }

        @Test("Set: delete removes a member")
        func testSetDelete() throws {
            let set = try MerkleSetImpl().insert("a").insert("b").insert("c")
            let (updated, _) = try set.query(#"delete "b""#)
            let (_, result) = try updated.query("keys sorted")
            #expect(result == .list(["a", "c"]))
        }

        @Test("Set: insert via set command adds member")
        func testSetInsert() throws {
            let set = try MerkleSetImpl().insert("a")
            let (updated, _) = try set.query(#"insert "b" = """#)
            #expect(updated.count == 2)
            #expect(try updated.contains("b"))
        }

        @Test("Set: pipeline insert then keys sorted")
        func testSetPipeline() throws {
            let (_, result) = try MerkleSetImpl().query(
                #"insert "cherry" = "" | insert "apple" = "" | insert "banana" = "" | keys sorted"#
            )
            #expect(result == .list(["apple", "banana", "cherry"]))
        }
    }

    @Suite("Header Queries on Dictionary")
    struct HeaderDictQueryTests {

        @Test("Header wrapping dict: query keys")
        func testHeaderDictKeys() throws {
            let dict = try Dict()
                .inserting(key: "x", value: "1")
                .inserting(key: "y", value: "2")
            let header = try HeaderImpl(node: dict)
            let (_, result) = try header.query("keys sorted")
            #expect(result == .list(["x", "y"]))
        }

        @Test("Header wrapping dict: get value")
        func testHeaderDictGet() throws {
            let dict = try Dict().inserting(key: "name", value: "alice")
            let header = try HeaderImpl(node: dict)
            let (_, result) = try header.query(#"get "name""#)
            #expect(result == .value("alice"))
        }

        @Test("Header wrapping dict: transform updates CID")
        func testHeaderDictTransform() throws {
            let dict = try Dict().inserting(key: "a", value: "1")
            let original = try HeaderImpl(node: dict)
            let (updated, _) = try original.query(#"insert "b" = "2""#)
            #expect(updated.rawCID != original.rawCID)
            #expect(updated.node!.count == 2)
        }

        @Test("Header wrapping dict: async query with fetcher")
        func testHeaderDictAsync() async throws {
            let dict = try Dict()
                .inserting(key: "alpha", value: "first")
                .inserting(key: "beta", value: "second")
            let header = try HeaderImpl(node: dict)
            let store = TestStoreFetcher()
            try await header.storeAsVolume(storer: store)

            let unresolved = HeaderImpl<Dict>(rawCID: header.rawCID)
            let (resolved, result) = try await unresolved.query(#"get "alpha""#, fetcher: store)
            #expect(result == .value("first"))
            #expect(resolved.node != nil)
        }
    }

    @Suite("Header Queries on Array")
    struct HeaderArrayQueryTests {

        @Test("Header wrapping array: get at index")
        func testHeaderArrayGetAt() throws {
            let arr = try Arr().append("zero").append("one").append("two")
            let header = try HeaderImpl(node: arr)
            let (_, result) = try header.query("get at 1")
            #expect(result == .value("one"))
        }

        @Test("Header wrapping array: first and last")
        func testHeaderArrayFirstLast() throws {
            let arr = try Arr().append("a").append("b").append("c")
            let header = try HeaderImpl(node: arr)
            let (_, first) = try header.query("first")
            let (_, last) = try header.query("last")
            #expect(first == .value("a"))
            #expect(last == .value("c"))
        }

        @Test("Header wrapping array: count")
        func testHeaderArrayCount() throws {
            let arr = try Arr().append("x").append("y")
            let header = try HeaderImpl(node: arr)
            let (_, result) = try header.query("count")
            #expect(result == .count(2))
        }

        @Test("Header wrapping array: append via query")
        func testHeaderArrayAppend() throws {
            let arr = try Arr().append("a")
            let header = try HeaderImpl(node: arr)
            let (updated, _) = try header.query(#"append "b""#)
            #expect(updated.node!.count == 2)
            let (_, result) = try updated.query("last")
            #expect(result == .value("b"))
        }

        @Test("Header wrapping array: async query with fetcher")
        func testHeaderArrayAsync() async throws {
            let arr = try Arr().append("p").append("q").append("r")
            let header = try HeaderImpl(node: arr)
            let store = TestStoreFetcher()
            try await header.storeAsVolume(storer: store)

            let unresolved = HeaderImpl<Arr>(rawCID: header.rawCID)
            let (_, result) = try await unresolved.query("get at 2", fetcher: store)
            #expect(result == .value("r"))
        }
    }

    @Suite("Header Queries on Set")
    struct HeaderSetQueryTests {

        @Test("Header wrapping set: keys and count")
        func testHeaderSetKeysCount() throws {
            let set = try MerkleSetImpl().insert("red").insert("green").insert("blue")
            let header = try HeaderImpl(node: set)
            let (_, keys) = try header.query("keys sorted")
            let (_, count) = try header.query("count")
            #expect(keys == .list(["blue", "green", "red"]))
            #expect(count == .count(3))
        }

        @Test("Header wrapping set: contains and delete")
        func testHeaderSetContainsDelete() throws {
            let set = try MerkleSetImpl().insert("a").insert("b").insert("c")
            let header = try HeaderImpl(node: set)
            let (_, yes) = try header.query(#"contains "b""#)
            #expect(yes == .bool(true))
            let (updated, _) = try header.query(#"delete "b""#)
            let (_, no) = try updated.query(#"contains "b""#)
            #expect(no == .bool(false))
        }
    }

    @Suite("Nested Data Structure Queries")
    struct NestedQueryTests {

        typealias InnerDict = MerkleDictionaryImpl<String>
        typealias DictOfDicts = MerkleDictionaryImpl<HeaderImpl<InnerDict>>
        typealias ArrayOfDicts = MerkleArrayImpl<HeaderImpl<InnerDict>>
        typealias InnerArray = MerkleArrayImpl<String>
        typealias DictOfArrays = MerkleDictionaryImpl<HeaderImpl<InnerArray>>
        typealias ArrayOfArrays = MerkleArrayImpl<HeaderImpl<InnerArray>>

        @Test("Dict of dicts: outer query returns header CIDs")
        func testDictOfDictsOuterQuery() throws {
            let inner1 = try InnerDict().inserting(key: "name", value: "alice")
            let inner2 = try InnerDict().inserting(key: "name", value: "bob")
            let h1 = try HeaderImpl(node: inner1)
            let h2 = try HeaderImpl(node: inner2)

            let outer = try DictOfDicts()
                .inserting(key: "user1", value: h1)
                .inserting(key: "user2", value: h2)

            let (_, result) = try outer.query("keys sorted")
            #expect(result == .list(["user1", "user2"]))
            #expect(outer.count == 2)
        }

        @Test("Dict of dicts: get returns queryable child")
        func testDictOfDictsGet() throws {
            let inner = try InnerDict().inserting(key: "role", value: "admin")
            let h = try HeaderImpl(node: inner)
            let outer = try DictOfDicts().inserting(key: "profile", value: h)

            let (_, result) = try outer.query(#"get "profile""#)
            guard case .node(let child) = result else {
                Issue.record("Expected .node with queryable child")
                return
            }
            let innerResult = try child.execute(plan: CashewPlan.compile([.get("role")]))
            #expect(innerResult == .value("admin"))
        }

        @Test("Dict of dicts: pipeline navigates into child")
        func testDictOfDictsPipeline() throws {
            let inner = try InnerDict()
                .inserting(key: "role", value: "admin")
                .inserting(key: "dept", value: "eng")
            let outer = try DictOfDicts()
                .inserting(key: "profile", value: try HeaderImpl(node: inner))

            let (_, countResult) = try outer.query(#"get "profile" | count"#)
            #expect(countResult == .count(2))

            let (_, keysResult) = try outer.query(#"get "profile" | keys sorted"#)
            #expect(keysResult == .list(["dept", "role"]))

            let (_, getResult) = try outer.query(#"get "profile" | get "role""#)
            #expect(getResult == .value("admin"))
        }

        @Test("Dict of dicts: delete inner entry")
        func testDictOfDictsDelete() throws {
            let inner1 = try HeaderImpl(node: try InnerDict().inserting(key: "k", value: "v1"))
            let inner2 = try HeaderImpl(node: try InnerDict().inserting(key: "k", value: "v2"))
            let outer = try DictOfDicts()
                .inserting(key: "a", value: inner1)
                .inserting(key: "b", value: inner2)

            let (updated, _) = try outer.query(#"delete "a""#)
            #expect(updated.count == 1)
            let (_, result) = try updated.query(#"contains "a""#)
            #expect(result == .bool(false))
        }

        @Test("Array of dicts: count and get at index")
        func testArrayOfDictsQuery() throws {
            let d1 = try HeaderImpl(node: try InnerDict().inserting(key: "city", value: "NYC"))
            let d2 = try HeaderImpl(node: try InnerDict().inserting(key: "city", value: "LA"))
            let d3 = try HeaderImpl(node: try InnerDict().inserting(key: "city", value: "SF"))
            let arr = try ArrayOfDicts().append(d1).append(d2).append(d3)

            let (_, count) = try arr.query("count")
            #expect(count == .count(3))

            let (_, first) = try arr.query("first")
            if case .value(let cid) = first {
                #expect(cid == d1.rawCID)
            } else {
                Issue.record("Expected .value with CID")
            }
        }

        @Test("Dict of arrays: outer keys, inner accessible via resolve")
        func testDictOfArraysQuery() throws {
            let a1 = try HeaderImpl(node: try InnerArray().append("x").append("y"))
            let a2 = try HeaderImpl(node: try InnerArray().append("p").append("q").append("r"))
            let dict = try DictOfArrays()
                .inserting(key: "list1", value: a1)
                .inserting(key: "list2", value: a2)

            let (_, keys) = try dict.query("keys sorted")
            #expect(keys == .list(["list1", "list2"]))
            let (_, count) = try dict.query("count")
            #expect(count == .count(2))
        }

        @Test("Array of arrays: nested structure navigable")
        func testArrayOfArraysQuery() throws {
            let a1 = try HeaderImpl(node: try InnerArray().append("a0").append("a1"))
            let a2 = try HeaderImpl(node: try InnerArray().append("b0").append("b1").append("b2"))
            let outer = try ArrayOfArrays().append(a1).append(a2)

            let (_, count) = try outer.query("count")
            #expect(count == .count(2))
            let (_, last) = try outer.query("last")
            if case .value(let cid) = last {
                #expect(cid == a2.rawCID)
            } else {
                Issue.record("Expected .value with CID")
            }
        }

        @Test("Three-level nesting: dict of dict of dicts")
        func testThreeLevelNesting() throws {
            typealias MidDict = MerkleDictionaryImpl<HeaderImpl<InnerDict>>
            typealias OuterDict = MerkleDictionaryImpl<HeaderImpl<MidDict>>

            let leaf1 = try InnerDict().inserting(key: "val", value: "1")
            let leaf2 = try InnerDict().inserting(key: "val", value: "2")
            let mid = try MidDict()
                .inserting(key: "leaf1", value: try HeaderImpl(node: leaf1))
                .inserting(key: "leaf2", value: try HeaderImpl(node: leaf2))
            let outer = try OuterDict()
                .inserting(key: "branch", value: try HeaderImpl(node: mid))

            let (_, outerKeys) = try outer.query("keys")
            if case .list(let keys) = outerKeys {
                #expect(keys.contains("branch"))
            } else {
                Issue.record("Expected .list")
            }

            let innerHeader = try outer.get(key: "branch")!
            let midDict = innerHeader.node!
            let (_, midKeys) = try midDict.query("keys sorted")
            #expect(midKeys == .list(["leaf1", "leaf2"]))

            let leafHeader = try midDict.get(key: "leaf1")!
            let leafDict = leafHeader.node!
            let (_, leafResult) = try leafDict.query(#"get "val""#)
            #expect(leafResult == .value("1"))
        }
    }

    @Suite("Store/Resolve/Query Cycle with Nested Types")
    struct StoreResolveQueryTests {

        typealias InnerDict = MerkleDictionaryImpl<String>
        typealias DictOfDicts = MerkleDictionaryImpl<HeaderImpl<InnerDict>>

        @Test("Dict of dicts: full store, resolve from CID, query")
        func testDictOfDictsStoreResolve() async throws {
            let inner1 = try InnerDict()
                .inserting(key: "name", value: "alice")
                .inserting(key: "role", value: "engineer")
            let inner2 = try InnerDict()
                .inserting(key: "name", value: "bob")
                .inserting(key: "role", value: "designer")
            let outer = try DictOfDicts()
                .inserting(key: "user1", value: try HeaderImpl(node: inner1))
                .inserting(key: "user2", value: try HeaderImpl(node: inner2))

            let store = TestStoreFetcher()
            let header = try HeaderImpl(node: outer)
            try await header.storeAsVolume(storer: store)

            let resolved = try await HeaderImpl<DictOfDicts>(rawCID: header.rawCID)
                .resolveRecursive(fetcher: store)

            let (_, keys) = try resolved.query("keys sorted")
            #expect(keys == .list(["user1", "user2"]))
            #expect(resolved.node!.count == 2)

            let innerHeader = try resolved.node!.get(key: "user1")!
            let innerResolved = try await innerHeader.resolve(fetcher: store)
            let (_, name) = try innerResolved.query(#"get "name""#)
            #expect(name == .value("alice"))
        }

        @Test("Array: store, resolve from CID, query via header")
        func testArrayStoreResolveQuery() async throws {
            typealias Arr = MerkleArrayImpl<String>
            let arr = try Arr().append("first").append("second").append("third")
            let store = TestStoreFetcher()
            let header = try HeaderImpl(node: arr)
            try await header.storeAsVolume(storer: store)

            let unresolved = HeaderImpl<Arr>(rawCID: header.rawCID)
            let (_, result) = try await unresolved.query("get at 1", fetcher: store)
            #expect(result == .value("second"))
        }

        @Test("Set: store, resolve from CID, query via header")
        func testSetStoreResolveQuery() async throws {
            let set = try MerkleSetImpl().insert("red").insert("green").insert("blue")
            let store = TestStoreFetcher()
            let header = try HeaderImpl(node: set)
            try await header.storeAsVolume(storer: store)

            let unresolved = HeaderImpl<MerkleSetImpl>(rawCID: header.rawCID)
            let (_, result) = try await unresolved.query("keys sorted", fetcher: store)
            #expect(result == .list(["blue", "green", "red"]))
        }

        @Test("Nested array of dicts: store, resolve, navigate")
        func testNestedArrayOfDictsStoreResolve() async throws {
            typealias InnerDict = MerkleDictionaryImpl<String>
            typealias ArrOfDicts = MerkleArrayImpl<HeaderImpl<InnerDict>>

            let d1 = try InnerDict()
                .inserting(key: "fruit", value: "apple")
                .inserting(key: "color", value: "red")
            let d2 = try InnerDict()
                .inserting(key: "fruit", value: "banana")
                .inserting(key: "color", value: "yellow")
            let arr = try ArrOfDicts()
                .append(try HeaderImpl(node: d1))
                .append(try HeaderImpl(node: d2))

            let store = TestStoreFetcher()
            let header = try HeaderImpl(node: arr)
            try await header.storeAsVolume(storer: store)

            let resolved = try await HeaderImpl<ArrOfDicts>(rawCID: header.rawCID)
                .resolveRecursive(fetcher: store)
            let (_, count) = try resolved.query("count")
            #expect(count == .count(2))

            let innerHeader = try resolved.node!.get(at: 0)!
            let innerResolved = try await innerHeader.resolve(fetcher: store)
            let (_, fruit) = try await innerResolved.query(#"get "fruit""#, fetcher: store)
            #expect(fruit == .value("apple"))
        }

        @Test("Transform via query then re-store preserves integrity")
        func testTransformRestore() async throws {
            let dict = try InnerDict()
                .inserting(key: "a", value: "1")
                .inserting(key: "b", value: "2")
            let store = TestStoreFetcher()
            let h1 = try HeaderImpl(node: dict)
            try await h1.storeAsVolume(storer: store)

            let (updated, _) = try await HeaderImpl<InnerDict>(rawCID: h1.rawCID)
                .query(#"insert "c" = "3" | delete "a""#, fetcher: store)
            try await updated.storeAsVolume(storer: store)

            let reloaded = try await HeaderImpl<InnerDict>(rawCID: updated.rawCID)
                .resolveRecursive(fetcher: store)
            let (_, result) = try reloaded.query("keys sorted")
            #expect(result == .list(["b", "c"]))
        }

        @Test("Dict of dicts: transform outer then verify inner intact")
        func testNestedTransformIntegrity() async throws {
            let inner1 = try InnerDict().inserting(key: "x", value: "1")
            let inner2 = try InnerDict().inserting(key: "y", value: "2")
            let inner3 = try InnerDict().inserting(key: "z", value: "3")
            let outer = try DictOfDicts()
                .inserting(key: "a", value: try HeaderImpl(node: inner1))
                .inserting(key: "b", value: try HeaderImpl(node: inner2))

            let store = TestStoreFetcher()
            let h = try HeaderImpl(node: outer)
            try await h.storeAsVolume(storer: store)
            try await HeaderImpl(node: inner3).storeAsVolume(storer: store)

            let resolved = try await HeaderImpl<DictOfDicts>(rawCID: h.rawCID)
                .resolveRecursive(fetcher: store)

            let h3Cid = try HeaderImpl(node: inner3).rawCID
            let (updated, _) = try resolved.query(
                #"delete "a" | set "c" = "\#(h3Cid)""#
            )
            #expect(updated.node!.count == 2)

            let (_, keys) = try updated.query("keys sorted")
            #expect(keys == .list(["b", "c"]))

            let bHeader = try updated.node!.get(key: "b")!
            let bResolved = try await bHeader.resolve(fetcher: store)
            let (_, yVal) = try await bResolved.query(#"get "y""#, fetcher: store)
            #expect(yVal == .value("2"))
        }
    }

    // MARK: - Custom Node Queries
    //
    // Domain model — an org chart with three levels of custom nodes:
    //
    //   Org (custom Node)
    //    └─ departments: [name → Header<Team>]
    //         └─ Team (custom Node)
    //              └─ members: [name → Header<MerkleDictionaryImpl<String>>]  (profiles)
    //
    // Queries can drill through all three levels automatically:
    //   get "eng" | get "alice" | get "role"  →  .value("lead")

    struct Team: Node, Sendable {
        var members: [String: HeaderImpl<MerkleDictionaryImpl<String>>] = [:]

        func properties() -> Set<String> { Set(members.keys) }
        func get(property: String) -> (any Header)? { members[property] }
        func set(properties: [String: any Header]) -> Team {
            var copy = self
            for (k, v) in properties { copy.members[k] = v as? HeaderImpl<MerkleDictionaryImpl<String>> }
            return copy
        }

        func toData() -> Data? { nil }
        init?(data: Data) { nil }
        init(members: [String: HeaderImpl<MerkleDictionaryImpl<String>>] = [:]) { self.members = members }
    }

    struct Org: Node, Sendable {
        var departments: [String: HeaderImpl<Team>] = [:]

        func properties() -> Set<String> { Set(departments.keys) }
        func get(property: String) -> (any Header)? { departments[property] }
        func set(properties: [String: any Header]) -> Org {
            var copy = self
            for (k, v) in properties { copy.departments[k] = v as? HeaderImpl<Team> }
            return copy
        }

        func toData() -> Data? { nil }
        init?(data: Data) { nil }
        init(departments: [String: HeaderImpl<Team>] = [:]) { self.departments = departments }
    }

    static func profile(_ kvs: (String, String)...) throws -> HeaderImpl<MerkleDictionaryImpl<String>> {
        var dict = MerkleDictionaryImpl<String>()
        for (k, v) in kvs { dict = try dict.inserting(key: k, value: v) }
        return try HeaderImpl(node: dict)
    }

    static func sampleOrg() throws -> Org {
        let eng = Team(members: [
            "alice": try profile(("role", "lead"), ("level", "senior")),
            "bob":   try profile(("role", "ic"), ("level", "mid")),
        ])
        let design = Team(members: [
            "carol": try profile(("role", "lead"), ("level", "senior")),
            "dave":  try profile(("role", "ic"), ("level", "junior")),
            "eve":   try profile(("role", "ic"), ("level", "mid")),
        ])
        return Org(departments: [
            "eng":    try HeaderImpl(node: eng),
            "design": try HeaderImpl(node: design),
        ])
    }

    @Suite("Custom Node Queries")
    struct CustomNodeTests {

        @Test("Three-level pipeline: org → team → profile field")
        func testDeepPipeline() throws {
            let org = try sampleOrg()
            let (_, role) = try org.query(#"get "eng" | get "alice" | get "role""#)
            #expect(role == .value("lead"))

            let (_, level) = try org.query(#"get "design" | get "dave" | get "level""#)
            #expect(level == .value("junior"))
        }

        @Test("Pipeline queries at each level of the hierarchy")
        func testEachLevel() throws {
            let org = try sampleOrg()

            let (_, depts) = try org.query("keys sorted")
            #expect(depts == .list(["design", "eng"]))

            let (_, members) = try org.query(#"get "design" | keys sorted"#)
            #expect(members == .list(["carol", "dave", "eve"]))

            let (_, fields) = try org.query(#"get "eng" | get "bob" | keys sorted"#)
            #expect(fields == .list(["level", "role"]))
        }

        @Test("Count at each level")
        func testCountAtEachLevel() throws {
            let org = try sampleOrg()

            let (_, orgCount) = try org.query("count")
            #expect(orgCount == .count(2))

            let (_, teamCount) = try org.query(#"get "design" | count"#)
            #expect(teamCount == .count(3))

            let (_, profileCount) = try org.query(#"get "eng" | get "alice" | count"#)
            #expect(profileCount == .count(2))
        }

        @Test("Contains checks at different levels")
        func testContainsMultiLevel() throws {
            let org = try sampleOrg()

            let (_, hasDept) = try org.query(#"contains "eng""#)
            #expect(hasDept == .bool(true))

            let (_, hasMember) = try org.query(#"get "eng" | contains "alice""#)
            #expect(hasMember == .bool(true))

            let (_, noMember) = try org.query(#"get "eng" | contains "carol""#)
            #expect(noMember == .bool(false))
        }

        @Test("Paginated keys on a team")
        func testPaginatedKeys() throws {
            let org = try sampleOrg()

            let (_, first2) = try org.query(#"get "design" | keys sorted limit 2"#)
            #expect(first2 == .list(["carol", "dave"]))

            let (_, afterD) = try org.query(#"get "design" | keys sorted after "dave""#)
            #expect(afterD == .list(["eve"]))
        }

        @Test("Pipeline works even when evaluate is overridden")
        func testPipelineBypassesCustomEvaluate() throws {
            struct CustomOrg: Node, Sendable {
                var departments: [String: HeaderImpl<Team>] = [:]
                func properties() -> Set<String> { Set(departments.keys) }
                func get(property: String) -> (any Header)? { departments[property] }
                func set(properties: [String: any Header]) -> CustomOrg {
                    var copy = self
                    for (k, v) in properties { copy.departments[k] = v as? HeaderImpl<Team> }
                    return copy
                }

                func evaluate(_ expression: CashewExpression) throws -> (CustomOrg, CashewResult) {
                    switch expression {
                    case .count:
                        return (self, .value("\(departments.count) departments"))
                    default:
                        return try defaultEvaluate(expression)
                    }
                }

                func toData() -> Data? { nil }
                init?(data: Data) { nil }
                init(departments: [String: HeaderImpl<Team>]) { self.departments = departments }
            }

            let base = try sampleOrg()
            let custom = CustomOrg(departments: base.departments)

            let (_, count) = try custom.query("count")
            #expect(count == .value("2 departments"))

            let (_, role) = try custom.query(#"get "eng" | get "alice" | get "role""#)
            #expect(role == .value("lead"))
        }

        @Test("Header wrapping a custom node delegates queries through")
        func testHeaderDelegation() throws {
            let org = try sampleOrg()
            let header = try HeaderImpl(node: org)

            let (_, depts) = try header.query("keys sorted")
            #expect(depts == .list(["design", "eng"]))

            let (_, role) = try header.query(#"get "eng" | get "bob" | get "role""#)
            #expect(role == .value("ic"))
        }

        @Test("Missing key at any level returns nil")
        func testMissingKeys() throws {
            let org = try sampleOrg()

            let (_, noDept) = try org.query(#"get "sales""#)
            #expect(noDept == .value(nil))

            let (_, noMember) = try org.query(#"get "eng" | get "zach""#)
            #expect(noMember == .value(nil))
        }
    }

    @Suite("Exploring a Server Fleet")
    struct FleetExplorationTests {

        // A sysadmin's mental model of their infrastructure:
        //
        //   Fleet
        //    ├─ web-1  →  Server
        //    │              ├─ nginx   →  { port: "443", status: "healthy", version: "1.25" }
        //    │              └─ app     →  { port: "8080", status: "healthy", version: "3.1.0" }
        //    ├─ web-2  →  Server
        //    │              ├─ nginx   →  { port: "443", status: "degraded", version: "1.24" }
        //    │              └─ app     →  { port: "8080", status: "healthy", version: "3.0.9" }
        //    ├─ db-1   →  Server
        //    │              └─ postgres → { port: "5432", status: "healthy", version: "16.2", role: "primary" }
        //    └─ db-2   →  Server
        //                   └─ postgres → { port: "5432", status: "healthy", version: "16.2", role: "replica" }

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

        static func config(_ kvs: (String, String)...) throws -> HeaderImpl<ServiceConfig> {
            var dict = ServiceConfig()
            for (k, v) in kvs { dict = try dict.inserting(key: k, value: v) }
            return try HeaderImpl(node: dict)
        }

        static func fleet() throws -> Fleet {
            let web1 = Server(services: [
                "nginx": try config(("port", "443"), ("status", "healthy"), ("version", "1.25")),
                "app":   try config(("port", "8080"), ("status", "healthy"), ("version", "3.1.0")),
            ])
            let web2 = Server(services: [
                "nginx": try config(("port", "443"), ("status", "degraded"), ("version", "1.24")),
                "app":   try config(("port", "8080"), ("status", "healthy"), ("version", "3.0.9")),
            ])
            let db1 = Server(services: [
                "postgres": try config(("port", "5432"), ("status", "healthy"), ("version", "16.2"), ("role", "primary")),
            ])
            let db2 = Server(services: [
                "postgres": try config(("port", "5432"), ("status", "healthy"), ("version", "16.2"), ("role", "replica")),
            ])
            return Fleet(hosts: [
                "web-1": try HeaderImpl(node: web1),
                "web-2": try HeaderImpl(node: web2),
                "db-1":  try HeaderImpl(node: db1),
                "db-2":  try HeaderImpl(node: db2),
            ])
        }

        @Test("Explore the fleet like a sysadmin would")
        func testExploration() throws {
            let fleet = try Self.fleet()

            // "What hosts do we have?"
            let (_, hosts) = try fleet.query("keys sorted")
            #expect(hosts == .list(["db-1", "db-2", "web-1", "web-2"]))

            // "How many hosts?"
            let (_, hostCount) = try fleet.query("count")
            #expect(hostCount == .count(4))

            // "What services run on web-1?"
            let (_, services) = try fleet.query(#"get "web-1" | keys sorted"#)
            #expect(services == .list(["app", "nginx"]))

            // "What's the nginx config on web-2?"
            let (_, nginxConfig) = try fleet.query(#"get "web-2" | get "nginx" | values sorted"#)
            #expect(nginxConfig == .entries([
                (key: "port", value: "443"),
                (key: "status", value: "degraded"),
                (key: "version", value: "1.24"),
            ]))

            // "Is web-2's nginx degraded?"
            let (_, status) = try fleet.query(#"get "web-2" | get "nginx" | get "status""#)
            #expect(status == .value("degraded"))

            // "What version is the app on web-1?"
            let (_, appVersion) = try fleet.query(#"get "web-1" | get "app" | get "version""#)
            #expect(appVersion == .value("3.1.0"))

            // "Is db-1 the primary?"
            let (_, role) = try fleet.query(#"get "db-1" | get "postgres" | get "role""#)
            #expect(role == .value("primary"))

            // "Does db-2 run postgres?"
            let (_, hasPg) = try fleet.query(#"get "db-2" | contains "postgres""#)
            #expect(hasPg == .bool(true))

            // "Does db-2 run nginx?"
            let (_, hasNginx) = try fleet.query(#"get "db-2" | contains "nginx""#)
            #expect(hasNginx == .bool(false))

            // "Do we have a host called cache-1?"
            let (_, hasCache) = try fleet.query(#"contains "cache-1""#)
            #expect(hasCache == .bool(false))

            // "How many config keys does postgres on db-1 have?"
            let (_, pgKeys) = try fleet.query(#"get "db-1" | get "postgres" | count"#)
            #expect(pgKeys == .count(4))
        }

        @Test("Wrap the fleet in a Header and explore the same way")
        func testHeaderWrapped() throws {
            let header = try HeaderImpl(node: try Self.fleet())

            let (_, hosts) = try header.query("keys sorted")
            #expect(hosts == .list(["db-1", "db-2", "web-1", "web-2"]))

            let (_, version) = try header.query(#"get "web-1" | get "app" | get "version""#)
            #expect(version == .value("3.1.0"))
        }

        @Test("Browse the first two hosts, then paginate to the rest")
        func testPaginatedBrowsing() throws {
            let fleet = try Self.fleet()

            let (_, page1) = try fleet.query("keys sorted limit 2")
            #expect(page1 == .list(["db-1", "db-2"]))

            let (_, page2) = try fleet.query(#"keys sorted limit 2 after "db-2""#)
            #expect(page2 == .list(["web-1", "web-2"]))

            let (_, page3) = try fleet.query(#"keys sorted after "web-2""#)
            #expect(page3 == .list([]))
        }

        @Test("Drill down to find a problem, then fix it at each level")
        func testDrillDownAndFix() throws {
            let fleet = try Self.fleet()

            // Discover the degraded service
            let (_, before) = try fleet.query(#"get "web-2" | get "nginx" | get "status""#)
            #expect(before == .value("degraded"))

            // Fix at the config level, then rebuild upward (immutable tree)
            let nginx = fleet.hosts["web-2"]!.node!.services["nginx"]!.node!
            let (fixedNginx, _) = try nginx.query(#"set "status" = "healthy""#)

            let fixedServer = Server(services: [
                "nginx": try HeaderImpl(node: fixedNginx),
                "app":   fleet.hosts["web-2"]!.node!.services["app"]!,
            ])
            let fixedFleet = Fleet(hosts: fleet.hosts.merging(
                ["web-2": try HeaderImpl(node: fixedServer)]) { _, new in new })

            // Verify the fix, and that other hosts are untouched
            let (_, after) = try fixedFleet.query(#"get "web-2" | get "nginx" | get "status""#)
            #expect(after == .value("healthy"))

            let (_, web1ok) = try fixedFleet.query(#"get "web-1" | get "nginx" | get "status""#)
            #expect(web1ok == .value("healthy"))
        }
    }
}
