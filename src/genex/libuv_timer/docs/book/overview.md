# Overview

genex/libuv_timer is an experimental owned timer package for native ingress. Its C shim builds against libuv 1.52.x, and `open` owns a materialized native library plus its ingress subscription. Each notification is the UTF-8 byte string `tick`; the handler receives it. `close` stops admission, and `IoResource:wait_closed` waits for handle close callbacks, the native thread, in-flight entries, and the handler. `status` forwards the subscription's counters and terminal state. A cancelled waiter does not cancel native retirement.
