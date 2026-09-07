import CryptoKit
import Foundation

/// Sparkle EdDSA signature for an update archive (same idea as `sign_update`).
let args = CommandLine.arguments.dropFirst()
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: sign-update.swift <file> <private-b64-path>\n".utf8))
    exit(2)
}
let file = URL(fileURLWithPath: args[args.startIndex])
let keyPath = URL(fileURLWithPath: args[args.index(after: args.startIndex)])
let fileData = try Data(contentsOf: file)
let keyB64 = try String(contentsOf: keyPath, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let raw = Data(base64Encoded: keyB64) else {
    FileHandle.standardError.write(Data("invalid private key\n".utf8))
    exit(2)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
let signature = try key.signature(for: fileData)
print(signature.base64EncodedString())
