#!/usr/bin/env python3
"""Run the named Cordis/Harness scenarios and migration fixtures offline."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
CATALOG = REPO / "tests/harness_migration_scenarios.json"
LEGACY = REPO / "tests/fixtures/harness_pre_cordis"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_job(report: dict, name: str, command: list[str], *, cwd: Path,
            env: dict[str, str], expected_status: int = 0,
            markers: tuple[str, ...] = (), timeout: int = 120) -> dict:
    try:
        result = subprocess.run(command, cwd=cwd, env=env, text=True,
                                capture_output=True, timeout=timeout)
        output = result.stdout + result.stderr
        passed = result.returncode == expected_status and all(m in output for m in markers)
        row = {"name": name, "command": command, "cwd": str(cwd),
               "status": result.returncode, "expected_status": expected_status,
               "passed": passed, "output": output}
    except subprocess.TimeoutExpired as error:
        def captured(value):
            return value.decode(errors="replace") if isinstance(value, bytes) else (value or "")
        row = {"name": name, "command": command, "cwd": str(cwd),
               "status": "timeout", "passed": False,
               "output": captured(error.stdout) + captured(error.stderr) + "\nprocess timeout"}
    report["jobs"].append(row)
    print(f'{"PASS" if row["passed"] else "FAIL"} {name}', flush=True)
    if not row["passed"]:
        print(row["output"], flush=True)
    return row


def validate_catalog(catalog: dict) -> None:
    for suite, package, pattern in [("cordis", "cordis", "*.gene"),
                                     ("harness", "gene-harness", "*_smoke.gene")]:
        cases = [c for c in catalog["cases"] if c["suite"] == suite]
        actual = {p.name for p in (REPO / "examples" / package / "tests").glob(pattern)
                  if not p.name.endswith("_spec.gene")}
        expected = {c["file"] for c in cases}
        if actual != expected or len(cases) != catalog[suite] or not cases:
            raise ValueError(f"{suite} scenario catalog drift: actual={actual}, catalog={expected}")


def named_suite(report: dict, gene: Path, root: Path, env: dict, catalog: dict,
                suite: str, package: str) -> None:
    cases = [c for c in catalog["cases"] if c["suite"] == suite]
    data = root / f"{suite}-data"
    data.mkdir()
    child_env = dict(env, GENE_HARNESS_TEST_ROOT=str(data))
    command = [str(gene), "test",
               "tests/scenarios_spec.gene" if suite == "cordis" else "tests/runner/scenarios_spec.gene"]
    if suite == "harness":
        command += ["--allow_read_write_dir", str(data)]
    count = len(cases)
    row = run_job(report, f"{suite}: {count} named scenarios",
                  command,
                  cwd=REPO / "examples" / package, env=child_env,
                  markers=tuple(c["marker"] for c in cases) +
                    (f"{count} passed, 0 failed, 0 errors, 0 skipped",))
    names = re.findall(r"^\[passed\] (.+)$", row["output"], re.MULTILINE)
    expected = {f'{"Cordis" if suite == "cordis" else "Harness"} {c["name"]}' for c in cases}
    if set(names) != expected or len(names) != count:
        row["passed"] = False
        row["output"] += "\nNamed example identities did not match the scenario catalog."
    report["scenarios"][suite] = count if row["passed"] else 0


def adapter_ownership(report: dict, gene: Path, env: dict) -> None:
    names = (
        "retirement gates new calls and drains an admitted suspended call",
        "retired callbacks cannot attach to a restarted plugin ID",
        "retained invocations keep the Cordis execution limit",
    )
    row = run_job(report, "Cordis adapter: owned invocation and revision retirement",
                  [str(gene), "test", "tests/integration", "--name", "Cordis adapter ownership"],
                  cwd=REPO / "examples/gene-harness", env=env,
                  markers=tuple(f"[passed] Cordis adapter ownership {name}" for name in names) +
                    ("3 passed, 0 failed, 0 errors, 0 skipped",), timeout=30)
    report["scenarios"]["adapter_ownership"] = len(names) if row["passed"] else 0


def adapter_publication(report: dict, gene: Path, env: dict) -> None:
    names = (
        "old cleanup failure reports recovery after publishing the new rows",
        "nonunique dependencies follow the registry selected row",
        "registry cleanup runs once for invisible old rows after publication",
        "failed candidate rows stay private and old cleanup preserves replacement rows",
        "selected entry dependencies handle absence appearance removal and replacement without replay",
    )
    row = run_job(report, "Cordis adapter: registry publication and selected-entry dependencies",
                  [str(gene), "test", "tests/integration", "--name", "Cordis adapter publication"],
                  cwd=REPO / "examples/gene-harness", env=env,
                  markers=tuple(f"[passed] Cordis adapter publication {name}" for name in names) +
                    ("5 passed, 0 failed, 0 errors, 0 skipped",), timeout=60)
    report["scenarios"]["adapter_publication"] = len(names) if row["passed"] else 0


def adapter_sources(report: dict, gene: Path, env: dict) -> None:
    names = (
        "generated workspace state flushes after an owned call and survives reopen",
        "escaped typed provider methods retain their entry capability ceiling",
        "generated descriptors load in owned sandbox generations and replace safely",
        "generated call policy grants one read root and denies another",
    )
    row = run_job(report, "Cordis adapter: generated sources and sealed entry policies",
                  [str(gene), "test", "tests/integration", "--name", "Cordis adapter sources"],
                  cwd=REPO / "examples/gene-harness", env=env,
                  markers=tuple(f"[passed] Cordis adapter sources {name}" for name in names) +
                    ("4 passed, 0 failed, 0 errors, 0 skipped",), timeout=45)
    report["scenarios"]["adapter_sources"] = len(names) if row["passed"] else 0


def commit_phases(report: dict, gene: Path, env: dict) -> None:
    names = (
        "a losing desired CAS performs no Cordis activation or publication",
        "registry publication failure preserves the original error and committed rows",
        "failure after desired CAS never attempts to roll CURRENT backward",
    )
    row = run_job(report, "Cordis adapter: post-commit failures preserve commit facts",
                  [str(gene), "test", "tests/integration", "--name", "Cordis commit phases"],
                  cwd=REPO / "examples/gene-harness", env=env,
                  markers=tuple(f"[passed] Cordis commit phases {name}" for name in names) +
                    ("3 passed, 0 failed, 0 errors, 0 skipped",), timeout=45)
    report["scenarios"]["commit_phases"] = len(names) if row["passed"] else 0


def cordis_durable_path(report: dict, gene: Path, root: Path, env: dict) -> None:
    home = root / "cordis-agent-home"
    home.mkdir()
    def command(mode, directory=home):
        return [str(gene), "run", "--allow_read_write_dir", str(directory),
                "examples/gene-harness/tests/cordis_durable_fixture.gene", mode, str(directory)]
    seeded = run_job(report, "Cordis model/tool/durable replacement path", command("seed"),
                     cwd=REPO, env=env, markers=("cordis durable seed: ok",))
    if not seeded["passed"]:
        return
    restored = run_job(report, "Cordis agent fresh-process restore", command("restore"),
                       cwd=REPO, env=env, markers=("cordis durable fresh-process restore: ok",))
    if not restored["passed"]:
        return
    for mode, restore_mode, marker in [
        ("crash", "restore_crash", "cordis crash recovery uses committed desired source: ok"),
        ("crash_bad", "restore_bad", "cordis crash recovery failure: ok"),
    ]:
        copied = root / f"cordis-{mode}-home"
        shutil.copytree(home, copied)
        process = subprocess.Popen(command(mode, copied), cwd=REPO, env=env,
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        reached_commit = False
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if (copied / "committed").exists():
                    reached_commit = (copied / "committed").read_text() == "5"
                    break
                if process.poll() is not None:
                    break
                time.sleep(0.02)
        finally:
            if process.poll() is None:
                process.kill()
            output, _ = process.communicate(timeout=10)
        passed = reached_commit and process.returncode == -9
        report["jobs"].append({"name": f"{mode}: process killed after CURRENT and before reconciliation",
                               "command": command(mode, copied), "cwd": str(REPO),
                               "status": process.returncode, "passed": passed, "output": output})
        print(f'{"PASS" if passed else "FAIL"} {mode}: killed at durable commit barrier', flush=True)
        if passed:
            run_job(report, f"{mode}: committed desired source restored", command(restore_mode, copied),
                    cwd=REPO, env=env, markers=(marker,))
        else:
            print(output, flush=True)


def failure_probe(report: dict, gene: Path, root: Path, env: dict) -> None:
    fixture = root / "deliberate_failure_spec.gene"
    fixture.write_text('(import $test [describe it])\n'
                       '(describe "migration gate" (it "deliberate failure" [] ($assert false)))\n')
    run_job(report, "deliberate failure is rejected", [str(gene), "test", str(fixture)],
            cwd=root, env=env, expected_status=1,
            markers=("0 passed, 1 failed, 0 errors, 0 skipped",))
    run_job(report, "empty selection is rejected",
            [str(gene), "test", str(fixture), "--name", "no-such-migration-example"],
            cwd=root, env=env, expected_status=2,
            markers=("No examples selected.",))


def legacy_fixture(report: dict, gene: Path, root: Path, env: dict) -> None:
    manifest = json.loads((LEGACY / "manifest.json").read_text())
    for name, expected in manifest["files"].items():
        if digest(LEGACY / "home" / name) != expected:
            raise ValueError(f"pre-migration fixture was changed: {name}")
    home = root / "legacy-home"
    shutil.copytree(LEGACY / "home", home)
    def command(mode: str, target: Path = home):
        return [str(gene), "run", "--allow_read_write_dir", str(target),
                "examples/gene-harness/tests/migration_workspace_fixture.gene", mode,
                str(target / "composition"), str(target / "events")]
    run_job(report, "legacy metadata requires explicit upgrade", command("refuse"),
            cwd=REPO, env=env, markers=("legacy workspace requires explicit upgrade: ok",))
    expected = json.loads(json.dumps(manifest["expected"]))
    expected["revision"] += 1
    for entry in expected["entries"]:
        entry["interfaces"] = {
            "core": "gene-harness/PluginHost:1", "plugin_api": "gene-harness/Plugin:1",
            "harness_render": "gene-harness/HarnessRender:1", "harness_fs": "gene-harness/HarnessFs:1"}
    for mode, name in [("upgrade", "known legacy metadata upgrades without activation"),
                       ("inspect", "upgraded workspace reopens in a fresh process"),
                       ("inspect_cordis", "upgraded legacy workspace restores through Cordis generations")]:
        row = run_job(report, name, command(mode), cwd=REPO, env=env)
        if row["passed"]:
            observed = json.loads(row["output"].strip().splitlines()[-1])
            row["observed"] = observed
            if observed != expected:
                row["passed"] = False
                row["output"] += "\nUpgrade changed data beyond the declared interface metadata and revision."
        for path, expected_digest in manifest["files"].items():
            if path.startswith("composition/blobs/") and digest(home / path) != expected_digest:
                row["passed"] = False
                row["output"] += f"\nUpgrade changed immutable source blob: {path}"
    unknown = root / "unknown-interface-home"
    shutil.copytree(LEGACY / "home", unknown)
    run_job(report, "unknown interfaces refuse without activation or upgrade CAS",
            command("unknown", unknown), cwd=REPO, env=env,
            markers=("unknown interfaces refused without activation or CAS: ok",))
    damaged = root / "damaged-legacy-home"
    shutil.copytree(LEGACY / "home", damaged)
    disabled_digest = manifest["expected"]["entries"][2]["module_digest"].split(":")[1]
    blob = next((damaged / "composition/blobs").glob(f"*{disabled_digest}*"))
    blob.write_text(blob.read_text().replace("dormant", "damaged"))
    run_job(report, "upgrade revalidates disabled source bytes", command("damaged", damaged),
            cwd=REPO, env=env, markers=("damaged disabled source refuses upgrade CAS: ok",))
    hostile = root / "hostile-legacy-home"
    shutil.copytree(LEGACY / "home", hostile)
    run_job(report, "upgrade bounds disabled descriptor init", command("hostile", hostile),
            cwd=REPO, env=env, markers=("hostile disabled init refuses upgrade CAS: ok",), timeout=15)


def hmr_probe(report: dict, gene: Path, root: Path, env: dict) -> None:
    source = REPO / "examples/cordis"
    original = source / "fixtures/plugins/reloadable.gene"
    before = digest(original)
    isolated = root / "cordis-hmr"
    shutil.copytree(source, isolated,
                    ignore=shutil.ignore_patterns(".gene", ".cache", "build"))
    row = run_job(report, "bounded watcher reload, rejection, and recovery",
                  [str(gene), "run", "probes/hmr.gene"], cwd=isolated, env=env,
                  markers=("hmr: ok",), timeout=45)
    if digest(original) != before or digest(isolated / "fixtures/plugins/reloadable.gene") != before:
        row["passed"] = False
        row["output"] += "\nHMR probe did not preserve the source fixture."


def workflow(report: dict, gene: Path, root: Path, env: dict) -> None:
    home = root / "workflow-home"
    home.mkdir()
    child_env = dict(env, GENE_HARNESS_HOME=str(home))
    prefix = [str(gene), "run", "--allow_read_write_dir", str(home),
              "examples/gene-harness/src/main.gene", "web"]
    run_job(report, "durable build", prefix + ["build", "migration_echo", "hello"],
            cwd=REPO, env=child_env, markers=("registered migration_echo at revision 1",))
    run_job(report, "fresh-process tool restore", prefix + ["tool", "migration_echo", "world"],
            cwd=REPO, env=child_env, markers=("migration_echo(world) -> hello",))
    run_job(report, "durable disable", prefix + ["disable", "migration_echo"],
            cwd=REPO, env=child_env, markers=("composition revision 2",))
    run_job(report, "disabled tool stays absent after restore",
            prefix + ["tool", "migration_echo", "world"],
            cwd=REPO, env=child_env, markers=("no tool migration_echo",))
    run_job(report, "durable enable", prefix + ["enable", "migration_echo"],
            cwd=REPO, env=child_env, markers=("composition revision 3",))
    run_job(report, "enabled tool returns after restore",
            prefix + ["tool", "migration_echo", "world"],
            cwd=REPO, env=child_env, markers=("migration_echo(world) -> hello",))
    run_job(report, "fresh-process doctor", prefix + ["doctor"], cwd=REPO, env=child_env)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gene", type=Path, help="existing task-owned Gene executable")
    parser.add_argument("--report", type=Path, help="retain detailed JSON evidence")
    parser.add_argument("--self-test", action="store_true", help="only check failure/empty-selection detection")
    options = parser.parse_args()
    report = {"format": 1, "jobs": [], "scenarios": {}}
    try:
        catalog = json.loads(CATALOG.read_text())
        validate_catalog(catalog)
        with tempfile.TemporaryDirectory(prefix="gene-migration-gate-") as temporary:
            root = Path(temporary)
            env = dict(os.environ, GENE_HARNESS_HOME=str(root / "unused-home"))
            gene = options.gene.resolve() if options.gene else root / "gene"
            if not options.gene:
                built = run_job(report, "build task-owned Gene",
                                ["nim", "c", "--path:src", "--hints:off", f"-o:{gene}", "src/gene.nim"],
                                cwd=REPO, env=env, timeout=240)
                if not built["passed"]: return 1
            failure_probe(report, gene, root, env)
            if not options.self_test:
                named_suite(report, gene, root, env, catalog, "cordis", "cordis")
                named_suite(report, gene, root, env, catalog, "harness", "gene-harness")
                adapter_ownership(report, gene, env)
                adapter_publication(report, gene, env)
                adapter_sources(report, gene, env)
                commit_phases(report, gene, env)
                cordis_durable_path(report, gene, root, env)
                hmr_probe(report, gene, root, env)
                legacy_fixture(report, gene, root, env)
                workflow(report, gene, root, env)
                run_job(report, "event catalog", ["python3", "tools/generate_harness_event_catalog.py", "--check"],
                        cwd=REPO, env=env, markers=("harness event catalog: current",))
        report["passed"] = bool(report["jobs"]) and all(row["passed"] for row in report["jobs"])
    except (OSError, ValueError) as error:
        report["passed"] = False
        report["error"] = str(error)
        print(f"FAIL {error}", flush=True)
    finally:
        if options.report:
            options.report.parent.mkdir(parents=True, exist_ok=True)
            options.report.write_text(json.dumps(report, indent=2) + "\n")
    print(f'migration gate: {"passed" if report.get("passed") else "failed"}; '
          f'cordis={report["scenarios"].get("cordis", 0)} harness={report["scenarios"].get("harness", 0)}')
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
