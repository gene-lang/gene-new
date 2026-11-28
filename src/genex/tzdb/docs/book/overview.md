# Overview

genex/tzdb is an experimental package carrying compiled IANA 2026d time-zone rules. It never uses the host time-zone database. `resolve_local` maps a local DateTime and zone to `datetime`, `instant`, `offset_seconds`, `zone`, and `tzdb_release`; an ambiguous local time fails unless `^fold "earlier"` or `^fold "later"` selects an instant, and a nonexistent local time always fails. `to_local` maps an instant into a zone. For historical offsets with seconds, the `datetime` field keeps exact local fields and `offset_seconds` preserves the interpretation.
