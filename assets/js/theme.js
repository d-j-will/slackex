// Theme initialization — runs synchronously before first paint to prevent FOUC.
(() => {
  const setTheme = (theme) => {
    if (theme === "system") {
      localStorage.removeItem("phx:theme");
      document.documentElement.removeAttribute("data-theme");
    } else {
      localStorage.setItem("phx:theme", theme);
      document.documentElement.setAttribute("data-theme", theme);
    }
  };
  if (!document.documentElement.hasAttribute("data-theme")) {
    setTheme(localStorage.getItem("phx:theme") || "system");
  }
  window.addEventListener("storage", (e) => e.key === "phx:theme" && setTheme(e.newValue || "system"));

  window.addEventListener("phx:set-theme", (e) => {
    const theme = e.target.dataset.phxTheme;
    if (theme === "toggle") {
      const current = document.documentElement.getAttribute("data-theme");
      setTheme(current === "dark" ? "light" : "dark");
    } else {
      setTheme(theme);
    }
  });
})();
