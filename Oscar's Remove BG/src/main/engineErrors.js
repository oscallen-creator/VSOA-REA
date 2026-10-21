// Engine failures in words a user can act on, and whether they stop the run
// (remove.bg treats an unwritable output folder as fatal; a single bad image
// only marks its own row).

const FATAL_FS_CODES = new Set(["EACCES", "EPERM", "EROFS"]);

/** Error → { code, message, fatal } in words a user can act on. */
export const classifyError = (error) => {
  if (error?.name === "ModelDownloadError") {
    return {
      code: "model_unavailable",
      fatal: true,
      message: `Could not download the background-removal model (${error.message}). Check your internet connection and press Start again.`,
    };
  }
  if (error?.stage === "write" && FATAL_FS_CODES.has(error.code)) {
    return {
      code: "output_dir_not_writable",
      fatal: true,
      message: "Output folder is not writable. Please change output folder.",
    };
  }
  if (error?.stage === "write" && error.code === "ENOSPC") {
    return {
      code: "disk_full",
      fatal: true,
      message: "The disk is full.",
    };
  }
  if (error?.code === "unknown_foreground") {
    return { code: error.code, fatal: false, message: error.message };
  }
  if (/unsupported image format|corrupt|premature end/i.test(error?.message)) {
    return {
      code: "load_image_error",
      fatal: false,
      message: `Could not read this image: ${error.message}`,
    };
  }
  return {
    code: error?.code ?? "process_image_error",
    fatal: false,
    message: error?.message ?? String(error),
  };
};
