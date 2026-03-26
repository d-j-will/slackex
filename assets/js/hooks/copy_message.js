const CopyMessage = {
  mounted() {
    this.el.addEventListener("click", () => {
      const bubble = this.el.closest("[id^='msg-']");
      const content = bubble?.querySelector("[data-message-content]");
      if (!content) return;

      navigator.clipboard.writeText(content.textContent.trim()).then(() => {
        // Brief checkmark feedback using safe DOM methods
        const icon = this.el.querySelector("span");
        if (!icon) return;
        const origClass = icon.className;
        icon.className = "hero-check size-4";
        setTimeout(() => { icon.className = origClass; }, 1500);
      });
    });
  }
};

export default CopyMessage;
