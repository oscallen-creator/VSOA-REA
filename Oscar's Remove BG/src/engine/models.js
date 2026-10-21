// Open-source segmentation models. They are downloaded on first use (see
// modelStore.js) and must match these digests. Input sizes and normalization
// follow rembg's sessions for the same files, so masks match rembg's.

const RELEASES =
  "https://github.com/danielgatis/rembg/releases/download/v0.0.0";
const IMAGENET = Object.freeze({
  mean: Object.freeze([0.485, 0.456, 0.406]),
  std: Object.freeze([0.229, 0.224, 0.225]),
});

const model = (fields) =>
  Object.freeze({ ...fields, url: `${RELEASES}/${fields.id}.onnx` });

export const MODELS = Object.freeze({
  "isnet-general-use": model({
    id: "isnet-general-use",
    label: "IS-Net general use (best quality)",
    sha256: "60920e99c45464f2ba57bee2ad08c919a52bbf852739e96947fbb4358c0d964a",
    bytes: 178648008,
    inputSize: 1024,
    mean: Object.freeze([0.5, 0.5, 0.5]),
    std: Object.freeze([1, 1, 1]),
    license: "Apache-2.0",
    upstream: "https://github.com/xuebinqin/DIS",
  }),
  u2net_human_seg: model({
    id: "u2net_human_seg",
    label: "U²-Net human segmentation (people)",
    sha256: "01eb6a29a5c4d8edb30b56adad9bb3a2a0535338e480724a213e0acfd2d1c73c",
    bytes: 175997641,
    inputSize: 320,
    ...IMAGENET,
    license: "Apache-2.0",
    upstream: "https://github.com/xuebinqin/U-2-Net",
  }),
  u2netp: model({
    id: "u2netp",
    label: "U²-Net small (fast, lower quality)",
    sha256: "309c8469258dda742793dce0ebea8e6dd393174f89934733ecc8b14c76f4ddd8",
    bytes: 4574861,
    inputSize: 320,
    ...IMAGENET,
    license: "Apache-2.0",
    upstream: "https://github.com/xuebinqin/U-2-Net",
  }),
});

export const DEFAULT_MODEL_ID = "isnet-general-use";

export const getModel = (id = DEFAULT_MODEL_ID) => {
  const found = Object.hasOwn(MODELS, id) ? MODELS[id] : undefined;
  if (!found) {
    throw new Error(
      `Unknown model "${id}". Choose one of: ${Object.keys(MODELS).join(", ")}`,
    );
  }
  return found;
};
