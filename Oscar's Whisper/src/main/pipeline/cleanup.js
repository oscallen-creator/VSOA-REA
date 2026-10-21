// Local fallback cleanup, used only when the cleanup model returned nothing (no API key yet,
// or a raw-only result). Wispr leaves real cleanup to its server-side model; these rules are
// this app's own minimal stand-in so pasted text is still readable without one.

const FILLER_WORDS = /\b(?:um+|uh+|erm+|uhm+|hmm+)\b,?\s*/gi;

export const cleanupTranscript = (raw) => {
  let text = String(raw ?? "")
    .replace(FILLER_WORDS, "")
    .replace(/\s+/g, " ")
    .replace(/\s+([,.!?;:])/g, "$1")
    .replace(/\bi\b/g, "I")
    .trim();
  if (text) text = text[0].toUpperCase() + text.slice(1);
  return text;
};
