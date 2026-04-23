const AppBadge = {
  mounted() {
    // Listen for service-worker postMessages so we know a push arrived even
    // if the WebSocket missed it. The LiveView already increments unread
    // counts via the WS path, so we don't pushEvent here — we just keep the
    // OS badge in lockstep with what the server tells us.
    this._onSWMessage = (event) => {
      // Currently a no-op handler — kept so future SW protocol changes have
      // a place to land. The visibility-clear logic below covers the common
      // "user came back to the app" path.
      if (event.data?.type !== "push:received") return;
    };
    if (navigator.serviceWorker) {
      navigator.serviceWorker.addEventListener("message", this._onSWMessage);
    }

    // Clear the OS badge whenever the user actually looks at the app.
    this._clearWhenVisible = () => {
      if (document.visibilityState === "visible" && "clearAppBadge" in navigator) {
        navigator.clearAppBadge().catch(() => {});
      }
    };
    document.addEventListener("visibilitychange", this._clearWhenVisible);
    window.addEventListener("focus", this._clearWhenVisible);
    this._clearWhenVisible();

    // Server is the source of truth — every unread-count change pushes a
    // badge:set event so the OS badge can never drift from assigns.
    this.handleEvent("badge:set", ({ count }) => {
      if (!("setAppBadge" in navigator)) return;
      if (count > 0) {
        navigator.setAppBadge(count).catch(() => {});
      } else {
        navigator.clearAppBadge().catch(() => {});
      }
    });
  },

  destroyed() {
    if (navigator.serviceWorker && this._onSWMessage) {
      navigator.serviceWorker.removeEventListener("message", this._onSWMessage);
    }
    document.removeEventListener("visibilitychange", this._clearWhenVisible);
    window.removeEventListener("focus", this._clearWhenVisible);
  },
};

export default AppBadge;
