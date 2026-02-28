const EditMessage = {
  mounted() {
    this.textarea = this.el;

    // Handle Escape key to cancel editing
    this.textarea.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        this.pushEvent("cancel_edit", {});
      }
    });

    // Focus the textarea and move cursor to the end
    this.textarea.focus();
    this.textarea.selectionStart = this.textarea.value.length;
    this.textarea.selectionEnd = this.textarea.value.length;

    // Attach save handler to the Save button
    const saveButton = this.el
      .closest("div")
      .querySelector("[phx-click='save_edit']");

    if (saveButton) {
      saveButton.addEventListener("click", (e) => {
        e.preventDefault();
        e.stopPropagation();
        const content = this.textarea.value;
        const msgId = saveButton.getAttribute("phx-value-msg-id");
        this.pushEvent("save_edit", { "msg-id": msgId, content: content });
      });
    }
  },
};

export default EditMessage;
