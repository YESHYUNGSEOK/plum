// Signs releases so Plum installs only updates that come from you.
//
//   swift scripts/update-signing.swift new-key <private key file>
//       makes a key pair; prints the public key to put in Updates.swift
//   swift scripts/update-signing.swift sign <zip> <private key file>
//       prints the zip's signature (base64), for <zip>.sig
//
// Ed25519 (CryptoKit). Keep the private key out of the repository and backed
// up: without it, no later release will install itself in copies already out.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "" {
case "new-key" where arguments.count == 3:
    let path = arguments[2]
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) exists; not replacing a key") }
    let key = Curve25519.Signing.PrivateKey()
    let folder = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600]) else { fail("could not write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign" where arguments.count == 4:
    guard let archive = FileManager.default.contents(atPath: arguments[2]) else { fail("cannot read \(arguments[2])") }
    guard let text = try? String(contentsOfFile: arguments[3], encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("cannot read the key \(arguments[3])") }
    guard let signature = try? key.signature(for: archive) else { fail("signing failed") }
    print(signature.base64EncodedString())
default:
    fail("usage: update-signing.swift new-key <key file> | sign <zip> <key file>")
}
