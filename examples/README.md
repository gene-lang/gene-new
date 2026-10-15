# Examples

Run a single-file example from the repository root with
`bin/gene run examples/<file>.gene`; the language tours print what they
demonstrate.

## Language tours

| Example | Shows |
| --- | --- |
| [simple.gene](simple.gene) | Hello world. |
| [fibonacci.gene](fibonacci.gene) | Recursive functions. |
| [style_guide.gene](style_guide.gene) | Canonical Gene style. |
| [pipeline.gene](pipeline.gene) | `->` and `=>` value pipelines. |
| [nil_void_demo.gene](nil_void_demo.gene) | Optional arguments, missing fields, `nil` and `void`. |
| [protocol_demo.gene](protocol_demo.gene) | Types, protocols, messages, inheritance, and `Self`. |
| [error_handling.gene](error_handling.gene) | Typed errors and recovery. |
| [generators.gene](generators.gene) | Generators, including inherited generator messages. |
| [concurrency.gene](concurrency.gene) | Structured tasks, channels, cancellation, actors, and supervisors. |
| [events.gene](events.gene) | The event bus. |
| [macro.gene](macro.gene) | Template macros. |
| [fexpr_demo.gene](fexpr_demo.gene) | Fexprs, which interpret syntax at runtime. |
| [testing_demo.gene](testing_demo.gene) | The test library; also runs under `bin/gene test`. |

## Services and the web

| Example | Shows |
| --- | --- |
| [async-http-server.gene](async-http-server.gene) | The `net/http` server: routes, async jobs, limits, logging. `async-http-server.sh validate` checks it end to end. |
| [todo_app](todo_app/src/main.gene) | A server-rendered web app with forms and a JSON API (`bin/gene run examples/todo_app/src/main.gene`; creates `./todo.db`). |
| [web_component.gene](web_component.gene) | A web-profile component that renders a DOM node; see [web applications](../docs/workflows.md#web-applications). |
| [utils](utils/src/form.gene) | URL-encoded form handling shared by the web examples. |

## Native code

| Example | Shows |
| --- | --- |
| [native](native/README.md) | The experimental `typed_native` C backend calling SQLite, and the AOT Fibonacci benchmark. |

## Applications

These are full packages with their own tests (`bin/gene test` from their
directory).

| Application | What it is |
| --- | --- |
| [gene-harness](gene-harness/README.md) | Gene Harness: durable model conversations that answer in Gene code. |
| [cordis](cordis/README.md) | A plugin runtime with scoped services, hooks, and hot reload; the Harness builds on it. |

Imagination, Miclone, World, and Life live in their own repositories beside
this checkout.
