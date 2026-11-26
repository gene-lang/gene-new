# Gene on the web

This chapter serves HTTP, calls HTTP services, builds HTML and CSS as data,
and compiles Gene for the browser with the web profile.

## An HTTP server

`$net/http` serves HTTP. `listen` opens a port, and `serve` hands each
request to a handler function, which returns a response:

```gene
(import $net/http/[listen serve text])

(fn handle [request]
  (match request/path
    when "/" (text 200 "Hello from Gene")
    else (text 404 "Not found")))

(fn main [args]
  (let server (listen ^host "127.0.0.1" ^port 8080))
  (serve server ^handler handle)
  0)
```

```sh
gene run server.gene &
curl http://127.0.0.1:8080/
# Hello from Gene
```

- Each request runs as its own task. A handler that waits, on a database or
  another service, does not hold up the others.
- `^port 0` picks a free port, and `server/port` reports it.
- A port already in use raises an `HttpError` whose `code` is
  `address_in_use`.

The server also handles routing, request limits, timeouts, streamed request
and response bodies, and WebSockets. The reference documents each one under
`lib/gene/net/http`. The [Todo app](../../examples/todo_app/src/main.gene)
puts routes, forms, SQLite, and browser code together.

## Calling HTTP services

`$net/http_client/request` sends a request and returns a Task for the
response, with its `status`, `headers`, and `body`:

```gene
(import $net/http_client/[request])
(let response (await (request ^url "http://127.0.0.1:8080/")))
[response/status response/body]
# [200 "Hello from Gene"]
```

- A non-2xx status is an ordinary response. A failed connection raises an
  `HttpClientError`.
- Redirects are returned, not followed.
- TLS certificates are verified. `^ca_file` adds a CA.
- Credentials and cookies are plain request headers; there is no automatic
  store.

`$net/http_client/open` makes a reusable client that keeps connections open
between requests.

## HTML as data

Markup is ordinary node data, built with templates and rendered at the edge.
Rendering escapes text and attribute values:

```gene runnable
(import $html/[render])
(let title "Ada & Grace")
(render `(article ^class "card" (h1 %title)))
# "<article class=\"card\"><h1>Ada &amp; Grace</h1></article>"
```

Because a page is data until it is rendered, it can be built by ordinary
functions and inspected or tested like any value.

## CSS as data

`$css` builds style rules as data and renders them:

```gene runnable
(import $css/[decl render rule])
(render (rule ".card" (decl color "red") (decl padding "1rem")))
# ".card {\n  color: red;\n  padding: 1rem;\n}\n"
```

`$css` also covers media and container queries, `@font-face`, and class names
scoped to one component.

## The web profile

A module marked `^profile web` compiles to JavaScript, with TypeScript
declarations and source maps:

```gene
(mod browser ^profile web)
(fn double [value : Int] : Int (* value 2))
```

```sh
gene build --target web --out-dir web-out browser.gene
```

```js
import { double } from "./web-out/browser.mjs";
console.log(double(21n)); // 42n
```

| Gene | JavaScript |
| --- | --- |
| Int, F64 | bigint, number |
| `nil` | `null`; a host `undefined` reads as `nil` |
| List | Array |
| property map | Object |
| record type | an instance of a generated class |

The profile is a checked subset of Gene. It supports annotated functions,
macros, types and protocols, `match`, paths, collections, Streams, an async
subset, and checked DOM and JavaScript interop. It rejects what it does not
support, such as fexprs, `eval`, actors, channels, and native FFI, instead
of running it differently. Module-level `var` is rejected too, because
module state has no initialization order there.

> **Watch out:** the web profile requires both arithmetic operands to have the
> same type. `(+ 1 2.5)` runs on the VM, but on the web it needs an explicit
> `($to_float 1)`.

## Browser code in a server

A browser entry module declares `(fn main [root : EventTarget] : Nil …)`,
which runs with the element it mounts on. A server publishes the entry with
`($web/load "client.gene")` and puts it on a page with
`($web/script asset ^mount "root")`. The compiled files are served at
content-addressed URLs, so a browser caches them safely.

Browser bindings live under `$dom`, `$browser`, `$event`, and `$http` in the
web profile. They cover elements, events, history, storage, and requests
back to the server.

`($web/published_routes)` lists every compiled asset a server would serve,
so a server-rendered site can also be exported as static files.
