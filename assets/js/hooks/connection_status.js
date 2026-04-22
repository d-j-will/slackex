const ConnectionStatus = {
  mounted() {
    this.banner = this.el;
    this.banner.classList.add("hidden");

    this._show = () => this.banner.classList.remove("hidden");
    this._hide = () => this.banner.classList.add("hidden");

    this._onLoadingStart = (e) => {
      if (e.detail.kind === "error") this._show();
    };
    this._onLoadingStop = () => this._hide();
    window.addEventListener("phx:page-loading-start", this._onLoadingStart);
    window.addEventListener("phx:page-loading-stop", this._onLoadingStop);

    // Guard against re-entrant reconnect attempts. visibilitychange and focus
    // often fire in the same event loop tick when a tab regains focus. Without
    // a guard the second event would see readyState=CONNECTING (which
    // isConnected() reports as false), close the in-flight handshake, and
    // start another. _reconnecting is set to true before each attempt and
    // cleared by the socket's onOpen callback once the handshake completes.
    this._reconnecting = false;
    this._reconnectOpenRef = null;

    // Force a reconnect when the tab regains focus or visibility — browsers
    // throttle background tabs and may have closed the socket while we slept.
    this._forceReconnect = () => {
      if (
        document.visibilityState === "visible" &&
        window.liveSocket &&
        !window.liveSocket.isConnected() &&
        !this._reconnecting
      ) {
        this._reconnecting = true;
        const socket = window.liveSocket.socket;
        this._reconnectOpenRef = socket.onOpen(() => {
          this._reconnecting = false;
          socket.off([this._reconnectOpenRef]);
          this._reconnectOpenRef = null;
        });
        window.liveSocket.disconnect();
        window.liveSocket.connect();
      }
    };
    document.addEventListener("visibilitychange", this._forceReconnect);
    window.addEventListener("focus", this._forceReconnect);
  },
  destroyed() {
    window.removeEventListener("phx:page-loading-start", this._onLoadingStart);
    window.removeEventListener("phx:page-loading-stop", this._onLoadingStop);
    document.removeEventListener("visibilitychange", this._forceReconnect);
    window.removeEventListener("focus", this._forceReconnect);
    if (this._reconnectOpenRef !== null && window.liveSocket) {
      window.liveSocket.socket.off([this._reconnectOpenRef]);
      this._reconnectOpenRef = null;
    }
  },
};

export default ConnectionStatus;
