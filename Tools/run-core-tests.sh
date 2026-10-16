#!/bin/zsh
# Builds and runs the TeleprompterCore checks with only the Swift compiler
# (no Xcode or XCTest needed). In Xcode, the same checks run as XCTest.
set -euo pipefail
ROOT="${0:A:h:h}"
CORE="$ROOT/Packages/TeleprompterCore"
OUT="${TMPDIR:-/tmp}/teleprompter-core-tests"
mkdir -p "$OUT"

cat > "$OUT/main.swift" <<'EOF'
import Foundation

var failed = 0
func runAll(_ title: String, _ entries: [(String, () -> ScenarioReport)]) {
    print("\n\(title)")
    for (name, scenario) in entries {
        let report = scenario()
        print("  \(report.passed ? "PASS" : "FAIL")  \(name)")
        for note in report.notes { print("        \(note)") }
        for failure in report.failures { print("        - \(failure)") }
        if !report.passed { failed += 1 }
    }
}
runAll("Unit checks", UnitChecks.all)
runAll("Voice-follow acceptance scenarios", AcceptanceScenarios.all)
runAll("Voice commands", VoiceCommandChecks.all)
print(failed == 0 ? "\nAll checks passed." : "\n\(failed) check group(s) failed.")
exit(failed == 0 ? 0 : 1)
EOF

# Test files use `@testable import TeleprompterCore`; compiled as one module here.
TESTS=("$CORE"/Tests/TeleprompterCoreTests/{VoiceFollowSimulation,AcceptanceScenarios,UnitChecks,VoiceCommandChecks}.swift)
for f in $TESTS; do sed '/@testable import TeleprompterCore/d' "$f" > "$OUT/${f:t}"; done

SWIFTC=$(command -v swiftc)

"$SWIFTC" -O -module-name CoreChecks \
  "$CORE"/Sources/TeleprompterCore/*.swift \
  "$OUT"/{VoiceFollowSimulation,AcceptanceScenarios,UnitChecks,VoiceCommandChecks}.swift "$OUT/main.swift" \
  -o "$OUT/core-checks"
"$OUT/core-checks"
