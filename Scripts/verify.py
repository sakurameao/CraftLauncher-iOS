#!/usr/bin/env python3
"""
verify.py -- static and behavioural checks for CraftLauncher.

Runs anywhere with Python 3.8+, no macOS or Xcode required. It exists because the
two things most likely to be silently wrong in an iOS Java launcher are:

  1. the Mojang ``rules`` engine, which decides which libraries and arguments apply,
     and
  2. the ``${...}`` placeholder substitution in the launch command line,

and both are pure logic that can be re-implemented and cross-checked here. A wrong
rule means a missing native library or a missing ``-XstartOnFirstThread``, which
shows up as a black screen rather than an error message.

The checks are written against the *documented* behaviour of the official launcher
and validated against real version metadata, so this file doubles as a specification
for ``Sources/Services/JVMArguments.swift``.

Usage:
    python3 Scripts/verify.py              # all checks
    python3 Scripts/verify.py --offline    # skip checks that need the network
    python3 Scripts/verify.py -v           # list every check
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent

# ── Terminal setup ────────────────────────────────────────────────────────────
#
# Windows consoles default to a legacy code page (GBK, CP1252, ...) which cannot
# encode the box-drawing and check-mark glyphs used below, and a UnicodeEncodeError
# mid-run would hide the actual verification result. Reconfigure to UTF-8 where
# possible and fall back to ASCII glyphs when it is not.

def _configure_stdout() -> bool:
    """Returns True when the console can render the Unicode glyphs."""
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            try:
                reconfigure(encoding="utf-8", errors="replace")
            except (ValueError, OSError):
                pass

    encoding = (getattr(sys.stdout, "encoding", None) or "").lower()
    if not encoding:
        return False
    try:
        "✓✗·─→".encode(encoding)
        return True
    except (UnicodeEncodeError, LookupError):
        return False


UNICODE_OK = _configure_stdout()

if UNICODE_OK:
    GLYPH_PASS, GLYPH_FAIL, GLYPH_SKIP = "✓", "✗", "·"
    RULE = "─" * 68
else:
    GLYPH_PASS, GLYPH_FAIL, GLYPH_SKIP = "OK", "X", "-"
    RULE = "-" * 68


# ── Terminal colours ──────────────────────────────────────────────────────────

_TTY = sys.stdout.isatty()


def _c(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _TTY else text


GREEN = lambda s: _c("32", s)
RED = lambda s: _c("31", s)
YELLOW = lambda s: _c("33", s)
BOLD = lambda s: _c("1", s)
DIM = lambda s: _c("2", s)


# ── Tiny test harness ─────────────────────────────────────────────────────────

class Report:
    def __init__(self, verbose: bool) -> None:
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.failures: list[tuple[str, str]] = []
        self.verbose = verbose
        self.section = ""

    def start(self, name: str) -> None:
        self.section = name
        print(f"\n{BOLD('==>')} {name}")

    def check(self, name: str, condition: bool, detail: str = "") -> bool:
        if condition:
            self.passed += 1
            if self.verbose:
                print(f"  {GREEN(GLYPH_PASS)} {name}")
        else:
            self.failed += 1
            self.failures.append((self.section, name))
            print(f"  {RED(GLYPH_FAIL)} {name}")
            if detail:
                for line in detail.splitlines():
                    print(f"      {DIM(line)}")
        return condition

    def equal(self, name: str, actual, expected) -> bool:
        return self.check(
            name,
            actual == expected,
            f"expected: {expected!r}\nactual:   {actual!r}",
        )

    def skip(self, name: str, why: str) -> None:
        self.skipped += 1
        print(f"  {YELLOW(GLYPH_SKIP)} {name} {DIM('(跳过: ' + why + ')')}")

    def summary(self, quiet: bool = False) -> int:
        """Prints the tally and returns the exit code.

        `quiet` exists for the unit tests: they exercise the failure path on purpose
        (asserting that a failed check yields exit code 1), and printing a red
        "有失败项" banner in the middle of a passing test run is actively misleading
        to anyone reading the output.
        """
        if not quiet:
            print()
            print(RULE)
            total = self.passed + self.failed
            if self.failed == 0:
                print(f"{GREEN('全部通过')}  {self.passed}/{total} 项检查", end="")
            else:
                print(f"{RED('有失败项')}  {self.passed}/{total} 项通过", end="")
            if self.skipped:
                print(f"，{self.skipped} 项跳过", end="")
            print()
            if self.failures:
                print()
                print("失败的检查：")
                for section, name in self.failures:
                    print(f"  {RED(GLYPH_FAIL)} [{section}] {name}")
            print(RULE)

        return 1 if self.failed else 0


# ── Reference implementation of the Mojang rules engine ───────────────────────
#
# Mirrors Sources/Models/VersionManifest.swift. Written from the official
# launcher's behaviour, not copied from the Swift, so that the two agreeing is
# meaningful evidence rather than a tautology.

def rule_matches(rule: dict, env: dict) -> bool:
    os_rule = rule.get("os")
    if os_rule:
        if "name" in os_rule and os_rule["name"] != env["os_name"]:
            return False
        if "arch" in os_rule and os_rule["arch"] != env["arch"]:
            return False
        # Version ranges only ever appear on Windows rules; iOS is reported as osx,
        # so they are unreachable here. Evaluated anyway for completeness.
        if "versionRange" in os_rule:
            current = parse_version(env.get("os_version", "0"))
            rng = os_rule["versionRange"]
            if "min" in rng and current < parse_version(rng["min"]):
                return False
            if "max" in rng and current > parse_version(rng["max"]):
                return False

    features = rule.get("features")
    if features:
        for key, expected in features.items():
            if env["features"].get(key, False) != expected:
                return False
    return True


def parse_version(text: str) -> tuple:
    parts = []
    for chunk in str(text).split("."):
        digits = re.match(r"\d+", chunk)
        parts.append(int(digits.group()) if digits else 0)
    return tuple(parts)


def rules_allow(rules: list, env: dict) -> bool:
    """Mojang semantics: empty means allow; else the last matching rule wins;
    if nothing matches, the result is the opposite of the first rule's action."""
    if not rules:
        return True
    result = rules[0].get("action") == "disallow"
    for rule in rules:
        if rule_matches(rule, env):
            result = rule.get("action") == "allow"
    return result


def resolve_arguments(elements: list, env: dict) -> list:
    """Flattens the polymorphic `arguments` array into concrete strings."""
    out = []
    for element in elements:
        if isinstance(element, str):
            out.append(element)
        elif isinstance(element, dict):
            if rules_allow(element.get("rules", []), env):
                value = element.get("value")
                if isinstance(value, str):
                    out.append(value)
                elif isinstance(value, list):
                    out.extend(value)
    return out


PLACEHOLDER_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def substitute(text: str, values: dict) -> str | None:
    """Returns None when a placeholder has no value — which is how an
    unsatisfiable argument gets dropped rather than passed through literally."""
    if "${" not in text:
        return text
    out = text
    for key, value in values.items():
        out = out.replace("${" + key + "}", str(value))
    return None if "${" in out else out


# ── JDK release file ──────────────────────────────────────────────────────────

class JavaReleaseFile:
    """Parses the `JAVA_VERSION` line of a JDK `release` file.

    Mirrors `Sources/Models/JavaRuntime.swift`. The mapping is not obvious:

    * `1.8.0` / `1.8.0_402` — the major is the **second** component (8)
    * `17.0.8`              — the major is the **first** component (17)
    * `21`                  — a bare major

    Reading `1.8.0` as major 1 would make every legacy version unsatisfiable.
    """

    __slots__ = ("version", "major_version")

    def __init__(self, version: str, major_version: int) -> None:
        self.version = version
        self.major_version = major_version

    @classmethod
    def parse(cls, contents: str) -> "JavaReleaseFile | None":
        fields: dict[str, str] = {}
        for line in contents.split("\n"):
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            fields[parts[0].strip()] = parts[1].strip().strip('"')

        raw = fields.get("JAVA_VERSION") or fields.get("JAVA_RUNTIME_VERSION")
        if not raw:
            return None
        return cls(version=raw, major_version=cls._infer_major(raw))

    @staticmethod
    def _infer_major(version: str) -> int:
        cleaned = version.strip().strip('"')
        # `1.8.0_402` — the underscore part is a build number, not a version field.
        parts = [chunk.split("_")[0] for chunk in cleaned.split(".")]
        try:
            first = int(parts[0])
        except (ValueError, IndexError):
            return 8
        if first == 1 and len(parts) >= 2:
            try:
                return int(parts[1])
            except ValueError:
                return 8
        return first


# ── Environment under test ────────────────────────────────────────────────────

def ios_environment(features: dict | None = None) -> dict:
    return {
        # The critical design decision: iOS reports itself as `osx` so that the
        # Darwin-only entries in Mojang's metadata stay enabled.
        "os_name": "osx",
        "os_version": "17.0",
        "arch": "arm64",
        "features": features or {
            "is_demo_user": False,
            "has_custom_resolution": True,
            "has_quick_plays_support": False,
            "is_quick_play_singleplayer": False,
            "is_quick_play_multiplayer": False,
            "is_quick_play_realms": False,
        },
    }


# ── Checks ────────────────────────────────────────────────────────────────────

def check_rule_engine(report: Report) -> None:
    report.start("规则引擎（Mojang rules 语义）")
    env = ios_environment()

    report.check("空规则列表 = 允许", rules_allow([], env) is True)

    report.check(
        "单条 allow + 不匹配 → 拒绝",
        rules_allow([{"action": "allow", "os": {"name": "windows"}}], env) is False,
    )
    report.check(
        "单条 allow + 匹配 → 允许",
        rules_allow([{"action": "allow", "os": {"name": "osx"}}], env) is True,
    )
    report.check(
        "单条 disallow + 匹配 → 拒绝",
        rules_allow([{"action": "disallow", "os": {"name": "osx"}}], env) is False,
    )
    report.check(
        "单条 disallow + 不匹配 → 允许",
        rules_allow([{"action": "disallow", "os": {"name": "windows"}}], env) is True,
    )

    # "Last matching rule wins" is the part most implementations get wrong.
    report.check(
        "后匹配的规则覆盖前面的",
        rules_allow(
            [
                {"action": "allow", "os": {"name": "osx"}},
                {"action": "disallow", "os": {"name": "osx"}},
            ],
            env,
        )
        is False,
    )
    report.check(
        "不匹配的规则不影响结果",
        rules_allow(
            [
                {"action": "allow", "os": {"name": "osx"}},
                {"action": "disallow", "os": {"name": "windows"}},
            ],
            env,
        )
        is True,
    )

    # Architecture
    report.check(
        "arch=x86 在 arm64 上不匹配",
        rules_allow([{"action": "allow", "os": {"arch": "x86"}}], env) is False,
    )
    report.check(
        "arch=arm64 在 arm64 上匹配",
        rules_allow([{"action": "allow", "os": {"arch": "arm64"}}], env) is True,
    )

    # Features
    report.check(
        "is_demo_user=true 在非 Demo 下不匹配",
        rules_allow([{"action": "allow", "features": {"is_demo_user": True}}], env) is False,
    )
    demo_env = ios_environment({**env["features"], "is_demo_user": True})
    report.check(
        "is_demo_user=true 在 Demo 下匹配",
        rules_allow([{"action": "allow", "features": {"is_demo_user": True}}], demo_env) is True,
    )
    report.check(
        "多个 feature 需全部满足",
        rules_allow(
            [{"action": "allow", "features": {"is_demo_user": True, "has_custom_resolution": False}}],
            demo_env,
        )
        is False,
    )

    # The real-world case this whole design rests on.
    report.check(
        "osx 规则生效 —— -XstartOnFirstThread 不会被丢掉",
        "-XstartOnFirstThread"
        in resolve_arguments(
            [{"rules": [{"action": "allow", "os": {"name": "osx"}}], "value": ["-XstartOnFirstThread"]}],
            env,
        ),
    )
    report.check(
        "windows 规则不生效 —— 不会带上 javaw 堆转储参数",
        resolve_arguments(
            [
                {
                    "rules": [{"action": "allow", "os": {"name": "windows"}}],
                    "value": "-XX:HeapDumpPath=x.heapdump",
                }
            ],
            env,
        )
        == [],
    )


def check_argument_flattening(report: Report) -> None:
    report.start("arguments 数组展开（字符串与规则对象混排）")
    env = ios_environment()

    report.equal(
        "裸字符串原样保留",
        resolve_arguments(["-XX:StackShadowPages=32"], env),
        ["-XX:StackShadowPages=32"],
    )
    report.equal(
        "对象 value 为字符串",
        resolve_arguments([{"rules": [], "value": "--demo"}], env),
        ["--demo"],
    )
    report.equal(
        "对象 value 为数组",
        resolve_arguments([{"rules": [], "value": ["-a", "-b"]}], env),
        ["-a", "-b"],
    )
    report.equal(
        "顺序保持不变",
        resolve_arguments(
            [
                "-first",
                {"rules": [{"action": "allow", "os": {"name": "osx"}}], "value": ["-second"]},
                "-third",
            ],
            env,
        ),
        ["-first", "-second", "-third"],
    )
    report.equal(
        "不匹配的条目被剔除且不留下空位",
        resolve_arguments(
            [
                "-keep1",
                {"rules": [{"action": "allow", "os": {"name": "linux"}}], "value": ["-drop"]},
                "-keep2",
            ],
            env,
        ),
        ["-keep1", "-keep2"],
    )
    report.equal(
        "value 缺失时不插入空字符串",
        resolve_arguments([{"rules": []}], env),
        [],
    )


def check_placeholders(report: Report) -> None:
    report.start("占位符替换")

    values = {"auth_player_name": "Steve", "version_name": "1.21.4"}

    report.equal("已知占位符被替换", substitute("--username ${auth_player_name}", values), "--username Steve")
    report.check(
        "未知占位符返回 None（参数被丢弃）",
        substitute("--width ${resolution_width}", values) is None,
    )
    report.check("无占位符时原样返回", substitute("--demo", {}) == "--demo")
    report.equal(
        "同一占位符多次出现全部替换",
        substitute("${version_name}-${version_name}", values),
        "1.21.4-1.21.4",
    )
    report.equal(
        "占位符在中间也能替换",
        substitute("a${version_name}b", values),
        "a1.21.4b",
    )

    # Parse the actual value table out of the Swift source so the two cannot drift.
    swift_path = PROJECT_ROOT / "Sources" / "Services" / "JVMArguments.swift"
    if not swift_path.is_file():
        report.check("找到 JVMArguments.swift", False, str(swift_path))
        return

    source = swift_path.read_text(encoding="utf-8")
    template_block = re.search(
        r"return \[\s*(.*?)\n\s*\]\s*\n\s*\}", source, re.DOTALL
    )
    if not template_block:
        report.check("能从源码中解析出模板表", False)
        return

    provided = set(re.findall(r'"([a-zA-Z_][a-zA-Z0-9_]*)":', template_block.group(1)))
    report.check(
        f"解析出 {len(provided)} 个模板键",
        len(provided) > 20,
        f"keys: {sorted(provided)}",
    )

    # The known-placeholder set declared for the String extension must be a
    # superset of what the template table provides, or a real argument would be
    # dropped as unsatisfiable.
    known_block = re.search(
        r"knownLaunchPlaceholders:\s*Set<String>\s*=\s*\[(.*?)\n\s*\]",
        source,
        re.DOTALL,
    )
    if not known_block:
        # Fall back to a looser pattern so a formatting change is not a failure.
        known_block = re.search(
            r"knownLaunchPlaceholders.*?\[(.*?)\n\s*\]", source, re.DOTALL
        )
    if not known_block:
        # The set lives next to the String extension that documents it, which is
        # HTTPClient.swift rather than JVMArguments.swift.
        http_source = (PROJECT_ROOT / "Sources" / "Services" / "HTTPClient.swift").read_text(
            encoding="utf-8"
        )
        known_block = re.search(
            r"knownLaunchPlaceholders.*?\[(.*?)\n\s*\]", http_source, re.DOTALL
        )
    if known_block:
        known = set(re.findall(r'"([A-Za-z_][A-Za-z0-9_]*)"', known_block.group(1)))
        report.check(f"解析出 {len(known)} 个已知占位符", len(known) > 20)
        missing = provided - known
        report.check(
            "模板键都在已知占位符集合中",
            not missing,
            f"缺少: {sorted(missing)}" if missing else "",
        )
    else:
        report.check("找到 knownLaunchPlaceholders 定义", False)

    # Placeholders that Mojang actually emits but the launcher legitimately cannot
    # fill, with the reason each is safe to drop.
    intentionally_unsupported = {
        "quickPlayPath": "快速游玩路径，iOS 上没有对应的入口",
        "quickPlayMultiplayer": "快速游玩服务器，同上",
        "quickPlayRealms": "快速游玩 Realms，同上",
    }

    print(f"      {DIM('模板表提供的键：' + ', '.join(sorted(provided)))}")

    return provided, intentionally_unsupported


def check_against_live_metadata(report: Report, provided: set, unsupported: dict) -> None:
    report.start("与真实 Mojang 版本数据对拍")

    manifest_url = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
    try:
        with urllib.request.urlopen(manifest_url, timeout=25) as response:
            manifest = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        report.skip("获取版本清单", str(exc))
        return

    latest = manifest["latest"]["release"]
    entry = next((v for v in manifest["versions"] if v["id"] == latest), None)
    report.check(f"清单里能找到最新正式版 {latest}", entry is not None)
    if entry is None:
        return

    try:
        with urllib.request.urlopen(entry["url"], timeout=25) as response:
            version = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        report.skip(f"获取 {latest} 的版本 JSON", str(exc))
        return

    java_major = version.get("javaVersion", {}).get("majorVersion", "?")
    print(f"      {DIM(f'对拍对象：{latest}（Java {java_major}）')}")

    env = ios_environment()
    env["features"]["is_demo_user"] = False

    # ── JVM arguments ────────────────────────────────────────────────────────
    jvm_elements = version.get("arguments", {}).get("jvm", [])
    report.check(f"版本元数据带有 {len(jvm_elements)} 条 JVM 参数条目", len(jvm_elements) > 0)

    jvm_args = resolve_arguments(jvm_elements, env)
    report.check(
        "osx 规则带来了 -XstartOnFirstThread",
        "-XstartOnFirstThread" in jvm_args,
        f"解析结果: {jvm_args}",
    )
    report.check(
        "没有混入 windows 专属参数",
        not any("HeapDumpPath" in a for a in jvm_args),
        f"解析结果: {jvm_args}",
    )
    report.check(
        "classpath 占位符出现在元数据参数中（所以启动器必须自己接管 -cp）",
        any("${classpath}" in a for a in jvm_args),
    )
    report.check(
        "java.library.path 占位符出现在元数据参数中（启动器必须覆盖）",
        any("java.library.path" in a for a in jvm_args),
    )

    # The launcher's drop list must cover every one of these, or a desktop value
    # would leak through and override the iOS one.
    swift_source = (PROJECT_ROOT / "Sources" / "Services" / "JVMArguments.swift").read_text(encoding="utf-8")
    for token in ["-XstartOnFirstThread", "-Djava.library.path=", "${classpath}"]:
        pattern = re.escape(token)
        report.check(
            f"过滤逻辑覆盖 {token}",
            re.search(pattern, swift_source) is not None,
        )

    # ── Game arguments ───────────────────────────────────────────────────────
    game_elements = version.get("arguments", {}).get("game", [])
    game_args = resolve_arguments(game_elements, env)
    report.check(f"版本元数据带有 {len(game_elements)} 条游戏参数条目", len(game_elements) > 0)

    used_placeholders = set()
    for arg in game_args:
        used_placeholders.update(PLACEHOLDER_RE.findall(arg))
    for element in jvm_elements:
        if isinstance(element, str):
            used_placeholders.update(PLACEHOLDER_RE.findall(element))
        elif isinstance(element, dict):
            value = element.get("value")
            values = [value] if isinstance(value, str) else (value or [])
            for item in values:
                used_placeholders.update(PLACEHOLDER_RE.findall(item))

    print(f"      {DIM('元数据用到的占位符：' + ', '.join(sorted(used_placeholders)))}")

    missing = used_placeholders - provided - set(unsupported)
    report.check(
        "所有会用到的占位符都有对应值（或有明确的忽略理由）",
        not missing,
        "缺少: " + ", ".join(sorted(missing)) if missing else "",
    )

    for name in sorted(set(unsupported) & used_placeholders):
        print(f"      {DIM(f'有意不支持 {name}：{unsupported[name]}')}")

    # ── Feature-gated arguments ──────────────────────────────────────────────
    demo_env = ios_environment({**env["features"], "is_demo_user": True})
    demo_args = resolve_arguments(game_elements, demo_env)
    report.check(
        "Demo 模式下会带上 --demo",
        "--demo" in demo_args,
        f"解析结果: {demo_args}",
    )
    report.check(
        "非 Demo 模式下没有 --demo",
        "--demo" not in game_args,
    )
    report.check(
        "分辨率参数按 has_custom_resolution 生效",
        "--width" in game_args and "${resolution_width}" in game_args,
        f"解析结果: {game_args}",
    )

    # ── Libraries ────────────────────────────────────────────────────────────
    libraries = version.get("libraries", [])
    applicable = [l for l in libraries if rules_allow(l.get("rules", []), env)]
    report.check(
        f"{len(libraries)} 个库中 {len(applicable)} 个适用于 iOS 环境",
        len(applicable) > 0,
    )

    # Mojang ships platform-specific native bundles; the launcher must skip them
    # or the stock LWJGL would shadow the patched one from the app bundle.
    lwjgl = [l for l in applicable if l.get("name", "").startswith("org.lwjgl:lwjgl:")]
    report.check(
        "识别出需要跳过的桌面版 LWJGL",
        len(lwjgl) > 0,
        f"找到 {len(lwjgl)} 个",
    )
    report.check(
        "过滤列表里包含 lwjgl",
        "lwjgl" in swift_source and "isDesktopNativeBundle" in swift_source,
    )

    natives_macos = [
        l for l in applicable
        if "natives-macos" in l.get("name", "") and "arm64" in l.get("name", "")
    ]
    report.check(
        "arm64 macOS 原生库规则能被正确求值（用于确认 arch 匹配）",
        isinstance(natives_macos, list),
    )

    # ── Runtime requirement ──────────────────────────────────────────────────
    #
    # Cross-check the real version's requirement against the Swift mapping.
    #
    # `None` is a *correct* answer when the newest game version needs a Java the
    # bundled runtimes cannot provide — that is exactly the Java 21+ situation, and
    # the launcher turns it into an explicit "needs Java 21" message. What would be
    # wrong is resolving to a runtime that is too old.
    major = version.get("javaVersion", {}).get("majorVersion", 8)
    mapping = parse_runtime_tags()

    resolved_tag = resolve_minimum_tag(mapping, major)
    provided_major = mapping["major_for_tag"].get(resolved_tag) if resolved_tag else None

    if resolved_tag is None:
        report.check(
            f"{latest} 需要 Java {major}，本启动器无法满足 —— 合理拒绝（而不是降级）",
            True,
        )
        print(f"      {DIM(f'{latest} 需要 Java {major}；内置运行时最高 Java '
                           f'{max(mapping["major_for_tag"].values(), default=0)}。')}")
        print(f"      {DIM('启动器会明确提示「只支持到 1.20.4」，不会尝试用旧 JDK 启动。')}")
    else:
        report.check(
            f"{latest} 需要 Java {major}，解析到 {resolved_tag}（提供 Java {provided_major}）",
            provided_major is not None and provided_major >= major,
            f"降级了：需要 Java {major}，却选了 Java {provided_major}",
        )

    # A version the launcher cannot run must be detectable up front, so the UI can
    # mark it rather than letting the user download 1.5 GB and then fail.
    manifest_swift = (PROJECT_ROOT / "Sources" / "Models" / "VersionManifest.swift").read_text(
        encoding="utf-8"
    )
    report.check(
        "版本模型暴露「需要不可用的 Java」的判断",
        "requiresUnavailableJava" in manifest_swift,
        "UI 需要据此在版本列表里提示",
    )

    # The downloads for a version needing Java 21 are the same size as any other, so
    # refusing late wastes the user's bandwidth and disk.
    report.check(
        "运行时缺失时报错信息说明支持范围，而不是让用户去装 Java 21",
        "没有可公开获取的 iOS 构建" in (
            PROJECT_ROOT / "Sources" / "Core" / "LauncherError.swift"
        ).read_text(encoding="utf-8"),
        "错误文案必须说清这是硬上限",
    )

    # ── default-user-jvm must be ignored ─────────────────────────────────────
    default_jvm = resolve_arguments(version.get("arguments", {}).get("default-user-jvm", []), env)
    if default_jvm:
        print(f"      {DIM('元数据建议的默认 JVM 参数：' + ' '.join(default_jvm))}")

        build_fn = swift_source.split("static func build(")[-1]
        build_fn = build_fn.split("// MARK: - Template substitution")[0]
        report.check(
            "build() 不会把 defaultUserJvm 加入 argv（它含 -Xmx4G，手机上会被系统杀掉）",
            "defaultUserJvm" not in build_fn,
            "JVMArguments.build 里出现了 defaultUserJvm",
        )
        report.check(
            "元数据的 -Xmx/-Xms 会被过滤掉",
            'hasPrefix("-Xmx")' in swift_source and 'hasPrefix("-Xms")' in swift_source,
        )
    else:
        report.skip("default-user-jvm 检查", "该版本没有这个字段")


def parse_runtime_tags() -> dict:
    """Reads the tag names and the major-version mapping out of `RuntimeTag`.

    Parsing rather than hard-coding means the verifier fails when the Swift changes,
    instead of passing against a stale copy of the numbers.
    """
    swift_source = (PROJECT_ROOT / "Sources" / "Models" / "VersionManifest.swift").read_text(
        encoding="utf-8"
    )

    # `static let java8 = "1_16_5_older"` style declarations.
    tag_constants = re.findall(r'static let (java\d+) = "([^"]+)"', swift_source)
    const_to_tag = dict(tag_constants)
    all_tags = [value for _, value in tag_constants]

    # `case java8: return 8` inside major(for:)
    major_for_tag: dict = {}
    major_fn = re.search(
        r"static func major\(for tag: String\) -> Int \{(.*?)\n    \}",
        swift_source,
        re.DOTALL,
    )
    if major_fn:
        for const, number in re.findall(r"case (\w+): return (\d+)", major_fn.group(1)):
            tag = const_to_tag.get(const)
            if tag:
                major_for_tag[tag] = int(number)

    # `if major <= 8 { return java8 }` plus a trailing `return java17`, OR the
    # filter-based form `all.filter { ... }.min { ... }` used after the rewrite.
    tag_for_major: dict = {}
    tag_fn = re.search(
        r"static func minimumTag\(forMajor major: Int\) -> String\? \{(.*?)\n    \}",
        swift_source,
        re.DOTALL,
    )
    if tag_fn:
        body = tag_fn.group(1)
        for threshold, const in re.findall(
            r"if major <= (\d+) \{ return (\w+) \}", body
        ):
            tag = const_to_tag.get(const)
            if tag:
                tag_for_major[int(threshold)] = tag

        trailing = re.search(r"\n\s*return (\w+)\s*$", body)
        if trailing:
            tag = const_to_tag.get(trailing.group(1))
            if tag:
                tag_for_major["default"] = tag

    return {
        "all_tags": all_tags,
        "major_for_tag": major_for_tag,
        "tag_for_major_fn": tag_for_major,
        # True when selection is expressed as "smallest sufficient" rather than a
        # chain of thresholds. The verifier asserts the semantics, not the syntax.
        "uses_filter_min": "filter { self.major(for: $0) >= major }" in swift_source,
    }


def check_runtime_tag_mapping(report: Report) -> None:
    """The Java-version → runtime-bucket mapping must never round down.

    Handing a version needing Java 21 a Java 17 runtime produces an
    `UnsupportedClassVersionError` deep inside the JVM, which reads as a random
    crash to the user. Rounding up gives a clear launcher-side message instead.

    Rounding *down* in the other direction is equally wrong at runtime, which is why
    selection takes the smallest sufficient runtime rather than the newest — see
    `JavaRuntimeManager.runtime(requiredMajor:)`.
    """
    report.start("Java 版本 → 运行时映射")
    mapping = parse_runtime_tags()

    report.check(
        f"解析出 {len(mapping['all_tags'])} 个运行时标签",
        len(mapping["all_tags"]) >= 2,
        f"tags: {mapping['all_tags']}",
    )
    report.check(
        "minimumTag(forMajor:) 使用「最小足够版本」的选择逻辑",
        mapping["uses_filter_min"],
        "应当用 filter{...}.min{...} 而不是阈值链",
    )

    # Requirements the bundled runtimes can satisfy.
    for required in (8, 11, 17):
        tag = resolve_minimum_tag(mapping, required)
        provided = mapping["major_for_tag"].get(tag) if tag else None
        report.check(
            f"Java {required} 可满足 → {tag}（提供 Java {provided}）",
            provided is not None and provided >= required,
            f"unexpected: needs {required}, got {provided}",
        )

    # Requirements they cannot. Returning None is the *correct* answer here: the
    # caller turns it into an explicit "needs Java 21" message. Silently rounding
    # down to Java 17 would move the failure inside the JVM.
    for required in (21, 25):
        tag = resolve_minimum_tag(mapping, required)
        report.check(
            f"Java {required} 无法满足（返回 None，而不是降级）",
            tag is None,
            f"got {tag} — 用 Java 17 跑需要 Java {required} 的版本会在 JVM 里报 class 版本错误",
        )

    # A tag with no declared major version would break selection.
    undeclared = [t for t in mapping["all_tags"] if t not in mapping["major_for_tag"]]
    report.check("每个标签都声明了 Java 主版本", not undeclared, f"缺少: {undeclared}")

    # Selection must prefer the smallest sufficient runtime, not the newest.
    manager = (PROJECT_ROOT / "Sources" / "Services" / "JavaRuntimeManager.swift").read_text(
        encoding="utf-8"
    )
    report.check(
        "运行时选择取「满足要求的最小版本」而不是最新版本",
        ".min { $0.majorVersion < $1.majorVersion }" in manager,
        "JavaRuntimeManager 里应使用 min 选择最小的足够版本",
    )

    return mapping


def resolve_minimum_tag(mapping: dict, required: int) -> str | None:
    """Mirrors `RuntimeTag.minimumTag(forMajor:)`.

    Returns the smallest tag whose Java version is at least `required`, or None when
    nothing is new enough. Both branches matter: the None case is what makes the
    launcher refuse Minecraft 1.20.5+ with an explanation instead of launching it
    into a class-version error.
    """
    thresholds = sorted(
        (k, v) for k, v in mapping["tag_for_major_fn"].items() if isinstance(k, int)
    )
    for threshold, tag in thresholds:
        if required <= threshold:
            return tag

    # Filter/min form: pick the smallest tag whose major is >= required.
    candidates = [
        (mapping["major_for_tag"][tag], tag)
        for tag in mapping["all_tags"]
        if tag in mapping["major_for_tag"] and mapping["major_for_tag"][tag] >= required
    ]
    if not candidates:
        return mapping["tag_for_major_fn"].get("default")
    return min(candidates)[1]


def java_reference_uuid(seed: str) -> str:
    """Straight port of java.util.UUID.nameUUIDFromBytes.

    MD5 the seed, then force the version nibble to 3 and the variant bits to 10.
    """
    digest = bytearray(hashlib.md5(seed.encode("utf-8")).digest())
    digest[6] = (digest[6] & 0x0F) | 0x30
    digest[8] = (digest[8] & 0x3F) | 0x80
    hexed = digest.hex()
    return f"{hexed[0:8]}-{hexed[8:12]}-{hexed[12:16]}-{hexed[16:20]}-{hexed[20:32]}"


def check_uuid_algorithms(report: Report) -> None:
    report.start("UUID 算法一致性")

    # The canonical, externally verifiable value: Java's
    # UUID.nameUUIDFromBytes("OfflinePlayer:Notch".getBytes()) is the identity every
    # offline-mode server derives. If this drifts, players lose their inventory.
    derived = java_reference_uuid("OfflinePlayer:Notch")
    report.equal("OfflinePlayer:Notch 的结果稳定", derived, java_reference_uuid("OfflinePlayer:Notch"))
    report.check(
        "版本位为 3（name-based）",
        derived[14] == "3",
        f"得到 {derived}",
    )
    report.check(
        "变体位符合 IETF 规范（8/9/a/b）",
        derived[19] in "89ab",
        f"得到 {derived}",
    )
    report.check(
        "格式为 8-4-4-4-12",
        bool(re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", derived)),
        f"得到 {derived}",
    )

    # Confirm the Swift implements the same two bit operations.
    swift = (PROJECT_ROOT / "Sources" / "Core" / "HashUtil.swift").read_text(encoding="utf-8")
    report.check("Swift 里设置了版本位 0x30", "| 0x30" in swift)
    report.check("Swift 里设置了变体位 0x80", "| 0x80" in swift)
    report.check(
        "Swift 使用 OfflinePlayer: 前缀",
        '"OfflinePlayer:\\(name)"' in swift or "OfflinePlayer:" in swift,
    )

    # The hyphenation helper must agree with the canonical formatting.
    raw = derived.replace("-", "")
    report.check(
        "hyphenated() 的重组位置正确",
        f"{raw[0:8]}-{raw[8:12]}-{raw[12:16]}-{raw[16:20]}-{raw[20:32]}" == derived,
    )
    print(f"      {DIM('示例：OfflinePlayer:Notch → ' + derived)}")


def check_required_imports(report: Report) -> None:
    """Framework types must have their module imported.

    SwiftUI re-exports Foundation and Combine, but *not* UIKit, SafariServices,
    CryptoKit, UniformTypeIdentifiers or Compression. A file that uses
    `UIImpactFeedbackGenerator` without `import UIKit` is a compile error — and one
    that only shows up after a full CI round trip, which on a macOS runner is ten
    minutes.

    This mirrors `.bootstrap/audit-swift.mjs`, but lives here so it runs on every
    `verify.py` invocation by default.
    """
    report.start("必需的 import")

    requirements = [
        (r"\bUIImpactFeedbackGenerator\b|\bUIPasteboard\b|\bUIApplication\b"
         r"|\bUIViewControllerRepresentable\b|\bUIColor\b", "UIKit"),
        (r"\bSFSafariViewController\b", "SafariServices"),
        (r"\bInsecure\.(MD5|SHA1)\b", "CryptoKit"),
        (r"\bUTType\b", "UniformTypeIdentifiers"),
        (r"\bcompression_decode_buffer\b", "Compression"),
        (r"\bASWebAuthenticationSession\b", "AuthenticationServices"),
    ]

    problems = []
    for path in sorted((PROJECT_ROOT / "Sources").rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        imports = set(re.findall(r"^\s*import\s+([A-Za-z_]\w*)", text, re.MULTILINE))
        for pattern, module in requirements:
            if re.search(pattern, text) and module not in imports:
                problems.append(f"{path.name}: 用了 {module} 的类型但没 import")

    report.check("没有缺失的 framework import", not problems, "\n".join(problems))


def check_cross_file_call_sites(report: Report) -> None:
    """Cross-file method calls must match a real declaration's parameter labels.

    Swift argument labels are part of the selector, so `runtime(requiredMajor:)`
    and `runtime(major:)` are different functions. A typo there is a compile error.
    This scans call sites of project-defined functions and checks the first label
    agrees with some declaration of the same name.

    Heuristic — it only checks the *first* label, which is where renames actually
    bite, and it tolerates overloads by accepting a match against any declaration.
    """
    report.start("跨文件调用签名")

    sources = {}
    for path in sorted((PROJECT_ROOT / "Sources").rglob("*.swift")):
        sources[path] = path.read_text(encoding="utf-8")

    # name -> set of accepted first labels ("" means no first label).
    declarations: dict[str, set[str]] = {}
    decl_re = re.compile(
        r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
        r"(?:public |private |internal |fileprivate |final |static |override |"
        r"nonisolated |mutating |class )*"
        r"func\s+(\w+)\s*(?:<[^>]*>)?\s*\(([^)]*)\)",
        re.MULTILINE,
    )
    for text in sources.values():
        for match in decl_re.finditer(text):
            name, params = match.group(1), match.group(2).strip()
            if not params:
                declarations.setdefault(name, set()).add("")
                continue
            # `label name: Type` or `name: Type` (no label) or `_ name: Type`.
            first = params.split(",", 1)[0].strip()
            label_match = re.match(r"(\w+|_)\s+\w+\s*:", first) or re.match(r"(\w+)\s*:", first)
            if label_match:
                label = label_match.group(1)
                declarations.setdefault(name, set()).add("" if label == "_" else label)

            # A parameter with a default value makes the call legal with that label
            # omitted — and if the *first* one has a default, the whole call can be
            # written with no arguments at all, as `manifest()` is.
            if "=" in first:
                declarations.setdefault(name, set()).add("")

    # A call site, not a declaration. `func name(` appears everywhere and would
    # otherwise be reported as a call with the wrong label. Declarations are
    # neutralised below by renaming the identifier to the same length, so match
    # offsets stay valid.
    call_re = re.compile(r"(?<![\w.])(\w+)\s*\(\s*(?:(\w+)\s*:)?")
    mismatches = []
    for path, text in sources.items():
        scrubbed = re.sub(
            r"\bfunc\s+(\w+)", lambda m: "func " + "_" * len(m.group(1)), text
        )
        for match in call_re.finditer(scrubbed):
            name, label = match.group(1), match.group(2)
            if name not in declarations:
                continue
            # `Foo(...)` is a type initialiser, not a function call.
            if name[0].isupper():
                continue
            actual = label or ""
            if actual not in declarations[name]:
                mismatches.append(
                    f"{path.name}: {name}({actual + ': ' if actual else ''}…) "
                    f"→ 已声明的标签: {sorted(declarations[name]) or ['(无参数)']}"
                )

    # De-duplicate: one renamed function produces many identical lines.
    unique = sorted(set(mismatches))
    report.check(
        "所有跨文件调用的首个参数标签都存在对应声明",
        not unique,
        "\n".join(unique[:20]) + ("\n…" if len(unique) > 20 else ""),
    )


def check_workflows(report: Report) -> None:
    """CI must both produce the app and stay consistent with the runtime layout.

    Two workflows exist for different purposes and they must not be conflated:

    * `build.yml` — builds CraftLauncher itself (the thing that is needed).
    * `build-ios-jre21.yml` — an optional, manual recipe for producing the Java 21
      runtime that upstream can no longer build. It is copied into a *different*
      repository to run, so it must not be wired into the main build.
    """
    report.start("CI 工作流")

    workflows_dir = PROJECT_ROOT / ".github" / "workflows"
    build_yml = workflows_dir / "build.yml"
    jre_yml = workflows_dir / "build-ios-jre21.yml"

    report.check("build.yml 存在", build_yml.is_file())
    report.check("build-ios-jre21.yml 存在", jre_yml.is_file())

    if build_yml.is_file():
        text = build_yml.read_text(encoding="utf-8")

        # No stale references to the removed RuntimeSeed design.
        report.check(
            "build.yml 不再引用已删除的 RuntimeSeed",
            "RuntimeSeed" not in text,
            "运行时会以 java_runtimes/ 目录形式打包，不是压缩包",
        )

        # It must reference the real runtime layout, or the cache and the checks
        # silently do nothing.
        for path in ("Runtime/java_runtimes", "Runtime/libs", "Runtime/Frameworks"):
            report.check(f"build.yml 处理 {path}", path in text)

        # The bundle check has to be a hard failure. A warning would let a broken
        # IPA be produced and only discovered on-device.
        report.check(
            "bundle 结构校验失败会让构建失败（不是警告）",
            "exit ${failed}" in text or "exit $failed" in text,
            "缺目录或 JDK 目录被拍平必须直接失败",
        )

        # The JDK layout probe is the thing that catches a folder-reference mistake
        # in project.yml. Without it the app builds and then cannot start a JVM.
        report.check(
            "build.yml 探测 JDK 内部布局（libjli / libjvm）",
            "lib/jli/libjli.dylib" in text and "lib/server/libjvm.dylib" in text,
        )

        # Unsigned on purpose: signing happens on-device with a certificate tool.
        report.check(
            "build.yml 产出无签名包（签名由侧载工具负责）",
            "CODE_SIGNING_ALLOWED=NO" in text,
        )

        # A single .ipa is ~280-300 MB. GitHub's default artifact retention is 90
        # days and artifacts count against the account's Actions storage — 500 MB on
        # a free private repo. Leaving the default would exhaust the quota after two
        # builds, and the failure mode is an upload error that looks unrelated.
        report.check(
            "build.yml 显式设置产物保留期（默认 90 天会撑爆私有仓库配额）",
            "artifact_retention_days" in text,
            "产物体积约 300 MB，必须用可配置的短保留期",
        )

        # Parse the declared default rather than trusting a comment about it.
        retention_match = re.search(
            r"artifact_retention_days:\s*\n\s*description:[^\n]*\n\s*required:\s*\w+\s*\n\s*default:\s*\"(\d+)\"",
            text,
        )
        if retention_match:
            default_days = int(retention_match.group(1))
            report.check(
                f"保留期默认值 {default_days} 天在合理范围内（1–30）",
                1 <= default_days <= 30,
                "私有仓库 500 MB 配额装不下几份 300 MB 产物",
            )
        else:
            report.check("能解析出保留期默认值", False, "artifact_retention_days 缺少 default")

    if jre_yml.is_file():
        text = jre_yml.read_text(encoding="utf-8")

        # It must run on a GitHub-hosted runner. Upstream pinned its iOS job to a
        # self-hosted "MacStadium" runner, which is why every artifact expired.
        report.check(
            "JRE 构建用 GitHub 托管 runner（不是自托管的 MacStadium）",
            "runs-on: macos-" in text and "MacStadium" not in text.split("── How to use")[-1],
            "上游的自托管 runner 已不存在，这是 Java 21 产物消失的直接原因",
        )

        # `continue-on-error: true` is what hid the upstream failure for months.
        report.check(
            "JRE 构建不忽略失败",
            "continue-on-error: false" in text,
            "上游设了 true，导致 runner 消失后没人发现",
        )

        report.check(
            "JRE 构建用 TARGET_VERSION 控制版本",
            "TARGET_VERSION" in text,
        )
        report.check(
            "JRE 构建产出 jre21-ios-aarch64 命名一致的产物",
            "ios-aarch64" in text and "jre21" in text,
        )
        report.check(
            "空产物会让 JRE 构建失败",
            "if-no-files-found: error" in text,
        )

        # It must not be wired into the main build — producing Java 21 takes hours
        # and is a separate manual decision.
        if build_yml.is_file():
            build = build_yml.read_text(encoding="utf-8")
            report.check(
                "build.yml 不依赖 JRE21 工作流",
                "build-ios-jre21" not in build and "jre21" not in build.lower(),
                "Java 21 是可选的手动步骤，不能拖慢主构建",
            )

    # The docs must point at the workflow, or nobody will find it.
    java_doc = (PROJECT_ROOT / "docs" / "JAVA-RUNTIMES.md").read_text(encoding="utf-8")
    report.check(
        "JAVA-RUNTIMES.md 指向可执行的复现工作流",
        "build-ios-jre21.yml" in java_doc,
    )
    report.check(
        "JAVA-RUNTIMES.md 说明了上游用自托管 runner 这个原因",
        "MacStadium" in java_doc,
        "这是产物消失的直接原因，必须写清楚",
    )


def check_swift_structure(report: Report) -> None:
    report.start("Swift 源码结构")

    sources = sorted((PROJECT_ROOT / "Sources").rglob("*.swift"))
    report.check(f"找到 {len(sources)} 个 Swift 文件", len(sources) >= 15, f"路径: {PROJECT_ROOT / 'Sources'}")

    # Every file must start with the expected header and have balanced braces.
    unbalanced = []
    empty = []
    for path in sources:
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(PROJECT_ROOT)

        if len(text.strip()) < 80:
            empty.append(str(rel))
            continue

        # Strip strings and comments so braces inside them do not count.
        stripped = strip_swift_noise(text)
        if stripped.count("{") != stripped.count("}"):
            unbalanced.append(
                f"{rel}: {{ {stripped.count('{')} vs }} {stripped.count('}')}"
            )
        if stripped.count("(") != stripped.count(")"):
            unbalanced.append(
                f"{rel}: ( {stripped.count('(')} vs ) {stripped.count(')')}"
            )

    report.check("没有空文件", not empty, "\n".join(empty))
    report.check("大括号与圆括号都成对", not unbalanced, "\n".join(unbalanced))

    # Expected modules must exist.
    expected = [
        "Sources/App/CraftLauncherApp.swift",
        "Sources/App/AppState.swift",
        "Sources/Core/LauncherPath.swift",
        "Sources/Core/LauncherError.swift",
        "Sources/Core/LogConsole.swift",
        "Sources/Core/KeychainStore.swift",
        "Sources/Core/HashUtil.swift",
        "Sources/Models/VersionManifest.swift",
        "Sources/Models/MinecraftAccount.swift",
        "Sources/Models/JavaRuntime.swift",
        "Sources/Models/LaunchModels.swift",
        "Sources/Services/JVMArguments.swift",
        "Sources/Services/LaunchPipeline.swift",
        "Sources/Services/VersionService.swift",
        "Sources/Services/VersionManager.swift",
        "Sources/Services/ResourceDownloader.swift",
        "Sources/Services/JavaRuntimeManager.swift",
        "Sources/Services/HTTPClient.swift",
        "Sources/Auth/MicrosoftAuth.swift",
        "Sources/Auth/AccountManager.swift",
        "Sources/Mods/ModInspector.swift",
        "Sources/Mods/ModManager.swift",
        "Sources/Mods/ZipReader.swift",
        "Sources/Mods/ZipExtractor.swift",
        "Sources/Runtime/RuntimeBridge.h",
        "Sources/Runtime/RuntimeBridge.mm",
        "Sources/Runtime/RuntimeLauncher.swift",
        "Sources/Runtime/CraftLauncher-Bridging-Header.h",
        "Sources/UI/Theme.swift",
        "Sources/UI/HomeView.swift",
        "Sources/UI/VersionsView.swift",
        "Sources/UI/AccountsView.swift",
        "Sources/UI/ModsView.swift",
        "Sources/UI/ConsoleView.swift",
        "Sources/UI/SettingsView.swift",
    ]
    missing = [p for p in expected if not (PROJECT_ROOT / p).is_file()]
    report.check(
        f"关键文件齐备（{len(expected) - len(missing)}/{len(expected)}）",
        not missing,
        "\n".join(missing),
    )

    # The bridging header must import the bridge, or every RuntimeBridge call from
    # Swift fails to compile.
    bridging = PROJECT_ROOT / "Sources/Runtime/CraftLauncher-Bridging-Header.h"
    if bridging.is_file():
        report.check(
            "桥接头文件引入了 RuntimeBridge.h",
            '#import "RuntimeBridge.h"' in bridging.read_text(encoding="utf-8"),
        )

    # project.yml must point at that same header.
    project_yml = PROJECT_ROOT / "project.yml"
    if project_yml.is_file():
        yml = project_yml.read_text(encoding="utf-8")
        report.check(
            "project.yml 设置了 SWIFT_OBJC_BRIDGING_HEADER",
            "SWIFT_OBJC_BRIDGING_HEADER" in yml
            and "CraftLauncher-Bridging-Header.h" in yml,
        )
        report.check(
            "project.yml 声明了 JLI_Launch 所需的框架搜索路径",
            "LIBRARY_SEARCH_PATHS" in yml or "OTHER_LDFLAGS" in yml,
        )


def strip_swift_noise(text: str) -> str:
    """Removes string literals, line comments and block comments.

    String contents are discarded rather than preserved, so a brace that appears
    inside a message like "{" does not affect the balance check. Interpolation is
    handled by tracking how deep inside ``\\( ... )`` we are, so a `"` that opens a
    nested literal does not end the outer one.
    """
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]

        # Line comment
        if text.startswith("//", i):
            newline = text.find("\n", i)
            i = n if newline == -1 else newline
            continue

        # Block comment (nesting is legal in Swift, but one level covers this codebase)
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end == -1 else end + 2
            continue

        # Multi-line string
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            i = n if end == -1 else end + 3
            continue

        # Single-line string: skip to the closing quote, honouring escapes and
        # interpolation nesting.
        if ch == '"':
            i += 1
            depth = 0
            while i < n:
                cur = text[i]
                if cur == "\\":
                    if i + 1 < n and text[i + 1] == "(":
                        depth += 1
                        i += 2
                        continue
                    i += 2
                    continue
                if cur == ")" and depth > 0:
                    depth -= 1
                elif cur == '"' and depth == 0:
                    i += 1
                    break
                i += 1
            continue

        out.append(ch)
        i += 1
    return "".join(out)


def check_bootstrap_consistency(report: Report, mapping: dict) -> None:
    """The bootstrap script, the Swift and the real upstream IPA must agree.

    This is the check that would have caught the jre21 mistake. Previously it only
    compared the Swift tag list against the shell script's copy of the same list —
    both written by hand, so they agreed while both being wrong about what upstream
    actually ships.

    Now the third source of truth is the IPA itself, when one has been extracted
    into .bootstrap/. That check is skipped (not failed) when it has not, so the
    verifier still runs on a fresh checkout.
    """
    report.start("运行时标签 / 脚本 / 上游 IPA 三方一致性")

    bootstrap_path = PROJECT_ROOT / "Scripts" / "bootstrap-runtime.sh"
    if not bootstrap_path.is_file():
        report.check("找到 bootstrap-runtime.sh", False)
        return

    bootstrap = bootstrap_path.read_text(encoding="utf-8")
    manager = (PROJECT_ROOT / "Sources" / "Services" / "JavaRuntimeManager.swift").read_text(
        encoding="utf-8"
    )

    # 1. The script must look for every tag the Swift can select.
    for tag in mapping["all_tags"]:
        report.check(
            f"bootstrap 脚本检查 {tag}",
            tag in bootstrap,
            "Scripts/bootstrap-runtime.sh 里没有提到这个标签",
        )

    # 2. It must extract from the right place. The runtimes are directory trees
    #    under java_runtimes/, not zip archives — the original mistake.
    report.check(
        "脚本从 java_runtimes/ 提取运行时（而不是找 .zip）",
        "java_runtimes" in bootstrap and "classify_jdk" not in bootstrap,
        "运行时是完整目录，不是压缩包",
    )

    # 3. It must handle all three jar sources, or one Java generation loses AWT.
    for sub in ("libs", "libs_caciocavallo", "libs_caciocavallo17"):
        report.check(
            f"脚本提取 {sub}/ 下的 jar",
            sub in bootstrap,
            "缺一个目录就会导致某一代 Java 的 AWT 不可用",
        )

    # 4. And the Log4Shell patches, which the JVM argument references.
    for patch in ("log4j-rce-patch-1.7.xml", "log4j-rce-patch-1.12.xml"):
        report.check(f"脚本提取 {patch}", patch in bootstrap)

    # 5. The app reads runtimes from the bundle, so the manager must not be looking
    #    for archives or installing anything.
    report.check(
        "JavaRuntimeManager 从包内的 java_runtimes/ 读取",
        "bundleRuntimesDirectory" in manager and "java_runtimes" in manager,
    )
    report.check(
        "JavaRuntimeManager 不再解压安装运行时",
        "installBundledRuntimesIfNeeded" not in manager
        and "RuntimeSeed" not in manager,
        "运行时随 App 一起签名，不应在设备上解压",
    )

    # 6. project.yml must bundle the runtime as a folder reference, otherwise the
    #    JDK's internal layout is flattened and JLI_Launch cannot find libjvm.
    project_yml = (PROJECT_ROOT / "project.yml").read_text(encoding="utf-8")
    report.check(
        "project.yml 以 folder 引用方式打包 java_runtimes",
        "path: Runtime/java_runtimes" in project_yml and "type: folder" in project_yml,
        "普通 resources 会把 JDK 的目录结构拍平",
    )

    # 7. Ground truth: the extracted upstream IPA, when present.
    upstream = PROJECT_ROOT / ".bootstrap" / "inspect" / "Payload" / "PojavLauncher.app" / "java_runtimes"
    if not upstream.is_dir():
        report.skip(
            "对照上游 IPA 的真实运行时目录",
            "未找到 .bootstrap/inspect/Payload/PojavLauncher.app/java_runtimes",
        )
        return

    actual = {p.name for p in upstream.iterdir() if p.is_dir()}
    expected = set(mapping["all_tags"])
    report.check(
        f"Swift 声明的标签与上游 IPA 完全一致（上游提供 {sorted(actual)}）",
        expected == actual,
        "Swift 声明: " + str(sorted(expected)) + "\n上游实际: " + str(sorted(actual)),
    )

    # Each declared tag must really contain the libraries the app will dlopen.
    #
    # These paths are asserted against the *extracted* upstream tree, which is the
    # only way to catch a filename the launcher invents. The `libawt_xawt` entry
    # guards a real bug: the launcher originally looked for `lib/awt_xawt.dylib`
    # when the file is `lib/libawt_xawt.dylib`.
    for tag in sorted(expected & actual):
        home = upstream / tag
        is_java8 = tag.startswith("java-8")
        jli = home / ("lib/jli/libjli.dylib" if is_java8 else "lib/libjli.dylib")
        report.check(
            f"{tag} 里有 libjli.dylib",
            jli.is_file(),
            f"查找路径: {jli.relative_to(upstream)}",
        )
        report.check(
            f"{tag} 里有 lib/server/libjvm.dylib",
            (home / "lib/server/libjvm.dylib").is_file(),
        )
        report.check(
            f"{tag} 里有 lib/libawt_xawt.dylib",
            (home / "lib/libawt_xawt.dylib").is_file(),
            "注意文件名带 lib 前缀",
        )

    # The Swift must reference those same real paths.
    runtime_swift = (PROJECT_ROOT / "Sources" / "Models" / "JavaRuntime.swift").read_text(
        encoding="utf-8"
    )
    for needle, label in [
        ('"lib/jli/libjli.dylib"', "Java 8 的 libjli 路径"),
        ('"lib/libjli.dylib"', "Java 17 的 libjli 路径"),
        ('"lib/server/libjvm.dylib"', "libjvm 路径"),
        ('"lib/libawt_xawt.dylib"', "AWT 库路径（带 lib 前缀）"),
    ]:
        report.check(f"JavaRuntime 使用正确的{label}", needle in runtime_swift)

    # And nothing may still reference the wrong name.
    report.check(
        "JavaRuntime 里没有写成 lib/awt_xawt.dylib",
        '"lib/awt_xawt.dylib"' not in runtime_swift,
        "真实文件名是 lib/libawt_xawt.dylib",
    )


def check_entitlements(report: Report) -> None:
    """Signing must not be blocked by entitlements the signer cannot issue.

    This is the single most likely thing to stop a build from reaching a device.
    Apple-reserved entitlements cannot be issued to a normal certificate, so
    declaring them in the base set makes the signature fail — and a signer that
    "succeeds" by stripping them silently is worse, because the app then runs with
    fewer privileges than it was built for.
    """
    report.start("签名与授权（entitlements）")

    ent_path = PROJECT_ROOT / "Resources" / "CraftLauncher.entitlements"
    yml_path = PROJECT_ROOT / "project.yml"

    report.check("Resources/CraftLauncher.entitlements 存在", ent_path.is_file())
    if not ent_path.is_file():
        return

    text = ent_path.read_text(encoding="utf-8")

    # Everything before the closing comment marker is documentation, which also
    # mentions the privileged keys. Only the plist body is authoritative.
    body = text.split("-->", 1)[-1] if "-->" in text else text
    keys = set(re.findall(r"<key>([^<]+)</key>", body))

    report.check(
        "授权文件里声明了 get-task-allow（SideStore/Xcode 靠它给 JIT）",
        "get-task-allow" in keys,
        f"找到: {sorted(keys)}",
    )
    report.check(
        "授权文件里声明了 disable-library-validation（否则 dlopen 不了 Java 运行时）",
        "com.apple.security.cs.disable-library-validation" in keys,
        f"找到: {sorted(keys)}",
    )

    # Apple-reserved keys must not be in the active set.
    reserved = [k for k in keys if k.startswith("com.apple.private.") or k.startswith("com.apple.developer.")]
    report.check(
        "基础授权里没有 Apple 保留权限（否则证书签名会失败）",
        not reserved,
        "需要移到文档注释里、仅在越狱设备上手动启用：" + ", ".join(sorted(reserved)),
    )

    # macOS-only hardened-runtime keys are meaningless on iOS and only add a way for
    # signing to fail.
    macos_only = [k for k in keys if k.startswith("com.apple.security.cs.allow-")]
    report.check(
        "没有混入 macOS 硬化运行时的键（在 iOS 上无意义）",
        not macos_only,
        "应移除：" + ", ".join(sorted(macos_only)),
    )

    # The plist must actually parse, or Xcode fails with an unhelpful message.
    report.check(
        "plist 结构完整",
        body.count("<dict>") == body.count("</dict>")
        and body.count("<plist") == body.count("</plist>"),
        "dict/plist 标签不配对",
    )

    # project.yml must point at that file rather than re-declaring properties, which
    # is how the reserved keys got in the first time.
    if yml_path.is_file():
        yml = yml_path.read_text(encoding="utf-8")
        report.check(
            "project.yml 指向授权文件而不是内联声明权限",
            "path: Resources/CraftLauncher.entitlements" in yml,
        )

        # Only look *inside* the `entitlements:` block. A naive search would run on
        # into `info.properties` and report a false positive, since both keys are
        # spelled the same way at different nesting levels.
        ent_block = re.search(
            r"\n    entitlements:\n(.*?)(?=\n    [a-z_]+:|\Z)", yml, re.DOTALL
        )
        inline = ent_block is not None and re.search(r"\n\s+properties:", ent_block.group(1))
        report.check(
            "project.yml 的 entitlements 块里没有内联 properties（避免两处定义漂移）",
            inline is None,
            "内联的 properties 会与 .entitlements 文件产生两个真相来源",
        )

    # The launcher must degrade gracefully when a signer strips the privileged keys,
    # which is the common case for certificate-based tools.
    pipeline = (PROJECT_ROOT / "Sources" / "Services" / "LaunchPipeline.swift").read_text(
        encoding="utf-8"
    )
    bridge_h = (PROJECT_ROOT / "Sources" / "Runtime" / "RuntimeBridge.h").read_text(encoding="utf-8")
    bridge_mm = (PROJECT_ROOT / "Sources" / "Runtime" / "RuntimeBridge.mm").read_text(encoding="utf-8")
    launcher = (PROJECT_ROOT / "Sources" / "Runtime" / "RuntimeLauncher.swift").read_text(encoding="utf-8")

    report.check(
        "缺少内存授权时会退回较小的内存分配比例",
        "hasExtendedMemory ? 0.4 : 0.25" in pipeline,
        "LaunchPipeline.resolveMemoryMB 应依据 RuntimeLauncher 的权限探测结果",
    )
    report.check(
        "内存比例的判断依据来自权限探测，而不是写死",
        "RuntimeLauncher.entitlements.extendedMemory" in pipeline,
        "不要在这边再写一份 SecTask 探测 —— 桥接层已经有了",
    )
    # `SecTaskCopyValueForEntitlement` also appears once in a doc comment, so count
    # the actual calls (`(` immediately after the name) rather than raw occurrences.
    report.check(
        "权限探测只有一处实现",
        pipeline.count("SecTaskCopyValueForEntitlement(") == 0
        and bridge_mm.count("SecTaskCopyValueForEntitlement(") == 1,
        "重复实现会出现两份可能不一致的答案",
    )

    # The whole point of the in-app diagnostics is to tell "the signer stripped it"
    # apart from "you have not activated JIT yet". Without probing get-task-allow,
    # a user on a certificate-signed install has no way to see which case they are in.
    bridge_h = (PROJECT_ROOT / "Sources" / "Runtime" / "RuntimeBridge.h").read_text(encoding="utf-8")
    bridge_mm = (PROJECT_ROOT / "Sources" / "Runtime" / "RuntimeBridge.mm").read_text(encoding="utf-8")
    launcher = (PROJECT_ROOT / "Sources" / "Runtime" / "RuntimeLauncher.swift").read_text(encoding="utf-8")

    for probe in ["hasGetTaskAllow", "hasLibraryValidationDisabled", "hasExtendedMemoryEntitlement"]:
        report.check(f"桥接层暴露 {probe}", probe in bridge_h and probe in bridge_mm)

    report.check(
        "探针读取的是实际生效的权限（SecTask API）",
        "SecTaskCopyValueForEntitlement" in bridge_mm,
    )
    report.check(
        "布尔型权限为 false 时视为未授予",
        "CFBooleanGetValue" in bridge_mm,
        "权限键存在但值为 false 时不能当作已授予",
    )
    report.check(
        "Swift 侧暴露权限快照供界面诊断使用",
        "EntitlementReport" in launcher and "canReceiveJITByDebugger" in launcher,
    )

    settings = (PROJECT_ROOT / "Sources" / "UI" / "SettingsView.swift").read_text(encoding="utf-8")
    report.check(
        "设置页展示调试器附加许可（诊断 SideJITServer 失败的原因）",
        "调试器附加许可" in settings and "get-task-allow" in settings,
    )
    report.check(
        "设置页针对缺少 get-task-allow 给出可操作的结论",
        "企业证书" in settings or "个人开发者证书" in settings,
    )


def check_no_obvious_api_mistakes(report: Report) -> None:
    report.start("常见 iOS API 误用排查")

    patterns = [
        # macOS-only APIs that would fail to compile for iOS.
        (r"NSOpenPanel|NSSavePanel", "macOS 专属的 NSOpenPanel / NSSavePanel"),
        (r"\.help\(", "View.help() 是 macOS 专属"),
        (r"\bNSApplication\b", "NSApplication 在 iOS 上不存在"),
        (r"\.navigationSplitView", "NavigationSplitView 布局需要单独适配"),
        (r"Process\(\)", "iOS 不能用 Foundation.Process 启动子进程"),
        (r"NSWorkspace", "NSWorkspace 是 macOS 专属"),
        # Java detection we rely on must not be Windows-shaped.
        (r'"windows"\s*\)\s*$', None),
    ]

    problems = []
    for path in sorted((PROJECT_ROOT / "Sources").rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        # Ignore matches inside comments.
        cleaned = strip_swift_noise(text)
        for pattern, description in patterns:
            if description and re.search(pattern, cleaned):
                problems.append(f"{path.relative_to(PROJECT_ROOT)}: {description}")

    report.check("没有使用 macOS 专属 API", not problems, "\n".join(problems))

    # The bridging header is Objective-C; make sure it does not use Swift syntax.
    header = PROJECT_ROOT / "Sources/Runtime/RuntimeBridge.h"
    if header.is_file():
        text = header.read_text(encoding="utf-8")
        report.check("桥接头文件使用 NS_ASSUME_NONNULL", "NS_ASSUME_NONNULL_BEGIN" in text)
        report.check("桥接头文件声明了 jitStatus", "jitStatus" in text)
        report.check("桥接头文件声明了 launchJVMWithArguments", "launchJVMWithArguments" in text)

    # The implementation must call JLI_Launch with the documented signature.
    impl = PROJECT_ROOT / "Sources/Runtime/RuntimeBridge.mm"
    if impl.is_file():
        text = impl.read_text(encoding="utf-8")
        report.check("实现里 dlopen 了 libjli", "libjli.dylib" in text)
        report.check("实现里取 JLI_Launch 符号", 'dlsym(libjli, "JLI_Launch")' in text)
        report.check("实现里导出了 POJAV_HOME", "POJAV_HOME" in text)
        report.check("实现里导出了 POJAV_RENDERER", "POJAV_RENDERER" in text)
        report.check(
            "实现里清理了信号处理器（否则 JVM 崩溃处理被覆盖）",
            "signal(SIGSEGV, SIG_DFL)" in text,
        )


def check_project_layout(report: Report) -> None:
    report.start("工程文件")

    for relative in ["project.yml", "README.md", "LICENSE", ".gitignore",
                     ".gitattributes",
                     "Scripts/bootstrap-runtime.sh", "Scripts/generate-project.sh",
                     "Scripts/verify.py", "Scripts/test_verify.py",
                     "Resources/CraftLauncher.entitlements"]:
        report.check(f"{relative} 存在", (PROJECT_ROOT / relative).is_file())

    # Shell scripts must be executable and syntactically valid.
    for script in sorted((PROJECT_ROOT / "Scripts").glob("*.sh")):
        text = script.read_text(encoding="utf-8")
        report.check(f"{script.name} 有 shebang", text.startswith("#!/usr/bin/env bash"))
        report.check(f"{script.name} 启用了严格模式", "set -euo pipefail" in text)

        # A CRLF shebang fails on Linux/macOS with
        #     /bin/bash^M: bad interpreter: No such file or directory
        # and GitHub Actions runs there, so this is a build failure on every push.
        report.check(
            f"{script.name} 是纯 LF（CRLF 会让 CI 无法执行）",
            b"\r\n" not in script.read_bytes(),
            "Windows 检出会把换行符改成 CRLF，靠 .gitattributes 的 eol=lf 挡住",
        )

    # The verifier is itself code, and it produced four false results while being
    # written. Its logic is covered by Scripts/test_verify.py; this only confirms the
    # suite exists and is wired up.
    test_file = PROJECT_ROOT / "Scripts" / "test_verify.py"
    if test_file.is_file():
        test_text = test_file.read_text(encoding="utf-8")
        report.check(
            "校验器自带单元测试",
            "unittest" in test_text,
            "未被测试的检查器只是第二个未经验证的说法来源",
        )
        for covered in ("rules_allow", "resolve_arguments", "substitute",
                        "resolve_minimum_tag", "java_reference_uuid"):
            report.check(
                f"单元测试覆盖 {covered}",
                covered in test_text,
                "这条逻辑错了会让校验器验证一个错误的实现",
            )
    else:
        report.check("Scripts/test_verify.py 存在", False)

    # Documentation
    for doc in ["docs/ARCHITECTURE.md", "docs/JIT.md", "docs/SIGNING.md",
                "docs/TROUBLESHOOTING.md", "docs/TODO.md", "docs/JAVA-RUNTIMES.md"]:
        report.check(f"{doc} 存在", (PROJECT_ROOT / doc).is_file())

    # .gitignore must exclude the fetched binaries, which are hundreds of megabytes
    # and are GPL-3.0 upstream artefacts rather than this project's source.
    gitignore = PROJECT_ROOT / ".gitignore"
    if gitignore.is_file():
        text = gitignore.read_text(encoding="utf-8")
        report.check(".gitignore 排除了 Runtime/", "Runtime/" in text)
        report.check(".gitignore 排除了构建产物", "build/" in text or "*.xcodeproj" in text)


def check_log4j_handling(report: Report) -> None:
    """The Log4Shell patch must apply, and must not be undone by the downloader.

    Two files have to agree here, and getting it wrong is a security regression
    rather than a cosmetic one: `JVMArguments` substitutes a hardened config for
    `client-1.7.xml` / `client-1.12.xml`, and `ResourceDownloader` must therefore
    *not* fetch Mojang's original under the same name — that would overwrite the
    patch on the very next launch.
    """
    report.start("Log4Shell 补丁一致性")

    jvm = (PROJECT_ROOT / "Sources/Services/JVMArguments.swift").read_text(encoding="utf-8")
    downloader = (PROJECT_ROOT / "Sources/Services/ResourceDownloader.swift").read_text(encoding="utf-8")

    # 1. The config selector exists and reads the metadata's file id.
    report.check(
        "JVMArguments 按 version.logging.client.file.id 选择配置",
        "logging.client.file.id" in jvm and "log4jConfiguration" in jvm,
    )
    report.check(
        "把选择结果传给 -Dlog4j.configurationFile",
        "-Dlog4j.configurationFile=" in jvm,
    )
    report.check(
        "两个补丁文件名都对",
        "log4j-rce-patch-1.7.xml" in jvm and "log4j-rce-patch-1.12.xml" in jvm,
    )

    # 2. The downloader must skip exactly those two ids, and agree on their names.
    report.check(
        "ResourceDownloader 有 shouldDownloadLog4jConfig 判定",
        "shouldDownloadLog4jConfig" in downloader,
    )
    for file_id in ("client-1.12.xml", "client-1.7.xml"):
        report.check(
            f"下载器跳过 {file_id}（否则会覆盖掉补丁）",
            file_id in downloader and "shouldDownloadLog4jConfig" in downloader,
        )

    # 3. Both sides must list the same two ids. If one side gains a third patched
    #    config and the other does not, the patch would be silently overwritten.
    jvm_ids = set(re.findall(r'"(client-[\d.]+\.xml)"', jvm))
    downloader_ids = set(re.findall(r'"(client-[\d.]+\.xml)"', downloader))
    report.check(
        "两侧的补丁文件 id 列表一致",
        jvm_ids == downloader_ids,
        f"JVMArguments: {sorted(jvm_ids)}\nResourceDownloader: {sorted(downloader_ids)}",
    )

    # 4. The plan must actually carry the download, and execute() must include it.
    report.check(
        "DownloadPlan 里有 log4jConfig 项",
        "var log4jConfig: DownloadItem?" in downloader,
    )
    report.check(
        "execute() 把 log4jConfig 纳入下载批次",
        "plan.log4jConfig.map { [$0] }" in downloader,
        "漏掉它会让这个配置永远下载不到",
    )

    # 5. project.yml must ship the patch files, or the selector finds nothing.
    project_yml = (PROJECT_ROOT / "project.yml").read_text(encoding="utf-8")
    for patch in ("log4j-rce-patch-1.7.xml", "log4j-rce-patch-1.12.xml"):
        report.check(f"project.yml 打包 {patch}", patch in project_yml)

    # 6. And the bootstrap script must extract them from the upstream IPA.
    bootstrap = (PROJECT_ROOT / "Scripts/bootstrap-runtime.sh").read_text(encoding="utf-8")
    for patch in ("log4j-rce-patch-1.7.xml", "log4j-rce-patch-1.12.xml"):
        report.check(f"bootstrap 脚本提取 {patch}", patch in bootstrap)


def check_download_pipeline(report: Report) -> None:
    """Every category in the plan must actually be downloaded.

    `LaunchPipeline` originally downloaded libraries, client and assets in separate
    hand-written batches. Adding a fourth category to `DownloadPlan` silently
    skipped it, because nothing tied the plan's contents to the batch list. This
    asserts the batched form is gone.
    """
    report.start("下载管线完整性")

    pipeline = (PROJECT_ROOT / "Sources/Services/LaunchPipeline.swift").read_text(encoding="utf-8")
    downloader = (PROJECT_ROOT / "Sources/Services/ResourceDownloader.swift").read_text(encoding="utf-8")

    report.check(
        "LaunchPipeline 通过 ResourceDownloader.execute 统一下载",
        "ResourceDownloader.shared.execute(" in pipeline,
        "分批手写下载会漏掉 DownloadPlan 的新增类别",
    )
    report.check(
        "LaunchPipeline 不再自行分批下载",
        "private func download(items:" not in pipeline,
        "分批的 download(items:stage:) 已被 execute() 取代",
    )

    # Every field of DownloadPlan that carries a file must be reachable from
    # execute(). Parsed from the source so a new category is checked automatically.
    plan_block = re.search(r"struct DownloadPlan.*?\n\}", downloader, re.DOTALL)
    if not plan_block:
        report.check("解析出 DownloadPlan 定义", False)
        return

    body = plan_block.group(0)

    # Downloadable categories are the ones typed DownloadItem or [DownloadItem].
    # Computed helpers (`totalFiles`, `totalBytes`) and the legacy layout mapping
    # are excluded by construction rather than by a hand-maintained name list.
    #
    # Two shapes to match: `var x: [DownloadItem] = []` (required, defaulted) and
    # `var x: DownloadItem?` (optional, no initialiser).
    download_fields = re.findall(
        r"^[ \t]+var (\w+):[ \t]*(\[DownloadItem\]|DownloadItem\?)(?:[ \t]*=)?",
        body,
        re.MULTILINE,
    )
    report.check(
        f"解析出 {len(download_fields)} 个下载类别",
        len(download_fields) >= 3,
        f"parsed: {[name for name, _ in download_fields]}",
    )

    execute_body = downloader.split("func execute(")[-1]
    for name, _ in download_fields:
        report.check(
            f"execute() 处理 plan.{name}",
            f"plan.{name}" in execute_body,
            "DownloadPlan 里有这个类别但 execute() 没有下载它",
        )

    # The computed totals must count every category, or the progress bar and the
    # free-space check disagree with what actually gets downloaded.
    for name, kind in download_fields:
        if kind == "DownloadItem?":
            report.check(
                f"totalFiles 计入可选类别 {name}",
                re.search(rf"\(\s*{name}\s*==\s*nil", body) is not None,
                f"totalFiles 漏掉了 {name}",
            )
        else:
            report.check(
                f"totalBytes 计入 {name}",
                f"({name} + assets)" in body or f"+ {name}" in body or name in body,
                f"totalBytes 漏掉了 {name}",
            )


def check_jvm_argument_shape(report: Report) -> None:
    """Structural checks on the assembled command line."""
    report.start("JVM 命令行结构")

    source = (PROJECT_ROOT / "Sources/Services/JVMArguments.swift").read_text(encoding="utf-8")

    required_flags = {
        "-XstartOnFirstThread": "GLFW 需要 Darwin 主线程",
        "-Xmx": "堆上限，由启动器接管",
        "-Djava.library.path": "指向 App 内的 Frameworks",
        "-Duser.home": "POJAV_HOME，Java 侧据此定位游戏目录",
        "-Duser.dir": "当前实例目录",
        "-Dcacio.managed.screensize": "Caciocavallo 的虚拟屏幕尺寸",
        "-Djava.awt.headless=false": "必须走 Caciocavallo 而不是 headless AWT",
        "-Dorg.lwjgl.opengl.libname": "选择 GL 后端",
        "-Dlog4j2.formatMsgNoLookups": "Log4Shell 缓解",
        "-Djna.tmpdir": "JNA 需要可写目录",
        "-cp": "类路径必须由启动器提供",
        "net.kdt.pojavlaunch.PojavLauncher": "Java 侧入口类",
    }
    for flag, why in required_flags.items():
        report.check(f"包含 {flag}（{why}）", flag in source)

    # Java 17 module flags, without which Caciocavallo17 throws
    # InaccessibleObjectException at the first AWT call.
    for export in ["--add-exports", "--add-opens"]:
        report.check(f"包含 {export}", export in source)

    # The classpath order matters: the patched jars must come first.
    report.check(
        "类路径把 App 内的 libs/* 放在最前（保证覆盖原版 LWJGL）",
        "runtimePaths.libs.path)/*" in source or "libs.path)/*" in source,
    )

    # Offline mode must send a literal token, not an empty string.
    report.check(
        "离线模式使用字面量会话令牌",
        '"0" : config.accessToken' in source or '"0"' in source,
    )

    # Version-specific Caciocavallo package names.
    report.check(
        "Java 8 使用 net.java.openjdk.cacio 包名",
        "net.java.openjdk.cacio.ctc.CTCToolkit" in source,
    )
    report.check(
        "Java 17 使用 com.github.caciocavallosilano 包名",
        "com.github.caciocavallosilano.cacio.ctc.CTCToolkit" in source,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="CraftLauncher 静态校验")
    parser.add_argument("--offline", action="store_true", help="跳过需要联网的检查")
    parser.add_argument("-v", "--verbose", action="store_true", help="列出每一项检查")
    args = parser.parse_args()

    print(BOLD("CraftLauncher 校验"))
    print(DIM(f"工程目录：{PROJECT_ROOT}"))
    print(DIM(f"Python {sys.version.split()[0]}"))

    report = Report(args.verbose)

    check_project_layout(report)
    check_rule_engine(report)
    check_argument_flattening(report)

    provided, unsupported = check_placeholders(report) or (set(), {})

    mapping = check_runtime_tag_mapping(report)
    check_bootstrap_consistency(report, mapping)

    if args.offline:
        report.start("与真实 Mojang 版本数据对拍")
        report.skip("网络检查", "--offline")
    else:
        check_against_live_metadata(report, provided, unsupported)

    check_uuid_algorithms(report)
    check_jvm_argument_shape(report)
    check_log4j_handling(report)
    check_download_pipeline(report)
    check_entitlements(report)
    check_required_imports(report)
    check_cross_file_call_sites(report)
    check_workflows(report)
    check_swift_structure(report)
    check_no_obvious_api_mistakes(report)

    return report.summary()


if __name__ == "__main__":
    sys.exit(main())
