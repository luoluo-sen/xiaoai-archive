"""Run the existing synchronous scrolling test bodies on CLT-only Macs.

This is an assertion-based smoke runner, NOT XCTest. It leaves the original
XCTest sources untouched, removes only their XCTest imports/base class in a
.build copy, and supplies real assertions. Unknown assertions, test signatures,
or fixtures are rejected instead of silently skipped. Use swift test with a
complete Xcode toolchain for the full suite and XCTest lifecycle semantics.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".build" / "scroll-regressions"
FILES = [
    "WeChatFocusHoldTests.swift",
    "WeChatScrollStepTests.swift",
    "WeChatPrefetchTests.swift",
]
ASSERTIONS = {
    "XCTAssertEqual", "XCTAssertTrue", "XCTAssertFalse", "XCTAssertNil",
    "XCTAssertNotNil", "XCTAssertLessThan", "XCTAssertLessThanOrEqual",
    "XCTAssertGreaterThan", "XCTAssertGreaterThanOrEqual",
}
SWIFT_ASSERTIONS = r'''
import Foundation

func require(_ condition: Bool, _ message: String, file: StaticString, line: UInt) {
    if !condition { fatalError("Assertion failed: \(message)", file: file, line: line) }
}
func smokeAssertTrue(_ value: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    require(value(), message(), file: file, line: line)
}
func smokeAssertFalse(_ value: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    require(!value(), message(), file: file, line: line)
}
func smokeAssertEqual<T: Equatable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    require(lhs() == rhs(), message(), file: file, line: line)
}
func smokeAssertEqual<T: BinaryFloatingPoint>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T, accuracy: T, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    require(abs(lhs() - rhs()) <= accuracy, message(), file: file, line: line)
}
func smokeAssertNil<T>(_ value: @autoclosure () -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    require(value() == nil, message(), file: file, line: line)
}
func smokeAssertNotNil<T>(_ value: @autoclosure () -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    require(value() != nil, message(), file: file, line: line)
}
'''


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    parts = [SWIFT_ASSERTIONS]
    for name, op in [
        ("LessThan", "<"), ("LessThanOrEqual", "<="),
        ("GreaterThan", ">"), ("GreaterThanOrEqual", ">="),
    ]:
        parts.append(f'''
func smokeAssert{name}<T: Comparable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {{
    require(lhs() {op} rhs(), message(), file: file, line: line)
}}
''')
    calls: list[str] = []
    counts: dict[str, int] = {}
    for filename in FILES:
        source = (ROOT / "Tests/DukouCoreTests" / filename).read_text()
        methods = re.findall(r"func\s+(test\w+)\(\)\s*\{", source)
        all_tests = re.findall(r"func\s+(test\w+)\s*\(", source)
        if not methods or methods != all_tests or re.search(r"\b(?:setUp|tearDown|XCTContext)\b", source):
            raise ValueError(f"Unsupported test signature or fixture in {filename}; use XCTest")
        unknown = set(re.findall(r"\b(XCT\w+)\s*\(", source)) - ASSERTIONS
        if unknown:
            raise ValueError(f"Unsupported assertions in {filename}: {sorted(unknown)}")
        class_name = filename.removesuffix(".swift")
        expected = f"final class {class_name}: XCTestCase"
        if expected not in source:
            raise ValueError(f"Unexpected test class in {filename}")
        source = source.replace("import XCTest\n", "").replace("@testable import DukouCore\n", "")
        source = source.replace(expected, f"final class {class_name}")
        for assertion in sorted(ASSERTIONS, key=len, reverse=True):
            source = re.sub(r"\b" + assertion + r"\b", assertion.replace("XCT", "smoke", 1), source)
        parts.append(source)
        counts[class_name] = len(methods)
        for method in methods:
            calls.append(f'{class_name}().{method}(); print("PASS: {class_name}.{method}")')
    parts.append("@main enum ScrollSmoke { static func main() {\n" + "\n".join(calls)
                 + f'\nprint("{len(calls)}/{len(calls)} existing test bodies passed (standalone assertions, not XCTest)")\n}}}}')
    generated = OUT / "ScrollSmoke.swift"
    generated.write_text("\n".join(parts))
    env = dict(os.environ)
    sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
    if not env.get("SDKROOT") and sdk.is_dir():
        env["SDKROOT"] = str(sdk)
    binary = OUT / "check-scroll-regressions"
    core = sorted((ROOT / "Sources/DukouCore").glob("*.swift"))
    print("Standalone assertions; original test bodies:", counts, flush=True)
    subprocess.run(["swiftc", "-swift-version", "6", *map(str, core), str(generated), "-o", str(binary)],
                   cwd=ROOT, env=env, check=True, timeout=300)
    return subprocess.run([str(binary)], cwd=ROOT, env=env, timeout=30).returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Regression runner failed: {error}", file=sys.stderr)
        sys.exit(1)
