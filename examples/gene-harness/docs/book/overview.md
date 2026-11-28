# Overview

Gene Harness runs durable conversations in a project workspace. A turn sends
Gene source to a model, appends the model's code and results to the transcript,
evaluates the code, and interprets the final value. The operator sees the code,
labeled results, progress, questions, and expandable live output. The Harness
itself is a Gene package; workspace plugins extend its conversation without
changing the language.

## A valid response

A response is Gene source. It may define values, call the standard library and
the workspace's plugin functions, and append output with helpers such as
`append_prompt`. It ends in an `Outcome`, the value the loop interprets. Core
outcomes are `(Outcome ^^done ^reply "...")` for a finished turn, `(Outcome
^questions ...)` when the operator must choose, and `(Outcome ^prompt "...")`
when the turn continues after more input. Extensions may own additional
Outcome fields. A response that evaluates to something else, or raises, fails
the turn; the failure and its repair hint stay in the transcript.

File edits use an apply-patch block, not shell redirection. Read and write
workspace files through the plugin functions the turn makes callable. The
operator's workspace is the current directory unless the workspace says
otherwise.

## Getting help

Two helpers are always available and do not consume the turn:

- `(discover "topic")` searches documentation and capabilities by name,
  summary, and tag. All query words must match, so use one focused topic or an
  exact name per call. It returns owners, callable signatures, and chapter
  references. Narrow with `^kind "docs"` or `^kind "functions"`, or with
  `^owner "plugin_id"`. Results page with `^offset`.
- `(doc "chapter/name")` loads one documentation chapter or page. Section ids
  are `book/<chapter>/<section>`; a chapter's page lists its sections.

The docs index is the first page to load: it lists the book chapters and the
public API. A workspace plugin's functions become callable in response code,
`/run`, and the REPL; `discover` finds them after activation.

## Managing workspaces

The `gene-harness` launcher serves the manager and a workspace's web UI. The
manager uses its own workspace root (`$HOME/.gene-harness-root` by default) and
hosts workspaces under `ROOT/workspaces`. A workspace's `web` command starts its
UI; provider configuration and port preferences stay with the workspace.

## What comes next

This overview is the first chapter of the Harness book. The chapters it will
point to are: installing and starting a workspace; the turn loop and response
grammar; `Outcome` kinds and questions; workspace and plugin contracts;
managing files and patches; web components and cards; notifications and
background work; voice and computer use; media and documents; providers and
models; triggers, discovery, and sub-agents; logging and verification; and the
operator's manager and settings.
