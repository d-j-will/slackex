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
