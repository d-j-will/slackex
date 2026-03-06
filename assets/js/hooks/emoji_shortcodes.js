// Common emoji shortcodes — maps :name: to native emoji.
// Sorted by frequency of use in chat apps.
const SHORTCODES = {
  thumbsup: "\u{1F44D}",
  thumbsdown: "\u{1F44E}",
  smile: "\u{1F604}",
  laugh: "\u{1F602}",
  joy: "\u{1F602}",
  lol: "\u{1F602}",
  grin: "\u{1F601}",
  wink: "\u{1F609}",
  heart: "\u{2764}\u{FE0F}",
  fire: "\u{1F525}",
  rocket: "\u{1F680}",
  eyes: "\u{1F440}",
  thinking: "\u{1F914}",
  clap: "\u{1F44F}",
  tada: "\u{1F389}",
  pray: "\u{1F64F}",
  wave: "\u{1F44B}",
  ok: "\u{1F44C}",
  muscle: "\u{1F4AA}",
  100: "\u{1F4AF}",
  check: "\u{2705}",
  x: "\u{274C}",
  warning: "\u{26A0}\u{FE0F}",
  bug: "\u{1F41B}",
  bulb: "\u{1F4A1}",
  sparkles: "\u{2728}",
  star: "\u{2B50}",
  sob: "\u{1F62D}",
  cry: "\u{1F622}",
  angry: "\u{1F620}",
  scream: "\u{1F631}",
  skull: "\u{1F480}",
  poop: "\u{1F4A9}",
  ghost: "\u{1F47B}",
  raised_hands: "\u{1F64C}",
  facepalm: "\u{1F926}",
  shrug: "\u{1F937}",
  sunglasses: "\u{1F60E}",
  rolling_eyes: "\u{1F644}",
  confused: "\u{1F615}",
  sleeping: "\u{1F634}",
  party: "\u{1F389}",
  beer: "\u{1F37A}",
  coffee: "\u{2615}",
  pizza: "\u{1F355}",
  plus1: "\u{1F44D}",
  minus1: "\u{1F44E}",
  up: "\u{2B06}\u{FE0F}",
  down: "\u{2B07}\u{FE0F}",
};

// Search shortcodes by prefix (without leading colon)
export function searchShortcodes(query, limit = 8) {
  const q = query.toLowerCase();
  const results = [];

  for (const [name, emoji] of Object.entries(SHORTCODES)) {
    if (name.startsWith(q)) {
      results.push({ name, emoji });
      if (results.length >= limit) break;
    }
  }

  return results;
}

// Replace :shortcode: with native emoji in a string
export function replaceShortcodes(text) {
  return text.replace(/:([a-z0-9_]+):/g, (match, name) => {
    return SHORTCODES[name] || match;
  });
}
