const MessageList = {
  mounted() {
    this.scrollToBottom();
    this.pending = false;

    this.el.addEventListener("scroll", () => {
      if (this.el.scrollTop < 100 && !this.pending) {
        this.pending = true;
        this.pushEvent("load_more", {});
      }
    });

    this.handleEvent("scroll_to_message", ({ id }) => {
      requestAnimationFrame(() => {
        const el = document.getElementById(id);
        if (el) {
          el.scrollIntoView({ behavior: "smooth", block: "center" });
          el.classList.add("highlight-flash");
          el.addEventListener(
            "animationend",
            () => {
              el.classList.remove("highlight-flash");
            },
            { once: true },
          );
        }
      });
    });
  },

  updated() {
    this.pending = false;

    if (this.isAtBottom()) {
      this.scrollToBottom();
    }
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },

  isAtBottom() {
    const threshold = 100;
    return (
      this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight <
      threshold
    );
  },
};

export default MessageList;
