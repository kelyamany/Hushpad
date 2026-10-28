import Testing

/// `LibraryCrypto` keeps its key in process-wide state. Every suite that changes it is nested here, and this suite
/// is serialized, so they never run in parallel with each other.
@Suite(.serialized) enum CryptoGlobalState {}
