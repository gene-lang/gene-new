# Experimental `gene/temporal`

`$temporal` uses Gene's existing Date, DateTime, and Duration values. Its
calendar and instant operations never consult the host timezone database or
the process `TZ` setting.

| Call | Contract |
| --- | --- |
| `add_days date n` | Add calendar days to a Date in the proleptic Gregorian calendar; the result must remain in years 1..9999. |
| `add datetime duration` | Add elapsed microseconds to a DateTime with an explicit UTC offset. Preserve the fixed offset. Clear a named-zone annotation because that rule may change across the interval; preserve `UTC` only at offset zero. |
| `difference left right` | Return a Duration measuring `left - right` in elapsed microseconds. Both DateTimes need explicit offsets. |
| `to_utc datetime` | Convert an offset DateTime to the same instant with offset zero and name `UTC`. |
| `parse_rfc3339 text` | Parse a complete timestamp with seconds and a `Z` or `±HH:MM` offset. Accept `T`/`Z` in either case and 1..6 fractional digits. Reject unknown offset `-00:00`, unsupported leap seconds, invalid dates, and excess precision. |
| `format_rfc3339 datetime` | Emit a complete timestamp, trimmed microsecond fraction, and `Z` or `±HH:MM`. Require an explicit offset; omit any named-zone annotation. |

The arithmetic range is the existing DateTime range (years 1..9999) and Int64
microsecond Duration range. Overflow and unrepresentable results raise errors.
Offset-free or name-only DateTimes are local wall-clock values and cannot be
used as instants. `add` uses a fixed elapsed Duration, so a caller wanting a
new named-zone interpretation after a transition must resolve the resulting
instant again with `genex/tzdb` once that optional package is available.

The optional [genex/tzdb](tzdb.md) package supplies pinned named-zone
interpretations and fold/gap resolution. Re-resolve after elapsed addition to
apply the zone's rules at the resulting instant.
