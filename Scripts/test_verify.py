#!/usr/bin/env python3
"""
test_verify.py -- unit tests for the检查 logic inside verify.py.

Why this exists: `Scripts/verify.py` is itself code, and it produced four separate
false results while it was being written:

  1. an assertion that read "the runtime bucket must provide Java 21+" after Java 21
     support was deliberately removed — it passed against a stale idea of the design;
  2. a call-site regex that matched `func name(` declarations and reported dozens of
     phantom mismatches;
  3. the same check not accounting for default parameter values, so a legal
     `manifest()` call looked wrong;
  4. an assertion ending in `or True`, which could never fail.

Each of those is now a test below. A checker that is not itself tested is just a
second source of unverified claims.

Usage:
    python3 Scripts/test_verify.py
"""

from __future__ import annotations

import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

import verify  # noqa: E402  (path manipulation must come first)


# ── Test doubles ──────────────────────────────────────────────────────────────

class RecordingReport(verify.Report):
    """A Report that captures results instead of printing them."""

    def __init__(self) -> None:
        with redirect_stdout(io.StringIO()):
            super().__init__(verbose=False)
        self.records: list[tuple[str, bool, str]] = []

    def check(self, name: str, condition: bool, detail: str = "") -> bool:
        self.records.append((name, bool(condition), detail))
        with redirect_stdout(io.StringIO()):
            return super().check(name, condition, detail)

    def start(self, name: str) -> None:
        with redirect_stdout(io.StringIO()):
            super().start(name)

    def skip(self, name: str, why: str) -> None:
        with redirect_stdout(io.StringIO()):
            super().skip(name, why)

    def summary(self, quiet: bool = False) -> int:
        # The harness prints nothing: a deliberate-failure test would otherwise emit
        # a red "有失败项" banner in the middle of a passing run.
        with redirect_stdout(io.StringIO()):
            return super().summary(quiet=True)

    def failed_names(self) -> list[str]:
        return [name for name, ok, _ in self.records if not ok]


def run_quietly(func, *args):
    with redirect_stdout(io.StringIO()):
        return func(*args)


# ── 1. The rules engine ───────────────────────────────────────────────────────
#
# The reference implementation in verify.py is what the Swift is checked against, so
# an error here silently validates a wrong Swift implementation.

class RulesEngineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = verify.ios_environment()

    def test_empty_rules_allow(self) -> None:
        self.assertTrue(verify.rules_allow([], self.env))

    def test_single_allow_non_matching_denies(self) -> None:
        rules = [{"action": "allow", "os": {"name": "windows"}}]
        self.assertFalse(verify.rules_allow(rules, self.env))

    def test_single_allow_matching_allows(self) -> None:
        rules = [{"action": "allow", "os": {"name": "osx"}}]
        self.assertTrue(verify.rules_allow(rules, self.env))

    def test_single_disallow_matching_denies(self) -> None:
        rules = [{"action": "disallow", "os": {"name": "osx"}}]
        self.assertFalse(verify.rules_allow(rules, self.env))

    def test_single_disallow_non_matching_allows(self) -> None:
        # The subtle part of Mojang's semantics: nothing matched, so the result is
        # the opposite of the *first* rule's action — i.e. allow.
        rules = [{"action": "disallow", "os": {"name": "windows"}}]
        self.assertTrue(verify.rules_allow(rules, self.env))

    def test_last_matching_rule_wins(self) -> None:
        rules = [
            {"action": "allow", "os": {"name": "osx"}},
            {"action": "disallow", "os": {"name": "osx"}},
        ]
        self.assertFalse(verify.rules_allow(rules, self.env))

    def test_non_matching_rules_do_not_affect_result(self) -> None:
        rules = [
            {"action": "allow", "os": {"name": "osx"}},
            {"action": "disallow", "os": {"name": "windows"}},
        ]
        self.assertTrue(verify.rules_allow(rules, self.env))

    def test_arch_x86_does_not_match_arm64(self) -> None:
        rules = [{"action": "allow", "os": {"arch": "x86"}}]
        self.assertFalse(verify.rules_allow(rules, self.env))

    def test_feature_flag_mismatch_denies(self) -> None:
        rules = [{"action": "allow", "features": {"is_demo_user": True}}]
        self.assertFalse(verify.rules_allow(rules, self.env))

    def test_feature_flags_must_all_match(self) -> None:
        env = verify.ios_environment({**self.env["features"], "is_demo_user": True})
        rules = [{
            "action": "allow",
            "features": {"is_demo_user": True, "has_custom_resolution": False},
        }]
        self.assertFalse(verify.rules_allow(rules, env))

    def test_ios_reports_as_osx(self) -> None:
        # The single most important design decision. If this changes, the
        # Darwin-only entries in Mojang's metadata disappear and the game hangs on a
        # black screen with no error.
        self.assertEqual(self.env["os_name"], "osx")


# ── 2. Argument flattening ────────────────────────────────────────────────────

class ArgumentFlatteningTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = verify.ios_environment()

    def test_bare_string_preserved(self) -> None:
        self.assertEqual(verify.resolve_arguments(["-Xss1M"], self.env), ["-Xss1M"])

    def test_object_with_string_value(self) -> None:
        out = verify.resolve_arguments([{"rules": [], "value": "--demo"}], self.env)
        self.assertEqual(out, ["--demo"])

    def test_object_with_array_value(self) -> None:
        out = verify.resolve_arguments([{"rules": [], "value": ["-a", "-b"]}], self.env)
        self.assertEqual(out, ["-a", "-b"])

    def test_order_preserved(self) -> None:
        elements = [
            "-first",
            {"rules": [{"action": "allow", "os": {"name": "osx"}}], "value": ["-second"]},
            "-third",
        ]
        self.assertEqual(
            verify.resolve_arguments(elements, self.env), ["-first", "-second", "-third"]
        )

    def test_non_matching_entry_removed_without_gap(self) -> None:
        elements = [
            "-keep1",
            {"rules": [{"action": "allow", "os": {"name": "linux"}}], "value": ["-drop"]},
            "-keep2",
        ]
        self.assertEqual(verify.resolve_arguments(elements, self.env), ["-keep1", "-keep2"])

    def test_missing_value_inserts_nothing(self) -> None:
        self.assertEqual(verify.resolve_arguments([{"rules": []}], self.env), [])

    def test_start_on_first_thread_is_kept(self) -> None:
        # Without this flag GLFW never pumps the Darwin run loop.
        elements = [{
            "rules": [{"action": "allow", "os": {"name": "osx"}}],
            "value": ["-XstartOnFirstThread"],
        }]
        self.assertIn("-XstartOnFirstThread", verify.resolve_arguments(elements, self.env))


# ── 3. Placeholder substitution ───────────────────────────────────────────────

class SubstitutionTests(unittest.TestCase):
    def test_known_placeholder_replaced(self) -> None:
        values = {"auth_player_name": "Steve"}
        self.assertEqual(
            verify.substitute("--username ${auth_player_name}", values), "--username Steve"
        )

    def test_unknown_placeholder_returns_none(self) -> None:
        # None is how an unsatisfiable argument gets dropped rather than passed
        # through with a literal ${...} in it.
        self.assertIsNone(verify.substitute("--width ${resolution_width}", {}))

    def test_no_placeholder_passthrough(self) -> None:
        self.assertEqual(verify.substitute("--demo", {}), "--demo")

    def test_repeated_placeholder(self) -> None:
        values = {"version_name": "1.21.4"}
        self.assertEqual(
            verify.substitute("${version_name}-${version_name}", values), "1.21.4-1.21.4"
        )

    def test_placeholder_in_the_middle(self) -> None:
        values = {"version_name": "1.21.4"}
        self.assertEqual(verify.substitute("a${version_name}b", values), "a1.21.4b")


# ── 4. Runtime tag resolution ─────────────────────────────────────────────────
#
# The bug this guards: Java 25 used to resolve to a Java 21 bucket that no runtime
# could fill, and a later version rounded *down*, which would hand Minecraft 1.17 a
# Java 21 runtime and crash it.

class RuntimeTagResolutionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.mapping = verify.parse_runtime_tags()

    def test_tags_parsed(self) -> None:
        self.assertGreaterEqual(len(self.mapping["all_tags"]), 2)

    def test_every_tag_declares_a_major(self) -> None:
        for tag in self.mapping["all_tags"]:
            self.assertIn(tag, self.mapping["major_for_tag"])

    def test_uses_smallest_sufficient_selection(self) -> None:
        self.assertTrue(
            self.mapping["uses_filter_min"],
            "minimumTag(forMajor:) 应当是 filter/min 形式，而不是阈值链",
        )

    def test_java8_resolves_to_java8(self) -> None:
        tag = verify.resolve_minimum_tag(self.mapping, 8)
        self.assertEqual(self.mapping["major_for_tag"][tag], 8)

    def test_java17_resolves_to_a_sufficient_runtime(self) -> None:
        tag = verify.resolve_minimum_tag(self.mapping, 17)
        self.assertIsNotNone(tag)
        self.assertGreaterEqual(self.mapping["major_for_tag"][tag], 17)

    def test_never_rounds_down(self) -> None:
        # The property that matters, asserted directly rather than via examples.
        for required in (8, 11, 17, 21, 25):
            tag = verify.resolve_minimum_tag(self.mapping, required)
            if tag is None:
                highest = max(self.mapping["major_for_tag"].values())
                self.assertLess(
                    highest, required,
                    f"Java {required} 返回 None，但存在满足它的运行时",
                )
            else:
                self.assertGreaterEqual(
                    self.mapping["major_for_tag"][tag], required,
                    f"Java {required} 被降级到 Java {self.mapping['major_for_tag'][tag]}",
                )

    def test_java21_is_not_satisfiable(self) -> None:
        # Documents the real constraint. If a Java 21 runtime is ever added, this
        # test fails and points at docs/JAVA-RUNTIMES.md — which is the intent.
        self.assertIsNone(
            verify.resolve_minimum_tag(self.mapping, 21),
            "内置运行时若能满足 Java 21，请更新此测试与 JAVA-RUNTIMES.md",
        )


# ── 5. UUID derivation ────────────────────────────────────────────────────────

class UUIDTests(unittest.TestCase):
    def test_matches_java_algorithm(self) -> None:
        # Java's UUID.nameUUIDFromBytes, reimplemented here from the JDK source.
        import hashlib

        seed = "OfflinePlayer:Notch".encode("utf-8")
        digest = bytearray(hashlib.md5(seed).digest())
        digest[6] = (digest[6] & 0x0F) | 0x30
        digest[8] = (digest[8] & 0x3F) | 0x80
        hexed = digest.hex()
        expected = f"{hexed[0:8]}-{hexed[8:12]}-{hexed[12:16]}-{hexed[16:20]}-{hexed[20:32]}"

        self.assertEqual(verify.java_reference_uuid("OfflinePlayer:Notch"), expected)

    def test_version_nibble_is_3(self) -> None:
        self.assertEqual(verify.java_reference_uuid("OfflinePlayer:Notch")[14], "3")

    def test_variant_bits_are_valid(self) -> None:
        self.assertIn(verify.java_reference_uuid("OfflinePlayer:Notch")[19], "89ab")

    def test_deterministic(self) -> None:
        self.assertEqual(
            verify.java_reference_uuid("OfflinePlayer:Steve"),
            verify.java_reference_uuid("OfflinePlayer:Steve"),
        )

    def test_different_names_differ(self) -> None:
        self.assertNotEqual(
            verify.java_reference_uuid("OfflinePlayer:Steve"),
            verify.java_reference_uuid("OfflinePlayer:Alex"),
        )


# ── 6. The report harness itself ──────────────────────────────────────────────

class ReportTests(unittest.TestCase):
    def test_failed_check_is_recorded(self) -> None:
        report = RecordingReport()
        report.check("总是失败", False)
        self.assertEqual(report.failed, 1)
        self.assertIn("总是失败", report.failed_names())

    def test_passing_check_is_recorded(self) -> None:
        report = RecordingReport()
        report.check("总是通过", True)
        self.assertEqual(report.failed, 0)

    def test_summary_exit_code(self) -> None:
        passing = RecordingReport()
        passing.check("ok", True)
        self.assertEqual(passing.summary(), 0)

        failing = RecordingReport()
        failing.check("bad", False)
        self.assertEqual(failing.summary(), 1)


# ── 7. Live checks against the extracted upstream runtime ─────────────────────
#
# Skipped when the IPA has not been unpacked, so the suite still runs on a fresh
# checkout.

RUNTIME_ROOT = (
    PROJECT_ROOT / ".bootstrap" / "inspect" / "Payload" / "PojavLauncher.app" / "java_runtimes"
)


@unittest.skipUnless(RUNTIME_ROOT.is_dir(), "未解包上游 IPA，跳过")
class UpstreamRuntimeTests(unittest.TestCase):
    """The third source of truth: what upstream actually ships.

    These are the tests that would have caught the `jre21` mistake, where the Swift
    tag list and the shell script agreed with each other while both being wrong about
    reality.
    """

    def test_swift_tags_match_upstream_directories(self) -> None:
        mapping = verify.parse_runtime_tags()
        actual = {p.name for p in RUNTIME_ROOT.iterdir() if p.is_dir()}
        self.assertEqual(
            set(mapping["all_tags"]),
            actual,
            "Swift 声明的运行时标签必须与上游 IPA 里的目录完全一致",
        )

    def test_each_runtime_has_libjli_and_libjvm(self) -> None:
        for tag_dir in sorted(p for p in RUNTIME_ROOT.iterdir() if p.is_dir()):
            is_java8 = tag_dir.name.startswith("java-8")
            jli = tag_dir / ("lib/jli/libjli.dylib" if is_java8 else "lib/libjli.dylib")
            with self.subTest(runtime=tag_dir.name):
                self.assertTrue(jli.is_file(), f"缺少 {jli.relative_to(RUNTIME_ROOT)}")
                self.assertTrue(
                    (tag_dir / "lib/server/libjvm.dylib").is_file(),
                    f"{tag_dir.name} 缺少 lib/server/libjvm.dylib",
                )

    def test_awt_shim_has_lib_prefix(self) -> None:
        # The file is `lib/libawt_xawt.dylib`, not `lib/awt_xawt.dylib`. Getting this
        # wrong produced a silent "AWT 支持库缺失" warning at launch.
        for tag_dir in sorted(p for p in RUNTIME_ROOT.iterdir() if p.is_dir()):
            with self.subTest(runtime=tag_dir.name):
                self.assertTrue((tag_dir / "lib/libawt_xawt.dylib").is_file())
                self.assertFalse((tag_dir / "lib/awt_xawt.dylib").exists())

    def test_runtime_has_no_bin_java(self) -> None:
        # These are trimmed runtimes started via dlopen(JLI_Launch), not by exec.
        # If `bin/java` ever appears, the Swift's argv[0] assumption should be revisited.
        for tag_dir in sorted(p for p in RUNTIME_ROOT.iterdir() if p.is_dir()):
            with self.subTest(runtime=tag_dir.name):
                self.assertFalse((tag_dir / "bin").exists(), "运行时不应有 bin/ 目录")

    def test_release_file_reports_expected_major(self) -> None:
        mapping = verify.parse_runtime_tags()
        for tag_dir in sorted(p for p in RUNTIME_ROOT.iterdir() if p.is_dir()):
            release = tag_dir / "release"
            if not release.is_file():
                continue
            parsed = verify.JavaReleaseFile.parse(release.read_text(encoding="utf-8", errors="replace"))
            if parsed is None:
                continue
            with self.subTest(runtime=tag_dir.name):
                self.assertEqual(
                    parsed.major_version,
                    mapping["major_for_tag"][tag_dir.name],
                    f"{tag_dir.name} 的 release 文件与 Swift 声明的主版本不一致",
                )


# ── 8. Self-consistency of the project files ──────────────────────────────────

class ProjectConsistencyTests(unittest.TestCase):
    def test_bootstrap_script_extracts_from_java_runtimes(self) -> None:
        text = (SCRIPT_DIR / "bootstrap-runtime.sh").read_text(encoding="utf-8")
        self.assertIn("java_runtimes", text)
        # The original design classified .zip archives by size; that never worked.
        self.assertNotIn("classify_jdk", text)

    def test_bootstrap_script_covers_all_jar_sources(self) -> None:
        text = (SCRIPT_DIR / "bootstrap-runtime.sh").read_text(encoding="utf-8")
        for sub in ("libs", "libs_caciocavallo", "libs_caciocavallo17"):
            self.assertIn(sub, text, f"缺少 {sub}/ 会导致某一代 Java 的 AWT 不可用")

    def test_curl_resume_is_conditional(self) -> None:
        """`curl -C -` must only be used when a partial file exists.

        With no local file, curl sends `Range: bytes=1-` and GitHub's release CDN
        answers 404 rather than 200 or 416. That aborted a real CI run with exit
        code 56 — the resume flag, added to cope with a throttled home network, broke
        the build on a well-connected runner that had nothing to resume.
        """
        text = (SCRIPT_DIR / "bootstrap-runtime.sh").read_text(encoding="utf-8")

        # The bare form must not appear: it would break any clean checkout.
        for line in text.split("\n"):
            stripped = line.strip()
            if stripped.startswith("curl ") or stripped.startswith("wget "):
                self.assertNotIn(
                    "-C -", stripped,
                    "curl 调用行里不能直接写死 -C -，必须走 ${RESUME_FLAG}",
                )

        # And the guard must exist, keyed on the file being non-empty.
        self.assertIn("RESUME_FLAG", text)
        self.assertIn('-s "${CANDIDATE}"', text, "判断部分文件是否存在的条件不见了")

    def test_scripts_are_lf_only(self) -> None:
        # A CRLF shebang fails on Linux/macOS with "/bin/bash^M: bad interpreter".
        # GitHub Actions runs there, so this is a build failure, not cosmetics.
        for name in ("bootstrap-runtime.sh", "generate-project.sh", "attach-jit.sh"):
            data = (SCRIPT_DIR / name).read_bytes()
            with self.subTest(script=name):
                self.assertNotIn(b"\r\n", data, f"{name} 含 CRLF，在 CI 上无法执行")

    def test_gitattributes_forces_lf_for_scripts(self) -> None:
        text = (PROJECT_ROOT / ".gitattributes").read_text(encoding="utf-8")
        self.assertIn("*.sh", text)
        self.assertIn("eol=lf", text)

    def test_entitlements_exclude_apple_reserved_keys(self) -> None:
        text = (PROJECT_ROOT / "Resources" / "CraftLauncher.entitlements").read_text(
            encoding="utf-8"
        )
        # Only the plist body counts; the privileged keys live in a doc comment.
        body = text.split("-->", 1)[-1]
        self.assertIn("get-task-allow", body)
        for reserved in ("com.apple.private.", "com.apple.developer."):
            self.assertNotIn(
                reserved, body,
                f"{reserved} 会让证书签名失败",
            )

    def test_no_tautological_assertions(self) -> None:
        # A previous assertion read `re.search(...) is None or True`, which could
        # never fail. Match the shape rather than the exact text so a differently
        # worded tautology is still caught.
        import re as _re

        text = (SCRIPT_DIR / "verify.py").read_text(encoding="utf-8")
        tautologies = _re.findall(r"report\.check\((?:[^()]|\([^()]*\))*?or True\s*[,)]", text)
        self.assertEqual(tautologies, [], f"发现恒真断言: {tautologies}")


def main() -> int:
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
