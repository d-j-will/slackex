const MessageList = {
  mounted() {
    this.scrollToBottom();
  },
  updated() {
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
      this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < threshold
    );
  },
};

export default MessageList;
