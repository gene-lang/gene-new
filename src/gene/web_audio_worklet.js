// Reusable Web Audio boundary. No Harness policy or network access lives here.
// The compiler publishes these bytes as a same-origin content-addressed module.
class GeneCapture extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const {rate, frameMs} = options.processorOptions;
    this.width = sampleRate / rate;
    this.capacity = Math.round(rate * frameMs / 1000);
    this.frame = new Int16Array(this.capacity);
    this.count = 0;
    this.area = 0;
    this.weight = 0;
    this.levelFrames = 0;
    this.energy = 0;
    this.energyCount = 0;
    this.closed = false;
    this.port.onmessage = ({data}) => {
      if (data === 'finish' && !this.closed) {
        if (this.weight > 0) this.sample(this.area / this.weight);
        this.flush();
        this.closed = true;
        this.port.postMessage({type: 'closed'});
      }
    };
  }
  sample(value) {
    const clipped = Math.max(-1, Math.min(1, value));
    this.frame[this.count++] = Math.round(clipped * (clipped < 0 ? 32768 : 32767));
    if (this.count === this.capacity) this.flush();
  }
  flush() {
    if (!this.count) return;
    // Explicit little endian, independent of the device's native byte order.
    const bytes = new ArrayBuffer(this.count * 2);
    const view = new DataView(bytes);
    for (let i = 0; i < this.count; i++) view.setInt16(i * 2, this.frame[i], true);
    this.port.postMessage({type: 'frame', bytes}, [bytes]);
    this.count = 0;
  }
  process(inputs) {
    if (this.closed) return false;
    const channels = inputs[0];
    if (!channels || !channels.length) return true;
    for (let i = 0; i < channels[0].length; i++) {
      let sample = 0;
      for (const channel of channels) sample += channel[i] || 0;
      sample /= channels.length;
      this.energy += sample * sample;
      this.energyCount++;
      // A streaming area resampler preserves fractional position across render
      // quanta. Averaging before decimation attenuates high-frequency aliases.
      let remaining = 1;
      while (remaining > 1e-9) {
        const take = Math.min(remaining, this.width - this.weight);
        this.area += sample * take;
        this.weight += take;
        remaining -= take;
        if (this.weight >= this.width - 1e-9) {
          this.sample(this.area / this.width);
          this.area = 0;
          this.weight = 0;
        }
      }
    }
    this.levelFrames += channels[0].length;
    if (this.levelFrames >= sampleRate / 20) {
      this.port.postMessage({type: 'level', value: Math.sqrt(this.energy / Math.max(1, this.energyCount))});
      this.levelFrames = 0; this.energy = 0; this.energyCount = 0;
    }
    return true;
  }
}

class GenePlayer extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.rate = options.processorOptions.rate;
    this.step = this.rate / sampleRate;
    this.queue = [];
    this.position = 0;
    this.offset = 0;
    this.queued = 0;
    this.played = 0;
    this.frames = 0;
    this.started = false;
    this.wait = Math.round(sampleRate * 0.05);
    this.fade = 0;
    this.closed = false;
    this.port.onmessage = ({data}) => {
      if (data.type === 'stop') {
        this.fade = Math.max(1, Math.round(sampleRate * 0.01));
      } else if (data.type === 'push' && !this.fade && !this.closed) {
        const view = new DataView(data.bytes);
        const count = view.byteLength / 2;
        if (count + this.queued > this.rate * 2.5 || count % 1) {
          this.port.postMessage({type: 'error', message: 'PCM player capacity exceeded.'});
          return;
        }
        const samples = new Float32Array(count);
        for (let i = 0; i < count; i++) samples[i] = view.getInt16(i * 2, true) / 32768;
        if (count) { this.queue.push(samples); this.queued += count; }
      }
    };
  }
  status(type = 'progress') {
    this.port.postMessage({type, played: this.played * 2, queued: this.queued * 1000 / this.rate});
  }
  process(_inputs, outputs) {
    if (this.closed) return false;
    const output = outputs[0][0];
    for (let i = 0; i < output.length; i++) {
      if (!this.queue.length) continue;
      if (this.wait > 0) { this.wait--; continue; }
      if (!this.started) { this.started = true; this.status('started'); }
      const chunk = this.queue[0];
      const index = this.offset;
      const fraction = this.position;
      const next = index + 1 < chunk.length ? chunk[index + 1] : (this.queue[1]?.[0] ?? chunk[index]);
      let value = chunk[index] * (1 - fraction) + next * fraction;
      if (this.fade > 0) {
        value *= this.fade / Math.max(1, Math.round(sampleRate * 0.01));
        if (--this.fade === 0) {
          output[i] = value;
          this.queue = []; this.queued = 0; this.closed = true;
          this.status('stopped'); return false;
        }
      }
      output[i] = value;
      this.position += this.step;
      let remaining = Math.floor(this.position);
      this.position -= remaining;
      while (remaining > 0 && this.queue.length) {
        const consumed = Math.min(remaining, this.queue[0].length - this.offset);
        this.queued -= consumed; this.played += consumed;
        this.offset += consumed; remaining -= consumed;
        if (this.offset === this.queue[0].length) { this.queue.shift(); this.offset = 0; }
      }
      if (!this.queue.length) {
        this.position = 0; this.queued = 0; this.status('drained');
      }
    }
    this.frames += output.length;
    if (this.frames >= sampleRate / 50) { this.frames = 0; this.status(); }
    return true;
  }
}
registerProcessor('gene-capture', GeneCapture);
registerProcessor('gene-player', GenePlayer);
