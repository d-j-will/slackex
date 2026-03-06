import { searchShortcodes, replaceShortcodes } from "./emoji_shortcodes";

const Compose = {
  mounted() {
    this.textarea = this.el.querySelector("textarea");
    if (!this.textarea) return;

    this.popover = null;
    this.selectedIndex = 0;
    this.matches = [];

    this.textarea.addEventListener("keydown", (e) => {
      // Handle popover navigation when visible
      if (this.popover) {
        if (e.key === "ArrowDown") {
          e.preventDefault();
          this.selectedIndex = (this.selectedIndex + 1) % this.matches.length;
          this.renderPopover();
          return;
        }
        if (e.key === "ArrowUp") {
          e.preventDefault();
          this.selectedIndex =
            (this.selectedIndex - 1 + this.matches.length) %
            this.matches.length;
          this.renderPopover();
          return;
        }
        if (e.key === "Tab" || e.key === "Enter") {
          e.preventDefault();
          this.acceptMatch(this.matches[this.selectedIndex]);
          return;
        }
        if (e.key === "Escape") {
          e.preventDefault();
          this.closePopover();
          return;
        }
      }

      // Submit on Enter (without shift)
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        // Replace any remaining shortcodes before submitting
        this.textarea.value = replaceShortcodes(this.textarea.value);
        this.el.dispatchEvent(
          new Event("submit", { bubbles: true, cancelable: true }),
        );
      }
    });

    this.textarea.addEventListener("input", () => {
      this.autoResize();
      this.checkForShortcode();
    });

    this.setupTypingDebounce();
  },

  // Find the :shortcode being typed at the cursor position
  checkForShortcode() {
    const pos = this.textarea.selectionStart;
    const text = this.textarea.value.substring(0, pos);

    // Match a colon followed by 1+ lowercase chars at the end of text
    const match = text.match(/:([a-z0-9_]{1,20})$/);

    if (match) {
      const query = match[1];
      this.matches = searchShortcodes(query);

      if (this.matches.length > 0) {
        this.selectedIndex = 0;
        this.colonStart = pos - match[0].length;
        this.showPopover();
        return;
      }
    }

    this.closePopover();
  },

  showPopover() {
    if (!this.popover) {
      this.popover = document.createElement("div");
      this.popover.className =
        "absolute bottom-full left-0 mb-1 bg-base-200 border border-base-300 rounded-lg shadow-lg overflow-hidden z-50 w-64";
      this.textarea.parentElement.style.position = "relative";
      this.textarea.parentElement.appendChild(this.popover);
    }
    this.renderPopover();
  },

  renderPopover() {
    if (!this.popover) return;

    // Clear existing children
    while (this.popover.firstChild) {
      this.popover.removeChild(this.popover.firstChild);
    }

    this.matches.forEach((m, i) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = `flex items-center gap-2 w-full px-3 py-1.5 text-sm text-left hover:bg-base-300 ${i === this.selectedIndex ? "bg-base-300" : ""}`;

      const emojiSpan = document.createElement("span");
      emojiSpan.className = "text-lg";
      emojiSpan.textContent = m.emoji;

      const nameSpan = document.createElement("span");
      nameSpan.className = "text-base-content/70";
      nameSpan.textContent = `:${m.name}:`;

      btn.appendChild(emojiSpan);
      btn.appendChild(nameSpan);

      btn.addEventListener("mousedown", (e) => {
        e.preventDefault();
        this.acceptMatch(m);
      });

      this.popover.appendChild(btn);
    });
  },

  acceptMatch(match) {
    if (!match) return;

    const before = this.textarea.value.substring(0, this.colonStart);
    const after = this.textarea.value.substring(this.textarea.selectionStart);
    this.textarea.value = before + match.emoji + after;

    // Set cursor after the inserted emoji
    const newPos = before.length + match.emoji.length;
    this.textarea.setSelectionRange(newPos, newPos);
    this.textarea.focus();

    this.closePopover();
    this.autoResize();

    // Trigger input event so LiveView picks up the change
    this.textarea.dispatchEvent(new Event("input", { bubbles: true }));
  },

  closePopover() {
    if (this.popover) {
      this.popover.remove();
      this.popover = null;
    }
    this.matches = [];
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
      this.closePopover();
    }
  },

  destroyed() {
    this.closePopover();
  },
};

export default Compose;
