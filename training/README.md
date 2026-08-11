# Reversible-format model-training pipeline

Implements Steps 6-7 of `docs/proposals/reversible-ai-native-program-format.md`'s
suggested sequence, on top of the already-implemented and verified durable
format (`src/gene/program_document.nim`, `src/gene/packed_format.nim`,
`src/gene/document_units.nim`).

Code lives in this repo and is developed/tested locally; training runs on a
remote GPU host over SSH (`training/sync.sh`, default host alias `lenovo`,
remote directory `~/exp/`). Models download directly on the remote host into
`~/exp/models/`, never through this machine.

## Pipeline

```
.gene source files
  -> gene compile               (catches macro/name-resolution errors)
  -> gene docpack -o out.gdoc   (parse, validate, canonicalize, encode -- one step)
  -> gene docunits -o out.jsonl (model-native logical unit stream)
  -> gene docunpack out.gdoc    (canonical .gene text, for the matched control)
  -> gene docunits --decode     (must reproduce that same canonical text:
                                 the study's zero-representation-loss gate)
  -> deduplicate by packed-document sha256
  -> deterministic train/validation/test split
```

driven by `build_corpus.py`, which shells out to a locally built `gene`
binary for every Gene-specific step (parsing, canonicalization, encoding are
the compiler's job; Python only orchestrates). See `build_corpus.py`'s
module docstring for the exact, honest mapping from the proposal's six pipe
stages to what's actually implemented, and what's deliberately narrower
(e.g. "run declared tests" is currently "compiles," not test discovery).

`units_dataset.py` turns the corpus into two matched token streams:

- **units arm** (the treatment): `UnitVocab` expands each `gene docunits`
  record into a small structural-kind token, with text payloads (symbols,
  strings, comments, canonical int/float text) expanded byte-by-byte and
  closed with an explicit end marker -- no length prediction required.
- **bytes arm** (the matched control): `ByteVocab` is plain byte-level
  tokenization of the canonical `.gene` text decoded from the *same* packed
  document, so both arms provably see the same underlying program.

`evaluate.py` scores a finished pilot against the proposal's *pre-registered*
gates and prints one verdict per gate. A gate whose inputs do not exist yet
reports `NOT_MEASURABLE` and names what is missing -- it is never quietly
counted as a pass, and the script exits non-zero so a CI wiring cannot read
an unrun study as a green one.

Where each gate stands. Read the corpus column carefully: several verdicts
differ between this repo's own 186 documents and the 1002 generated ones,
and those differences were properties of the *corpus*, not of the modality.

- **G1** (zero representation loss) **passes** on both, and
  `build_corpus.py` enforces it per file at build time.
- **G2** (memorization) **passes** at 99.33%, on the deliberately tiny
  corpus the gate is stated over. It takes budget: 93.6% at 4k steps with
  dropout 0.1, 98.98% at 12k with dropout 0, 99.33% at 36k. Dropout
  directly opposes what this gate measures -- always probe with
  `--dropout 0.0`.
- **G3** (structural validity) is **not measurable on the repo corpus**
  (median ~4,700 logical units, so whole-document generation measures
  length) but **is measurable on the generated corpus** (median 359 units,
  all 1002 inside a 4096-unit budget). The gate reports `NOT_MEASURABLE`
  when most samples hit the generation budget, rather than quoting a number
  that means something else.
- **G4/G5** (semantic pass rate; beating the control) are the only gates
  that speak to modality *benefit* -- the proposal calls G1-G3 sanity gates
  in its own words. The generated corpus's `.expected` files are the
  missing oracle; wiring them into a held-out task split is what remains.
- **G6** (positions, throughput) is measurable. Position ratio is
  corpus-dependent: 0.981x on the repo corpus, 1.367x on ordinary small
  programs. Both clear the 1.5x bar; do not quote the first alone.
- **The payload routing rule fires on the repo corpus (95.6%) and does not
  on the generated one (60.9%, threshold 70%).** The repo figure came from
  a few serialized-session fixtures that are ~99.9% string payload.

A caution about the `.expected` oracle, found while generating the corpus:
a program that computes the *wrong* answer still runs cleanly and produces
output, and `.expected` captured from that run enshrines the bug. A green
validator is not a correctness proof; expected values need independent
derivation, not just capture.

`--dump-generations DIR` writes G3's generated unit streams out, so
generation can run on the GPU host and decoding on a host that has a built
`gene` binary -- they are not always the same machine.

`model.py` is one small decoder-only Transformer class used for both arms;
only `vocab_size` differs between the two runs, everything else in
`ModelConfig` must match. `train.py` runs one arm; `run_matched.sh` runs
both back to back with identical flags, since hand-typing two `train.py`
commands risks a silent mismatch that would quietly invalidate the
Model-training study's comparison.

## Status (2026-08-10)

Built and smoke-tested end to end on CPU with this repo's own 186-file
bootstrap corpus (both arms train, loss decreases, checkpoints/logs write
correctly). This is infrastructure verification, not a pilot result -- see
what's still open below.

**Not yet done, in the order they'd need to happen:**

1. Wire the generated corpus's `.expected` oracles into a held-out task
   split, which is what G4/G5 need. `build_corpus.py` still groups by source
   directory; the 15 task families are the intended holdout unit and are not
   used as such yet.
2. Decide whether the from-scratch model track is worth continuing at all.
   Corpus scale is the binding constraint and it is severe: even 200,000
   programs is ~79M unit tokens, Chinchilla-optimal at roughly 4M
   parameters. No corpus this project can realistically build produces a
   model that writes good Gene code, and the corpus itself is generated by a
   model that already can. The study's gates are *comparative* (beat a
   matched byte control at identical budget), so weakness does not falsify
   them -- but a modality advantage measured at ~1M parameters may not
   survive to any scale anyone deploys. The proposal's own appendix routes
   "the first serious Gene model" through a pretrained checkpoint instead.
3. If continuing: matched from-scratch runs scored with `evaluate.py`, on
   the generated corpus rather than the repo one.

## Usage

```bash
# 1. Build a gene binary (repo root)
nim c -d:release -o:bin/gene src/gene.nim

# 2. Build the corpus (local; needs the gene binary, not a GPU)
python3 training/build_corpus.py --gene-bin bin/gene --out training/corpus/out

# 3. Sync code (+ corpus, if built) to the remote host
training/sync.sh lenovo ~/exp/code

# 4. On the remote host: install deps, then run both arms
ssh lenovo
cd ~/exp/code/training
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
./run_matched.sh ../corpus/out ../checkpoints/pilot1 \
  --context-len 1024 --d-model 512 --n-layers 8 --n-heads 8 --steps 20000

# 5. Score the finished pilot against the pre-registered gates
python3 evaluate.py --corpus ../corpus/out \
  --units-run ../checkpoints/pilot1/units \
  --bytes-run ../checkpoints/pilot1/bytes \
  --gene-bin /path/to/gene --out ../checkpoints/pilot1/report.json
```
