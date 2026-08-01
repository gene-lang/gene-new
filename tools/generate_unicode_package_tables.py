#!/usr/bin/env python3
"""Generate the Unicode 15.1 tables used by package format 1.

Input is the pinned Unicode UCD.zip archive. The generated Nim module contains
only canonical-decomposition, combining-class, composition, and default full
case-fold mappings needed by package path canonicalization.
"""

from __future__ import annotations

import hashlib
import pathlib
import sys
import zipfile


EXPECTED_SHA256 = "cb1c663d053926500cd501229736045752713a066bd75802098598b7a7056177"


def records(name: str, data: bytes):
    for raw in data.decode("utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            yield line.split(";")


def write_array(out, name: str, type_name: str, values: list[str]):
    out.write(f"const {name}*: array[{len(values)}, {type_name}] = [\n")
    for index in range(0, len(values), 4):
        out.write("  " + ", ".join(values[index:index + 4]))
        out.write(",\n" if index + 4 < len(values) else "\n")
    out.write("]\n\n")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: generate_unicode_package_tables.py UCD.zip OUTPUT")
    archive_path = pathlib.Path(sys.argv[1])
    output_path = pathlib.Path(sys.argv[2])
    archive = archive_path.read_bytes()
    observed = hashlib.sha256(archive).hexdigest()
    if observed != EXPECTED_SHA256:
        raise SystemExit(f"UCD.zip digest mismatch: {observed}")

    with zipfile.ZipFile(archive_path) as source:
        unicode_data = source.read("UnicodeData.txt")
        case_folding = source.read("CaseFolding.txt")
        normalization = source.read("DerivedNormalizationProps.txt")

    combining: list[tuple[int, int]] = []
    decompositions: dict[int, list[int]] = {}
    for fields in records("UnicodeData.txt", unicode_data):
        cp = int(fields[0], 16)
        ccc = int(fields[3])
        if ccc:
            combining.append((cp, ccc))
        decomposition = fields[5].strip()
        if decomposition and not decomposition.startswith("<"):
            decompositions[cp] = [int(value, 16) for value in decomposition.split()]

    excluded: set[int] = set()
    for fields in records("DerivedNormalizationProps.txt", normalization):
        if fields[1].strip() != "Full_Composition_Exclusion":
            continue
        bounds = fields[0].strip().split("..")
        first = int(bounds[0], 16)
        last = int(bounds[-1], 16)
        excluded.update(range(first, last + 1))

    decomposition_data: list[int] = []
    decomposition_records: list[tuple[int, int, int]] = []
    for cp, mapping in sorted(decompositions.items()):
        offset = len(decomposition_data)
        decomposition_data.extend(mapping)
        decomposition_records.append((cp, offset, len(mapping)))

    compositions: list[tuple[int, int, int]] = []
    for cp, mapping in decompositions.items():
        if len(mapping) == 2 and cp not in excluded:
            compositions.append((mapping[0], mapping[1], cp))
    compositions.sort()

    folds: dict[int, list[int]] = {}
    fold_priority: dict[int, int] = {}
    for fields in records("CaseFolding.txt", case_folding):
        cp = int(fields[0].strip(), 16)
        status = fields[1].strip()
        if status not in {"C", "F"}:
            continue
        priority = 2 if status == "F" else 1
        if priority >= fold_priority.get(cp, 0):
            folds[cp] = [int(value, 16) for value in fields[2].split()]
            fold_priority[cp] = priority
    fold_data: list[int] = []
    fold_records: list[tuple[int, int, int]] = []
    for cp, mapping in sorted(folds.items()):
        offset = len(fold_data)
        fold_data.extend(mapping)
        fold_records.append((cp, offset, len(mapping)))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8", newline="\n") as out:
        out.write("## Generated from Unicode 15.1.0 UCD.zip; do not edit.\n")
        out.write("## Generator: tools/generate_unicode_package_tables.py\n")
        out.write("## UCD SHA-256: " + EXPECTED_SHA256 + "\n\n")
        out.write("type\n")
        out.write("  UnicodeMapping* = tuple[codePoint, offset, length: int32]\n")
        out.write("  UnicodeCombining* = tuple[codePoint, combiningClass: int32]\n")
        out.write("  UnicodeComposition* = tuple[first, second, composed: int32]\n\n")
        write_array(out, "unicodeCanonicalData", "int32",
                    [f"{value}'i32" for value in decomposition_data])
        write_array(out, "unicodeCanonicalMappings", "UnicodeMapping",
                    [f"({cp}'i32, {offset}'i32, {length}'i32)"
                     for cp, offset, length in decomposition_records])
        write_array(out, "unicodeCombiningClasses", "UnicodeCombining",
                    [f"({cp}'i32, {ccc}'i32)" for cp, ccc in combining])
        write_array(out, "unicodeCompositions", "UnicodeComposition",
                    [f"({first}'i32, {second}'i32, {composed}'i32)"
                     for first, second, composed in compositions])
        write_array(out, "unicodeFoldData", "int32",
                    [f"{value}'i32" for value in fold_data])
        write_array(out, "unicodeFoldMappings", "UnicodeMapping",
                    [f"({cp}'i32, {offset}'i32, {length}'i32)"
                     for cp, offset, length in fold_records])


if __name__ == "__main__":
    main()
