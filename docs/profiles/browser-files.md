# Browser-selected files

The web profile provides `$files` for files the user selects, drops, or pastes.
It does not expose arbitrary local filesystem paths.

| Function | Result |
| --- | --- |
| `($files/from_input input)` | List of File handles from a file input EventTarget. |
| `($files/from_event event)` | List of File handles from a drop or clipboard event; empty for ordinary text. |
| `($files/name file)` | Display filename, without a local filesystem path. |
| `($files/mime file)` | Browser-reported MIME type; the receiving server must validate it. |
| `($files/size file)` | Byte length as a Gene Int. |
| `($files/read_base64 file maximum on_read on_error)` | A FileReader EventTarget; callbacks receive base64 or an error message. |
| `($files/cancel reader)` | Abort a pending read. |

`maximum` must be between zero and 64 MiB. Oversized files are rejected before
reading. The callbacks use `(Fn [Str] Void)`; no caller task scope is required.
`on_read` receives only the encoded bytes, not a data URL. File input, clipboard,
and drop handles can all use the same reader.

```gene
(mod upload_example ^profile web)
(fn main [root : EventTarget] : Void
  (var input ($dom/element "upload"))
  ($dom/add_event_listener input "change" (fn [event : Any] : Void
    (for file in ($files/from_input input)
      ($files/read_base64 file 10485760
        (fn [data : Str] : Void ($console/log "File ready for upload"))
        (fn [message : Str] : Void ($console/error message)))))))
```

For drop targets, prevent the browser's default navigation on `dragover` and
`drop`. For paste, prevent the default only if `files/from_event` returns files,
so ordinary text paste remains usable. Treat all uploaded contents as data;
never execute them merely because a file was selected.
