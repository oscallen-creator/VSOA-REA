// Light local tidy-up of the transcript. Parakeet already punctuates and capitalizes; these
// rules drop the filler words it sometimes keeps and normalize spacing. Wispr does its real
// cleanup with a server-side language model, which this app deliberately does not use.

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
