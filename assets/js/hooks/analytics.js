const RATE_LIMIT_MS = 60_000;

const Analytics = {
  mounted() {
    if (this.el.dataset.analyticsEnabled !== "true") return;

    this._recentErrors = new Map();

    // JS error tracking
    this._errorHandler = (event) => {
      const key = `${event.message}:${event.filename}:${event.lineno}`;
      if (this._isRateLimited(key)) return;

      this.pushEvent("analytics:js_error", {
        message: event.message || "Unknown error",
        stack: event.error?.stack || "",
        url: event.filename || window.location.href,
        line: event.lineno || 0,
        column: event.colno || 0,
        user_agent: navigator.userAgent,
      });
    };

    this._rejectionHandler = (event) => {
      const message = event.reason?.message || String(event.reason);
      const key = `unhandled_rejection:${message}`;
      if (this._isRateLimited(key)) return;

      this.pushEvent("analytics:js_error", {
        message: message,
        stack: event.reason?.stack || "",
        url: window.location.href,
        line: 0,
        column: 0,
        user_agent: navigator.userAgent,
      });
    };

    window.addEventListener("error", this._errorHandler);
    window.addEventListener("unhandledrejection", this._rejectionHandler);

    // Click tracking (declarative via data-track)
    this._clickHandler = (event) => {
      const tracked = event.target.closest("[data-track]");
      if (!tracked) return;

      this.pushEvent("analytics:click", {
        target: tracked.dataset.track,
        context: tracked.dataset.trackContext || "",
        path: window.location.pathname,
      });
    };

    document.addEventListener("click", this._clickHandler, true);

    // Performance metrics (batched)
    this._perfEntries = [];
    this._perfInterval = setInterval(() => this._flushPerf(), 30_000);

    if (typeof PerformanceObserver !== "undefined") {
      try {
        this._lcpObserver = new PerformanceObserver((list) => {
          const entries = list.getEntries();
          const last = entries[entries.length - 1];
          if (last) {
            this._perfEntries.push({
              metric: "lcp",
              value: Math.round(last.startTime),
              path: window.location.pathname,
            });
          }
        });
        this._lcpObserver.observe({ type: "largest-contentful-paint", buffered: true });

        this._longTaskObserver = new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            this._perfEntries.push({
              metric: "long_task",
              value: Math.round(entry.duration),
              path: window.location.pathname,
            });
          }
        });
        this._longTaskObserver.observe({ type: "longtask", buffered: true });
      } catch (_e) {
        // PerformanceObserver types not supported in this browser
      }
    }
  },

  destroyed() {
    if (this._errorHandler) {
      window.removeEventListener("error", this._errorHandler);
      window.removeEventListener("unhandledrejection", this._rejectionHandler);
    }
    if (this._clickHandler) {
      document.removeEventListener("click", this._clickHandler, true);
    }
    if (this._perfInterval) {
      clearInterval(this._perfInterval);
      this._flushPerf();
    }
    if (this._lcpObserver) this._lcpObserver.disconnect();
    if (this._longTaskObserver) this._longTaskObserver.disconnect();
  },

  _isRateLimited(key) {
    const now = Date.now();
    const lastSeen = this._recentErrors.get(key);
    if (lastSeen && now - lastSeen < RATE_LIMIT_MS) return true;
    this._recentErrors.set(key, now);
    return false;
  },

  _flushPerf() {
    if (this._perfEntries.length === 0) return;
    const batch = this._perfEntries.splice(0);
    for (const entry of batch) {
      this.pushEvent("analytics:performance", entry);
    }
  },
};

export default Analytics;
