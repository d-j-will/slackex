// AppearancePanel — reflects the CURRENT Loom preference selection onto the
// panel's `[data-pref]` buttons. The server can't read localStorage, so this
// hook adds `.is-active` to the button whose `data-value` matches the stored
// (or default) value and removes it from its siblings.
//
// Persistence + CSS-var application live in the LoomPrefs hook, which reacts to
// the same `loom:set-pref` window event each control dispatches. This hook only
// mirrors state, re-running on mount, on LiveView patches, and on every
// `loom:set-pref` (so the selection updates live as the user clicks).
//
// Defaults mirror loom_prefs.js: a value equal to its default is cleared from
// storage, so a clean profile reads `null` and must reflect the default button
// (e.g. the #e8c547 swatch and the "Regular" density start active).

const DEFAULTS = {
  density: "regular",
  weave: "subtle",
  "serif-ai": "true",
  accent: "#e8c547",
};

function currentValue(pref) {
  const stored = localStorage.getItem("phx:" + pref);
  return stored || DEFAULTS[pref];
}

function reflect(el) {
  // Group buttons by their data-pref so siblings are scoped per control.
  const buttons = el.querySelectorAll("[data-pref]");
  const wanted = {};
  buttons.forEach((btn) => {
    const pref = btn.dataset.pref;
    if (!(pref in wanted)) wanted[pref] = currentValue(pref);
    const isActive = btn.dataset.value === wanted[pref];
    btn.classList.toggle("is-active", isActive);
  });
}

const AppearancePanel = {
  mounted() {
    this._onSetPref = () => reflect(this.el);
    window.addEventListener("loom:set-pref", this._onSetPref);
    reflect(this.el);
  },
  updated() {
    reflect(this.el);
  },
  destroyed() {
    window.removeEventListener("loom:set-pref", this._onSetPref);
  },
};

export default AppearancePanel;
