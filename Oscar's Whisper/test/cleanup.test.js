import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { cleanupTranscript } from "../src/main/pipeline/cleanup.js";

// Most inputs are what Parakeet actually wrote for speech with natural pauses.
const cases = (rows) => {
  for (const [input, expected] of rows)
    test(JSON.stringify(input), () =>
      assert.equal(cleanupTranscript(input), expected),
    );
};

describe("cleanupTranscript: fillers", () => {
  cases([
    ["um hello world", "Hello world"],
    ["Um I think, uh, we should go.", "I think we should go."],
    ["It was, like, really good, you know.", "It was really good."],
    [
      "So, you know, I was, like, thinking we should go.",
      "So I was thinking we should go.",
    ],
    ["I mean, it's fine.", "It's fine."],
    ["Okay. You know, it's fine.", "Okay. It's fine."],
    ["Um.", ""],
    ["uh", ""],
  ]);
});

describe("cleanupTranscript: real words that look like fillers stay", () => {
  cases([
    ["I like it.", "I like it."],
    ["Do you know what I like about it?", "Do you know what I like about it?"],
    ["It looks like rain.", "It looks like rain."],
    ["What I mean is simple.", "What I mean is simple."],
    ["The umbrella is likely wet.", "The umbrella is likely wet."],
  ]);
});

describe("cleanupTranscript: repeated words", () => {
  cases([
    ["I I think the meeting is is at noon.", "I think the meeting is at noon."],
    ["I want to I want to go home.", "I want to go home."],
    ["The the the end.", "The end."],
    ["She had had enough.", "She had had enough."],
    ["I know that that is true.", "I know that that is true."],
    ["No, no, no.", "No, no, no."],
  ]);
});

describe("cleanupTranscript: spoken commands", () => {
  cases([
    ["Hello period. How are you question mark?", "Hello. How are you?"],
    [
      "First item. New line. Second item. New line. Third item.",
      "First item\nSecond item\nThird item.",
    ],
    [
      "Thanks for the notes period. New paragraph. Best, Oscar.",
      "Thanks for the notes.\n\nBest, Oscar.",
    ],
    [
      "I'll be there at noon period. See you then period.",
      "I'll be there at noon. See you then.",
    ],
    ["Wait comma, really question mark.", "Wait, really?"],
    // Seen in the app: the model also punctuates the pause before a command.
    ["Hello, period. How are you? Question mark.", "Hello. How are you?"],
    ["Wait, comma, really? Question mark?", "Wait, really?"],
    ["Is it done? New line. Yes.", "Is it done?\nYes."],
    ["Send it to me exclamation point.", "Send it to me!"],
    ["first item new line second item", "First item\nSecond item"],
    ["Dear team new line", "Dear team\n"],
    ["New line.", "\n"],
    ["Room 5 period. 6 is next.", "Room 5. 6 is next."],
  ]);
});

describe("cleanupTranscript: 'period' as a word stays", () => {
  cases([
    ["The trial period ended last week.", "The trial period ended last week."],
    [
      "Hello period how are you question mark.",
      "Hello period how are you?",
    ],
  ]);
});
