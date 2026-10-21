// Hidden recorder window: owns the microphone, the 16 kHz AudioContext and the chunking worklet.
// Chunks are converted to 16-bit PCM before they leave the renderer.

const SAMPLE_RATE = 16_000;
const bridge = window.recorderBridge;
let session = null;

/** Float32 [-1, 1] -> little-endian Int16 PCM bytes. */
const toPcm16 = (samples) => {
  const pcm = new Int16Array(samples.length);
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    pcm[i] = s < 0 ? Math.round(s * 32768) : Math.round(s * 32767);
  }
  return new Uint8Array(pcm.buffer);
};

const start = async () => {
  if (session) return bridge.started();
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: {
      echoCancellation: false,
      noiseSuppression: false,
      autoGainControl: false,
      sampleRate: SAMPLE_RATE,
      channelCount: 1,
    },
  });
  const context = new AudioContext({
    sampleRate: SAMPLE_RATE,
    latencyHint: "interactive",
  });
  await context.audioWorklet.addModule("./recorderWorklet.js");
  const source = context.createMediaStreamSource(stream);
  const node = new AudioWorkletNode(context, "chunk-recorder", {
    numberOfInputs: 1,
    numberOfOutputs: 1,
  });
  source.connect(node);
  node.connect(context.destination);
  session = { stream, context, source, node, done: null };
  node.port.onmessage = ({ data }) => {
    if (data === "done") return session?.done?.();
    bridge.chunk(toPcm16(data.samples));
    bridge.level(data.rms);
  };
  node.port.postMessage("start");
  if (context.state === "suspended") await context.resume();
  bridge.started();
};

const teardown = async () => {
  const current = session;
  session = null;
  if (!current) return;
  current.source.disconnect();
  current.node.disconnect();
  for (const track of current.stream.getTracks()) track.stop();
  await current.context.close();
};

const stop = async () => {
  if (!session) return bridge.done();
  const flushed = new Promise((resolve) => {
    session.done = resolve;
    setTimeout(resolve, 500);
  });
  session.node.port.postMessage("stop");
  await flushed;
  await teardown();
  bridge.done();
};

bridge.onCommand(async (command) => {
  try {
    if (command === "start") await start();
    else if (command === "stop") await stop();
    else if (command === "cancel") await teardown();
  } catch (error) {
    await teardown().catch(() => {});
    bridge.error(
      error instanceof Error
        ? `${error.name}: ${error.message}`
        : String(error),
    );
  }
});
