# Native effect coverage inventory

This inventory is checked by `tools/check_native_effect_inventory.py`. The
runtime catalog is `src/gene/native_effects.nim`; changing a callable's display
name does not grant its disposition. Trusted constructors attach immutable
metadata. Unclassified host extensions and unsupported operations reject in
normalized execution before their implementation runs. Guarded adapters still
derive and check the actual operation at its effect boundary.

Entries identify native implementations. Namespace aliases, held values,
protocol/type methods, bound calls and callable adaptations preserve the same
native value and disposition. Public HTTP-server paths are `net/http/*`, and
database-opening paths are `db/sqlite/*` and `db/postgres/*`. Other type-prefixed
entries name receiver methods. Dynamic map/filter-map stages use their existing
catalog identities. Dynamic AOT entries are explicitly unsupported; compiler
FFI placeholders have no executable implementation or arithmetic fast path.

Private host control is currently separated by retained source origins. The
ordinary startup source-policy migration must finish before this distinction
supports deny-by-default launcher rollout. Additional providers and callback
adapters required by the supported Harness workflow remain required work.
Unsupported actor/event registrations, REPL adapters, filesystem async I/O,
stores, logging and server APIs are migration work, not completed provider claims.

The checks below cover native dispatch and its registered surface. Backend
release also requires the bytecode/FFI/AOT boundary audit, internal host-work
inventory, registration/lifecycle coverage, and real workflow tests. A listed
test suite is an enforcement evidence location, not proof that every exported
alias has an independent integration fixture.

| Native identity | Disposition | Contract / enforcement | Evidence | Registration sites |
| --- | --- | --- | --- | --- |
| `!=` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biNe) |
| `$` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDollar) |
| `*` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biMul) |
| `+` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biAdd) |
| `-` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biSub) |
| `/` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDiv) |
| `//` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRem) |
| `<` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (comparison) |
| `<=` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (comparison) |
| `==` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biEq) |
| `>` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (comparison) |
| `>=` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (comparison) |
| `Actor/ask` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biActorAsk) |
| `Actor/send` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biActorSend) |
| `Actor/snapshot` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biActorSnapshot) |
| `Actor/try_send` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biActorTrySend) |
| `Actor/upgrade` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biActorUpgrade) |
| `AtomicCell/compare_exchange` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biAtomicCellCompareExchange) |
| `AtomicCell/load` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biAtomicCellLoad) |
| `AtomicCell/store` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biAtomicCellStore) |
| `AtomicCell/swap` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biAtomicCellSwap) |
| `Buffer/copy_from` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biBufferCopyFromBang) |
| `Buffer/elem_type` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biBufferElemType) |
| `Buffer/fill` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biBufferFillBang) |
| `Buffer/get` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biBufferGet) |
| `Buffer/len` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biBufferLen) |
| `Buffer/set` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biBufferSetBang) |
| `Buffer/to_bytes` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biBufferToBytes) |
| `Buffer/to_list` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biBufferToList) |
| `Bus/close` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/events.nim` (biEventBusClose) |
| `Bus/closed?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/events.nim` (biEventBusClosed) |
| `Bus/publish` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/events.nim` (biEventBusPublish) |
| `Bus/subscribe` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/events.nim` (biEventBusSubscribe) |
| `Bus/subscription_count` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/events.nim` (biEventBusSubscriptionCount) |
| `C/close` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biCPtrClose) |
| `C/closed?` | Capability-free | Provided handle bookkeeping/payload only; no resource I/O, discovery or release. | test_native_effects; existing API suites | `src/gene/vm.nim` (biCPtrClosed) |
| `CallerEnv/snapshot` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biEnvSnapshot) |
| `Cell/get` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biCellGet) |
| `Cell/set` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biCellSet) |
| `Cell/swap` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biCellSwap) |
| `Cell/update` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biCellUpdate) |
| `Channel/close` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biChannelClose) |
| `Channel/recv` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biChannelRecv) |
| `Channel/send` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biChannelSend) |
| `Channel/try_recv` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biChannelTryRecv) |
| `Channel/try_send` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biChannelTrySend) |
| `CompositeSink/sinks` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/events.nim` (biCompositeSinkSinks) |
| `Date/day` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDateDay) |
| `Date/month` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDateMonth) |
| `Date/year` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDateYear) |
| `DateTime/day` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDateTimeDay) |
| `DateTime/hour` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDateTimeHour) |
| `DateTime/microsecond` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDateTimeMicrosecond) |
| `DateTime/minute` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDateTimeMinute) |
| `DateTime/month` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDateTimeMonth) |
| `DateTime/offset` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDateTimeOffset) |
| `DateTime/second` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDateTimeSecond) |
| `DateTime/timezone` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDateTimeTimezone) |
| `DateTime/year` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDateTimeYear) |
| `Db/close` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biDbClose) |
| `Db/closed?` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biDbClosed) |
| `Db/exec` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biSqliteExec), `src/gene/stdlib.nim` (biPostgresExec) |
| `Db/execute` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biSqliteExecute), `src/gene/stdlib.nim` (biPostgresExecute) |
| `Db/query` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biSqliteQuery), `src/gene/stdlib.nim` (biPostgresQuery) |
| `Db/query_one` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biSqliteQueryOne), `src/gene/stdlib.nim` (biPostgresQueryOne) |
| `Db/transaction` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biSqliteTransaction), `src/gene/stdlib.nim` (biPostgresTransaction) |
| `Duration/microseconds` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDurationMicroseconds) |
| `Duration/milliseconds` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDurationMilliseconds) |
| `Duration/seconds` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDurationSeconds) |
| `Enum/backing` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biEnumBacking) |
| `Enum/from_backing` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biEnumFromBacking) |
| `Enum/from_name` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biEnumFromName) |
| `Enum/from_ordinal` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biEnumFromOrdinal) |
| `Enum/name` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biEnumName) |
| `Enum/names` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biEnumNames) |
| `Enum/ordinal` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biEnumOrdinal) |
| `Enum/variants` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biEnumVariants) |
| `Env/extend` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biEnvExtend) |
| `EventSink/emit` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/events.nim` (biEventSinkEmit) |
| `FsFileLock/close` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biFsFileLockClose) |
| `FsWatcher/close` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biFsWatcherClose) |
| `FsWatcher/recv` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biFsWatcherRecv) |
| `List/assoc` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biListAssoc) |
| `List/push` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biListPushBang) |
| `List/set` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biListSetBang) |
| `Logger/child` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biLoggerChild) |
| `Logger/debug` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biLoggerDebug) |
| `Logger/emit` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biLoggerEmit) |
| `Logger/enabled?` | Capability-free | Provided handle bookkeeping/payload only; no resource I/O, discovery or release. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biLoggerEnabled) |
| `Logger/error` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biLoggerError) |
| `Logger/info` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biLoggerInfo) |
| `Logger/trace` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biLoggerTrace) |
| `Logger/warn` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biLoggerWarn) |
| `Logger/with` | Capability-free | Provided handle bookkeeping/payload only; no resource I/O, discovery or release. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biLoggerWith) |
| `Map/assoc` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biMapAssoc) |
| `Map/delete` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biMapDeleteBang) |
| `Map/get` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biMapGet) |
| `Map/put` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biMapPutBang) |
| `Module/declarations` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biModuleDeclarations) |
| `Module/meta` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biModuleMeta) |
| `Module/name` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biModuleName) |
| `Module/path` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biModulePath) |
| `Module/root_namespace` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biModuleRootNamespace) |
| `Namespace/bindings` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biNamespaceBindings) |
| `Namespace/declarations` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biNamespaceDeclarations) |
| `Namespace/lookup` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biNamespaceLookup) |
| `Node/push_body` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biNodePushBodyBang) |
| `Node/set_body` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biNodeSetBodyBang) |
| `Node/set_prop` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biNodeSetPropBang) |
| `Range/inclusive?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRangeInclusive) |
| `Range/size` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRangeSize) |
| `Range/start` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRangeStart) |
| `Range/step` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRangeStep) |
| `Range/stop` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRangeStop) |
| `RecordingSink/clear` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/events.nim` (biRecordingSinkClear) |
| `RecordingSink/events` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/events.nim` (biRecordingSinkEvents) |
| `Regex` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRegex) |
| `ReplyTo/send` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biReplyToSend) |
| `SandboxGeneration/graph` | Private host control | Host source/generation management; reject retained application source origins. | test_capability_source_policy | `src/gene/vm.nim` (biSandboxGenerationGraph) |
| `SandboxGeneration/module` | Private host control | Host source/generation management; reject retained application source origins. | test_capability_source_policy | `src/gene/vm.nim` (biSandboxGenerationModule) |
| `SandboxGeneration/release` | Private host control | Host source/generation management; reject retained application source origins. | test_capability_source_policy | `src/gene/vm.nim` (biSandboxGenerationRelease) |
| `SandboxTransaction/commit` | Private host control | Host source/generation management; reject retained application source origins. | test_capability_source_policy | `src/gene/vm.nim` (biSandboxTransactionCommit) |
| `SandboxTransaction/discard` | Private host control | Host source/generation management; reject retained application source origins. | test_capability_source_policy | `src/gene/vm.nim` (biSandboxTransactionDiscard) |
| `SandboxTransaction/prepare` | Private host control | Host source/generation management; reject retained application source origins. | test_capability_source_policy | `src/gene/vm.nim` (biSandboxTransactionPrepare) |
| `Set` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biSet) |
| `Store/checkpoint` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biStoreCheckpoint) |
| `Store/clear` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biStoreClear) |
| `Store/close` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biStoreClose) |
| `Store/delete` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biStoreDelete) |
| `Store/get` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biStoreGet) |
| `Store/has?` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biStoreHas) |
| `Store/keys` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biStoreKeys) |
| `Store/load_checkpoint` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biStoreLoadCheckpoint) |
| `Store/put` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biStorePut) |
| `Stream/close` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biStreamClose) |
| `Stream/has_next` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biStreamHasNext) |
| `Stream/next` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biStreamNext) |
| `Stream/peek` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biStreamPeek) |
| `Stream/try_next` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biStreamTryNext) |
| `Subscription/active?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/events.nim` (biEventSubscriptionActive) |
| `Subscription/cancel` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/events.nim` (biEventSubscriptionCancel) |
| `Task/cancel` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTaskCancel) |
| `Task/detach` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTaskDetach) |
| `Task/join` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTaskJoin) |
| `Time/hour` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTimeHour) |
| `Time/microsecond` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTimeMicrosecond) |
| `Time/minute` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTimeMinute) |
| `Time/offset` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTimeOffset) |
| `Time/second` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTimeSecond) |
| `Time/timezone` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTimeTimezone) |
| `Timezone/name` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTimezoneName) |
| `Timezone/offset` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTimezoneOffset) |
| `Type/fields` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTypeFields) |
| `Type/name` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTypeName) |
| `absent?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biIsAbsent) |
| `actor/continue` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biActorContinue) |
| `actor/spawn` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biActorSpawn) |
| `actor/stop` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biActorStop) |
| `aot/load` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biAotLoad) |
| `assert` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/testing.nim` (biAssert) |
| `assoc_in` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biAssocIn) |
| `atomic_cell` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biAtomicCell) |
| `binary/concat` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesConcat) |
| `binary/from_list` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesFromList) |
| `binary/from_str` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesFromStr) |
| `binary/get` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesGet) |
| `binary/get_f32` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesGetF32) |
| `binary/get_f64` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesGetF64) |
| `binary/get_i32` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesGetI32) |
| `binary/get_u16` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesGetU16) |
| `binary/get_u32` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesGetU32) |
| `binary/put_f32` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesPutF32) |
| `binary/put_f64` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesPutF64) |
| `binary/put_i32` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesPutI32) |
| `binary/put_u16` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesPutU16) |
| `binary/put_u32` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesPutU32) |
| `binary/put_u8` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesPutU8) |
| `binary/size` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesSize) |
| `binary/slice` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesSlice) |
| `binary/to_buffer` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesToBuffer) |
| `binary/to_list` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesToList) |
| `binary/to_str` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBytesToStr) |
| `bit/and` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBitAnd) |
| `bit/not` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBitNot) |
| `bit/or` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBitOr) |
| `bit/shl` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBitShl) |
| `bit/shr` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBitShr) |
| `bit/xor` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBitXor) |
| `body` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biBody), `src/gene/vm.nim` (biBody) |
| `buffer` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biBuffer) |
| `bytes` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biBytes) |
| `capabilities/any` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/capability_api.nim` (biCapabilityAny) |
| `capabilities/build` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/capability_api.nim` (biCapabilityBuild) |
| `capabilities/check_operation` | Guarded | Advisory provider inspection; never perform or authorize the requested effect. | test_capability_api | `src/gene/capability_api.nim` (biCapabilityCheckOperation) |
| `capabilities/check_requirements` | Guarded | Advisory provider inspection; never perform or authorize the requested effect. | test_capability_api | `src/gene/capability_api.nim` (biCapabilityCheckRequirements) |
| `capabilities/entry` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/capability_api.nim` (biCapabilityEntry) |
| `capabilities/parse` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/capability_api.nim` (biCapabilityParse) |
| `capabilities/pattern` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/capability_api.nim` (biCapabilityPattern) |
| `cell` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biCell) |
| `channel` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biChannel) |
| `chars` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biChars) |
| `construct_type` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biConstructType) |
| `contains?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biContains) |
| `crypto/random_hex` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biCryptoRandomHex) |
| `crypto/secure_equal?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biCryptoSecureEqual) |
| `crypto/sha256` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biCryptoSha256) |
| `css/class_name` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biCssClassName) |
| `css/css` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biCss) |
| `css/decl_value` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biCssDeclValue) |
| `css/frame` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biCssFrame) |
| `css/keyframes` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biCssKeyframes) |
| `css/media` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biCssMedia) |
| `css/render` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biCssRender) |
| `css/rule` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biCssRule) |
| `css/scoped` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biCssScoped) |
| `curses/close` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biCursesClose) |
| `curses/dimensions` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biCursesDimensions) |
| `curses/draw` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biCursesDraw) |
| `curses/escape_pressed?` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biCursesEscapePressed) |
| `curses/next_event` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biCursesNextEvent) |
| `curses/open` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biCursesOpen) |
| `curses/read_input` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biCursesReadInput) |
| `curses/refresh_input` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biCursesRefreshInput) |
| `date` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDate) |
| `datetime` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDateTime) |
| `declarations` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biDeclarations), `src/gene/vm.nim` (biDeclarations) |
| `device/Buffer/backend` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biDeviceBufferBackend) |
| `device/Buffer/elem_type` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biDeviceBufferElemType) |
| `device/Buffer/len` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biDeviceBufferLen) |
| `device/buffer` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biDeviceBuffer) |
| `duration` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biDuration) |
| `each` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biEach), `src/gene/vm.nim` (biEach) |
| `empty?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biListEmpty) |
| `event/Bus` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/events.nim` (biEventBusNew) |
| `event/CompositeSink` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/events.nim` (biCompositeSinkNew) |
| `event/NullSink` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/events.nim` (biNullSinkNew) |
| `event/RecordingSink` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/events.nim` (biRecordingSinkNew) |
| `event/exact` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/events.nim` (biEventExact) |
| `ffi/Library/close` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biFfiLibraryClose) |
| `ffi/Library/closed?` | Capability-free | Provided handle bookkeeping/payload only; no resource I/O, discovery or release. | test_native_effects; existing API suites | `src/gene/vm.nim` (biFfiLibraryClosed) |
| `ffi/Library/path` | Capability-free | Provided handle bookkeeping/payload only; no resource I/O, discovery or release. | test_native_effects; existing API suites | `src/gene/vm.nim` (biFfiLibraryPath) |
| `ffi/bind` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biFfiBind) |
| `ffi/open` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biFfiOpen) |
| `filter` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biFilter), `src/gene/vm.nim` (biFilter) |
| `filter_map` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biFilterMap), `src/gene/vm.nim` (biFilterMap) |
| `first` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biListFirst) |
| `freeze` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biFreeze) |
| `freeze_shallow` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biFreezeShallow) |
| `fs/exists?` | Guarded | Section 11 filesystem demand, current/origin authority, no-follow identity checks. | test_fs_capability_policy; test_fs_capability_handles | `src/gene/stdlib.nim` (biFsExists) |
| `fs/list_dir` | Guarded | Section 11 filesystem demand, current/origin authority, no-follow identity checks. | test_fs_capability_policy; test_fs_capability_handles | `src/gene/stdlib.nim` (biFsListDir) |
| `fs/make_dir` | Guarded | Section 11 filesystem demand, current/origin authority, no-follow identity checks. | test_fs_capability_policy; test_fs_capability_handles | `src/gene/stdlib.nim` (biFsMakeDir) |
| `fs/read_bytes` | Guarded | Section 11 filesystem demand, current/origin authority, no-follow identity checks. | test_fs_capability_policy; test_fs_capability_handles | `src/gene/stdlib.nim` (biFsReadBytesSync) |
| `fs/read_text` | Guarded | Section 11 filesystem demand, current/origin authority, no-follow identity checks. | test_fs_capability_policy; test_fs_capability_handles | `src/gene/stdlib.nim` (biFsReadTextSync) |
| `fs/read_text_async` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biFsReadTextAsync) |
| `fs/real_path` | Guarded | Section 11 filesystem demand, current/origin authority, no-follow identity checks. | test_fs_capability_policy; test_fs_capability_handles | `src/gene/stdlib.nim` (biFsRealPath) |
| `fs/remove` | Guarded | Section 11 filesystem demand, current/origin authority, no-follow identity checks. | test_fs_capability_policy; test_fs_capability_handles | `src/gene/stdlib.nim` (biFsRemove) |
| `fs/try_lock` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biFsTryLock) |
| `fs/watch` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biFsWatch) |
| `fs/write_bytes` | Guarded | Section 11 filesystem demand, current/origin authority, no-follow identity checks. | test_fs_capability_policy; test_fs_capability_handles | `src/gene/stdlib.nim` (biFsWriteBytesSync) |
| `fs/write_text` | Guarded | Section 11 filesystem demand, current/origin authority, no-follow identity checks. | test_fs_capability_policy; test_fs_capability_handles | `src/gene/stdlib.nim` (biFsWriteTextSync) |
| `fs/write_text_async` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biFsWriteTextAsync) |
| `fs/write_text_atomic` | Guarded | Section 11 filesystem demand, current/origin authority, no-follow identity checks. | test_fs_capability_policy; test_fs_capability_handles | `src/gene/stdlib.nim` (biFsWriteTextAtomicSync) |
| `graphemes` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biGraphemes) |
| `hash` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biHash) |
| `head` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biHead), `src/gene/vm.nim` (biHead) |
| `html/attr_escape` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biHtmlEscape) |
| `html/escape` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biHtmlEscape) |
| `html/render` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biHtmlRender) |
| `http/actor_pool` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biHttpActorPool) |
| `http/bytes` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biHttpBytes) |
| `http/html` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biHttpHtml) |
| `http/json` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biHttpJson) |
| `http/listen` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biHttpListen) |
| `http/not_found` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biHttpNotFound) |
| `http/redirect` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biHttpRedirect) |
| `http/route` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biHttpRoute) |
| `http/serve` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biHttpServe) |
| `http/status` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biHttpStatus) |
| `http/stop` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biHttpStop) |
| `http/supervisor_policy` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biHttpSupervisorPolicy) |
| `http/text` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biHttpText) |
| `http/ws_accept` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biHttpWsAccept) |
| `http/ws_close` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biHttpWsClose) |
| `http/ws_send` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biHttpWsSend) |
| `into` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biInto), `src/gene/vm.nim` (biInto) |
| `json/parse` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biJsonParse) |
| `json/stringify` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biJsonStringify) |
| `key` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biSelectorKey) |
| `last` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biListLast) |
| `leaf?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biIsLeaf) |
| `lex_all` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biLexAll) |
| `log/new_file_logger` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biLogNewFileLogger) |
| `log/new_logger` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biLogNewLogger) |
| `map` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMap), `src/gene/vm.nim` (biMap) |
| `math/abs` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathAbs) |
| `math/acos` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathAcos) |
| `math/asin` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathAsin) |
| `math/atan` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathAtan) |
| `math/atan2` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathAtan2) |
| `math/ceil` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathCeil) |
| `math/clamp` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathClamp) |
| `math/cos` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathCos) |
| `math/exp` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathExp) |
| `math/floor` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathFloor) |
| `math/hypot` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathHypot) |
| `math/log` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathLog) |
| `math/log10` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathLog10) |
| `math/log2` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathLog2) |
| `math/max` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathMax) |
| `math/min` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathMin) |
| `math/pow` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathPow) |
| `math/round` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathRound) |
| `math/sign` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathSign) |
| `math/sin` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathSin) |
| `math/sqrt` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathSqrt) |
| `math/tan` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathTan) |
| `math/trunc` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMathTrunc) |
| `meta` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biMeta), `src/gene/vm.nim` (biMeta) |
| `net/http_client/describe_operation` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biDescribeCapabilityHttp) |
| `net/http_client/prepare` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biPrepareCapabilityHttp) |
| `net/http_client/request` | Guarded | Prepared HTTP facts; guard submission and worker start; retain request context. | test_http_capabilities; test_http_capability_transport | `src/gene/stdlib.nim` (biHttpClientRequest) |
| `net/http_client/send` | Guarded | Prepared HTTP facts; guard submission and worker start; retain request context. | test_http_capabilities; test_http_capability_transport | `src/gene/stdlib.nim` (biHttpClientSend) |
| `net/http_client/stream` | Guarded | Prepared HTTP facts; guard submission and worker start; retain request context. | test_http_capabilities; test_http_capability_transport | `src/gene/stdlib.nim` (biHttpClientStream) |
| `net/tcp_read_text_async` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biNetTcpReadTextAsync) |
| `net/tcp_write_text_async` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biNetTcpWriteTextAsync) |
| `nil?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biIsNil) |
| `not` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biNot) |
| `now` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biNow) |
| `os/begin_interrupt` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsBeginInterrupt) |
| `os/close_input` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsCloseInput) |
| `os/end_interrupt` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsEndInterrupt) |
| `os/env?` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsEnvOpt) |
| `os/exec` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsExec) |
| `os/exec_async` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsExecAsync) |
| `os/exec_stdio` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsExecStdio) |
| `os/exec_stdio_async` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsExecStdioAsync) |
| `os/exec_stream` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsExecStream) |
| `os/exec_stream_async` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsExecStreamAsync) |
| `os/executable_path` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsExecutablePath) |
| `os/get_env` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsGetEnv) |
| `os/launch_dir` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsLaunchDir) |
| `os/monotonic_ms` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsMonotonicMs) |
| `os/process_id` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsProcessId) |
| `os/read_input` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsReadInput) |
| `os/read_line` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsReadLine) |
| `os/refresh_input` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsRefreshInput) |
| `os/stdin_tty?` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsStdinTty) |
| `os/take_interrupt` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biOsTakeInterrupt) |
| `panic` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biPanic) |
| `parse_int` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biParseInt) |
| `postgres/open` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biPostgresOpen) |
| `present?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biIsPresent) |
| `print` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biPrint) |
| `println` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biPrintln) |
| `props` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biProps), `src/gene/vm.nim` (biProps) |
| `range` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRange) |
| `read_all` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biReadAll) |
| `read_one` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biReadOne) |
| `regex/find_all` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRegexFindAll) |
| `regex/match` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRegexMatch) |
| `regex/replace` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRegexReplace) |
| `regex/replace_all` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRegexReplaceAll) |
| `regex/split` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRegexSplit) |
| `repl/close` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biReplClose) |
| `repl/discard_pending` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biReplDiscardPending) |
| `repl/eval_guard_begin` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biReplEvalGuardBegin) |
| `repl/eval_guard_end` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biReplEvalGuardEnd) |
| `repl/eval_source` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biReplEval) |
| `repl/open` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biReplOpen) |
| `repl/run` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biReplRun) |
| `respond_to?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRespondTo) |
| `runtime/bind_call` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRuntimeBindCall) |
| `runtime/bind_shape` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRuntimeBindShape) |
| `runtime/callable?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRuntimeCallable) |
| `runtime/configure_module` | Private host control | Host source/generation management; reject retained application source origins. | test_capability_source_policy | `src/gene/vm.nim` (biRuntimeConfigureModule) |
| `runtime/constructor_signature` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRuntimeConstructorSignature) |
| `runtime/gc_stats` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biRuntimeGcStats) |
| `runtime/guard_call` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRuntimeGuardCall) |
| `runtime/load_sandboxed` | Private host control | Host source/generation management; reject retained application source origins. | test_capability_source_policy | `src/gene/vm.nim` (biRuntimeLoadSandboxed) |
| `runtime/require_root_lane` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRuntimeRequireRootLane) |
| `runtime/sandbox_transaction` | Private host control | Host source/generation management; reject retained application source origins. | test_capability_source_policy | `src/gene/vm.nim` (biRuntimeSandboxTransaction) |
| `runtime/signature` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biRuntimeSignature) |
| `same?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biSame) |
| `serde/data?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biSerdeDataP) |
| `serde/read` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biSerdeRead) |
| `serde/read_data` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biSerdeReadData) |
| `serde/write` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biSerdeWrite) |
| `serde/write_data` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biSerdeWriteData) |
| `set_has?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biSetHas) |
| `set_size` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biSetSize) |
| `size` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biListSize) |
| `sleep` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biSleep) |
| `sqlite/open` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biSqliteOpen) |
| `sqlite/visit_text_rows` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biSqliteVisitTextRows) |
| `store/fs/open` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biStoreFsOpen) |
| `store/sqlite/open` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biStoreSqliteOpen) |
| `str/byte_size` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biStrByteSize) |
| `str/contains?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biStrContains) |
| `str/ends_with?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biStrEndsWith) |
| `str/from_utf8` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biStrFromUtf8) |
| `str/join` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biStrJoin) |
| `str/lower` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biStrLower) |
| `str/slice_bytes` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biStrSliceBytes) |
| `str/split` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biStrSplit) |
| `str/starts_with?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biStrStartsWith) |
| `str/to_utf8` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biStrToUtf8) |
| `str/trim` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biStrTrim) |
| `take` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biTake), `src/gene/vm.nim` (biTake) |
| `terminal/capture_text` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalCaptureText) |
| `terminal/close` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalClose) |
| `terminal/focus` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalFocus) |
| `terminal/key` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalKey) |
| `terminal/mouse` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalMouse) |
| `terminal/next_update` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalNextUpdate) |
| `terminal/open` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalOpen) |
| `terminal/paste` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalPaste) |
| `terminal/pump` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalPump) |
| `terminal/request_stop` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalRequestStop) |
| `terminal/resize` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalResize) |
| `terminal/signal` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalSignal) |
| `terminal/snapshot` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalSnapshot) |
| `terminal/stop` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalStop) |
| `terminal/write` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biTerminalWrite) |
| `test/assert_equal` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/testing.nim` (biAssertEqual) |
| `test/assert_raises` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/testing.nim` (biAssertRaises) |
| `test/register_example` | Guarded | Capture registration authority/source origins; bound callbacks and diagnostics; application reporting rejects. | test_capability_cli; test_testing | `src/gene/testing.nim` (biTestRegisterExample) |
| `test/register_group` | Guarded | Capture registration authority/source origins; bound callbacks and diagnostics; application reporting rejects. | test_capability_cli; test_testing | `src/gene/testing.nim` (biTestRegisterGroup) |
| `test/register_hook` | Guarded | Capture registration authority/source origins; bound callbacks and diagnostics; application reporting rejects. | test_capability_cli; test_testing | `src/gene/testing.nim` (biTestRegisterHook) |
| `test/run` | Guarded | Capture registration authority/source origins; bound callbacks and diagnostics; application reporting rejects. | test_capability_cli; test_testing | `src/gene/testing.nim` (biTestRun) |
| `thaw` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biThaw) |
| `time` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTime) |
| `timezone` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biTimezone) |
| `to_float` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biToFloat) |
| `to_int` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biToInt) |
| `to_pairs_stream` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biToPairsStream), `src/gene/vm.nim` (biToPairsStream) |
| `to_str` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biToStr) |
| `to_stream` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biToStream), `src/gene/vm.nim` (biToStream) |
| `to_sym` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biToSym) |
| `today` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/vm.nim` (biToday) |
| `update_in` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biUpdateIn) |
| `url/decode_component` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biUrlDecodeComponent) |
| `url/encode_component` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biUrlEncodeComponent) |
| `url/format_query` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biUrlFormatQuery) |
| `url/parse_query` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/stdlib.nim` (biUrlParseQuery) |
| `void?` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biIsVoid) |
| `web/asset_base` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biWebAssetBase) |
| `web/load` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biWebLoad) |
| `web/published_routes` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biWebPublishedRoutes) |
| `web/script` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biWebScript) |
| `web/set_asset_base` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biWebSetAssetBase) |
| `web/set_source_maps` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biWebSetSourceMaps) |
| `web/stylesheet` | Unsupported | No admitted operation/adapter contract; reject before native implementation. | test_native_effects | `src/gene/stdlib.nim` (biWebStylesheet) |
| `\|` | Capability-free | In-memory data/computation; called application code keeps its own boundaries. | test_native_effects; existing API suites | `src/gene/vm.nim` (biUnionType) |
