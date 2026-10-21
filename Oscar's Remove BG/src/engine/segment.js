// Runs a segmentation model and returns an alpha mask at the image's size.
// Pre- and post-processing reproduce rembg's sessions step for step: Lanczos
// resize to the model's square input, divide by the brightest value, normalize
// per channel, min-max scale the first output, truncate to 8 bits, then Lanczos
// resize back.

import sharp from "sharp";

const loadRuntime = async () => (await import("onnxruntime-node")).default;

export const toInputTensor = (rgb, spec) => {
  const plane = spec.inputSize * spec.inputSize;
  let brightest = 0;
  for (const value of rgb) if (value > brightest) brightest = value;
  const divisor = Math.max(brightest, 1e-6);
  const tensor = new Float32Array(3 * plane);
  for (let channel = 0; channel < 3; channel += 1) {
    const mean = spec.mean[channel];
    const std = spec.std[channel];
    const offset = channel * plane;
    for (let i = 0; i < plane; i += 1) {
      tensor[offset + i] = (rgb[i * 3 + channel] / divisor - mean) / std;
    }
  }
  return tensor;
};

export const toMask = (prediction) => {
  let low = Infinity;
  let high = -Infinity;
  for (const value of prediction) {
    if (value < low) low = value;
    if (value > high) high = value;
  }
  const mask = new Uint8Array(prediction.length);
  const range = high - low;
  // A constant prediction carries no subject; rembg's division would give NaN.
  if (!(range > 0)) return mask;
  for (let i = 0; i < prediction.length; i += 1) {
    mask[i] = Math.trunc(((prediction[i] - low) / range) * 255);
  }
  return mask;
};

const resizeRaw = async (data, from, to, channels) => {
  let pipeline = sharp(data, {
    raw: { width: from.width, height: from.height, channels },
  }).resize(to.width, to.height, { fit: "fill", kernel: "lanczos3" });
  // sharp widens a resized 1-channel raw image to sRGB unless told otherwise.
  if (channels === 1) pipeline = pipeline.toColourspace("b-w");
  const { data: out, info } = await pipeline
    .raw()
    .toBuffer({ resolveWithObject: true });
  if (info.channels !== channels) {
    throw new Error(
      `Resize returned ${info.channels} channels, not ${channels}`,
    );
  }
  return out;
};

/**
 * @param {string} modelFile verified .onnx path
 * @param {object} spec entry from MODELS
 */
export const createSegmenter = async (modelFile, spec, { runtime } = {}) => {
  const ort = runtime ?? (await loadRuntime());
  const session = await ort.InferenceSession.create(modelFile, {
    executionProviders: ["cpu"],
    graphOptimizationLevel: "all",
    // ONNX Runtime's arena keeps ~1.7 GB for IS-Net; inside an Electron
    // utility process its growth on the second run crashes the process (exit
    // code 5). Without it memory stays ~0.6 GB at about the same speed.
    enableCpuMemArena: false,
    enableMemPattern: false,
  });
  const square = { width: spec.inputSize, height: spec.inputSize };
  // One run at a time: each run already uses every core.
  let queue = Promise.resolve();

  const run = async ({ data, width, height, channels }) => {
    if (channels !== 3) throw new Error("segment() expects raw RGB pixels");
    const rgb = await resizeRaw(data, { width, height }, square, 3);
    const input = new ort.Tensor("float32", toInputTensor(rgb, spec), [
      1,
      3,
      spec.inputSize,
      spec.inputSize,
    ]);
    // IS-Net has 12 outputs; only the first is the mask.
    const outputs = await session.run({ [session.inputNames[0]]: input }, [
      session.outputNames[0],
    ]);
    const prediction = outputs[session.outputNames[0]].data;
    if (prediction.length < square.width * square.height) {
      throw new Error(`Model ${spec.id} returned an unexpected output shape`);
    }
    const mask = toMask(prediction.subarray(0, square.width * square.height));
    const resized = await resizeRaw(mask, square, { width, height }, 1);
    return new Uint8Array(resized.buffer, resized.byteOffset, width * height);
  };

  return {
    model: spec.id,
    segment: (image) => {
      const result = queue.then(() => run(image));
      queue = result.catch(() => {});
      return result;
    },
    dispose: () => session.release(),
  };
};
