// AudioWorklet that slices microphone input into fixed 640-sample chunks (40 ms at 16 kHz).
// Port protocol (same shape as Wispr's recorder): "start" begins capture, "stop" flushes the
// partial chunk and then posts "done". Each chunk is posted with its RMS level for the bar meter.

const CHUNK_SAMPLES = 640;

class ChunkRecorder extends AudioWorkletProcessor {
  constructor() {
    super();
    this.recording = false;
    this.buffer = new Float32Array(CHUNK_SAMPLES);
    this.length = 0;
    this.port.onmessage = ({ data }) => {
      if (data === "start") {
        this.length = 0;
        this.recording = true;
      } else if (data === "stop") {
        this.recording = false;
        this.flush();
        this.port.postMessage("done");
      }
    };
  }

  flush() {
    if (this.length === 0) return;
    const samples = this.buffer.slice(0, this.length);
    let sumSquares = 0;
    for (const sample of samples) sumSquares += sample * sample;
    this.port.postMessage(
      { samples, rms: Math.sqrt(sumSquares / samples.length) },
      [samples.buffer],
    );
    this.length = 0;
  }

  process(inputs) {
    const channel = inputs[0]?.[0];
    if (!this.recording || !channel) return true;
    let offset = 0;
    while (offset < channel.length) {
      const take = Math.min(
        CHUNK_SAMPLES - this.length,
        channel.length - offset,
      );
      this.buffer.set(channel.subarray(offset, offset + take), this.length);
      this.length += take;
      offset += take;
      if (this.length === CHUNK_SAMPLES) this.flush();
    }
    return true;
  }
}

registerProcessor("chunk-recorder", ChunkRecorder);
