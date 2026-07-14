/// Errors from data serialization, CID computation, encryption, and structural storage traversal.
public enum DataErrors: Error, Equatable {
    case nodeNotAvailable
    /// `Node.properties()` declared a child that `get(property:)` did not return.
    /// A selected boundary must be structurally complete even when the missing
    /// child is not on a targeted path.
    case missingDeclaredChild(String)
    case serializationFailed
    case cidCreationFailed
    case cidMismatch
    case encryptionFailed
    case decryptionFailed
    case keyNotFound
    case invalidIV
}
