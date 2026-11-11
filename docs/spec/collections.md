# Collection views and operations

**Status:** normative and implemented.

Gene has two collection-operation families. The operation name selects the
view; a receiver's type declaration or a `^body` field never changes how an
operation reads it.

- The **list family** reads items: `for`, `size`, `empty?`, `map`, `filter`,
  `filter_map`, `each`, `first`, `last`, `contains?`, `take`, `drop`,
  `reverse`, `to_stream`, `join`, and `into` as a source.
- The **map family** reads entries: `map_for`, `map_size`, `map_empty?`,
  `map_map`, `map_filter`, `map_filter_map`, `map_each`,
  `to_pairs_stream`, and `has_key?`.

## Receiver rules

| Receiver | List family | Map family |
| --- | --- | --- |
| List, Set, Stream, Range, Str | that kind's items, as documented per operation | rejected; use the map-family name only on a Map or node |
| Map (PropMap or HashMap) | rejected; the error names the matching map-family operation | entries |
| node of an `IndexRead` type | logical items: `size` once, then `at` from `0`; `size` and `empty?` call the witness directly | stored props |
| any other node | rejected; use `value/.body` for body items | stored props |
| nil | `for` runs zero times | `map_for` runs zero times |

List-family results such as `map`, `take`, `drop`, and `reverse` are plain
Lists. Map-family results are plain Maps. Both inherit the source's frozen
flag. A node's body is always explicit: `value/.body` or `($body value)`.
Patterns and value/call spread continue to read a node's raw body; they do
not use `IndexRead`.

A type-direct message with the operation's name wins over these defaults.
`for` and `map_for` are syntax forms and do not dispatch. `has_key?` is the one
exception: it always reads stored props, with no user-message dispatch.

## Keyed node operations

`get`, `assoc`, `dissoc`, `has_key?`, `put`, `set`, `push`, and `delete`
address a node as follows:

| Key | Read | Persistent update | In-place update |
| --- | --- | --- | --- |
| Sym/Str | stored prop, or nil | set/remove a stored prop | `put` sets a stored prop |
| Int | body item, or the `IndexRead` witness on an indexed type | body item replaced; indexed types reject `assoc` | `set` follows the Int Path and `IndexWrite`; `push` appends to the body |

`head`, `props`, `body`, and `meta` are ordinary stored-prop names for these
messages when no prop shadows them. They are not anatomy aliases; Paths and
the `$assoc_in` family retain their existing anatomy behavior.

## JSON

`$json/stringify` writes a typed node whose body is empty as an object of its
stored props. A node with body items, a node whose head is not a Type, and a
native-wrapper instance are rejected with a diagnostic naming the data that
would be lost or the invalid representation.
