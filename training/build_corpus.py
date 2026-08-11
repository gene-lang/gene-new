#!/usr/bin/env python3
"""Training corpus pipeline -- docs/proposals/reversible-ai-native-program-format.md
"Training corpus pipeline":

    generated .gene
    -> read and validate
    -> compile and run declared tests
    -> canonicalize
    -> encode native document
    -> decode and verify forms/comments
    -> deduplicate
    -> assign a stable train/validation/test split

Implementation notes and honest scope (v0):

- "read and validate" + "canonicalize" + "encode native document" are one
  step here: `gene docpack` builds the ProgramDocument (which requires a
  successful parse) and its packed encoding in one pass. A file that fails
  to parse, or uses a value kind program_document.nim's v0 doesn't cover
  (regex/range/date-family/bigint-overflow -- see packed_format.nim's own
  doc comment), is rejected with its reason logged, not silently dropped.
- "decode and verify forms/comments" is the packed_format.nim round-trip
  invariant (`decodePacked(encodePacked(document)) == document`), which is
  covered by tests/test_packed_format.nim, not re-verified per file here --
  re-checking a proven invariant on every corpus file would just be
  spending CPU to re-confirm something already gated at the code level.
  The *unit* stream's round-trip is verified per file, though: it is the
  study's first pre-registered gate, it is what the treatment arm actually
  trains on, and a violation has to be rejected from the corpus rather than
  merely reported afterwards.
- "compile and run declared tests" is narrowed to "compiles" (`gene
  compile`, which forces macro expansion and name resolution, catching
  errors `docpack` alone would not). Actually discovering and running each
  file's *declared* tests needs package/project context most loose corpus
  files don't have; deferred, tracked below, not silently skipped.
- Deduplication is by the packed document's sha256, so two files that
  differ only in whitespace/comments/reader-sugar spelling (identical after
  canonicalization) collapse to one corpus entry with one source recorded.
- The train/validation/test split is stable and deterministic (sha256 of a
  group key, not `random`), but the *group* is a source directory, not a
  semantic-tree cluster -- the proposal's "Model-training study" requires
  holding out semantic-tree clusters and task families, which needs a
  designed task taxonomy this bootstrap corpus (this repo's own examples/
  and tests/ trees) doesn't have yet. Directory-grouping is a reasonable
  proxy against near-duplicate leakage for now; revisit before the gated
  pilot run.

Usage:
    python3 build_corpus.py --gene-bin /path/to/gene --out training/corpus/out \
        [--source-dir examples] [--source-dir tests] [--split 80,10,10]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class CorpusEntry:
    source: str
    sha256: str
    packed_bytes: int
    unit_count: int
    canonical_bytes: int
    group: str
    split: str = ""


@dataclass
class Rejection:
    source: str
    stage: str
    reason: str


@dataclass
class Report:
    accepted: list[CorpusEntry] = field(default_factory=list)
    rejected: list[Rejection] = field(default_factory=list)
    duplicates: int = 0


def run_gene(gene_bin: str, args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        [gene_bin, *args], capture_output=True, text=True, timeout=60
    )


def group_key(source: Path, source_root: Path) -> str:
    """Directory-level grouping key, used for split assignment (see module
    doc comment: a proxy for avoiding near-duplicate leakage, not the
    proposal's semantic-tree-cluster holdout)."""
    rel = source.relative_to(source_root)
    parts = rel.parts[:-1]  # drop the filename
    return str(source_root.name / Path(*parts)) if parts else str(source_root.name)


def assign_split(group: str, ratios: tuple[int, int, int]) -> str:
    """Deterministic split by hashing the group key -- same group always
    lands in the same split, and results don't depend on file discovery
    order or a random seed."""
    total = sum(ratios)
    bucket = int(hashlib.sha256(group.encode("utf-8")).hexdigest(), 16) % total
    if bucket < ratios[0]:
        return "train"
    if bucket < ratios[0] + ratios[1]:
        return "validation"
    return "test"


def process_file(
    gene_bin: str, path: Path, source_root: Path, out_dir: Path, seen_hashes: set[str],
    report: Report,
) -> None:
    source_label = str(path)

    compiled = run_gene(gene_bin, ["compile", source_label])
    if compiled.returncode != 0:
        report.rejected.append(Rejection(
            source_label, "compile",
            compiled.stderr.strip().splitlines()[-1] if compiled.stderr else "compile failed"))
        return

    packed_tmp = out_dir / "_tmp.gdoc"
    packed = run_gene(gene_bin, ["docpack", source_label, "-o", str(packed_tmp)])
    if packed.returncode != 0:
        report.rejected.append(Rejection(
            source_label, "docpack",
            packed.stderr.strip().splitlines()[-1] if packed.stderr else "docpack failed"))
        return

    packed_bytes = packed_tmp.read_bytes()
    digest = hashlib.sha256(packed_bytes).hexdigest()
    if digest in seen_hashes:
        report.duplicates += 1
        packed_tmp.unlink(missing_ok=True)
        return
    seen_hashes.add(digest)

    units_tmp = out_dir / "_tmp.units.jsonl"
    units = run_gene(gene_bin, ["docunits", source_label, "-o", str(units_tmp)])
    if units.returncode != 0:
        # v0 value-kind coverage is identical between docpack/docunits, so
        # this should not happen if docpack just succeeded; treat it as a
        # real, reportable inconsistency rather than silently dropping the
        # file (which would silently create a corpus with packed docs that
        # have no matching unit stream).
        report.rejected.append(Rejection(
            source_label, "docunits (inconsistent with docpack -- please report)",
            units.stderr.strip().splitlines()[-1] if units.stderr else "docunits failed"))
        seen_hashes.discard(digest)
        packed_tmp.unlink(missing_ok=True)
        return

    unit_count = sum(1 for _ in units_tmp.open("r", encoding="utf-8"))

    dest_stem = digest[:16]
    dest_packed = out_dir / "packed" / f"{dest_stem}.gdoc"
    dest_units = out_dir / "units" / f"{dest_stem}.units.jsonl"
    dest_canonical = out_dir / "canonical" / f"{dest_stem}.gene"
    dest_packed.parent.mkdir(parents=True, exist_ok=True)
    dest_units.parent.mkdir(parents=True, exist_ok=True)
    dest_canonical.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(packed_tmp), dest_packed)
    shutil.move(str(units_tmp), dest_units)

    # Canonical `.gene` text: the matched byte-control arm's input (Model-
    # training study). Decoded from the packed document we just wrote, not
    # re-derived from the original source, so both arms provably see the
    # same document -- decodePacked(dest_packed) round-trips to this text.
    canonical = run_gene(gene_bin, ["docunpack", str(dest_packed)])
    if canonical.returncode != 0:
        report.rejected.append(Rejection(
            source_label, "docunpack (inconsistent with docpack -- please report)",
            canonical.stderr.strip().splitlines()[-1] if canonical.stderr else "docunpack failed"))
        seen_hashes.discard(digest)
        dest_packed.unlink(missing_ok=True)
        dest_units.unlink(missing_ok=True)
        return
    dest_canonical.write_text(canonical.stdout, encoding="utf-8")

    # The Model-training study's first pre-registered gate -- the logical
    # units must round-trip "with zero representation loss" -- is enforced
    # here, per file, rather than assumed: a training corpus whose unit
    # stream decodes to a *different* program would silently invalidate
    # every downstream comparison between the two arms. Cheap enough to run
    # on every file, and the only place a violation can still be rejected
    # instead of trained on.
    decoded = run_gene(gene_bin, ["docunits", "--decode", str(dest_units)])
    if decoded.returncode != 0 or decoded.stdout != canonical.stdout:
        reason = (decoded.stderr.strip().splitlines()[-1]
                  if decoded.returncode != 0 and decoded.stderr
                  else "units decoded to different text than the canonical projection")
        report.rejected.append(Rejection(
            source_label, "units round-trip (zero-representation-loss gate)", reason))
        seen_hashes.discard(digest)
        dest_packed.unlink(missing_ok=True)
        dest_units.unlink(missing_ok=True)
        dest_canonical.unlink(missing_ok=True)
        return

    report.accepted.append(CorpusEntry(
        source=source_label, sha256=digest, packed_bytes=len(packed_bytes),
        unit_count=unit_count, canonical_bytes=len(canonical.stdout.encode("utf-8")),
        group=group_key(path, source_root)))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gene-bin", required=True, help="path to a built gene binary")
    parser.add_argument("--source-dir", action="append", dest="source_dirs",
                         help="directory to scan for .gene files (repeatable); "
                              "default: examples/ and tests/ relative to the repo root")
    parser.add_argument("--out", required=True, help="output corpus directory")
    parser.add_argument("--split", default="80,10,10",
                         help="train,validation,test integer ratios (default 80,10,10)")
    # The memorization gate is stated over "a deliberately tiny corpus". Make
    # that corpus reproducible from a flag rather than an ad-hoc directory of
    # hand-copied files, so the probe can be rerun and its inputs pinned.
    parser.add_argument("--max-source-bytes", type=int,
                         help="skip source files larger than this (tiny-corpus probes)")
    parser.add_argument("--limit", type=int,
                         help="stop after accepting this many documents "
                              "(applied after size filtering, in scan order)")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    source_dirs = [Path(d) for d in args.source_dirs] if args.source_dirs else [
        repo_root / "examples", repo_root / "tests",
    ]
    ratios = tuple(int(x) for x in args.split.split(","))
    if len(ratios) != 3 or any(r < 0 for r in ratios) or sum(ratios) == 0:
        print(f"invalid --split {args.split!r}: need three non-negative integers summing > 0", file=sys.stderr)
        return 2

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    report = Report()
    seen_hashes: set[str] = set()
    for source_dir in source_dirs:
        if not source_dir.exists():
            continue
        for path in sorted(source_dir.rglob("*.gene")):
            if not path.is_file():
                continue  # a `.gene` directory (Gene project metadata), not a source file
            if ".gene" in path.relative_to(source_dir).parts[:-1]:
                continue  # inside a .gene/ build-cache dir (auto-generated, not source)
            if args.max_source_bytes is not None and \
                    path.stat().st_size > args.max_source_bytes:
                continue
            if args.limit is not None and len(report.accepted) >= args.limit:
                break
            process_file(args.gene_bin, path, source_dir, out_dir, seen_hashes, report)

    for entry in report.accepted:
        entry.split = assign_split(entry.group, ratios)

    manifest_path = out_dir / "manifest.jsonl"
    with manifest_path.open("w", encoding="utf-8") as f:
        for entry in report.accepted:
            f.write(json.dumps(entry.__dict__) + "\n")

    rejected_path = out_dir / "rejected.jsonl"
    with rejected_path.open("w", encoding="utf-8") as f:
        for rej in report.rejected:
            f.write(json.dumps(rej.__dict__) + "\n")

    by_split = {"train": 0, "validation": 0, "test": 0}
    for entry in report.accepted:
        by_split[entry.split] += 1

    print(f"accepted:   {len(report.accepted)}  (train={by_split['train']} "
          f"validation={by_split['validation']} test={by_split['test']})")
    print(f"duplicates: {report.duplicates}")
    print(f"rejected:   {len(report.rejected)}")
    if report.rejected:
        stages: dict[str, int] = {}
        for rej in report.rejected:
            stages[rej.stage] = stages.get(rej.stage, 0) + 1
        for stage, count in sorted(stages.items()):
            print(f"  - {stage}: {count}")
    print(f"manifest:   {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
