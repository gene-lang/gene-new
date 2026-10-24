# Audio codecs

`audio.gene` provides bounded, in-memory s16le PCM/WAV conversion. It does not
open devices, launch engines, or save audio. `wav_encode pcm rate [channels]`
and `wav_decode bytes` preserve PCM exactly; decode returns `{^format ^pcm}`.
Only integer 16-bit PCM, 8–192 kHz, mono/stereo is accepted. RIFF length, chunks,
padding, block alignment and byte rate are validated before use. Unknown RIFF
chunks are skipped. The codec limit is 64 MiB of PCM. `pcm_duration_ms` validates
complete sample frames and returns the duration rounded down.

`worker.gene` provides binary length-framed subprocess I/O through Gene's
fiber-aware pipes. `open_worker command args` starts an owned process;
`read_packet`, `write_packet`, `read_json`, and `write_json` preserve packet
boundaries across short I/O. Reads default to a 64 KiB packet limit.
`close_worker` closes both pipe directions, cancels and joins the process and
its optional JSON dispatcher, and waits for physical I/O cleanup.

`dispatch_json worker message error` owns the sole stdout reader. Start it in
the long-lived service that owns the worker, after a bounded initialization
call returns. A persistent dispatcher started inside that call's structured
scope would keep the initialization invocation alive. The owner must bound and
fence callbacks and close the worker when its service or activation retires.
Stdout is reserved for framed data; SDK diagnostics belong on stderr.
