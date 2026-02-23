const Compose = {
  mounted() {
    this.textarea = this.el.querySelector("textarea");
    if (!this.textarea) return;

    this.textarea.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        this.el.dispatchEvent(
          new Event("submit", { bubbles: true, cancelable: true })
        );
      }
    });

    this.textarea.addEventListener("input", () => this.autoResize());
    this.setupTypingDebounce();
  },

  autoResize() {
    this.textarea.style.height = "auto";
    this.textarea.style.height =
      Math.min(this.textarea.scrollHeight, 200) + "px";
  },

  setupTypingDebounce() {
    let timeout;
    this.textarea.addEventListener("input", () => {
      if (!timeout) {
        this.pushEvent("typing", {});
      }
      clearTimeout(timeout);
      timeout = setTimeout(() => {
        timeout = null;
      }, 2000);
    });
  },

  updated() {
    if (this.textarea && this.textarea.value === "") {
      this.textarea.style.height = "auto";
    }
  },
};

export default Compose;
