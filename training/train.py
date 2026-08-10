"""Training loop for either study arm -- run twice with the same config and
`--arm units` vs `--arm bytes` to produce the matched comparison
docs/proposals/reversible-ai-native-program-format.md's Model-training
study needs. This script does not, by itself, constitute that study: it is
the mechanism the study runs on. The pre-registered gates (99% memorization
on a tiny corpus, 99% structural validity, semantic pass rate, the
5pp/20%-relative beat-the-control bar, position/throughput ratios) are
measured outside this script, against generated/compiled/executed output,
once there's a real pilot corpus and a GPU to run on.

Usage:
    python3 train.py --corpus training/corpus/out --arm units \\
        --out training/checkpoints/units_run1 --steps 2000
    python3 train.py --corpus training/corpus/out --arm bytes \\
        --out training/checkpoints/bytes_run1 --steps 2000

Both commands must share every flag except --arm and --out for the runs to
be a matched comparison; run_matched.sh drives that pairing directly rather
than relying on two hand-typed, easily-mismatched command lines.
"""

from __future__ import annotations

import argparse
import json
import random
import time
from pathlib import Path

import torch

from model import ModelConfig, TinyGeneModel
from units_dataset import ByteVocab, UnitVocab, load_manifest


def build_stream(entries: list[dict], corpus_dir: Path, arm: str, vocab) -> list[int]:
    stream: list[int] = []
    for entry in entries:
        stem = entry["sha256"][:16]
        if arm == "units":
            path = corpus_dir / "units" / f"{stem}.units.jsonl"
            stream.extend(vocab.encode_file(path))
        else:
            path = corpus_dir / "canonical" / f"{stem}.gene"
            stream.extend(vocab.encode_text(path.read_text(encoding="utf-8")))
    return stream


class ChunkDataset(torch.utils.data.Dataset):
    """Fixed-length windows over a concatenated token stream, matching the
    standard small-LM pretraining setup: every position in the stream is an
    equally likely window start, sampled with replacement each epoch."""

    def __init__(self, stream: list[int], context_len: int, samples_per_epoch: int):
        self.stream = torch.tensor(stream, dtype=torch.long)
        self.context_len = context_len
        self.samples_per_epoch = samples_per_epoch
        if len(self.stream) <= context_len + 1:
            raise ValueError(
                f"stream too short ({len(self.stream)} tokens) for context_len "
                f"{context_len} -- need at least {context_len + 2}; corpus is too "
                f"small for this config, not a bug")

    def __len__(self) -> int:
        return self.samples_per_epoch

    def __getitem__(self, _idx: int):
        start = random.randint(0, len(self.stream) - self.context_len - 2)
        chunk = self.stream[start:start + self.context_len + 1]
        return chunk[:-1], chunk[1:]


def evaluate(model: TinyGeneModel, dataset: ChunkDataset, device: str, batches: int) -> float:
    model.eval()
    loader = torch.utils.data.DataLoader(dataset, batch_size=8, shuffle=True)
    total, count = 0.0, 0
    with torch.no_grad():
        for i, (x, y) in enumerate(loader):
            if i >= batches:
                break
            x, y = x.to(device), y.to(device)
            _, loss = model(x, y)
            total += loss.item()
            count += 1
    model.train()
    return total / max(count, 1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--corpus", required=True, help="corpus directory from build_corpus.py")
    parser.add_argument("--arm", required=True, choices=["units", "bytes"])
    parser.add_argument("--out", required=True, help="checkpoint/log output directory")
    parser.add_argument("--context-len", type=int, default=512)
    parser.add_argument("--d-model", type=int, default=256)
    parser.add_argument("--n-layers", type=int, default=6)
    parser.add_argument("--n-heads", type=int, default=4)
    parser.add_argument("--d-ff", type=int, default=1024)
    parser.add_argument("--dropout", type=float, default=0.1)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--steps", type=int, default=2000)
    parser.add_argument("--eval-every", type=int, default=200)
    parser.add_argument("--eval-batches", type=int, default=20)
    parser.add_argument("--samples-per-epoch", type=int, default=10_000)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    args = parser.parse_args()

    torch.manual_seed(args.seed)
    random.seed(args.seed)

    corpus_dir = Path(args.corpus)
    manifest = load_manifest(corpus_dir / "manifest.jsonl")
    train_entries = [e for e in manifest if e["split"] == "train"]
    val_entries = [e for e in manifest if e["split"] == "validation"]
    if not train_entries:
        raise SystemExit("no training entries in the manifest -- run build_corpus.py first")

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.arm == "units":
        all_units_paths = [
            corpus_dir / "units" / f"{e['sha256'][:16]}.units.jsonl" for e in manifest]
        vocab = UnitVocab.build(all_units_paths)
        (out_dir / "vocab.json").write_text(json.dumps(vocab.to_json()), encoding="utf-8")
        pad_id = vocab.pad_id
    else:
        vocab = ByteVocab()
        pad_id = vocab.pad_id

    train_stream = build_stream(train_entries, corpus_dir, args.arm, vocab)
    val_stream = build_stream(val_entries, corpus_dir, args.arm, vocab) if val_entries else train_stream

    cfg = ModelConfig(
        vocab_size=vocab.size, context_len=args.context_len, d_model=args.d_model,
        n_layers=args.n_layers, n_heads=args.n_heads, d_ff=args.d_ff, dropout=args.dropout,
    )
    (out_dir / "config.json").write_text(json.dumps({
        **cfg.__dict__, "arm": args.arm, "seed": args.seed, "lr": args.lr,
        "batch_size": args.batch_size, "steps": args.steps,
    }), encoding="utf-8")

    model = TinyGeneModel(cfg).to(args.device)
    print(f"[{args.arm}] vocab_size={cfg.vocab_size} params={model.num_parameters():,} "
          f"train_tokens={len(train_stream):,} val_tokens={len(val_stream):,} device={args.device}")

    train_ds = ChunkDataset(train_stream, args.context_len, args.samples_per_epoch)
    val_ds = ChunkDataset(val_stream, args.context_len, args.samples_per_epoch)
    train_loader = torch.utils.data.DataLoader(train_ds, batch_size=args.batch_size, shuffle=True)

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr)
    log_path = out_dir / "train_log.jsonl"
    step = 0
    t0 = time.time()
    model.train()
    with log_path.open("w", encoding="utf-8") as log_f:
        while step < args.steps:
            for x, y in train_loader:
                if step >= args.steps:
                    break
                x, y = x.to(args.device), y.to(args.device)
                _, loss = model(x, y)
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                optimizer.step()
                step += 1
                if step % args.eval_every == 0 or step == args.steps:
                    val_loss = evaluate(model, val_ds, args.device, args.eval_batches)
                    elapsed = time.time() - t0
                    record = {"step": step, "train_loss": loss.item(), "val_loss": val_loss,
                              "elapsed_s": elapsed, "tokens_per_s": step * args.batch_size *
                              args.context_len / max(elapsed, 1e-9)}
                    print(f"step {step}/{args.steps}  train_loss={loss.item():.4f}  "
                          f"val_loss={val_loss:.4f}  {record['tokens_per_s']:.0f} tok/s")
                    log_f.write(json.dumps(record) + "\n")
                    log_f.flush()
                    torch.save({"model": model.state_dict(), "config": cfg.__dict__, "step": step},
                               out_dir / "checkpoint.pt")
    print(f"done: {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
