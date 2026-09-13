import Foundation
import Security

func check(_ status: OSStatus, _ operation: String) {
    guard status != errSecSuccess else { return }
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    fputs("\(operation): \(detail)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fputs("Usage: import-signing-identity.swift backup.p12 password-file keychain\n", stderr)
    exit(1)
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let password = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
    .trimmingCharacters(in: .newlines)
// codesign uses a file-based keychain. These legacy APIs also let the import
// grant access specifically to codesign instead of to every application.
var keychain: SecKeychain?
check(SecKeychainOpen(CommandLine.arguments[3], &keychain), "Open signing keychain")
var codesign: SecTrustedApplication?
check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &codesign), "Find codesign")
var access: SecAccess?
check(SecAccessCreate("Qpaste Local Code Signing" as CFString, [codesign!] as CFArray, &access), "Create signing access")
let options: [String: Any] = [
    kSecImportExportPassphrase as String: password,
    kSecImportExportKeychain as String: keychain!,
    kSecImportExportAccess as String: access!
]
var imported: CFArray?
check(SecPKCS12Import(data as CFData, options as CFDictionary, &imported), "Import Qpaste signing identity")
print("Imported Qpaste identity into the signing keychain.")
