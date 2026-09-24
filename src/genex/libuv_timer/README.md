# genex/libuv_timer

An experimental owned timer package for native ingress v5. Its format-1
`package.gene` builds the C shim against libuv 1.52.x through `pkg-config`;
it does not require a separate metadata format. The package currently targets
macOS arm64 and Linux x86_64. macOS arm64 has the installed-app runtime test;
Linux runtime qualification is pending.

```gene
(import $io [IoResource])
(import [open] ^from "." ^pkg "timer")

(let timer (open (fn [payload] ($println ($binary/to_str payload)))))
($sleep 50)
(timer .IoResource:close)
(await (timer .IoResource:wait_closed))
```

Each notification is the UTF-8 bytes `tick`. `open` owns a materialized C
library and its ingress subscription. `close` stops admission; `wait_closed`
waits for both libuv handle close callbacks, the native thread join, in-flight
ingress entries, and the Gene handler. `status` forwards the subscription's
bounded counters and terminal state. A cancelled waiter does not cancel native
retirement.

The installed-app test defaults to 100 lifetimes. Set
`GENE_LIBUV_LIFETIMES=10000` for the macOS qualification probe; it checks live
native contexts and handles after each close, total close callbacks, native
roots, and materialized leases.

The macOS test pins its SDK via
`tests/profiles/native-app/cli-toolchain.lock.json`; the installer records that
SDK path in the launcher for system-dependency validation.
