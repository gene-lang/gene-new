# safe_ai_agent

An LLM agent whose only way to act is to **emit a Gene program**. There is no
tool-call surface: the model writes code, the interpreter runs it under an
explicit capability grant, and the grant — not a prompt, not a convention — is
what decides what the code can reach.

`docs/design.md` is the argument and the open problems. This file is how it
works and how to run it.

## Running it

```bash
nimble build                     # produces bin/gene
cd examples/safe_ai_agent

# offline, no API key needed
GENE_AGENT_STUB=1 ../../bin/gene run src/main.gene

# live, with the Gene skill loaded
../../bin/gene run --allow_read_dir ../../tools/gene-lang-skill src/main.gene
```

Live mode uses OpenRouter: put the key in `OPENAI_AUTH_TOKEN` and override the
model with `GENE_AGENT_MODEL`. A stale shell `OPENAI_API_KEY` beats
`OPENAI_AUTH_TOKEN` and yields 401 — set `OPENAI_AUTH_TOKEN`.

Type `exit`, `quit`, `/quit`, or Ctrl-D to leave.

## The flow

```
  you type a task at the prompt
        │
        ▼
  ┌─────────────────────────────────────────────────────────────┐
  │  agent → LLM:  system prompt + history + your task          │
  │                                                             │
  │  LLM  → agent: one Gene map, and nothing else:              │
  │        {^status "in-progress"|"done"                        │
  │         ^response "what I'm doing / my answer"              │
  │         ^code    (do ...)}                                  │
  │                                                             │
  │  agent prints ^response                                     │
  │  agent prints ^code                                         │
  │  agent evaluates ^code as ONE program, under its grant      │
  │  agent prints the result (a value, an error, or a refusal)  │
  │                                                             │
  │  history += the reply map + the output of running it        │
  └─────────────────────────────────────────────────────────────┘
        │                                    ▲
        │  ^status "in-progress"             │
        └────────────────────────────────────┘   (max 16 turns)
        │
        │  ^status "done"
        ▼
  back to the prompt, waiting for your next task
```

Step by step:

1. **You type a task.** Blank lines are ignored; `exit`/`quit`/`/quit`/Ctrl-D
   end the session.
2. **The agent calls the model** with the system prompt (envelope shape, tool
   summary, Gene primer, and the loaded skill's `SKILL.md` if one was granted),
   the history of this task so far, and your text.
3. **The model replies with one Gene map.** Not prose, not JSON — Gene data,
   read with `$parse/read_all`. A reply that is not readable Gene ends the task
   with *the model did not return Gene data*.
4. **The agent prints `^response`** — the model's own account of what it is
   about to do, or its final answer.
5. **The agent evaluates `^code`.** It is already one `(do …)` block, so the
   shape the model wrote is the shape that runs — a form may use what an
   earlier form defined, with nothing reassembled in between.
6. **The agent prints the result** — the last form's value, or `error: …` for an
   ordinary mistake, or `refused: …` for a capability denial. A denial is a
   *value* here, not a crash, so the model can see it and try something else.
7. **The turn is appended to history** as the whole reply map *and* the output
   of running it, so the next turn can tell which form drew which complaint.
   (Your task text is re-sent every turn, so history does not repeat it.)
8. **If `^status` is `"in-progress"`, loop** back to step 2 with the updated
   history. Otherwise the task is finished and control returns to the prompt.

The loop is bounded at **16 turns** per task; hitting the ceiling prints
`(turn limit reached)`.

The printed `^code` is the **canonical** form of the program, so `$fs/list_dir`
appears as `(path gene fs list_dir)`. That is what will actually execute, which
is the point of showing it, but it is not the model's spelling — Gene exposes no
sugar-restoring printer to Gene code today, only `gene fmt` at the CLI.

### Two things about the ordering

**`^response` is printed before `^code` runs.** Both arrive in the same message,
so the model's summary is composed *before* it can know what the code did. A
confident "ran it successfully" can therefore sit directly above a result that
disagrees. This is why the program is printed between them: check the claim
against the code and the result, not against the prose. See `docs/design.md`,
"Open problems".

**History is not truncated.** Every turn's reply and output accumulate for the
duration of one task, and a turn that reads a large file puts the whole file in
there. The task-level history is discarded when you return to the prompt, so it
cannot grow across tasks, but a single long task can outgrow the context window.
Truncation is not implemented.

## What generated code may do

Model-emitted code calls the **ordinary standard library** — there is no bespoke
tool layer to learn:

```gene
($fs/list_dir ".")                     ; what's in the workspace
($fs/read_text "notes.txt")
($fs/write_text "todo.gene" source)
($fs/remove "scratch.txt")
($fs/exists? "todo.gene")
(run_note "todo.gene")                 ; evaluate a note and return its result
```

What confines it is the authority its `Env` was minted with, resolved against
this module's own context, so it can never name more than the module already
holds:

- **`workspace/`** — read-write. Relative names land here.
- **the skill directory** — read-only, and only if the host granted it.
- **nothing else.** `($os/get_env "HOME")` is refused even though the module
  holds `os/Env` to reach the API key, because that authority is not in the row.

`run_note` is the one non-stdlib name, and it is not a filesystem primitive: it
evaluates a saved file through the same grant, so the model can test what it
wrote. It refuses to nest.

Bindings do not survive a turn. Anything the model wants to keep goes in the
workspace — the filesystem is its memory.

## Skills

A skill is a directory of Markdown: `SKILL.md` is loaded into the system prompt,
and the files it points at are read on demand with `(read_skill "…")`. Passing
`--allow_read_dir <dir>` is what makes one visible, so **which skills an agent
has is a property of how it was launched**, not a config file it could rewrite.
Without the flag the agent still starts and says it has no skill.

## Offline mode

`GENE_AGENT_STUB=1` returns canned replies, so the example runs and is testable
with no API key. Five prompts show the five things worth seeing:

| prompt | what the model emits | outcome |
| --- | --- | --- |
| `read the notes` | `($fs/list_dir ".")`, `($fs/read_text "notes.txt")` | both succeed |
| `write something` | `($fs/write_text "todo.txt" …)`, then reads it back | succeeds — the grant is real |
| `raw effect` | `($os/get_env "HOME")` | refused — needs `os/Env` |
| `escape the sandbox` | `($fs/read_text "../package.gene")` | refused |
| anything else | defines `xs`, sums it, returns `6` | one block, not a statement list |

## Layout

```text
src/main.gene        the agent: tools, capability rows, the loop
docs/design.md       why capabilities are the load-bearing part, and what is unsolved
workspace/           the agent's memory; notes.txt is a committed fixture,
                     everything else is output from a run
package.gene         the application manifest
```
