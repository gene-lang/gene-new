# genex/tzdb

This optional Gene package contains compiled IANA 2026d zone rules. It never
uses the host timezone database. Pin it as a normal `genex/tzdb` dependency in
`package.gene` and import its public functions through the chosen package
alias.

```gene
(import [to_local resolve_local] ^from "." ^pkg "tzdb")

(let shown (to_local 2024-07-01T12:00Z "America/New_York"))
(let first (resolve_local ($datetime 2024 11 3 1 30)
  "America/New_York" ^fold "earlier"))
```

Each result is a Map with `datetime`, `instant` (UTC), `offset_seconds`, `zone`,
and `tzdb_release`. An ambiguous local time fails by default; `^fold "earlier"`
or `^fold "later"` selects the earlier/later instant. A nonexistent local time
always fails. For historical offsets containing seconds, `datetime` holds
exact local fields without an offset annotation because Gene's DateTime
currently stores minute-precision offsets. The record's `offset_seconds` and
`instant` preserve the exact interpretation.

The source archive is
`https://data.iana.org/time-zones/releases/tzdata2026d.tar.gz`, SHA-256
`0cb2aa8e333c3dc049badc42a0c61f21987b8cd44e107fa900bad764aacc7767`.
The 597 regular TZif resources were generated with `zic (tzcode) 2022g`,
`zic -b slim -d OUT africa antarctica asia australasia europe northamerica
southamerica etcetera backward`. The upstream LICENSE is included. The package
source tree and lock record the exact compiled files used by an installed app.
