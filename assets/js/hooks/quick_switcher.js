const QuickSwitcher = {
  mounted() {
    this.handleKeydown = (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === "k") {
        e.preventDefault()
        this.pushEvent("toggle_quick_switcher", {})
      }
    }
    document.addEventListener("keydown", this.handleKeydown)
  },
  destroyed() {
    document.removeEventListener("keydown", this.handleKeydown)
  }
}

export default QuickSwitcher
