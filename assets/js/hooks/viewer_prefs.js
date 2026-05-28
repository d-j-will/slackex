// Slice B1: read/write the active viewer slug from localStorage.
// The LiveView is the source of truth at runtime; this hook syncs the browser.
export default {
  mounted() {
    const stored = window.localStorage.getItem("sous:viewer_id");
    this.pushEventTo(this.el, "viewer_pref:loaded", { viewer_id: stored ?? "" });
    this.handleEvent("viewer_pref:save", ({ viewer_id }) => {
      if (viewer_id) {
        window.localStorage.setItem("sous:viewer_id", viewer_id);
      } else {
        window.localStorage.removeItem("sous:viewer_id");
      }
    });
  },
};
