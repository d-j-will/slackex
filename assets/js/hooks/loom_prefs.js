// LoomPrefs — applies user "Appearance" preferences as --loom-* override CSS
// variables on <html>. loom.css reads these via var(--loom-x, default), so with
// no prefs set every override is absent and the Loom theme renders unchanged.
//
// Mirrors assets/js/theme.js conventions: localStorage-backed, applied on mount,
// updated via a window CustomEvent ("loom:set-pref"). Vars live on
// document.documentElement (an ancestor of every .loom scope) so they cascade
// into #chat-container, the modal wrapper, and the chat <main> uniformly.

const root = () => document.documentElement;

// Density presets. "regular" sets no vars and removes the data-loom-density attr,
// so the density CSS rules don't match and the message rows keep their default
// Tailwind py-1/py-0.5 padding and text-sm sizing.
const DENSITY = {
  compact: {"--loom-msg-py": "0.25rem", "--loom-msg-fs": "0.8125rem", "--loom-msg-lh": "1.45"},
  regular: null,
  comfy: {"--loom-msg-py": "0.75rem", "--loom-msg-fs": "0.9375rem", "--loom-msg-lh": "1.65"},
};

const isHex = (v) => typeof v === "string" && /^#[0-9a-fA-F]{6}$/.test(v);

function applyDensity(value) {
  const s = root().style;
  ["--loom-msg-py", "--loom-msg-fs", "--loom-msg-lh"].forEach((p) => s.removeProperty(p));
  const preset = DENSITY[value];
  if (preset) {
    Object.entries(preset).forEach(([p, val]) => s.setProperty(p, val));
    // The density CSS rules are gated on this attribute (see loom.css).
    root().dataset.loomDensity = value;
  } else {
    delete root().dataset.loomDensity;
  }
}

function applyWeave(value) {
  const s = root().style;
  // off -> opacity 0; pronounced -> data attr drives a denser gradient; subtle -> default.
  if (value === "off") {
    s.setProperty("--loom-weave-opacity", "0");
  } else {
    s.removeProperty("--loom-weave-opacity");
  }
  if (value === "pronounced") {
    root().dataset.loomWeave = "pronounced";
  } else {
    delete root().dataset.loomWeave;
  }
}

function applySerifAi(value) {
  const s = root().style;
  // "false" -> swap AI labels/titles to sans + upright; "true"/unset -> default serif italic.
  if (value === "false") {
    s.setProperty("--loom-ai-font", "var(--ff-sans)");
    s.setProperty("--loom-ai-style", "normal");
  } else {
    s.removeProperty("--loom-ai-font");
    s.removeProperty("--loom-ai-style");
  }
}

function applyAccent(value) {
  const s = root().style;
  if (isHex(value)) {
    // 8-digit hex alpha: 59 ~= 35% (soft), 14 ~= 8% (wash) — matches the gold defaults.
    s.setProperty("--loom-accent", value);
    s.setProperty("--loom-accent-soft", `${value}59`);
    s.setProperty("--loom-accent-wash", `${value}14`);
  } else {
    s.removeProperty("--loom-accent");
    s.removeProperty("--loom-accent-soft");
    s.removeProperty("--loom-accent-wash");
  }
}

function applyPrefs() {
  applyDensity(localStorage.getItem("phx:density") || "regular");
  applyWeave(localStorage.getItem("phx:weave") || "subtle");
  applySerifAi(localStorage.getItem("phx:serif-ai"));
  applyAccent(localStorage.getItem("phx:accent"));
}

// A pref value that means "default" — clear from storage rather than persist.
const DEFAULTS = {density: "regular", weave: "subtle", "serif-ai": "true", accent: ""};

function setPref(key, value) {
  const storageKey = "phx:" + key;
  if (value == null || value === "" || value === DEFAULTS[key]) {
    localStorage.removeItem(storageKey);
  } else {
    localStorage.setItem(storageKey, value);
  }
  applyPrefs();
}

const onSetPref = (e) => {
  const {key, value} = e.detail || {};
  if (key) setPref(key, value);
};

const LoomPrefs = {
  mounted() {
    // Re-apply on mount so a full page load restores prefs.
    applyPrefs();
    window.addEventListener("loom:set-pref", onSetPref);
  },
  destroyed() {
    window.removeEventListener("loom:set-pref", onSetPref);
  },
};

export default LoomPrefs;
