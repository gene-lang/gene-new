# Conversation cards

A card is a value that response code places in its conversation, not an
installed extension. It appears inline in the transcript at the turn that made
it, stays there, and is stored with the session. Cards need no plugin; the
plugin system and the plugin manager do not know about them.

There are three uses:

- **Static cards** show a component tree with prompt and command buttons.
- **Card questions** give a question a custom view whose buttons select its
  answer.
- **Live cards** keep state plus `view` and `update` functions, so the user can
  work without a model call per click, then send the result once.

## Static cards

```gene
(card "plan" ^title "Migration plan"
  `(section
     (p "Three steps, about 40 files.")
     (button ^prompt "Start step 1." "Start step 1")))
(Outcome ^^done ^reply "The plan is in the card above.")
```

- Every card needs a concise `^title`: one line, at most 60 characters. The host
  draws it outside the card's tree, so do not repeat it inside.
- The id matches `[a-z0-9][a-z0-9_]{0,39}` and is unique in the session. Using
  the same id again redefines the card where it already is; a later turn shows
  a short "Updated: <title>" line linking to it.
- The tree uses the [web component](web-components.md) vocabulary and its
  24-level / 64 KiB bound, plus keyed controls.
- `^prompt` fills the composer. `^command` runs a slash command in this
  session, as if the user typed it. A card with command buttons is disabled
  after a reload until the user clicks **Enable**, because a stored `/run` or
  `/sh` button carries old code.

## Card questions

A question may carry a `^view`. Buttons with `^answer` select that value in the
question's draft (with `^^multi`, they toggle it); the user still submits the
batch with **Answer**.

```gene
(let tiles [])
(for id in ["c1" "c2" "c3" "c4"]
  (tiles .push `(button ^key %id ^answer %id
    (img ^src %$"out/${id}.png" ^alt %$"Candidate ${id}"))))
(Outcome ^questions
  [{^id "pick" ^prompt "Which candidate should I refine?"
    ^choices ["c1" "c2" "c3" "c4"]
    ^view `(div ^class_name "web_grid" %tiles...)}]
  ^reply "Pick the candidate to refine.")
```

- Every `^answer` value must be one of the question's `choices`, or text for a
  free-text question. A view that does not validate is an error in the turn.
- The host validates the submitted answers as for any question.
- After the batch is answered, dismissed or cancelled it is final. The
  transcript keeps the view with the saved answers marked and every control
  disabled; reloading never reopens it.
- `^^submit_on_answer` makes a click on an answer button submit at once. It is
  allowed only for a batch of one single-choice question with a view; the
  default stays select, then **Answer**, because a submitted answer is final.

### Question kinds that draw their own view

A plugin's `interactions` row may add `^render`, a function from the
validated question to a question view. A question of that kind without its own
`^view` gets the rendered one, validated like any question view:

```gene
(host .PluginHost:contribute "interactions"
  {^name "image_choice"
   ^validate_request (fn [question] question)
   ^validate_reply (fn [value] value)
   ^render (fn [question]
     (let tiles [])
     (for path in question/images
       (tiles .push `(button ^key %path ^answer %path (img ^src %path ^alt %path))))
     `(div ^class_name "web_grid" %tiles...))})
```

The render runs like any view render: leased, read-only and within 1 s /
32 MiB, whatever budget the asking response had left. The model then asks with
data only:
`{^id "pick" ^kind "image_choice" ^prompt "Which one?" ^choices ["a.png" "b.png"] ^images ["a.png" "b.png"]}`.

## Live cards

```gene
(card "renames" ^title "Proposed renames"
  ^state {^items [{^from "fetch_all" ^to "load_all" ^keep true}
                  {^from "do_it" ^to "apply_patch" ^keep true}]}
  ^view (fn [state]
    (let rows [])
    (for item in state/items
      (let label (if item/keep "Keep" "Skip"))
      (rows .push `(li ^key %item/from
        (button ^key %$"toggle-${item/from}" ^update "toggle"
          ^args %{^from item/from} %label)
        (code %$"${item/from} -> ${item/to}"))))
    `(section (ul %rows...)
       (button ^key "send" ^send "Apply the renames I kept." "Send to Gene")))
  ^update (fn [state action]
    (if (== action/name "toggle")
      {^items (state/items .map (fn [item]
        (if (== item/from action/args/from)
          {^from item/from ^to item/to ^keep (! item/keep)}
          item)))}
      state)))
(Outcome ^^done ^reply "Toggle the renames you want, then send them.")
```

- `^view` maps state to a tree. It must not have side effects; the host runs it
  whenever it redraws the card, under a 1 s / 32 MiB budget, and durable
  Harness writes fail inside it.
- `^update` maps `[state action]` to the new state, under a 2 s / 64 MiB budget.
  `action` has `name` (the control's `^update` value), `args` (its `^args`) and
  `fields` (a form's field values). `update` should only compute; put effects in
  a command button or hand them to the model with `^send`.
- `^view` and `^update` must be literal `(fn ...)` forms written in the `card`
  call. The host keeps their source and evaluates it in a fresh environment on
  every call: the standard library, the workspace's functions, `session_id`,
  `workspace_root` and `context` (`session_id`, `session`, and the session's
  current `round` or nil). A turn's local variables are never visible; put data
  the card needs in `^state`. An unresolved name fails when the code that uses
  it runs, so exercise `update` paths deliberately.
- State must serialize as data and stay under 64 KiB. A session holds at most 32
  cards.
- Live controls: buttons or forms with `^update`, buttons with `^send`, plus
  `^prompt` and `^command` buttons. Every control with an action, every form and
  every field needs a unique `^key`. Fields (`input`, `textarea`, `select` with
  `^field`) belong to a form that has `^update`.

### What the model can call

| Function | Effect |
| --- | --- |
| `(card "id" ^title "…" tree)` | Define or redefine a static card |
| `(card "id" ^title "…" ^state s ^view (fn …) ^update (fn …))` | Define or redefine a live card; `^update` is optional |
| `(card_update "id" state)` | Change a live card's state |
| `(card_state "id")` | Read a card's title, state and revisions |

A plugin function called from response code can place a card in the calling
conversation with `show_card` from `plugin_api`, which takes the same
arguments as `card` but needs `^view` and `^update` as quoted `fn` forms:

```gene
(import ^from "src/plugin_api.gene" [show_card])
(show_card "board" ^title "Board" ^state {^n 1}
  ^view (quote (fn [state] `(p %($to_str state/n)))))
```

Outside an open turn `show_card` fails.

`card` returns the card's id, revisions, a compact outline of the drawn tree
and `warnings`. The warnings list names in `^view` or `^update` that the card's
environment cannot resolve, such as a typo or a turn's local variable; they
also appear as a `[N.card]` item in the next request. The check is best-effort
and never refuses a card, because an unresolved name otherwise fails only when
the code that uses it runs. `card` checks everything else before it stores
anything: the id and title, the
state's size, one `view` run and the tree. If a check fails, the call raises
an error, a new card is not created and a redefined card keeps its previous
version. A card created in this round belongs to this round: `card_update` then
shows progress live, stored when the turn ends. `card_update` on a card from an
earlier round stores the state, runs no code and marks the card out of date
until the user redraws it.

## What the user sees

- **Enable after a reload.** A card is enabled in pages that were open when it
  was defined. Reloading the page disables every live card and every card with
  command buttons: each shows its last stored tree with **Enable**. Clicking it
  redraws the card with its stored code under the current workspace. Enabled
  state belongs to the page, so a host restart changes nothing for an open page.
- **The owning round.** While the round that defined a card is running, the card
  shows "Updating…" and refuses clicks. Clicks work again when the round ends or
  waits for answers.
- **A failed click leaves the card unchanged.** The state and tree are committed
  together only when `update`, the state check, `view` and tree validation all
  succeed; otherwise the error shows on the card. Effects of anything `update`
  called are not undone.
- **Stale clicks are refused.** Every action carries the card's definition and
  card revisions. If another tab or the model changed the card, the host refuses
  the click and the card shows its current tree.
- **Send delivers what the user saw.** `^send` submits a chat message with a
  `[card.<id>] <title>` item holding the card's state. A changed card is refused,
  not sent with newer data, and a busy session refuses the send.

Clicks that only call `update` never reach the model. A card reaches the model
through `^answer`, `^send`, a `^prompt` the user sends, or `card_state` in a
later turn.

## Storage and protocol

Each card is a `card/state` core projection in its session stream, keyed
`card/<id>`, holding the definition (title, kind, source), state, last tree,
the owning round and placement, both revisions and the last committed input
ids. Each click is a `card/action` record keyed by its input id; the newest 256
are kept.

- `POST /api/v8/sessions/<session>/cards/<id>/actions` takes `input_id`, `action`
  (`update` or `enable`), `name`, `args`, `fields`, `definition_revision`,
  `revision` and `generation` (the card's `action_generation`), and returns the
  receipt: `done`, `refused`, `failed` or `interrupted`, with the card's current
  public record.
- Action identities expire by generation. A generation advances every 128
  admissions; pruning a receipt raises the floor past its generation, first
  advancing the generation if the pruned receipt belongs to the current one. A
  request below the floor without a retained receipt is refused with
  `receipt_expired`, never run again; the refusal carries the card's current
  `action_generation`, so the page's next click is admissible. Admissions left by an earlier process are
  resolved before the next click in their session, while the card still names
  their input.
- A card's command button registers with the round-resume barrier until the
  command ends, so answering the card's round waits for it, like a click. A
  command that fails to start after admission releases its registration.
- Admission is durable before any card code runs, and a retained receipt
  answers a retry before any revision check. The commit names its input id, so
  a click admitted before a crash resolves to `done` or `interrupted`, never to
  a second run. `GET /api/v8/sessions/<session>/card-actions/<input_id>` reads a
  receipt.
- Round and command submissions accept `card` with `id`, `definition_revision`
  and `revision`. Commands from a static card check the definition revision; a
  live card's commands and every send check both.
- Snapshots include `card`, `card/update` and answered `questions` records; the
  `card` push message carries `card` and `event` (`defined`, `updated`,
  `enabled`, `stale` or `progress`).

The command-line `transcript` prints a card as its title and text, with
buttons shown as `[label]`, and an answered question view as its prompts and
answers. Cards are interactive only in the browser.

The design discussion is in `tmp/plugin-in-response.md`.
