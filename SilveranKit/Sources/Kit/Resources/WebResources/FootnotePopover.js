import { FootnoteHandler } from "./foliate-js/footnotes.js";
import { debugLog } from "./DebugConfig.js";

/**
 * FootnotePopover - shows a footnote over the page instead of navigating to it.
 *
 * Detection and extraction are foliate's FootnoteHandler: it loads the note's
 * section into a second foliate-view and keeps only the note. That view is
 * mounted in a centered card in the top-level document. Links inside the note
 * become plain text, so nothing in the card can navigate the book.
 *
 * Swift is told when the card opens and closes (FootnotePopover message) so it
 * can pause and resume read-aloud audio.
 */
export class FootnotePopover {
  #handler = new FootnoteHandler();
  #getStyles;
  #getTheme;
  #navigate;
  #el = null;
  #body = null;
  #view = null;
  #href = null;

  constructor({ getStyles, getTheme, navigate }) {
    this.#getStyles = getStyles;
    this.#getTheme = getTheme;
    this.#navigate = navigate;
    this.#handler.addEventListener("before-render", ({ detail }) => this.#mount(detail.view));
    this.#handler.addEventListener("render", ({ detail }) => this.#show(detail));
  }

  get isOpen() {
    return this.#el != null;
  }

  // Called with foliate's cancelable "link" event. Returns true when the link
  // was a note reference and the popover took it over.
  handleLink(book, event) {
    const { a, href } = event.detail ?? {};
    if (!a || !href?.includes("#")) return false;

    let pending;
    try {
      pending = this.#handler.handle(book, event);
    } catch (error) {
      console.warn("[FootnotePopover] Footnote detection failed:", error);
      return false;
    }
    if (!pending) return false;

    debugLog("FoliateManager", "Opening footnote popover for", href);
    this.#open(a, href);
    pending.catch((error) => this.#fail(href, error));
    return true;
  }

  close() {
    if (!this.#el) return false;

    this.#view?.close();
    this.#el.remove();
    this.#el = null;
    this.#body = null;
    this.#view = null;
    this.#href = null;
    window.removeEventListener("keydown", this.#onKeyDown, true);
    window.webkit?.messageHandlers?.FootnotePopover?.postMessage({ open: false });
    return true;
  }

  #onKeyDown = (event) => {
    if (event.key !== "Escape" || !this.isOpen) return;
    event.preventDefault();
    event.stopPropagation();
    this.close();
  };

  #open(a, href) {
    this.close();
    this.#href = href;

    const { backgroundColor, foregroundColor } = this.#getTheme();
    const background = backgroundColor || "Canvas";
    const foreground = foregroundColor || "CanvasText";

    const el = document.createElement("div");
    el.className = "silveran-footnote-backdrop";
    el.style.cssText = [
      "position:fixed",
      "inset:0",
      "z-index:2147483646",
      "display:flex",
      "align-items:center",
      "justify-content:center",
      "padding:16px",
      "background:rgba(0,0,0,0.3)",
    ].join(";");
    el.addEventListener("click", (e) => {
      if (e.target === el) this.close();
    });

    const card = document.createElement("div");
    card.setAttribute("role", "dialog");
    card.setAttribute("aria-modal", "true");
    card.style.cssText = [
      "box-sizing:border-box",
      "width:min(36rem,100%)",
      "padding:12px 20px 18px",
      "border-radius:12px",
      `background:${background}`,
      `color:${foreground}`,
      "border:1px solid rgba(127,127,127,0.3)",
      "box-shadow:0 12px 40px rgba(0,0,0,0.35)",
    ].join(";");

    const label = a.textContent.trim();
    card.setAttribute("aria-label", label ? `Note ${label}` : "Note");

    const head = document.createElement("div");
    head.style.cssText =
      "display:flex;align-items:center;justify-content:space-between;margin-bottom:6px;font:600 13px system-ui,sans-serif;opacity:0.7";
    const title = document.createElement("span");
    title.textContent = label ? `Note ${label}` : "Note";
    const closeButton = document.createElement("button");
    closeButton.type = "button";
    closeButton.textContent = "×";
    closeButton.setAttribute("aria-label", "Close note");
    closeButton.style.cssText =
      "all:unset;cursor:pointer;padding:2px 8px;border-radius:6px;font:20px/1 system-ui,sans-serif;color:inherit";
    closeButton.addEventListener("click", () => this.close());
    head.append(title, closeButton);

    const body = document.createElement("div");
    body.style.cssText = "position:relative";

    card.append(head, body);
    el.append(card);
    document.body.append(el);

    this.#el = el;
    this.#body = body;
    window.addEventListener("keydown", this.#onKeyDown, true);
    closeButton.focus({ preventScroll: true });
    window.webkit?.messageHandlers?.FootnotePopover?.postMessage({ open: true });
  }

  #mount(view) {
    if (!this.#body) return;
    this.#view?.close();
    this.#view = view;

    view.style.cssText = "display:block;width:100%;height:4em";
    view.addEventListener("link", (e) => e.preventDefault());
    view.addEventListener("external-link", (e) => e.preventDefault());
    view.addEventListener("load", ({ detail }) => {
      detail.doc?.addEventListener("keydown", this.#onKeyDown, true);
    });

    const renderer = view.renderer;
    renderer.setAttribute("flow", "scrolled");
    renderer.setAttribute("margin", "0px");
    renderer.setAttribute("gap", "0%");
    renderer.setAttribute("max-column-count", "1");
    renderer.setAttribute("max-inline-size", `${Math.ceil(this.#body.clientWidth) || 576}px`);
    renderer.setStyles?.(this.#getStyles());
    this.#body.replaceChildren(view);
  }

  #show({ view, target }) {
    if (view !== this.#view) return;
    if (!target) {
      this.#fail(this.#href, new Error("note target not found"));
      return;
    }

    const doc = target.ownerDocument;
    for (const link of doc.querySelectorAll("a")) {
      link.replaceWith(...link.childNodes);
    }

    const fit = () => {
      if (view !== this.#view) return;
      const height = doc.documentElement.scrollHeight;
      const max = Math.floor(window.innerHeight * 0.6);
      view.style.height = `${Math.min(height, max)}px`;
    };
    requestAnimationFrame(fit);
    doc.fonts?.ready?.then(fit);
  }

  #fail(href, error) {
    if (href !== this.#href) return;
    console.warn("[FootnotePopover] Could not show footnote, navigating instead:", error);
    this.close();
    this.#navigate(href);
  }
}
