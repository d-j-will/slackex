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

    // Force a reconnect when the tab regains focus or visibility — browsers
    // throttle background tabs and may have closed the socket while we slept.
    this._forceReconnect = () => {
      if (
        document.visibilityState === "visible" &&
        window.liveSocket &&
        !window.liveSocket.isConnected()
      ) {
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
  },
};

export default ConnectionStatus;
