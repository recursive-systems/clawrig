import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// QR Code generator
import "../vendor/qr.js"
import HighlightModule from "../vendor/highlight.min.js"

const hljs = HighlightModule?.default || HighlightModule
window.hljs ||= hljs

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
      this.el.innerHTML = window.QR.toSVG(qr, {fg: "#000000", bg: "#ffffff", padding: 1})
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

Hooks.ChatScroll = {
  mounted() {
    this.anchor = document.getElementById("chat-scroll-anchor")
    this.button = document.getElementById("chat-scroll-button")
    this.autoFollow = true
    this.syncButton()
    this.scrollToBottom("auto")

    this.onScroll = () => {
      this.autoFollow = this.isNearBottom()
      this.syncButton()
    }

    this.onJump = () => {
      this.autoFollow = true
      this.syncButton()
      this.scrollToBottom("smooth")
    }

    this.onWheel = (event) => {
      if (event.deltaY < 0) {
        this.autoFollow = false
        this.syncButton()
      }
    }

    this.el.addEventListener("scroll", this.onScroll)
    this.el.addEventListener("wheel", this.onWheel, {passive: true})
    this.button?.addEventListener("click", this.onJump)
  },
  updated() {
    if (this.autoFollow) {
      this.scrollToBottom("auto")
    } else {
      this.syncButton()
    }
  },
  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll)
    this.el.removeEventListener("wheel", this.onWheel)
    this.button?.removeEventListener("click", this.onJump)
  },
  isNearBottom() {
    return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight <= 72
  },
  syncButton() {
    const visible = !this.autoFollow && !this.isNearBottom()
    if (this.anchor) this.anchor.classList.toggle("visible", visible)
  },
  scrollToBottom(behavior) {
    requestAnimationFrame(() => {
      this.el.scrollTo({top: this.el.scrollHeight, behavior})
      this.syncButton()
    })
  }
}

Hooks.ChatComposer = {
  mounted() {
    this.resize()
    this.onInput = () => this.resize()
    this.onKeydown = (event) => {
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault()
        this.el.form?.requestSubmit()
      }
    }

    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("keydown", this.onKeydown)
  },
  updated() {
    this.resize()
  },
  destroyed() {
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("keydown", this.onKeydown)
  },
  resize() {
    this.el.style.height = "auto"
    this.el.style.height = `${Math.min(this.el.scrollHeight, 160)}px`
  }
}

Hooks.HighlightCode = {
  mounted() { this.highlight() },
  updated() { this.highlight() },
  highlight() {
    if (!hljs) return
    this.el.querySelectorAll("pre code").forEach((block) => {
      if (!block.dataset.highlighted) hljs.highlightElement(block)
    })
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
