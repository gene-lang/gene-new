"""Scores a matched pilot against the *pre-registered* gates in
docs/proposals/reversible-ai-native-program-format.md, "Model-training
study".

The point of pre-registration is that the thresholds were fixed before the
run, so this script's job is to report each gate's verdict verbatim --
including NOT_MEASURABLE, which is a real verdict here and must never be
quietly downgraded to a pass or dropped from the report. A gate that needs
inputs this repo does not have yet (see SEMANTIC_GATES_BLOCKER) says so and
names what is missing.

The gates, and what each one needs:

  G1 loader round-trip, zero representation loss    corpus + gene binary
  G2 memorization >= 99% exact unit-sequence acc    units checkpoint
  G3 structural validity >= 99% (held-out gen)      checkpoint + gene binary
  G4 semantic test-pass rate >= 20% (held out)      task corpus w/ tests
  G5 beat control by >= 5pp AND >= 20% relative     G4 for both arms
  G6 <= 1.5x positions/program, >= 80% throughput   corpus + both train logs
  R  payload share of positions/loss > 70% routes to a learned lossless
     payload-piece experiment rather than blaming the structural modality

Usage:
    python3 evaluate.py --corpus training/corpus/out \\
        --units-run training/checkpoints/pilot1/units \\
        --bytes-run training/checkpoints/pilot1/bytes \\
        --gene-bin bin/gene --out report.json

Every argument except --corpus is optional; a gate whose inputs are absent
reports NOT_MEASURABLE with the missing input named, so the same command
works on a corpus-only checkout and on a finished pilot.
"""

from __future__ import annotations

import argparse
import json
import random
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from units_dataset import ByteVocab, UnitVocab, load_manifest

SEMANTIC_GATES_BLOCKER = (
    "no task corpus with declared, executable tests exists yet -- build_corpus.py's "
    "'run declared tests' stage is currently only 'compiles' (see its module "
    "docstring), and the held-out task set the study specifies (structural units "
    "absent from the training templates) has not been designed")

PASS, FAIL, NOT_MEASURABLE = "PASS", "FAIL", "NOT_MEASURABLE"


@dataclass
class Gate:
    gate_id: str
    name: str
    verdict: str
    detail: str
    measured: dict = field(default_factory=dict)

    def to_json(self) -> dict:
        return {"gate": self.gate_id, "name": self.name, "verdict": self.verdict,
                "detail": self.detail, "measured": self.measured}


# ---------------------------------------------------------------------------
# Corpus-only measurements (no model needed)
# ---------------------------------------------------------------------------

def unit_position_profile(corpus: Path, entries: list[dict], vocab: UnitVocab) -> dict:
    """Per-program unit-arm positions, split into structural-kind tokens and
    payload bytes. The split is what the routing rule (R) is stated over."""
    structural = payload = 0
    per_program: list[int] = []
    per_program_share: list[tuple[float, str]] = []
    for entry in entries:
        path = corpus / "units" / f"{entry['sha256'][:16]}.units.jsonl"
        n_struct = n_payload = 0
        with path.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                unit = json.loads(line)
                n_struct += 1  # the kind token
                text = unit.get("t")
                if text:
                    # payload bytes + the explicit PAYLOAD_END terminator
                    n_payload += len(text.encode("utf-8")) + 1
        structural += n_struct
        payload += n_payload
        n_total = n_struct + n_payload
        per_program.append(n_total)
        if n_total:
            per_program_share.append((n_payload / n_total, entry["source"]))
    total = structural + payload
    # The aggregate share is a position-weighted mean, so a handful of files
    # with very large embedded string literals can carry it across the
    # routing threshold on their own. Report the per-document median and the
    # worst offenders alongside it, so corpus skew is visible as skew instead
    # of being read as a property of the modality.
    shares = sorted(s for s, _ in per_program_share)
    median = shares[len(shares) // 2] if shares else 0.0
    worst = sorted(per_program_share, reverse=True)[:5]
    return {"positions_total": total, "structural_positions": structural,
            "payload_positions": payload,
            "payload_share": (payload / total) if total else 0.0,
            "payload_share_median_per_document": median,
            "payload_share_worst_documents": [
                {"source": src, "payload_share": share} for share, src in worst],
            "per_program": per_program}


def byte_position_profile(corpus: Path, entries: list[dict]) -> dict:
    per_program = []
    for entry in entries:
        path = corpus / "canonical" / f"{entry['sha256'][:16]}.gene"
        per_program.append(len(path.read_text(encoding="utf-8").encode("utf-8")))
    return {"positions_total": sum(per_program), "per_program": per_program}


def gate_roundtrip(corpus: Path, gene_bin: Path | None, entries: list[dict],
                   sample: int) -> Gate:
    """G1: the data loader and the logical units must round-trip with zero
    representation loss. Checked end to end through the real binary:
    units JSONL -> canonical .gene must equal the corpus's own canonical
    .gene for the same document."""
    if gene_bin is None:
        return Gate("G1", "loader round-trip, zero representation loss",
                    NOT_MEASURABLE, "--gene-bin not provided")
    if not gene_bin.exists():
        return Gate("G1", "loader round-trip, zero representation loss",
                    NOT_MEASURABLE, f"gene binary not found at {gene_bin}")
    checked = mismatched = 0
    failures: list[str] = []
    chosen = entries if sample <= 0 or sample >= len(entries) else \
        random.Random(0).sample(entries, sample)
    for entry in chosen:
        stem = entry["sha256"][:16]
        units_path = corpus / "units" / f"{stem}.units.jsonl"
        canonical_path = corpus / "canonical" / f"{stem}.gene"
        if not units_path.exists() or not canonical_path.exists():
            continue
        proc = subprocess.run(
            [str(gene_bin), "docunits", "--decode", str(units_path)],
            capture_output=True, text=True)
        checked += 1
        if proc.returncode != 0:
            mismatched += 1
            if len(failures) < 5:
                failures.append(f"{entry['source']}: decode failed: {proc.stderr.strip()[:200]}")
            continue
        if proc.stdout != canonical_path.read_text(encoding="utf-8"):
            mismatched += 1
            if len(failures) < 5:
                failures.append(f"{entry['source']}: decoded text differs from canonical")
    if checked == 0:
        return Gate("G1", "loader round-trip, zero representation loss",
                    NOT_MEASURABLE, "no corpus entries had both units and canonical artifacts")
    verdict = PASS if mismatched == 0 else FAIL
    detail = f"{checked - mismatched}/{checked} documents round-tripped exactly"
    if failures:
        detail += "; first failures: " + "; ".join(failures)
    return Gate("G1", "loader round-trip, zero representation loss", verdict, detail,
                {"checked": checked, "mismatched": mismatched})


def gate_efficiency(unit_prof: dict, byte_prof: dict,
                    units_log: Path | None, bytes_log: Path | None) -> Gate:
    """G6: <= 1.5x model positions per program, and >= 80% of the control's
    training throughput."""
    u_per, b_per = unit_prof["per_program"], byte_prof["per_program"]
    n = min(len(u_per), len(b_per))
    if n == 0:
        return Gate("G6", "positions <= 1.5x and throughput >= 80% of control",
                    NOT_MEASURABLE, "corpus has no comparable programs")
    u_mean = sum(u_per[:n]) / n
    b_mean = sum(b_per[:n]) / n
    position_ratio = u_mean / b_mean if b_mean else float("inf")
    measured = {"units_positions_per_program": u_mean,
                "bytes_positions_per_program": b_mean,
                "position_ratio": position_ratio,
                "position_ratio_limit": 1.5}
    position_ok = position_ratio <= 1.5

    u_tps = _final_tokens_per_s(units_log)
    b_tps = _final_tokens_per_s(bytes_log)
    if u_tps is None or b_tps is None:
        return Gate("G6", "positions <= 1.5x and throughput >= 80% of control",
                    NOT_MEASURABLE,
                    f"position ratio {position_ratio:.3f} "
                    f"({'within' if position_ok else 'OVER'} the 1.5x limit); "
                    "throughput needs train_log.jsonl from both arms", measured)
    # tokens/s alone is not comparable across arms when a program costs a
    # different number of positions in each, so the study's "training
    # throughput" is read as programs/s: tokens/s divided by positions/program.
    u_pps = u_tps / u_mean if u_mean else 0.0
    b_pps = b_tps / b_mean if b_mean else 0.0
    throughput_ratio = u_pps / b_pps if b_pps else float("inf")
    measured.update({"units_tokens_per_s": u_tps, "bytes_tokens_per_s": b_tps,
                     "units_programs_per_s": u_pps, "bytes_programs_per_s": b_pps,
                     "throughput_ratio": throughput_ratio,
                     "throughput_ratio_floor": 0.8})
    throughput_ok = throughput_ratio >= 0.8
    verdict = PASS if (position_ok and throughput_ok) else FAIL
    return Gate("G6", "positions <= 1.5x and throughput >= 80% of control", verdict,
                f"position ratio {position_ratio:.3f} (limit 1.5), "
                f"throughput ratio {throughput_ratio:.3f} (floor 0.8)", measured)


def _final_tokens_per_s(log_path: Path | None) -> float | None:
    """Median *incremental* throughput between consecutive eval records.

    train.py's own `tokens_per_s` field is cumulative (total tokens / total
    elapsed), which folds in dataset construction and never recovers from a
    transient stall -- if anything else touches the GPU for ten seconds, every
    later record stays depressed. Since G6 compares two arms' throughput, a
    one-off blip in one arm would move the verdict. The median of per-interval
    rates measures steady-state training and ignores such a blip.
    """
    if log_path is None or not log_path.exists():
        return None
    records = []
    with log_path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    if not records:
        return None
    rates = []
    prev_step, prev_elapsed = 0, 0.0
    for rec in records:
        d_step = rec["step"] - prev_step
        d_time = rec["elapsed_s"] - prev_elapsed
        if d_step > 0 and d_time > 0:
            # tokens_per_s is cumulative, so tokens/step = rate * elapsed / step
            # recovers the constant batch_size * context_len this run used.
            tokens_per_step = rec["tokens_per_s"] * rec["elapsed_s"] / rec["step"]
            rates.append(tokens_per_step * d_step / d_time)
        prev_step, prev_elapsed = rec["step"], rec["elapsed_s"]
    if not rates:
        return records[-1].get("tokens_per_s")
    rates.sort()
    return rates[len(rates) // 2]


def routing_check(unit_prof: dict, loss_by_kind: dict | None) -> Gate:
    """R: if identifier/string/comment payloads take more than 70% of model
    positions *or* dominate more than 70% of held-out loss, the result routes
    to a learned lossless payload-piece experiment instead of being read as a
    verdict on the structural modality."""
    share = unit_prof["payload_share"]
    median = unit_prof["payload_share_median_per_document"]
    measured = {"payload_position_share": share,
                "payload_share_median_per_document": median,
                "payload_share_worst_documents": unit_prof["payload_share_worst_documents"],
                "threshold": 0.70}
    positions_over = share > 0.70
    skew = f"; median document is {median:.1%}" if abs(share - median) > 0.05 else ""
    if loss_by_kind is None:
        detail = (f"payload takes {share:.1%} of unit-arm positions "
                  f"({'OVER' if positions_over else 'under'} the 70% routing "
                  f"threshold){skew}; loss share needs a units checkpoint")
        return Gate("R", "payload share routes to a payload-piece experiment",
                    "ROUTE" if positions_over else "NO_ROUTE", detail, measured)
    loss_share = loss_by_kind["payload_loss_share"]
    measured["payload_loss_share"] = loss_share
    route = positions_over or loss_share > 0.70
    return Gate("R", "payload share routes to a payload-piece experiment",
                "ROUTE" if route else "NO_ROUTE",
                f"payload takes {share:.1%} of positions and {loss_share:.1%} of "
                f"held-out loss (routing threshold 70% on either)", measured)


# ---------------------------------------------------------------------------
# Model-dependent measurements
# ---------------------------------------------------------------------------

def load_run(run_dir: Path):
    """Returns (model, config, device) or None when the run is absent."""
    ckpt_path = run_dir / "checkpoint.pt"
    if not ckpt_path.exists():
        return None
    import torch
    from model import ModelConfig, TinyGeneModel
    device = "cuda" if torch.cuda.is_available() else "cpu"
    # train.py writes only tensors, plain dicts, and ints, so the checkpoint
    # never needs the arbitrary-unpickling path.
    blob = torch.load(ckpt_path, map_location=device, weights_only=True)
    cfg = ModelConfig(**blob["config"])
    model = TinyGeneModel(cfg).to(device)
    model.load_state_dict(blob["model"])
    model.eval()
    return model, cfg, device


def gate_memorization(run_dir: Path | None, corpus: Path, entries: list[dict],
                      vocab: UnitVocab, sample: int,
                      max_positions: int = 200_000) -> Gate:
    """G2: memorize a deliberately tiny corpus to >= 99% exact unit-sequence
    accuracy -- a learnability sanity gate on the modality and output head,
    explicitly *not* evidence of modality benefit.

    Scored two ways, because they measure different things and only one of
    them is the gate:

    - **stream** (the verdict): contiguous `context_len` windows over the
      same concatenated training stream `train.py` samples from. This is what
      the model was trained to predict, so it isolates "did it memorize the
      corpus" from "does it handle contexts it never saw".
    - **document-start**: each document scored from position 0. Reported
      alongside, but not the gate, because a document's first units are
      always preceded by the previous document's tail in the training stream
      -- scoring them from an empty context measures out-of-distribution
      generalization, not memorization, and drags the number down by roughly
      the share of positions that sit near a document boundary.
    """
    if run_dir is None:
        return Gate("G2", "memorization >= 99% exact unit-sequence accuracy",
                    NOT_MEASURABLE, "--units-run not provided")
    loaded = load_run(run_dir)
    if loaded is None:
        return Gate("G2", "memorization >= 99% exact unit-sequence accuracy",
                    NOT_MEASURABLE, f"no checkpoint.pt under {run_dir}")
    import torch
    model, cfg, device = loaded

    chosen = entries if sample <= 0 or sample >= len(entries) else \
        random.Random(0).sample(entries, sample)

    def score(ids: list[int]) -> tuple[int, int]:
        if len(ids) < 2:
            return 0, 0
        x = torch.tensor(ids[:-1], dtype=torch.long, device=device).unsqueeze(0)
        y = torch.tensor(ids[1:], dtype=torch.long, device=device)
        logits, _ = model(x)
        return int((logits[0].argmax(dim=-1) == y).sum().item()), y.numel()

    doc_correct = doc_total = 0
    stream: list[int] = []
    with torch.no_grad():
        for entry in chosen:
            ids = vocab.encode_file(
                corpus / "units" / f"{entry['sha256'][:16]}.units.jsonl")
            stream.extend(ids)
            c, t = score(ids[:cfg.context_len + 1])
            doc_correct += c
            doc_total += t
        # This gate is stated over "a deliberately tiny corpus"; pointed at a
        # full one it would score millions of positions one window at a time.
        # Cap it, and say so in the report rather than silently truncating.
        stream_correct = stream_total = 0
        scan_len = min(len(stream) - 1, max_positions)
        for start in range(0, max(scan_len, 0), cfg.context_len):
            c, t = score(stream[start:start + cfg.context_len + 1])
            stream_correct += c
            stream_total += t
    if stream_total == 0:
        return Gate("G2", "memorization >= 99% exact unit-sequence accuracy",
                    NOT_MEASURABLE, "no unit sequences long enough to score")
    accuracy = stream_correct / stream_total
    doc_accuracy = (doc_correct / doc_total) if doc_total else 0.0
    verdict = PASS if accuracy >= 0.99 else FAIL
    capped = "" if len(stream) - 1 <= max_positions else \
        f" (capped at {max_positions:,} of {len(stream):,} stream positions)"
    return Gate("G2", "memorization >= 99% exact unit-sequence accuracy", verdict,
                f"teacher-forced next-unit accuracy {accuracy:.4f} over "
                f"{stream_total:,} training-stream positions from "
                f"{len(chosen)} documents{capped} (threshold 0.99); "
                f"scored from document starts instead it is {doc_accuracy:.4f}",
                {"accuracy": accuracy, "positions": stream_total,
                 "max_positions": max_positions,
                 "document_start_accuracy": doc_accuracy,
                 "document_start_positions": doc_total,
                 "documents": len(chosen), "threshold": 0.99})


def gate_structural_validity(run_dir: Path | None, gene_bin: Path | None,
                             vocab: UnitVocab, samples: int,
                             max_units: int, temperature: float,
                             dump_dir: Path | None = None) -> Gate:
    """G3: >= 99% structurally valid documents on the generation task. A
    generated unit stream is decoded through the real binary; "structurally
    valid" means that decode produces a document the reader accepts.

    `dump_dir` writes every generated stream out as `.units.jsonl`. The GPU
    host and the host with a built `gene` binary are not always the same
    machine, so this lets generation happen where the model is and decoding
    happen where the compiler is (`gene docunits --decode <file>` per file);
    it also makes generations inspectable instead of only counted.
    """
    if run_dir is None:
        return Gate("G3", "structural validity >= 99%", NOT_MEASURABLE,
                    "--units-run not provided")
    if gene_bin is None and dump_dir is None:
        return Gate("G3", "structural validity >= 99%", NOT_MEASURABLE,
                    "--gene-bin not provided (or use --dump-generations to "
                    "score the streams on a host that has the binary)")
    loaded = load_run(run_dir)
    if loaded is None:
        return Gate("G3", "structural validity >= 99%", NOT_MEASURABLE,
                    f"no checkpoint.pt under {run_dir}")
    import torch
    model, cfg, device = loaded

    valid = truncated = 0
    failures: list[str] = []
    rng = torch.Generator(device="cpu").manual_seed(0)
    form_start_id = vocab.kind_to_id.get("ukFormStart")
    if form_start_id is None:
        return Gate("G3", "structural validity >= 99%", NOT_MEASURABLE,
                    "vocab has no ukFormStart token to prompt generation with")

    if dump_dir is not None:
        dump_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for i in range(samples):
            ids, closed = _generate_document(
                model, cfg, device, form_start_id, vocab,
                max_new=max_units, temperature=temperature, gen=rng)
            jsonl = _ids_to_units_jsonl(ids, vocab)
            if dump_dir is not None:
                # Dump every sample, closed or not: a truncated stream is
                # evidence about the model too, and dropping it here would
                # make the dumped set silently unrepresentative.
                (dump_dir / f"gen_{i}{'' if closed else '.truncated'}.units.jsonl"
                 ).write_text(jsonl, encoding="utf-8")
            if not closed:
                # The model never closed the document within the cap. That is
                # a structural failure of its own kind, not a decoder error,
                # and is counted separately so a too-small cap cannot be
                # mistaken for the model emitting malformed structure.
                truncated += 1
                continue
            if gene_bin is None:
                continue
            unit_file = Path(tmp) / f"gen_{i}.units.jsonl"
            unit_file.write_text(jsonl, encoding="utf-8")
            proc = subprocess.run(
                [str(gene_bin), "docunits", "--decode", str(unit_file)],
                capture_output=True, text=True)
            if proc.returncode == 0:
                valid += 1
            elif len(failures) < 5:
                failures.append(proc.stderr.strip()[:160])
    if gene_bin is None:
        return Gate("G3", "structural validity >= 99%", NOT_MEASURABLE,
                    f"generated {samples} streams into {dump_dir} "
                    f"({truncated} hit the {max_units}-unit budget); decode them "
                    "with `gene docunits --decode` on a host that has the binary",
                    {"samples": samples, "truncated": truncated,
                     "max_units": max_units, "dump_dir": str(dump_dir)})
    rate = valid / samples if samples else 0.0
    closed = samples - truncated
    detail = (f"{valid}/{samples} generated documents closed and decoded to a "
              f"valid document (threshold 0.99)")
    if truncated:
        detail += (f"; {truncated} never closed within {max_units} units")
    if closed:
        detail += f"; of those that closed, {valid}/{closed} decoded"
    if failures:
        detail += "; first decode failures: " + "; ".join(failures)
    measured = {"valid": valid, "samples": samples, "rate": rate,
                "closed": closed, "truncated": truncated,
                "max_units": max_units, "threshold": 0.99}
    # This gate's threshold is stated over "the structurally held-out
    # generation task", which does not exist yet (same blocker as G4). Run
    # against a corpus whose documents are much longer than any practical
    # generation budget, whole-document generation measures document length
    # far more than structural competence, and reporting a number anyway
    # would be reporting the wrong thing confidently.
    if truncated > samples // 2:
        return Gate("G3", "structural validity >= 99%", NOT_MEASURABLE,
                    detail + f" -- most samples hit the {max_units}-unit budget, "
                    "so this measures document length, not structural validity; "
                    "needs the held-out generation task (see G4's blocker) or a "
                    "corpus of documents that fit a generation budget", measured)
    verdict = PASS if rate >= 0.99 else FAIL
    return Gate("G3", "structural validity >= 99%", verdict, detail, measured)


# Kind names that open and close a container, used only to know when a
# generated document is finished. Keeping this as names (not ids) means a
# future UnitKind addition shows up as a missing name here rather than as a
# silently wrong depth count.
_OPENERS = {"ukNodeStart", "ukNodeImmutableStart", "ukListStart",
            "ukListImmutableStart", "ukMapStart", "ukMapImmutableStart",
            "ukHashMapStart"}
_CLOSERS = {"ukNodeEnd", "ukListEnd", "ukMapEnd", "ukHashMapEnd"}


def _generate_document(model, cfg, device, form_start_id: int, vocab: UnitVocab,
                       max_new: int, temperature: float, gen):
    """Samples until the opened form closes at container depth 0, or the cap
    is hit. Generating a fixed number of tokens instead would truncate almost
    every sample mid-subtree and score the model 0% no matter how good it is."""
    import torch
    ids = [form_start_id]
    depth = 0
    closed = False
    with torch.no_grad():
        for _ in range(max_new):
            window = ids[-cfg.context_len:]
            x = torch.tensor(window, dtype=torch.long, device=device).unsqueeze(0)
            logits, _ = model(x)
            probs = torch.softmax(logits[0, -1] / max(temperature, 1e-6), dim=-1).to("cpu")
            nxt = int(torch.multinomial(probs, 1, generator=gen).item())
            ids.append(nxt)
            if nxt < vocab.byte_base:
                kind = vocab.id_to_kind[nxt]
                if kind in _OPENERS:
                    depth += 1
                elif kind in _CLOSERS:
                    depth -= 1
                elif kind == "ukFormEnd" and depth <= 0:
                    closed = True
                    break
    return ids, closed


def _ids_to_units_jsonl(ids: list[int], vocab: UnitVocab) -> str:
    """Inverse of UnitVocab.encode_file for a generated stream. A payload run
    that the model never terminated is closed at the end of the stream rather
    than dropped, so an unterminated payload shows up as whatever structural
    error it really is instead of silently vanishing."""
    lines: list[str] = []
    i = 0
    while i < len(ids):
        tok = ids[i]
        i += 1
        if tok >= vocab.byte_base:
            continue  # a stray payload byte with no preceding kind token
        kind = vocab.id_to_kind[tok]
        payload = bytearray()
        while i < len(ids) and vocab.byte_base <= ids[i] < vocab.byte_base + 256:
            payload.append(ids[i] - vocab.byte_base)
            i += 1
        if i < len(ids) and ids[i] == vocab.payload_end_id:
            i += 1
        obj = {"k": kind}
        if payload:
            obj["t"] = payload.decode("utf-8", errors="replace")
        lines.append(json.dumps(obj))
    return "\n".join(lines) + ("\n" if lines else "")


def heldout_loss_by_kind(run_dir: Path | None, corpus: Path, entries: list[dict],
                         vocab: UnitVocab, sample: int) -> dict | None:
    """Held-out loss split by unit kind, and the payload-vs-structural share
    the routing rule (R) is stated over."""
    if run_dir is None:
        return None
    loaded = load_run(run_dir)
    if loaded is None:
        return None
    import torch
    import torch.nn.functional as F
    model, cfg, device = loaded

    chosen = entries if sample <= 0 or sample >= len(entries) else \
        random.Random(1).sample(entries, sample)
    by_kind: dict[str, list[float]] = {}
    structural_loss = payload_loss = 0.0
    with torch.no_grad():
        for entry in chosen:
            path = corpus / "units" / f"{entry['sha256'][:16]}.units.jsonl"
            ids = vocab.encode_file(path)[:cfg.context_len + 1]
            if len(ids) < 2:
                continue
            x = torch.tensor(ids[:-1], dtype=torch.long, device=device).unsqueeze(0)
            y = torch.tensor(ids[1:], dtype=torch.long, device=device)
            logits, _ = model(x)
            losses = F.cross_entropy(logits[0], y, reduction="none").to("cpu")
            for pos, target in enumerate(ids[1:]):
                loss = float(losses[pos])
                if target < vocab.byte_base:
                    by_kind.setdefault(vocab.id_to_kind[target], []).append(loss)
                    structural_loss += loss
                else:
                    by_kind.setdefault("<payload>", []).append(loss)
                    payload_loss += loss
    total = structural_loss + payload_loss
    if total == 0:
        return None
    return {"mean_loss_by_kind": {k: sum(v) / len(v) for k, v in sorted(by_kind.items())},
            "position_count_by_kind": {k: len(v) for k, v in sorted(by_kind.items())},
            "payload_loss_share": payload_loss / total,
            "structural_loss_share": structural_loss / total}


# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--units-run", help="checkpoint/log dir for the units arm")
    parser.add_argument("--bytes-run", help="checkpoint/log dir for the byte control arm")
    parser.add_argument("--gene-bin", help="path to a built gene binary")
    parser.add_argument("--out", help="write the full report as JSON here")
    parser.add_argument("--roundtrip-sample", type=int, default=0,
                        help="0 = every document (the default; G1 is a zero-loss gate)")
    parser.add_argument("--model-sample", type=int, default=64,
                        help="documents scored per model-dependent gate")
    parser.add_argument("--memorization-max-positions", type=int, default=200_000,
                        help="cap on G2's training-stream scan (G2 is a tiny-corpus gate)")
    parser.add_argument("--generation-samples", type=int, default=100)
    parser.add_argument("--generation-max-units", type=int, default=4096,
                        help="per-sample generation budget for G3; should exceed "
                             "the corpus's median document so the gate measures "
                             "structure rather than length")
    parser.add_argument("--generation-temperature", type=float, default=1.0)
    parser.add_argument("--dump-generations",
                        help="write G3's generated unit streams here, so they can be "
                             "decoded on a host that has a built gene binary")
    args = parser.parse_args()

    corpus = Path(args.corpus)
    gene_bin = Path(args.gene_bin) if args.gene_bin else None
    units_run = Path(args.units_run) if args.units_run else None
    bytes_run = Path(args.bytes_run) if args.bytes_run else None

    manifest = load_manifest(corpus / "manifest.jsonl")
    held_out = [e for e in manifest if e["split"] in ("validation", "test")] or manifest
    train_entries = [e for e in manifest if e["split"] == "train"] or manifest

    vocab = UnitVocab.build(
        [corpus / "units" / f"{e['sha256'][:16]}.units.jsonl" for e in manifest])
    unit_prof = unit_position_profile(corpus, manifest, vocab)
    byte_prof = byte_position_profile(corpus, manifest)

    loss_by_kind = heldout_loss_by_kind(units_run, corpus, held_out, vocab,
                                        args.model_sample)

    gates = [
        gate_roundtrip(corpus, gene_bin, manifest, args.roundtrip_sample),
        gate_memorization(units_run, corpus, train_entries, vocab, args.model_sample,
                          args.memorization_max_positions),
        gate_structural_validity(units_run, gene_bin, vocab, args.generation_samples,
                                 args.generation_max_units, args.generation_temperature,
                                 Path(args.dump_generations) if args.dump_generations else None),
        Gate("G4", "semantic test-pass rate >= 20% on held-out tasks",
             NOT_MEASURABLE, SEMANTIC_GATES_BLOCKER),
        Gate("G5", "beat the control by >= 5pp and >= 20% relative",
             NOT_MEASURABLE, "depends on G4, which is not measurable: " + SEMANTIC_GATES_BLOCKER),
        gate_efficiency(unit_prof, byte_prof,
                        units_run / "train_log.jsonl" if units_run else None,
                        bytes_run / "train_log.jsonl" if bytes_run else None),
        routing_check(unit_prof, loss_by_kind),
    ]

    report = {
        "corpus": str(corpus),
        "documents": len(manifest),
        "units_run": str(units_run) if units_run else None,
        "bytes_run": str(bytes_run) if bytes_run else None,
        "position_profile": {
            "units": {k: v for k, v in unit_prof.items() if k != "per_program"},
            "bytes": {k: v for k, v in byte_prof.items() if k != "per_program"},
        },
        "heldout_loss_by_kind": loss_by_kind,
        "gates": [g.to_json() for g in gates],
    }

    width = max(len(g.name) for g in gates)
    print(f"corpus: {corpus}  documents: {len(manifest)}")
    print("-" * (width + 30))
    for g in gates:
        print(f"{g.gate_id:<3} {g.name:<{width}}  {g.verdict}")
        print(f"    {g.detail}")
    print("-" * (width + 30))
    failed = [g.gate_id for g in gates if g.verdict == FAIL]
    unmeasured = [g.gate_id for g in gates if g.verdict == NOT_MEASURABLE]
    if failed:
        print(f"FAILED gates: {', '.join(failed)}")
    if unmeasured:
        print(f"NOT MEASURABLE (inputs missing, not a pass): {', '.join(unmeasured)}")
    if not failed and not unmeasured:
        print("all pre-registered gates measured and passing")

    if args.out:
        Path(args.out).write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"wrote {args.out}")

    # A failed gate is a real failure; a not-measurable gate is not a pass and
    # must not exit 0, or a CI wiring would read an unrun study as a green one.
    return 1 if (failed or unmeasured) else 0


if __name__ == "__main__":
    sys.exit(main())
