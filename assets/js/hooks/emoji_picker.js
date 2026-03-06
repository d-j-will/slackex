const EmojiPicker = {
  mounted() {
    this.pickerContainer = null;

    this.handleDocumentClick = (e) => {
      if (
        this.pickerContainer &&
        !this.pickerContainer.contains(e.target) &&
        !e.target.closest("[data-emoji-trigger]")
      ) {
        this.closePicker();
      }
    };

    document.addEventListener("click", this.handleDocumentClick);

    this.el.addEventListener("emoji:open", () => {
      const trigger = this.el.querySelector("[data-emoji-trigger]");
      if (trigger) this.openPicker(trigger);
    });
  },

  destroyed() {
    this.closePicker();
    document.removeEventListener("click", this.handleDocumentClick);
  },

  async openPicker(trigger) {
    if (this.pickerContainer) {
      this.closePicker();
      return;
    }

    const messageId = trigger.dataset.messageId;

    // Dynamic import to avoid loading emoji-mart until needed
    const [{ default: data }, { Picker }] = await Promise.all([
      import("@emoji-mart/data"),
      import("emoji-mart"),
    ]);

    const container = document.createElement("div");
    container.className = "absolute z-50 bottom-full right-0 mb-2";

    const picker = new Picker({
      data,
      onEmojiSelect: (emoji) => {
        this.pushEvent("toggle_reaction", {
          "message-id": messageId,
          emoji: emoji.native,
        });
        this.closePicker();
      },
      theme:
        document.documentElement.getAttribute("data-theme") === "dark"
          ? "dark"
          : "light",
      previewPosition: "none",
      skinTonePosition: "none",
      maxFrequentRows: 2,
    });

    container.appendChild(picker);
    trigger.closest(".relative").appendChild(container);
    this.pickerContainer = container;
  },

  closePicker() {
    if (this.pickerContainer) {
      this.pickerContainer.remove();
      this.pickerContainer = null;
    }
  },
};

export default EmojiPicker;
