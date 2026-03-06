const EmojiPicker = {
  mounted() {
    this.pickerContainer = null;

    // Use mousedown instead of click — emoji-mart's Shadow DOM swallows
    // click events, so contains() fails and the picker closes mid-select.
    // Mousedown fires before the picker's internal click handler.
    this.handleDocumentMousedown = (e) => {
      if (!this.pickerContainer) return;

      // Check if click is inside the picker container or its Shadow DOM
      const path = e.composedPath();
      const isInsidePicker = path.some(
        (el) => el === this.pickerContainer || el === this.el,
      );

      if (!isInsidePicker) {
        this.closePicker();
      }
    };

    document.addEventListener("mousedown", this.handleDocumentMousedown);

    this.el.addEventListener("emoji:open", () => {
      const trigger = this.el.querySelector("[data-emoji-trigger]");
      if (trigger) this.openPicker(trigger);
    });
  },

  destroyed() {
    this.closePicker();
    document.removeEventListener("mousedown", this.handleDocumentMousedown);
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

    // Backdrop overlay
    const backdrop = document.createElement("div");
    backdrop.className = "fixed inset-0 z-40 bg-black/30";
    backdrop.addEventListener("mousedown", (e) => {
      e.stopPropagation();
      this.closePicker();
    });

    // Centered container
    const container = document.createElement("div");
    container.className =
      "fixed z-50 top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2";

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
      previewPosition: "bottom",
      skinTonePosition: "search",
      maxFrequentRows: 3,
      perLine: 9,
    });

    container.appendChild(picker);
    document.body.appendChild(backdrop);
    document.body.appendChild(container);
    this.backdrop = backdrop;
    this.pickerContainer = container;
  },

  closePicker() {
    if (this.backdrop) {
      this.backdrop.remove();
      this.backdrop = null;
    }
    if (this.pickerContainer) {
      this.pickerContainer.remove();
      this.pickerContainer = null;
    }
  },
};

export default EmojiPicker;
