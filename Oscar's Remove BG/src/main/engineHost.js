// Runs in an Electron utility process so decoding, inference and encoding
// never block the window. Receives one job at a time from engineClient.js,
// writes the output file itself (no image bytes cross the process boundary)
// and reports a result or a classified error.

import { createRemover } from "../engine/removeBackground.js";
import { classifyError } from "./engineErrors.js";
import { writeNewFile } from "./writeNew.js";

const MODEL_FOR_QUALITY = { best: "isnet-general-use", fast: "u2netp" };
const modelDir = process.argv[2];
const removers = new Map();

const post = (message) => process.parentPort.postMessage(message);

const removerFor = (quality) => {
  const modelId = MODEL_FOR_QUALITY[quality] ?? MODEL_FOR_QUALITY.best;
  if (!removers.has(modelId)) {
    // Keep one model in memory; the large one needs about half a gigabyte.
    for (const [id, remover] of removers) {
      removers.delete(id);
      remover.dispose().catch(() => {});
    }
    removers.set(
      modelId,
      createRemover({
        modelId,
        modelDir,
        onModelProgress: ({ received, total }) =>
          post({ type: "model-progress", modelId, received, total }),
      }),
    );
  }
  return removers.get(modelId);
};

const runJob = async ({ sourcePath, resultPath, options, quality }) => {
  const result = await removerFor(quality).removeBackground(
    sourcePath,
    options,
  );
  const written = await writeNewFile(resultPath, result.buffer);
  return {
    skipped: !written,
    width: result.width,
    height: result.height,
    format: result.format,
  };
};

process.parentPort.on("message", async ({ data }) => {
  if (data?.type !== "process") return;
  try {
    post({ type: "result", id: data.id, ok: true, ...(await runJob(data)) });
  } catch (error) {
    post({
      type: "result",
      id: data.id,
      ok: false,
      error: classifyError(error),
    });
  }
});

post({ type: "ready" });
