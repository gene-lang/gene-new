# Browser playground

`index.html` evaluates Gene in the browser through the wasm host ABI. The
module is a build output and is not checked in; build it first:

```sh
nimble wasm        # needs Emscripten (`emcc` on PATH); writes web/gene.js + web/gene.wasm
cd web
python3 -m http.server 9000
open http://localhost:9000
```

`nimble wasm` also runs `tests/test_wasm.mjs` against the fresh build.
`gene_dom.generated.d.ts` is hand-maintained despite its name:
`tests/transpile_typecheck.mjs` type-checks emitted web-profile artifacts
against it.
