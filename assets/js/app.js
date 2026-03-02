import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// QR Code generator
import "../vendor/qr.js"

const Hooks = {}

// Auto-run hook: fires a LiveView event when panel becomes active
Hooks.AutoRun = {
  mounted() {
    if (this.el.dataset.run === "true" && this.el.classList.contains("active")) {
      this.pushEvent(this.el.dataset.event, {})
    }
  },
  updated() {
    if (this.el.dataset.run === "true" && this.el.classList.contains("active")) {
      this.pushEvent(this.el.dataset.event, {})
    }
  }
}

// OAuth popup hook
Hooks.OAuthPopup = {
  openPopup() {
    const url = this.el.dataset.url
    if (url) {
      window.open(url, "openai_oauth", "width=500,height=700,left=200,top=80")
      this.pollInterval = setInterval(() => {
        this.pushEvent("check_oauth", {})
      }, 1500)
    }
  },
  mounted() {
    // Auto-open on mount since the URL is already ready
    this.openPopup()
    this.el.addEventListener("click", (e) => {
      e.preventDefault()
      this.openPopup()
    })
  },
  destroyed() {
    if (this.pollInterval) clearInterval(this.pollInterval)
  }
}

// QR Code hook
Hooks.QRCode = {
  mounted() {
    this.render()
  },
  updated() {
    this.render()
  },
  render() {
    const url = this.el.dataset.url
    if (url && window.QR) {
      const qr = window.QR.generate(url, 0)
      this.el.innerHTML = window.QR.toSVG(qr, {fg: "#ffffff", bg: "transparent", padding: 1})
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
})

liveSocket.connect()
window.liveSocket = liveSocket
