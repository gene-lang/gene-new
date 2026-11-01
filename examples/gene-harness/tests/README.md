# Harness tests

Run commands from `examples/gene-harness` using the repository's Gene binary:

```text
../../bin/gene test tests
../../bin/gene test tests/unit
../../bin/gene test tests/integration
../../bin/gene test tests/integration/channels
../../bin/gene test tests/integration/web/client_contracts_spec.gene
../../bin/gene test tests/integration/storage/state_spec.gene tests/integration/runtime/kernel_recovery_spec.gene
```

Use a spec path or `--name` to select a focused regression. There is no separate
channel-suite runner or manual workspace-storage gate: both are discovered by
`gene test`.

## Organization

- `unit/` contains focused parsing, validation, pure behavior and architecture
  boundary checks.
- `integration/` contains runtime composition, persistence, subprocess, HTTP,
  recovery and compiled-browser checks. Both suites mirror source ownership.
- `support.gene` supplies isolated Applications and temporary workspaces.
  `web_support.gene` supplies HTTP/client helpers.
- `fixtures/` contains child-process entries, captured external data, and
  browser demonstration hosts. Some browser fixtures are for manual inspection;
  a fixture does not run merely because it is present.
- The top-level `.mjs` files exercise emitted browser modules with DOM and
  transport doubles. Some are also used by the repository's compiler tests.
  Gene owns their build and test orchestration; Node provides the external
  JavaScript runtime.

The compiled-client spec builds each browser entry once, runs every browser
fixture in a separate Node process, and checks rendered page identities against
workspace-scoped session storage. These checks do not replace live-browser
acceptance for layout or native browser behavior.

## Isolation and prerequisites

The suite is model-free. Tests use scripted providers, fake credentials and
local peers. Opt-in real-service probes live in `../probes/` and are not part of
the normal suite.

Integration tests require subprocess execution and some require loopback
listeners. Browser checks require Node; native-provider checks may require a C
compiler, `pkg-config` and the relevant native dependencies. The system timezone
adapter check requires an installed timezone database and `zdump -i`; calendar
unit tests use fixed intervals.

`isolated` creates a workspace under the package's ignored `tmp/`, masks ambient
provider credentials, and runs the selected case in an independent Application.
Successful cases remove their workspace; failures retain it and print the path.
Set `GENE_HARNESS_TEST_PROGRESS=1` for per-case progress and elapsed time.

If the default package and artifact stores are not writable, point
`GENE_USER_PACKAGES` and `GENE_ARTIFACT_STORE` at writable temporary directories.
After changing `package.gene`, run `../../bin/gene pkg resolve` to refresh the
lock before testing.

Add behavioral regressions to the owning spec. Keep architecture boundary
checks where they protect public contracts, and remove one-off migration
scanners once their migration is complete.
