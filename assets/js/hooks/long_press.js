const LONG_PRESS_MS = 500;

const LongPress = {
  mounted() {
    this.timer = null;
    this.isOpen = false;

    this.el.addEventListener("touchstart", (e) => {
      this.timer = setTimeout(() => {
        e.preventDefault();
        this.show();
      }, LONG_PRESS_MS);
    }, { passive: true });

    this.el.addEventListener("touchend", () => this.cancelTimer());
    this.el.addEventListener("touchmove", () => this.cancelTimer());

    // Dismiss when tapping outside
    this.dismissHandler = (e) => {
      if (this.isOpen && !this.el.contains(e.target)) {
        this.hide();
      }
    };
    document.addEventListener("touchstart", this.dismissHandler, { passive: true });
  },

  destroyed() {
    document.removeEventListener("touchstart", this.dismissHandler);
  },

  cancelTimer() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  },

  show() {
    // Close any other open action bars first
    document.querySelectorAll("[data-actions-open]").forEach((el) => {
      el.removeAttribute("data-actions-open");
    });
    this.el.setAttribute("data-actions-open", "");
    this.isOpen = true;
  },

  hide() {
    this.el.removeAttribute("data-actions-open");
    this.isOpen = false;
  }
};

export default LongPress;
