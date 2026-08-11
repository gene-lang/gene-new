"""Model-native unit tokenization and the matched canonical-`.gene`-byte
control -- docs/proposals/reversible-ai-native-program-format.md, "First
model-pilot unit recommendation" and "Model-training study" (the matched
control must differ from the treatment only in its input/output head).

Two encodings, both consumed by the same `PackedManifestDataset`:

- `UnitVocab` (the treatment arm): reads a `gene docunits` JSONL file
  (`document_units.nim`) and expands it into a flat integer sequence. Each
  logical unit's structural kind is one token from a small fixed vocabulary
  (discovered from the corpus, not hand-enumerated, so a future Nim-side
  UnitKind addition is picked up on the next corpus build rather than
  silently mis-tokenized); a unit's text payload (identifiers, strings,
  comments, canonical decimal text for ints/floats) is expanded into raw
  UTF-8 bytes, terminated by an explicit PAYLOAD_END token -- "do not
  require the model to predict byte lengths before it has generated a
  subtree" (the proposal's own wording) applies here as much as it does to
  containers.
- `ByteVocab` (the control arm): plain byte-level tokenization of the
  canonical `.gene` text (`gene docunpack` on the same packed document).
  This is the "matched canonical `.gene` byte-model control" the Model-
  training study requires: same corpus, same backbone (see model.py),
  different input head only because the modality forces it.

Vocab size is intentionally tiny for both arms (structural-kind count plus
256 byte values plus a couple of control tokens), matching "a small fixed
structural vocabulary" -- this is not meant to be a production tokenizer.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


PAD_TOKEN = "<pad>"
PAYLOAD_END_TOKEN = "<payload_end>"


@dataclass
class UnitVocab:
    kind_to_id: dict[str, int]
    id_to_kind: list[str]
    byte_base: int
    payload_end_id: int
    pad_id: int

    @property
    def size(self) -> int:
        return self.byte_base + 256 + 2  # + PAYLOAD_END + PAD

    @classmethod
    def build(cls, units_paths: list[Path]) -> "UnitVocab":
        kinds: set[str] = set()
        for path in units_paths:
            with path.open("r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    kinds.add(json.loads(line)["k"])
        ordered = sorted(kinds)  # deterministic across runs/machines
        kind_to_id = {k: i for i, k in enumerate(ordered)}
        byte_base = len(ordered)
        return cls(
            kind_to_id=kind_to_id, id_to_kind=ordered, byte_base=byte_base,
            payload_end_id=byte_base + 256, pad_id=byte_base + 256 + 1,
        )

    def to_json(self) -> dict:
        return {"id_to_kind": self.id_to_kind, "byte_base": self.byte_base,
                "payload_end_id": self.payload_end_id, "pad_id": self.pad_id}

    @classmethod
    def from_json(cls, data: dict) -> "UnitVocab":
        id_to_kind = data["id_to_kind"]
        return cls(
            kind_to_id={k: i for i, k in enumerate(id_to_kind)}, id_to_kind=id_to_kind,
            byte_base=data["byte_base"], payload_end_id=data["payload_end_id"],
            pad_id=data["pad_id"],
        )

    def encode_file(self, units_path: Path) -> list[int]:
        ids: list[int] = []
        with units_path.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                unit = json.loads(line)
                kind = unit["k"]
                if kind not in self.kind_to_id:
                    raise ValueError(
                        f"unit kind {kind!r} not in vocab (built from a different "
                        f"corpus snapshot?) -- rebuild the vocab")
                ids.append(self.kind_to_id[kind])
                text = unit.get("t")
                if text:
                    ids.extend(self.byte_base + b for b in text.encode("utf-8"))
                    ids.append(self.payload_end_id)
        return ids


@dataclass
class ByteVocab:
    pad_id: int = 256

    @property
    def size(self) -> int:
        return 257  # 0..255 raw bytes + PAD

    def encode_text(self, text: str) -> list[int]:
        return list(text.encode("utf-8"))


def load_manifest(manifest_path: Path) -> list[dict]:
    entries = []
    with manifest_path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                entries.append(json.loads(line))
    return entries
