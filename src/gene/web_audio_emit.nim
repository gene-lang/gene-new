# Included only inside the helper emitter; policy remains in Gene callers.
block:
  let voidResult = if typescript: ": void" else: ""
  let handleResult = if typescript: ": EventTarget" else: ""
  let handleParam = if typescript: "handle: EventTarget" else: "handle"
  let handleCast = if typescript: " as $GenePcmHandle" else: ""
  let contextCast = if typescript: " as AudioContext" else: ""
  let pcmCast = if typescript: " as $GenePcmHandle" else: ""
  if typescript:
    emitter.line("type $GenePcmHandle = EventTarget & {closeCapture(): void; finishCapture(done: () => void): void; push(bytes: Uint8Array): void; stop(): void; started: () => void; drained: () => void; queued(): number; played(): number};")
  emitter.line("const $gene_audio_modules = new WeakMap" &
    (if typescript: "<AudioContext, Promise<void>>" else: "") & "();")
  emitter.line("function $gene_audio_module(" & (if typescript: "context: AudioContext" else: "context") & ")" &
    (if typescript: ": Promise<void>" else: "") & " {")
  emitter.line("  let loading = $gene_audio_modules.get(context); if (!loading) { loading = context.audioWorklet.addModule(new URL(" & jsString("./" & audioWorkletFile()) & ", import.meta.url)); $gene_audio_modules.set(context, loading); loading.catch(() => $gene_audio_modules.delete(context)); } return loading;")
  emitter.line("}")
  let captureParams = if typescript:
      "target: EventTarget, rate: number, frameMs: number, frame: (bytes: Uint8Array) => void, level: (value: number) => void, error: (message: string) => void, processing = true"
    else: "target, rate, frameMs, frame, level, error, processing = true"
  emitter.line("function $gene_audio_capture_open(" & captureParams & ")" & handleResult & " {")
  emitter.line("  if (rate !== 16000 || frameMs !== 20) throw new RangeError('Capture requires 16000 Hz, 20 ms mono PCM.');")
  emitter.line("  const context = target" & contextCast & "; const handle = new EventTarget()" & pcmCast & ";")
  emitter.line("  let node" & (if typescript: ": AudioWorkletNode | null" else: "") & " = null; let source" & (if typescript: ": MediaStreamAudioSourceNode | null" else: "") & " = null; let stream" & (if typescript: ": MediaStream | null" else: "") & " = null; let closed = false; let finishing = false; let done = () => {};")
  emitter.line("  const cleanup = () => { closed = true; if (stream) stream.getTracks().forEach(track => track.stop()); source?.disconnect(); node?.disconnect(); if (node) node.port.close(); };")
  emitter.line("  handle.closeCapture = cleanup;")
  emitter.line("  handle.finishCapture = callback => { if (closed) { callback(); return; } finishing = true; done = callback; if (node) node.port.postMessage('finish'); else { cleanup(); done(); } };")
  emitter.line("  void (async () => { try {")
  emitter.line("    stream = await navigator.mediaDevices.getUserMedia({audio: {channelCount: 1, echoCancellation: processing, noiseSuppression: processing, autoGainControl: processing}}); if (closed) { stream.getTracks().forEach(track => track.stop()); return; }")
  emitter.line("    await $gene_audio_module(context); if (closed) { cleanup(); return; }")
  emitter.line("    node = new AudioWorkletNode(context, 'gene-capture', {numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1], processorOptions: {rate, frameMs}});")
  emitter.line("    node.port.onmessage = event => { if (closed) return; const data = event.data; if (data.type === 'frame') frame(new Uint8Array(data.bytes)); else if (data.type === 'level') level(data.value); else if (data.type === 'closed') { cleanup(); done(); } };")
  emitter.line("    node.onprocessorerror = () => { if (!closed) { cleanup(); error('Microphone processor failed.'); } };")
  emitter.line("    source = context.createMediaStreamSource(stream); source.connect(node); node.connect(context.destination); if (finishing) node.port.postMessage('finish');")
  emitter.line("  } catch (failure) { if (!closed) { cleanup(); error(failure instanceof Error ? failure.message : String(failure)); } } })(); return handle;")
  emitter.line("}")
  emitter.line("function $gene_audio_capture_close(" & handleParam & ")" & voidResult & " { (handle" & handleCast & ").closeCapture(); }")
  emitter.line("function $gene_audio_capture_finish(" & (if typescript: "handle: EventTarget, done: () => void" else: "handle, done") & ")" & voidResult & " { (handle" & handleCast & ").finishCapture(done); }")
  let playerParams = if typescript: "target: EventTarget, rate: number, error: (message: string) => void" else: "target, rate, error"
  emitter.line("function $gene_audio_player_open(" & playerParams & ")" & handleResult & " {")
  emitter.line("  if (!Number.isInteger(rate) || rate < 8000 || rate > 192000) throw new RangeError('Invalid PCM playback rate.');")
  emitter.line("  const context = target" & contextCast & "; const handle = new EventTarget()" & pcmCast & "; let closed = false; let sent = 0; let played = 0;")
  emitter.line("  let node" & (if typescript: ": AudioWorkletNode | null" else: "") & " = null; const pending" & (if typescript: ": ArrayBuffer[]" else: "") & " = [];")
  emitter.line("  handle.started = () => {}; handle.drained = () => {}; handle.queued = () => Math.max(0, sent - played) * 500 / rate; handle.played = () => played;")
  emitter.line("  handle.stop = () => { if (closed) return; closed = true; pending.length = 0; if (node) { const stopped = node; stopped.port.postMessage({type: 'stop'}); setTimeout(() => { stopped.disconnect(); stopped.port.close(); }, 15); } };")
  emitter.line("  handle.push = value => { if (closed) return; if (value.byteLength % 2 || sent - played + value.byteLength > rate * 5) { handle.stop(); error('PCM player capacity exceeded or sample truncated.'); return; } const bytes = new Uint8Array(value).buffer; sent += bytes.byteLength; if (node) node.port.postMessage({type: 'push', bytes}, [bytes]); else pending.push(bytes); };")
  emitter.line("  void $gene_audio_module(context).then(() => { if (closed) return; node = new AudioWorkletNode(context, 'gene-player', {numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [1], processorOptions: {rate}});")
  emitter.line("    node.port.onmessage = event => { if (closed) return; const data = event.data; if (typeof data.played === 'number') played = Math.max(played, Math.min(sent, data.played)); if (data.type === 'started') handle.started(); else if (data.type === 'drained') handle.drained(); else if (data.type === 'error') { handle.stop(); error(data.message); } };")
  emitter.line("    node.onprocessorerror = () => { if (!closed) { handle.stop(); error('PCM player processor failed.'); } }; node.connect(context.destination); for (const bytes of pending) node.port.postMessage({type: 'push', bytes}, [bytes]); pending.length = 0;")
  emitter.line("  }).catch(failure => { if (!closed) { handle.stop(); error(failure instanceof Error ? failure.message : String(failure)); } }); return handle;")
  emitter.line("}")
  emitter.line("function $gene_audio_player_push(" & (if typescript: "handle: EventTarget, bytes: Uint8Array" else: "handle, bytes") & ")" & voidResult & " { (handle" & handleCast & ").push(bytes); }")
  emitter.line("function $gene_audio_player_fade_stop(" & handleParam & ")" & voidResult & " { (handle" & handleCast & ").stop(); }")
  for operation in ["start", "drain"]:
    emitter.line("function $gene_audio_player_on_" & operation & "(" & (if typescript: "handle: EventTarget, callback: () => void" else: "handle, callback") & ")" & voidResult & " { (handle" & handleCast & ")." & (if operation == "start": "started" else: "drained") & " = callback; }")
  for operation in ["queued_ms", "played_bytes"]:
    emitter.line("function $gene_audio_player_" & operation & "(" & handleParam & ")" & (if typescript: ": number" else: "") & " { return (handle" & handleCast & ")." & (if operation == "queued_ms": "queued" else: "played") & "(); }")
