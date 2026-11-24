import CryptoKit
import Foundation

// Derives the Sparkle EdDSA public key from a 32-byte base64 seed.
// Usage: swift scripts/eddsa-public-key.swift <base64-seed>

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: eddsa-public-key.swift <base64-seed>\n".utf8))
    exit(2)
}
guard let seed = Data(base64Encoded: CommandLine.arguments[1]), seed.count == 32 else {
    FileHandle.standardError.write(Data("seed must be 32 bytes, base64 encoded\n".utf8))
    exit(2)
}

do {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    print(key.publicKey.rawRepresentation.base64EncodedString())
} catch {
    FileHandle.standardError.write(Data("could not derive key: \(error)\n".utf8))
    exit(1)
}
