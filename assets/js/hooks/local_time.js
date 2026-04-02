const LocalTime = {
  mounted() {
    this._format();
  },

  updated() {
    this._format();
  },

  _format() {
    const dt = this.el.getAttribute("datetime");
    if (!dt) return;

    const date = new Date(dt);
    this.el.textContent = date.toLocaleTimeString([], {
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    });
  },
};

export default LocalTime;
