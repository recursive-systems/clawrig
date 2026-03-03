import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// QR Code generator
import "../vendor/qr.js"

const Hooks = {}

// Auto-run hook: fires a LiveView event once when panel becomes active
Hooks.AutoRun = {
  mounted() {
    this._fired = false
    if (this.el.dataset.run === "true" && this.el.classList.contains("active")) {
      this._fired = true
      this.pushEvent(this.el.dataset.event, {})
    }
  },
  updated() {
    const isActive = this.el.classList.contains("active")
    const shouldRun = this.el.dataset.run === "true"

    if (!isActive) {
      this._fired = false
      return
    }

    if (shouldRun && !this._fired) {
      this._fired = true
      this.pushEvent(this.el.dataset.event, {})
    }
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

// Copy to clipboard hook (works over HTTP via execCommand fallback)
Hooks.CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.text
      if (!text) return
      const done = () => {
        const orig = this.el.textContent
        this.el.textContent = "Copied!"
        setTimeout(() => { this.el.textContent = orig }, 1500)
      }
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(done)
      } else {
        const ta = document.createElement("textarea")
        ta.value = text
        ta.style.position = "fixed"
        ta.style.left = "-9999px"
        document.body.appendChild(ta)
        ta.select()
        document.execCommand("copy")
        document.body.removeChild(ta)
        done()
      }
    })
  }
}

// Page focus hook: triggers immediate poll when user returns to the tab
Hooks.PageFocus = {
  mounted() {
    this._onVisible = () => {
      if (!document.hidden) {
        this.pushEvent("page_visible", {})
      }
    }
    document.addEventListener("visibilitychange", this._onVisible)
  },
  destroyed() {
    document.removeEventListener("visibilitychange", this._onVisible)
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
