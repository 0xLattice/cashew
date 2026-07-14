import Crypto
import Foundation

/// A Fetcher that writes verified fetched blocks to a sparse ``Storer``.
/// Successful writes remain cached if a later fetch in the resolution fails.
struct CachingFetcher: Fetcher, KeyProvider {
    private let fetcher: any Fetcher
    private let storer: any Storer

    init(fetcher: any Fetcher, storer: any Storer) {
        self.fetcher = fetcher
        self.storer = storer
    }

    func fetch(rawCid: String) async throws -> Data {
        let data = try await fetcher.fetch(rawCid: rawCid)
        try verifyContentAddress(data, matches: rawCid)
        try await storer.store(entries: [rawCid: data])
        return data
    }

    func key(for keyHash: String) -> SymmetricKey? {
        (fetcher as? any KeyProvider)?.key(for: keyHash)
    }
}
