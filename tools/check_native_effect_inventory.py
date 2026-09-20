#!/usr/bin/env python3
"""Check explicit native dispositions; optionally refresh the review inventory."""
from pathlib import Path
import argparse
import collections
import re

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "src/gene/native_effects.nim"
DOC = ROOT / "docs/implementation/capabilities-native-inventory.md"
KINDS = {
    "nekCapabilityFree": "Capability-free",
    "nekGuarded": "Guarded",
    "nekHostControl": "Private host control",
    "nekUnsupported": "Unsupported",
}


def scan():
    rules = dict(re.findall(r'\("([^"\n]+)", (nek\w+)\)', CATALOG.read_text()))
    registrations = collections.defaultdict(list)
    raw = collections.Counter()
    dynamic = []
    for path in sorted((ROOT / "src/gene").rglob("*.nim")):
        source = path.read_text()
        relative = str(path.relative_to(ROOT))
        for match in re.finditer(r'\bbuiltinNative(?:Call)?Fn\(\s*"([^"\n]+)"\s*,\s*([A-Za-z_]\w*)', source):
            site = (relative, match[2])
            if site not in registrations[match[1]]:
                registrations[match[1]].append(site)
        raw[relative] += len(re.findall(r'\bnewNative(?:Call)?Fn\(', source))
        for match in re.finditer(r'\bbuiltinNative(?:Call)?Fn\(\s*([a-zA-Z_]\w*)\s*,', source):
            dynamic.append((relative, match[1]))
    # Raw constructors are the explicit host-extension API, the two checked
    # wrappers, an inert compiler placeholder, and rejected dynamic AOT entries.
    expected_raw = {
        "src/gene/vm.nim": 2,
        "src/gene/native_api.nim": 2,
        "src/gene/compiler.nim": 1,
        "src/gene/stdlib.nim": 1,
    }
    actual_raw = {path: count for path, count in raw.items() if count}
    errors = []
    if actual_raw != expected_raw:
        errors.append(f"unreviewed raw native construction: {actual_raw}")
    if dynamic != [("src/gene/vm.nim", "name")]:
        errors.append(f"unreviewed dynamic builtin construction: {dynamic}")
    missing = registrations.keys() - rules.keys()
    stale = rules.keys() - registrations.keys()
    if missing:
        errors.append(f"unclassified builtin registrations: {sorted(missing)}")
    if stale:
        errors.append(f"catalog entries without a registration: {sorted(stale)}")
    if any(kind not in KINDS for kind in rules.values()):
        errors.append("catalog contains a disposition outside the adopted profile")
    return rules, registrations, errors


def contract(name, kind):
    if kind == "nekUnsupported":
        return "No admitted operation/adapter contract; reject before native implementation.", "test_native_effects"
    if kind == "nekHostControl":
        return "Host source/generation management; reject retained application source origins.", "test_capability_source_policy"
    if name.startswith("fs/"):
        return "Section 11 filesystem demand, current/origin authority, no-follow identity checks.", "test_fs_capability_policy; test_fs_capability_handles"
    if name.startswith("net/http_client/") and kind == "nekGuarded":
        return "Prepared HTTP facts; guard submission and worker start; retain request context.", "test_http_capabilities; test_http_capability_transport"
    if name.startswith("capabilities/check_"):
        return "Advisory provider inspection; never perform or authorize the requested effect.", "test_capability_api"
    if name.startswith("test/") and kind == "nekGuarded":
        return "Capture registration authority/source origins; bound callbacks and diagnostics; application reporting rejects.", "test_capability_cli; test_testing"
    if name in {"C/closed?", "ffi/Library/closed?", "ffi/Library/path", "Logger/with", "Logger/enabled?"}:
        return "Provided handle bookkeeping/payload only; no resource I/O, discovery or release.", "test_native_effects; existing API suites"
    return "In-memory data/computation; called application code keeps its own boundaries.", "test_native_effects; existing API suites"


def render(rules, registrations):
    text = """# Native effect coverage inventory

This inventory is checked by `tools/check_native_effect_inventory.py`. The
runtime catalog is `src/gene/native_effects.nim`; changing a callable's display
name does not grant its disposition. Trusted constructors attach immutable
metadata. Unclassified host extensions and unsupported operations reject in
normalized execution before their implementation runs. Guarded adapters still
derive and check the actual operation at its effect boundary.

Entries identify native implementations. Namespace aliases, held values,
protocol/type methods, bound calls and callable adaptations preserve the same
native value and disposition. Public HTTP-server paths are `net/http/*`, and
database-opening paths are `db/sqlite/*` and `db/postgres/*`. Other type-prefixed
entries name receiver methods. Dynamic map/filter-map stages use their existing
catalog identities. Dynamic AOT entries are explicitly unsupported; compiler
FFI placeholders have no executable implementation or arithmetic fast path.

Private host control is currently separated by retained source origins. The
ordinary startup source-policy migration must finish before this distinction
supports deny-by-default launcher rollout. Additional providers and callback
adapters required by the supported Harness workflow remain required work.
Unsupported actor/event registrations, REPL adapters, filesystem async I/O,
stores, logging and server APIs are migration work, not completed provider claims.

The checks below cover native dispatch and its registered surface. Backend
release also requires the bytecode/FFI/AOT boundary audit, internal host-work
inventory, registration/lifecycle coverage, and real workflow tests. A listed
test suite is an enforcement evidence location, not proof that every exported
alias has an independent integration fixture.

| Native identity | Disposition | Contract / enforcement | Evidence | Registration sites |
| --- | --- | --- | --- | --- |
"""
    for name, kind in sorted(rules.items()):
        meaning, tests = contract(name, kind)
        locations = ", ".join(f"`{path}` ({implementation})" for path, implementation in registrations[name])
        shown = name.replace("|", "\\|")
        text += f"| `{shown}` | {KINDS[kind]} | {meaning} | {tests} | {locations} |\n"
    return text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    rules, registrations, errors = scan()
    if errors:
        raise SystemExit("\n".join(errors))
    expected = render(rules, registrations)
    if args.write:
        DOC.write_text(expected)
    elif not DOC.exists() or DOC.read_text() != expected:
        raise SystemExit("native inventory is stale; review changes, then run with --write")
    counts = collections.Counter(KINDS[kind] for kind in rules.values())
    print(f"Native inventory: {len(rules)} identities; {dict(counts)}")


if __name__ == "__main__":
    main()
