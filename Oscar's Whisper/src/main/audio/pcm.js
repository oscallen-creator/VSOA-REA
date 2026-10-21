// The recorder sends little-endian 16-bit PCM; the speech model takes float samples.

/** @returns {Float32Array} samples in [-1, 1) */
export const pcm16ToFloat32 = (pcm) => {
  const count = Math.floor(pcm.length / 2);
  const samples = new Float32Array(count);
  for (let i = 0; i < count; i++) samples[i] = pcm.readInt16LE(i * 2) / 32768;
  return samples;
};
