"""Piper SDK boundary only. The Gene host owns policy, pacing and cancellation.

stdin: u32le JSON byte count + JSON {text, rate, speaker_id?}.
stdout: one framed JSON greeting, then per request framed JSON {ok}, framed
PCM chunks, zero length end. All audio stays in memory. One loaded voice.
"""
import json
import struct
import sys

from piper import PiperVoice, SynthesisConfig


def read_exact(count):
    parts = bytearray()
    while len(parts) < count:
        part = sys.stdin.buffer.read(count - len(parts))
        if not part:
            raise EOFError()
        parts.extend(part)
    return bytes(parts)


def packet(value):
    sys.stdout.buffer.write(struct.pack('<I', len(value)))
    sys.stdout.buffer.write(value)
    sys.stdout.buffer.flush()


def control(value):
    packet(json.dumps(value).encode('utf-8'))


def pcm_packets(chunk):
    pcm = chunk.audio_int16_bytes
    for offset in range(0, len(pcm), 32768):
        packet(pcm[offset:offset + 32768])


def main():
    voice = PiperVoice.load(sys.argv[1])
    control({'ok': True, 'rate': voice.config.sample_rate, 'channels': 1, 'encoding': 's16le'})
    while True:
        try:
            count, = struct.unpack('<I', read_exact(4))
        except EOFError:
            return
        if count > 65536:
            raise ValueError('Piper request exceeds 64 KiB')
        request = json.loads(read_exact(count))
        try:
            config = SynthesisConfig(length_scale=1.0 / max(0.5, min(2.0, request.get('rate', 1.0))),
                                     speaker_id=request.get('speaker_id'))
            chunks = iter(voice.synthesize(request['text'], syn_config=config))
            first = next(chunks, None)  # Report an error before entering PCM mode.
        except Exception:
            control({'ok': False, 'message': 'Piper could not synthesize this text. Check the model and speaker.'})
            continue
        control({'ok': True})
        # A failure after the header closes the process/stream. Binary framing
        # must never be polluted by JSON or diagnostics inside PCM.
        for chunk in ([first] if first else []):
            pcm_packets(chunk)
        for chunk in chunks:
            pcm_packets(chunk)
        packet(b'')


if __name__ == '__main__':
    main()
