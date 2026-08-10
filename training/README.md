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
  -> gene compile             (catches macro/name-resolution errors)
  -> gene docpack -o out.gdoc  (parse, validate, canonicalize, encode -- one step)
  -> gene docunits -o out.jsonl (model-native logical unit stream)
  -> gene docunpack out.gdoc    (canonical .gene text, for the matched control)
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

1. A real pilot-scale corpus. 186 files (this repo's own source) is enough
   to prove the pipeline runs, nowhere near "tens of thousands of candidate
   programs" the proposal's corpus pipeline assumes, and the current
   train/validation/test split groups by *source directory* -- a proxy for
   avoiding near-duplicate leakage, not the proposal's semantic-tree-cluster
   holdout, which needs a designed task taxonomy that doesn't exist yet.
2. A working GPU on the training host (see the top-level project memory --
   as of this writing lenovo's GPU firmware (GSP/SEC2) is wedged; the user
   is handling recovery).
3. Matched from-scratch training runs at whatever capacity the memory probe
   says fits, evaluated against the Model-training study's pre-registered
   gates (memorization, structural validity, semantic pass rate vs. the
   control, position/throughput ratios) -- none of that has run yet.

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
```
