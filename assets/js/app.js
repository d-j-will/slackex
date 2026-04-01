// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import MessageList from "./hooks/message_list"
import Compose from "./hooks/compose"
import EditMessage from "./hooks/edit_message"
import EmojiPicker from "./hooks/emoji_picker"
import QuickSwitcher from "./hooks/quick_switcher"
import LongPress from "./hooks/long_press"
import CopyMessage from "./hooks/copy_message"
import Analytics from "./hooks/analytics"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {MessageList, Compose, EditMessage, EmojiPicker, QuickSwitcher, LongPress, CopyMessage, Analytics},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())
window.addEventListener("phx:copy", (event) => {
  const text = event.detail.text
  if (text) navigator.clipboard.writeText(text)
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

// PWA service worker registration
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/service-worker.js')
    .then(() => console.debug('Service Worker registered'))
    .catch(err => console.warn('Service Worker registration failed:', err));
}

// PWA install prompt — capture the event and show an install banner
let deferredPrompt = null;

window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault();
  deferredPrompt = e;
  if (!sessionStorage.getItem('pwa-dismissed')) showInstallBanner();
});

function showInstallBanner() {
  if (document.getElementById('pwa-install-banner')) return;

  const banner = document.createElement('div');
  banner.id = 'pwa-install-banner';
  Object.assign(banner.style, {
    position: 'fixed', bottom: '0', left: '0', right: '0', zIndex: '9999',
    padding: '12px 16px', display: 'flex', alignItems: 'center',
    justifyContent: 'space-between', gap: '12px', fontFamily: 'system-ui, sans-serif',
    fontSize: '14px', background: 'var(--color-primary)', color: 'var(--color-primary-content)'
  });

  const text = document.createElement('span');
  const strong = document.createElement('strong');
  strong.textContent = 'Tenun';
  text.appendChild(strong);
  text.appendChild(document.createTextNode(' — Install for a native app experience'));

  const btnGroup = document.createElement('div');
  btnGroup.style.display = 'flex';
  btnGroup.style.gap = '8px';

  const installBtn = document.createElement('button');
  installBtn.textContent = 'Install';
  Object.assign(installBtn.style, {
    padding: '6px 16px', borderRadius: '6px', border: 'none',
    background: 'white', color: 'var(--color-primary)', fontWeight: '600', cursor: 'pointer'
  });

  const dismissBtn = document.createElement('button');
  dismissBtn.textContent = 'Later';
  Object.assign(dismissBtn.style, {
    padding: '6px 12px', borderRadius: '6px', border: '1px solid currentColor',
    background: 'transparent', color: 'inherit', cursor: 'pointer'
  });

  installBtn.addEventListener('click', async () => {
    if (deferredPrompt) {
      deferredPrompt.prompt();
      const { outcome } = await deferredPrompt.userChoice;
      console.debug('PWA install:', outcome);
      deferredPrompt = null;
    }
    banner.remove();
  });

  dismissBtn.addEventListener('click', () => {
    banner.remove();
    sessionStorage.setItem('pwa-dismissed', '1');
  });

  btnGroup.appendChild(installBtn);
  btnGroup.appendChild(dismissBtn);
  banner.appendChild(text);
  banner.appendChild(btnGroup);
  document.body.appendChild(banner);
}

window.addEventListener('appinstalled', () => {
  console.debug('PWA installed');
  const banner = document.getElementById('pwa-install-banner');
  if (banner) banner.remove();
});

