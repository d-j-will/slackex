// A hold row shows two moving numbers: how long the item has been held, and
// how long is left to answer it. LiveView only re-renders on events, and a
// hold sitting untouched for three hours produces none — so a server-rendered
// age freezes at whatever it said when the snapshot arrived.
//
// The server sends absolute times; this formats them and keeps them moving.
// "Overdue" is derived here too, from the deadline that already crossed.
const TICK_MS = 30000;

const AndonClock = {
  mounted() {
    this._start();
  },

  updated() {
    this._start();
  },

  destroyed() {
    this._stop();
  },

  _start() {
    this._stop();
    this._render();
    this._timer = setInterval(() => this._render(), TICK_MS);
  },

  _stop() {
    if (this._timer) clearInterval(this._timer);
    this._timer = null;
  },

  _render() {
    const since = this.el.dataset.since;
    const due = this.el.dataset.due;
    const acked = this.el.dataset.acked;
    const now = Date.now();

    const parts = [];
    if (since) parts.push(`held ${elapsed(now - Date.parse(since))}`);

    if (acked) {
      parts.push(`acked ${clock(acked)}`);
    } else if (due) {
      const remaining = Date.parse(due) - now;
      parts.push(remaining < 0 ? `unacked ⚠ since ${clock(due)}` : `due ${clock(due)}`);
    } else {
      parts.push("no clock");
    }

    this.el.textContent = parts.join(" · ");
  },
};

function elapsed(ms) {
  const seconds = Math.max(Math.floor(ms / 1000), 0);
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86400)}d`;
}

function clock(iso) {
  return new Date(iso).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

export default AndonClock;
