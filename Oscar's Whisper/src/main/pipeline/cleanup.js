// Light local tidy-up of the transcript. Parakeet already punctuates and capitalizes; these
// rules drop filler words and stutters, turn spoken commands ("new line", "period") into
// text, and normalize spacing. Wispr does its real cleanup with a server-side language
// model, which this app deliberately does not use.
//
// The rules lean on how Parakeet writes natural speech: it sets fillers off with commas
// ("It was, like, really good") and punctuates the pause around a command ("Hello period. How").

const FILLER_SOUNDS = String.raw`um+|uh+|erm+|uhm+|hmm+`;
// "like", "you know" and "I mean" are also real words ("I like it", "do you know"), so they
// only count as filler where the model set them off with commas.
const FILLER = String.raw`(?:${FILLER_SOUNDS}|like|you know|I mean)`;
const FILLER_BETWEEN_COMMAS = new RegExp(String.raw`(?:, ?${FILLER})+,`, "gi");
const FILLER_OPENING_SENTENCE = new RegExp(
  String.raw`(^|[.!?] )(?:${FILLER}, ?)+(\S)`,
  "gi",
);
const FILLER_CLOSING_SENTENCE = new RegExp(
  String.raw`(?:, ?${FILLER})+(?=[.!?]|$)`,
  "gi",
);
const BARE_FILLER_SOUND = new RegExp(String.raw`\b(?:${FILLER_SOUNDS})\b,? ?`, "gi");

const removeFillers = (text) =>
  text
    .replace(FILLER_BETWEEN_COMMAS, "")
    .replace(
      FILLER_OPENING_SENTENCE,
      (_, start, next) => start + next.toUpperCase(),
    )
    .replace(FILLER_CLOSING_SENTENCE, "")
    .replace(BARE_FILLER_SOUND, "");

/** Spoken commands and what they insert. Line breaks go first, so "period" can see one after it. */
const COMMANDS = [
  ["new paragraph", "\n\n"],
  ["(?:new line|line break)", "\n"],
  ["question mark", "?"],
  ["exclamation (?:point|mark)", "!"],
  ["comma", ","],
  // ponytail: "period" is also a noun ("the trial period ended"), so it counts only where the
  // model heard a pause after it, or at the very end. A spoken "period" run straight into the
  // next word stays a word; a sentence that really ends in the noun loses it.
  [String.raw`(?:period|full stop)(?=[.,?!\n]|$)`, "."],
];

const applyCommand = (text, [spoken, symbol]) => {
  const lineBreak = symbol.startsWith("\n");
  // Drop the punctuation the model put around the command ("Hello, period." and "How are
  // you? Question mark."). A line break keeps a "?" or "!" before it, and drops a "." because
  // "First item. New line. Second item" is a list, not sentences.
  const before = lineBreak ? "[.,]?" : "[.,?!]?";
  const pattern = new RegExp(
    String.raw`${before} *\b${spoken}\b[.,?!]? *(\S?)`,
    "giu",
  );
  return text.replace(pattern, (_, next) => {
    if (!next) return symbol;
    const spacing = lineBreak ? "" : " ";
    return symbol + spacing + (symbol === "," ? next : next.toUpperCase());
  });
};

// Stutters and false starts: "the the meeting", "I want to I want to go". "had had" and
// "that that" are grammatical, so they stay.
const WORD = String.raw`[\p{L}\p{N}']+`;
const REPEATED = new RegExp(
  String.raw`(?<![\p{L}\p{N}'])(${WORD}(?: ${WORD}){0,2})(?: \1)+(?![\p{L}\p{N}'])`,
  "giu",
);
const KEEP_DOUBLED = new Set(["had", "that"]);

export const cleanupTranscript = (raw) => {
  const words = removeFillers(String(raw ?? "").replace(/\s+/g, " "));
  let text = COMMANDS.reduce(applyCommand, words)
    .replace(REPEATED, (match, phrase) =>
      KEEP_DOUBLED.has(phrase.toLowerCase()) ? match : phrase,
    )
    .replace(/ +/g, " ")
    .replace(/ ?\n ?/g, "\n")
    .replace(/ ([,.!?;:])/g, "$1")
    .replace(/\bi\b/g, "I")
    .replace(/^ | $/g, "");
  // Filler-only speech comes back as a lone "." from the model.
  if (!/[\p{L}\p{N}\n]/u.test(text)) return "";
  if (text) text = text[0].toUpperCase() + text.slice(1);
  return text;
};
