import ArrayTrie

public extension Header {
    func resolve(paths: [[String]: ResolutionStrategy], fetcher: Fetcher) async throws -> Self {
        var pathTrie = ArrayTrie<ResolutionStrategy>()
        for (path, strategy) in paths {
            pathTrie.set(path, value: strategy)
        }
        return try await resolve(paths: pathTrie, fetcher: fetcher)
    }

    // MARK: - Base resolution methods (shared by Volume)

    func resolvePaths(_ paths: ArrayTrie<ResolutionStrategy>, fetcher: Fetcher) async throws -> Self {
        if paths.isEmpty && paths.get([]) == nil { return self }
        if let node = node {
            let resolvedNode = try await node.resolve(paths: paths, fetcher: fetcher)
            return Self(rawCID: rawCID, node: resolvedNode, encryptionInfo: encryptionInfo)
        } else {
            let newNode = try await fetchAndDecodeNode(fetcher: fetcher)
            let resolvedNode = try await newNode.resolve(paths: paths, fetcher: fetcher)
            return Self(rawCID: rawCID, node: resolvedNode, encryptionInfo: encryptionInfo)
        }
    }

    func resolveAllNodes(fetcher: Fetcher) async throws -> Self {
        if let node = node {
            let resolvedNode = try await node.resolveRecursive(fetcher: fetcher)
            return Self(rawCID: rawCID, node: resolvedNode, encryptionInfo: encryptionInfo)
        } else {
            let newNode = try await fetchAndDecodeNode(fetcher: fetcher)
            let resolvedNode = try await newNode.resolveRecursive(fetcher: fetcher)
            return Self(rawCID: rawCID, node: resolvedNode, encryptionInfo: encryptionInfo)
        }
    }

    func resolveNode(fetcher: Fetcher) async throws -> Self {
        if node != nil {
            return self
        } else {
            let newNode = try await fetchAndDecodeNode(fetcher: fetcher)
            return Self(rawCID: rawCID, node: newNode, encryptionInfo: encryptionInfo)
        }
    }

    // MARK: - Default resolve implementations

    func resolve(paths: ArrayTrie<ResolutionStrategy>, fetcher: Fetcher) async throws -> Self {
        try await resolvePaths(paths, fetcher: fetcher)
    }

    func resolveRecursive(fetcher: Fetcher) async throws -> Self {
        try await resolveAllNodes(fetcher: fetcher)
    }

    func resolve(fetcher: Fetcher) async throws -> Self {
        try await resolveNode(fetcher: fetcher)
    }

    /// Resolve through `fetcher` and persist each fetched block after CID verification.
    func resolve(
        paths: [[String]: ResolutionStrategy],
        fetcher: any Fetcher,
        cache: any Storer
    ) async throws -> Self {
        try await resolve(
            paths: paths,
            fetcher: CachingFetcher(fetcher: fetcher, storer: cache)
        )
    }

    /// Resolve through `fetcher` and persist each fetched block after CID verification.
    func resolve(
        paths: ArrayTrie<ResolutionStrategy>,
        fetcher: any Fetcher,
        cache: any Storer
    ) async throws -> Self {
        try await resolve(
            paths: paths,
            fetcher: CachingFetcher(fetcher: fetcher, storer: cache)
        )
    }

    /// Resolve recursively and persist each fetched block after CID verification.
    func resolveRecursive(fetcher: any Fetcher, cache: any Storer) async throws -> Self {
        try await resolveRecursive(
            fetcher: CachingFetcher(fetcher: fetcher, storer: cache)
        )
    }

    /// Resolve this Header and persist its fetched block after CID verification.
    func resolve(fetcher: any Fetcher, cache: any Storer) async throws -> Self {
        try await resolve(
            fetcher: CachingFetcher(fetcher: fetcher, storer: cache)
        )
    }

    // MARK: - Batched resolution over a ContentSource

    /// Resolve against a batched ``ContentSource``. The source is wrapped in a
    /// single ``CoalescingFetcher`` for the whole walk, so each concurrent wave
    /// of child fetches collapses into one batched request — no per-node round
    /// trips, with no Header-vs-Volume divergence
    /// (the recursive walk threads the one coalescer through every level).
    func resolve(paths: ArrayTrie<ResolutionStrategy>, source: any ContentSource) async throws -> Self {
        try await resolve(paths: paths, fetcher: CoalescingFetcher(source))
    }

    func resolveRecursive(source: any ContentSource) async throws -> Self {
        try await resolveRecursive(fetcher: CoalescingFetcher(source))
    }

    func resolve(source: any ContentSource) async throws -> Self {
        try await resolve(fetcher: CoalescingFetcher(source))
    }

    /// Resolve through a batched source and cache verified fetched blocks.
    func resolve(
        paths: ArrayTrie<ResolutionStrategy>,
        source: any ContentSource,
        cache: any Storer
    ) async throws -> Self {
        try await resolve(
            paths: paths,
            fetcher: CoalescingFetcher(source),
            cache: cache
        )
    }

    /// Resolve recursively through a batched source and cache verified fetched blocks.
    func resolveRecursive(source: any ContentSource, cache: any Storer) async throws -> Self {
        try await resolveRecursive(fetcher: CoalescingFetcher(source), cache: cache)
    }

    /// Resolve this Header through a batched source and cache its verified block.
    func resolve(source: any ContentSource, cache: any Storer) async throws -> Self {
        try await resolve(fetcher: CoalescingFetcher(source), cache: cache)
    }
}
