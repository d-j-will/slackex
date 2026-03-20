const LONG_PRESS_MS = 500;

const LongPress = {
  mounted() {
    this.timer = null;
    this.isOpen = false;
    this.triggered = false;

    // Prevent native context menu on long-press
    this.el.addEventListener("contextmenu", (e) => {
      if (this.triggered) {
        e.preventDefault();
        e.stopPropagation();
      }
    });

    this.el.addEventListener("touchstart", (e) => {
      this.triggered = false;
      this.startY = e.touches[0].clientY;

      this.timer = setTimeout(() => {
        this.triggered = true;
        // Prevent text selection
        window.getSelection().removeAllRanges();
        this.show();
      }, LONG_PRESS_MS);
    }, { passive: true });

    this.el.addEventListener("touchend", (e) => {
      this.cancelTimer();
      // If long-press just triggered, prevent the tap from doing anything else
      if (this.triggered) {
        e.preventDefault();
        this.triggered = false;
      }
    });

    this.el.addEventListener("touchmove", (e) => {
      // Cancel if finger moves more than 10px (scrolling)
      if (this.timer && e.touches[0]) {
        const dy = Math.abs(e.touches[0].clientY - this.startY);
        if (dy > 10) this.cancelTimer();
      }
    }, { passive: true });

    // Dismiss when tapping outside
    this.dismissHandler = (e) => {
      if (this.isOpen && !this.el.contains(e.target)) {
        this.hide();
      }
    };
    document.addEventListener("touchstart", this.dismissHandler, { passive: true });
    document.addEventListener("click", this.dismissHandler);
  },

  destroyed() {
    document.removeEventListener("touchstart", this.dismissHandler);
    document.removeEventListener("click", this.dismissHandler);
  },

  cancelTimer() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  },

  show() {
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
