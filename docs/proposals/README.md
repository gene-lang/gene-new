# Proposals and research

This directory holds future designs and research, not implemented feature
references. Shipped features are indexed in the [documentation guide](../README.md).

| Proposal | Status |
| --- | --- |
| [Application distribution](distribution.md) | Image formats and standalone launcher/distribution design; package resolution and pure-Gene build artifacts are implemented separately. |
| [JIT pipeline](jit-pipeline.md) | Unimplemented execution-tier design. |
| [Bundled libraries](bundled-libraries.md) | Gene-source library packaging and discovery design. |
| [General intelligence research](general_intelligence/architecture.md) | Research hypotheses, pilot evidence, and [evaluation protocols](general_intelligence/protocols/README.md); not a shipped runtime feature. |

Deferred extensions of implemented subsystems remain explicitly marked in their
feature references: [build recipes and native assembly](../package-builds.md),
[hosted package registries/publishing](../packages.md),
[HTTP production hardening](../http-server.md),
[native backend limits](../native-types.md),
[capability design extensions](../capabilities.md), and
[runtime event instrumentation](../events.md).

Move a feature reference out of this directory when implementation lands.
Keep status, evidence, and deferred work explicit. Retired work belongs in
[the archive](../archive/README.md), and dated results in [reports](../reports/README.md).
