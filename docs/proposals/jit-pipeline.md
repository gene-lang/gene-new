# JIT Pipeline Design for gene-new

Status: design doc (not yet implemented). Reference implementation: `~/gene-workspace/gene/src/gene/native/`.

## Goal

Compile typed Gene functions directly to native machine code (arm64 + x86_64), bypassing the bytecode VM dispatch loop. The target is numeric-loop and recursive-numeric workloads such as `fib`, `sum`, and tight arithmetic loops where the VM's boxing/dispatch overhead dominates.

Expected gain vs. current bytecode VM: 5–20× on eligible functions (matching the alcove and LuaJIT experience on unboxed-numeric code).

---

## Eligibility Condition

A function is JIT-eligible if and only if:

1. **All parameters have explicit type annotations**, and those types are in `{Int, I64, F64, Bool}`.
2. **Return type is annotated** and is one of the same primitive set.
3. **Body only contains instructions the HIR lowering handles** — arithmetic, comparisons, conditionals, loops, local variable reads/writes, and direct calls to other JIT-eligible functions or typed natives.
4. **No dynamic scope captures**, no closures over non-primitive values, no `yield`, no `try`, no protocol dispatch to unknown receivers, no `spawn`/`await`.

In gene-new this check runs at function-definition time (when `opMakeFn` executes) and sets a flag on `FunctionProto`. The stub for this already exists: `FunctionProto.nativeOp` and `aotExpr`/`aotFrameKind` fields in `gir.nim`.

In the old gene the eligibility check is `isNativeEligible` in `bytecode_to_hir.nim` (~80 lines); it also does a trial HIR conversion to catch any lowering failures early.

---

## Pipeline

```
Gene source
    │  (compiler.nim: existing path)
    ▼
GIR bytecode chunk (typed fn)
    │  gir_to_hir.nim  ← new file, ports bytecode_to_hir.nim
    ▼
HIR (SSA, typed)            ← port hir.nim verbatim
    │
    ├── arm64_codegen.nim   ← port verbatim
    └── x86_64_codegen.nim  ← port verbatim
    │
    ▼
mmap'd executable bytes
    │  trampoline.nim  ← port verbatim
    ▼
NativeFn pointer stored on FunctionProto
    │  vm.nim: applyNativeCompiled()  ← already wired
    ▼
Called from VM dispatch (opCall*, opCallLocal*, etc.)
```

---

## Component Breakdown

### 1. HIR — `src/gene/native/hir.nim` (new file, ~550 lines)

Port verbatim from `~/gene-workspace/gene/src/gene/native/hir.nim`.

SSA-form typed IR. Key types:

```nim
HirType = enum
  HtVoid, HtBool, HtI64, HtF64, HtString, HtValue   # HtValue = boxed fallback

HirInst = object
  case kind: HirInstKind
  of hikConst:      constVal: int64 | float64
  of hikAdd, hikSub, hikMul, hikDiv, hikMod: lhs, rhs: HirReg
  of hikLt, hikLe, hikGt, hikGe, hikEq, hikNe: lhs, rhs: HirReg
  of hikBranch:     cond: HirReg; thenBlock, elseBlock: HirBlockId
  of hikJump:       target: HirBlockId
  of hikCall:       fn: HirReg; args: seq[HirReg]; retType: HirType
  of hikReturn:     val: HirReg
  ...

HirBlock = object
  id: HirBlockId
  insts: seq[HirInst]

HirFunction = object
  name: string
  params: seq[tuple[name: string, typ: HirType]]
  returnType: HirType
  blocks: seq[HirBlock]
  callDescriptors: seq[CallDescriptor]  # for VM-call fallback sites
```

No changes needed; HIR is independent of both the old and new bytecode formats.

### 2. GIR → HIR Lowering — `src/gene/native/gir_to_hir.nim` (new file, ~800 lines)

This is the only piece that must be written fresh. It ports the *strategy* of `bytecode_to_hir.nim` but remaps old Gene opcodes to gene-new GIR opcodes.

**Strategy** (same as old gene):
- Simulate GIR execution on an abstract stack, tracking which HIR register holds each stack slot and its `HirType`.
- At each GIR instruction, emit zero or more HIR instructions and update the abstract stack.
- Create a new HIR basic block at every branch target.
- Use a worklist of pending blocks; stop when all reachable blocks are lowered.

**GIR opcode → HIR mapping** (key cases):

| GIR opcode | HIR output |
|---|---|
| `opPushConst` (Int) | `hikConst HtI64` |
| `opPushConst` (F64) | `hikConst HtF64` |
| `opLoadLocal` / `opLoadOuterLocal` | `hikLoad` from slot |
| `opDefineLocal` / `opSetLocal` | `hikStore` to slot |
| `opJumpIfFalse` | `hikBranch` |
| `opJump` | `hikJump` |
| `opNativeFast2` (+, -, * on Int/I64/F64) | `hikAdd`/`hikSub`/`hikMul` |
| `opCall` / `opCall1` to a JIT-compiled callee | `hikCall` (direct) |
| `opCall` to a non-JIT callee with typed args | `hikCall` via trampoline |
| `opReturn` | `hikReturn` |

Slots map to HIR SSA registers. Each `opDefineLocal` allocates a new SSA name; `opSetLocal` generates a new version (the lowering does simple SSA construction — one definition per slot per block, phi nodes at join points via the standard algorithm if needed, or simpler: keep a mutable slot map and insert phis on demand).

For the initial slice, skip phi nodes entirely: handle only straight-line code and tail recursion. That covers `fib`, `factorial`, simple arithmetic loops.

### 3. arm64 Codegen — `src/gene/native/arm64_codegen.nim` (port verbatim, ~855 lines)

Register allocation strategy from old gene (simple, stack-based, no spilling for the initial cut):
- Parameters: `x0–x7`, return value `x0` (AAPCS64).
- HIR registers spilled to a stack frame; a read-cache of caller-saved `x9–x15` avoids redundant loads.
- Float operands use `d0–d7`.
- Recursive calls use a fixup list resolved after all code is emitted.
- Branch targets use a fixup list; `B`/`CBZ` instructions are patched once all labels are known.

The emitter writes `uint32` instructions into a `seq[byte]` buffer that is later `mmap`'d with `PROT_READ | PROT_EXEC`.

Key constants already in the old file (copy verbatim):
```nim
INSN_STP_FP_LR = 0xA9BF7BFD'u32  # stp x29, x30, [sp, #-16]!
INSN_MOV_FP_SP = 0x910003FD'u32  # mov x29, sp
INSN_LDP_FP_LR = 0xA8C17BFD'u32  # ldp x29, x30, [sp], #16
INSN_RET       = 0xD65F03C0'u32  # ret
```

### 4. x86_64 Codegen — `src/gene/native/x86_64_codegen.nim` (port verbatim)

SysV AMD64 ABI: `rdi, rsi, rdx, rcx, r8, r9` for integer args; `xmm0–xmm7` for floats; return in `rax`/`xmm0`.

### 5. Trampoline — `src/gene/native/trampoline.nim` (port verbatim, ~46 lines)

Handles calls from JIT code back into the Gene VM (for call sites that are not themselves JIT-compiled). Stores `NativeFnSig` (arg types + return type) so the codegen knows how to marshal Gene `Value`s at call boundaries.

The NaN-boxing layout in gene-new is identical to old gene (same `STRING_TAG_U64` / `PAYLOAD_MASK_U64` constants already in the old codegen), so marshaling code ports unchanged.

### 6. Dispatch in the VM — `src/gene/vm.nim` (minimal changes)

`applyNativeCompiled` already exists and is wired into the call dispatch for all `opCall*` variants. Currently it pattern-matches on `NativeCompileOp` enum values. Replace with:

```nim
proc applyNativeCompiled(callee: Value, proto: FunctionProto,
                         args: openArray[Value], named: NamedArgs): Value =
  if proto.jitFn != nil:
    return proto.jitFn(args)   # direct native call via stored function pointer
  # fall through to existing NativeCompileOp dispatch (keep as fallback)
  ...
```

Add `jitFn: pointer` (or a typed proc var) to `FunctionProto` in `gir.nim`. Compile and store the JIT output at `opMakeFn` time for eligible functions.

---

## Phased Plan

### Phase 1 — Straight-line arithmetic + tail recursion (arm64 only)

Covers: `fib`, `factorial`, `gcd`, simple counters.

- Port `hir.nim` and `trampoline.nim` verbatim.
- Write `gir_to_hir.nim` for the subset: `opPushConst`, `opLoadLocal`, `opDefineLocal`, `opSetLocal`, `opNativeFast2` (Int +/-/*), `opJumpIfFalse`, `opJump`, `opReturn`, `opCall1` (recursive self-call).
- Port `arm64_codegen.nim` verbatim.
- Wire into `applyNativeCompiled` via `jitFn` pointer on `FunctionProto`.
- New benchmark: `vm.fib_jit.compiled_chunk` (target: >20M calls/sec vs current ~4.8M).

### Phase 2 — Float loops + x86_64

- Add `HtF64` paths in the lowering and codegen.
- Port `x86_64_codegen.nim`.
- Covers: numeric integration, float-heavy ML inference loops.

### Phase 3 — Typed cross-function calls

- JIT calls between different JIT-compiled functions (not just self-recursion).
- Trampoline fallback for calls into un-JIT'd functions.
- Covers: mutually recursive typed functions.

### Phase 4 — Loop unrolling + phi nodes

- Proper SSA with phi nodes at loop back-edges.
- Enables SIMD vectorization pass for float arrays.

---

## File Layout

```
src/gene/
  native/
    hir.nim             # SSA typed IR (port from old gene)
    gir_to_hir.nim      # GIR bytecode → HIR lowering (new, ~800 lines)
    arm64_codegen.nim   # arm64 machine code emitter (port from old gene)
    x86_64_codegen.nim  # x86_64 machine code emitter (port from old gene)
    trampoline.nim      # VM↔native call boundary (port from old gene)
  gir.nim               # add jitFn field to FunctionProto
  vm.nim                # applyNativeCompiled: add jitFn dispatch path
  compiler.nim          # isNativeEligible: mark FunctionProto at opMakeFn time
```

---

## What Ports Unchanged vs. What Must Be Rewritten

| Component | Action | Reason |
|---|---|---|
| `hir.nim` | Port verbatim | Pure typed IR, no bytecode dependency |
| `arm64_codegen.nim` | Port verbatim | NaN-boxing layout is identical |
| `x86_64_codegen.nim` | Port verbatim | Same |
| `trampoline.nim` | Port verbatim | Value layout is identical |
| `bytecode_to_hir.nim` | Rewrite as `gir_to_hir.nim` | Opcode set differs (GIR vs old IK* opcodes) |
| `isNativeEligible` | Rewrite using GIR opcodes | Same logic, different instruction enum |
| VM dispatch wiring | Small addition to `applyNativeCompiled` | New `jitFn` pointer path |
| Compiler trigger | Small addition at `opMakeFn` site | Call eligibility check + JIT compile |

---

## Key Invariants to Preserve

- `sizeof(Value) == sizeof(uint64)` — NaN-boxing must stay intact at JIT call boundaries.
- Zero-initialized `Value` remains `nil` — the codegen must never produce a zero word for a non-nil result.
- JIT-compiled functions must produce identical results to the bytecode path for all inputs.
- A function that fails JIT compilation at `opMakeFn` time must fall back to the bytecode VM silently (set `jitFn = nil`, continue normally).
- `mmap` regions must be freed when the `FunctionProto` is collected (add a destructor or track in a global registry).
