import Foundation
import MangaChecksSupport
let args = CommandLine.arguments
let filter = args.firstIndex(of: "--filter").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
let checks = allChecks().filter { filter == nil || $0.name.contains(filter!) }
if checks.isEmpty { print("No matching checks"); exit(2) }
var failures = 0
for check in checks {
    do { try await check.body(); print("PASS \(check.name)") }
    catch { failures += 1; print("FAIL \(check.name): \(error)") }
}
print("\(checks.count - failures)/\(checks.count) checks passed")
if failures > 0 { exit(1) }
