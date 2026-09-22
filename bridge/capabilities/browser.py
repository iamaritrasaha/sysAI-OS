"""
SysAI OS Browser Capability
============================
A controlled, read-mostly browser layer. This is deliberately NOT a headless
rendering browser (no Chromium/Playwright dependency in the bridge process):
it fetches pages over HTTP and extracts title/text/links with the stdlib
`html.parser`. That is an honest, documented limitation — `browser.capture`
persists an HTML/text snapshot, not a pixel screenshot.

Every function here is a pure(ish) capability handler: `(params, context) ->
result dict`, matching the same shape as `capabilities/registry.py` filesystem
and shell handlers, so it plugs into the same Capability Registry / Policy
Engine path. Nothing here executes outside that path.
"""
from __future__ import annotations

import os
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path
import threading
from typing import Any, Dict, List, Optional

class CancelledError(Exception): pass

# Some sites (including DuckDuckGo's lite search endpoint) serve a
# degraded/blocked response to non-browser User-Agents. A realistic UA is
# used here purely to fetch publicly served HTML reliably — this capability
# never authenticates, submits forms, or does anything a normal reader
# request page wouldn't.
_USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
_ACCEPT_HEADERS = {
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}
_MAX_BYTES = 2_000_000  # Refuse to buffer more than ~2MB of a page in memory.
_FETCH_TIMEOUT = 10
_MAX_TEXT_CHARS = 20_000  # What we keep in memory / hand back to the caller.
_MAX_LINKS = 40

# Content-Types this capability can meaningfully extract text from. Anything
# else (images, PDFs, video, generic binary, ...) gets an honest
# "not_text_renderable" failure instead of a silent empty-text "success" —
# there is no HTML parser here that could have extracted anything from it.
_TEXT_RENDERABLE_CONTENT_TYPES = ("text/html", "application/xhtml+xml", "text/plain", "application/xml", "text/xml")

# Below this many non-whitespace characters of extracted body text, a 200
# OK HTML response is treated as suspicious rather than silently reported
# as ordinary success — the common signature of a JS-rendered single-page
# app with no server-rendered content for this fetch-only capability to see.
_SUSPICIOUSLY_EMPTY_TEXT_CHARS = 40


def _session_id_for(context: Dict[str, Any]) -> str:
    """One browser session per Run — a reasonable Phase 3 simplification.
    A Run that browses multiple distinct topics still shares one session;
    splitting sessions further is not justified yet."""
    run_id = context.get("run_id") or "standalone"
    return f"browser-{run_id}"


class _PageTextExtractor(HTMLParser):
    """Minimal HTML -> (title, visible text, links) extractor. No JS
    execution, no CSS layout — good enough to let SysAI read a page's
    substance without a rendering engine."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.title_parts: List[str] = []
        self.text_parts: List[str] = []
        self.links: List[Dict[str, str]] = []
        self._in_title = False
        self._skip_depth = 0  # inside <script>/<style>/<noscript>
        self._current_href: Optional[str] = None
        self._current_link_text: List[str] = []

    def handle_starttag(self, tag: str, attrs: list) -> None:
        attr_dict = dict(attrs)
        if tag in ("script", "style", "noscript"):
            self._skip_depth += 1
        elif tag == "title":
            self._in_title = True
        elif tag == "a" and attr_dict.get("href"):
            self._current_href = attr_dict["href"]
            self._current_link_text = []

    def handle_endtag(self, tag: str) -> None:
        if tag in ("script", "style", "noscript") and self._skip_depth > 0:
            self._skip_depth -= 1
        elif tag == "title":
            self._in_title = False
        elif tag == "a" and self._current_href is not None:
            text = " ".join("".join(self._current_link_text).split())
            if text and len(self.links) < _MAX_LINKS:
                self.links.append({"href": self._current_href, "text": text[:200]})
            self._current_href = None
            self._current_link_text = []

    def handle_data(self, data: str) -> None:
        if self._skip_depth > 0:
            return
        if self._in_title:
            self.title_parts.append(data)
        elif self._current_href is not None:
            self._current_link_text.append(data)
        else:
            stripped = data.strip()
            if stripped:
                self.text_parts.append(stripped)

    @property
    def title(self) -> str:
        return " ".join("".join(self.title_parts).split())[:200]

    @property
    def text(self) -> str:
        return "\n".join(self.text_parts)[:_MAX_TEXT_CHARS]


def _fetch(url: str, cancel_flag=None) -> Dict[str, Any]:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError(f"Refusing to fetch non-HTTP(S) URL: {url!r}")

    request = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT, **_ACCEPT_HEADERS})

    result: List[Dict[str, Any]] = []
    error: List[Exception] = []

    def _do_fetch() -> None:
        try:
            with urllib.request.urlopen(request, timeout=_FETCH_TIMEOUT) as response:
                content_type = response.headers.get("Content-Type", "")
                raw = response.read(_MAX_BYTES + 1)
                truncated = len(raw) > _MAX_BYTES
                raw = raw[:_MAX_BYTES]
                charset = response.headers.get_content_charset() or "utf-8"
                try:
                    body = raw.decode(charset, errors="replace")
                except LookupError:
                    body = raw.decode("utf-8", errors="replace")
                result.append({
                    "status_code": response.status,
                    "content_type": content_type,
                    "body": body,
                    "truncated": truncated,
                    "final_url": response.geturl(),
                })
        except Exception as exc:
            error.append(exc)

    t = threading.Thread(target=_do_fetch, daemon=True)
    t.start()

    # Poll for completion, checking cancellation every second
    while t.is_alive():
        t.join(timeout=1.0)
        if t.is_alive() and cancel_flag is not None and cancel_flag.is_set():
            # Cancel flag raised — the thread is still running but we stop waiting.
            # The OS will eventually clean up the socket when the daemon thread exits.
            raise CancelledError("Browser fetch cancelled by run cancellation")

    if error:
        raise error[0]
    if not result:
        raise RuntimeError("Fetch returned no result")
    return result[0]


def _extract(body: str) -> _PageTextExtractor:
    parser = _PageTextExtractor()
    try:
        parser.feed(body)
    except Exception:
        pass
    return parser


# ── Capability Handlers ────────────────────────────────────────────────────

def handle_browser_navigate(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    url = str(params.get("url", "")).strip()
    if not url:
        return {"error": "No URL provided", "success": False}

    session_id = _session_id_for(context)
    emit = context.get("emit")
    run_id = context.get("run_id", "")

    if emit:
        emit({"type": "browser.session.created", "run_id": run_id, "session_id": session_id})
        emit({"type": "browser.navigation.started", "run_id": run_id, "session_id": session_id, "url": url})

    cancel_flag = context.get("cancel_flag")
    try:
        fetched = _fetch(url, cancel_flag=cancel_flag)
    except CancelledError:
        if emit:
            emit({"type": "browser.cancelled", "run_id": run_id, "session_id": session_id, "url": url})
        return {"error": "Fetch cancelled", "success": False, "cancelled": True, "session_id": session_id}
    except (urllib.error.URLError, ValueError, TimeoutError) as exc:
        # `socket.timeout`/`TimeoutError` and a generic `URLError` both
        # surface here; distinguish them explicitly rather than folding
        # every failure into the same opaque error string.
        timed_out = isinstance(exc, TimeoutError) or "timed out" in str(exc).lower()
        if emit:
            emit({"type": "browser.error", "run_id": run_id, "session_id": session_id, "url": url, "error": str(exc), "timed_out": timed_out})
        return {
            "error": f"Failed to load {url}: {exc}",
            "success": False,
            "session_id": session_id,
            "url": url,
            "timed_out": timed_out,
        }

    content_type_base = fetched["content_type"].split(";")[0].strip().lower()
    is_text_renderable = any(content_type_base.startswith(t) for t in _TEXT_RENDERABLE_CONTENT_TYPES)
    fetch_succeeded = 200 <= fetched["status_code"] < 400

    if fetch_succeeded and not is_text_renderable:
        # Never silently report empty content as success — this is the
        # honest failure for anything this fetch+extract capability
        # genuinely cannot read (images, PDFs, video, generic binary).
        result = {
            "success": False,
            "reason": "not_text_renderable",
            "session_id": session_id,
            "url": fetched["final_url"],
            "status_code": fetched["status_code"],
            "content_type": fetched["content_type"],
            "truncated": fetched["truncated"],
        }
        if emit:
            emit({
                "type": "browser.navigation.completed",
                "run_id": run_id,
                "session_id": session_id,
                "url": result["url"],
                "status_code": result["status_code"],
                "reason": "not_text_renderable",
            })
        return result

    parser = _extract(fetched["body"]) if fetch_succeeded else _PageTextExtractor()
    extracted_text = parser.text
    js_rendered_suspected = (
        fetch_succeeded and len(extracted_text.strip()) < _SUSPICIOUSLY_EMPTY_TEXT_CHARS and content_type_base.startswith("text/html")
    )

    result = {
        "session_id": session_id,
        "url": fetched["final_url"],
        "title": parser.title or url,
        "text": extracted_text,
        "links": parser.links,
        "status_code": fetched["status_code"],
        "content_type": fetched["content_type"],
        "truncated": fetched["truncated"],
        "success": fetch_succeeded,
    }
    if js_rendered_suspected:
        # Still reported as success (the fetch itself worked) but flagged
        # honestly — this is not "the page has no content," it's "this
        # fetch-only capability likely can't see content a real browser
        # would render via JavaScript." See docs/lifecycle.md for the
        # documented boundary this capability doesn't cross.
        result["renderable_text_found"] = False
        result["note"] = (
            "Almost no text was extracted from an HTML response. This page likely renders its "
            "content client-side; this capability fetches raw HTML only and does not execute "
            "JavaScript, so its substance may not be visible here."
        )
    elif fetch_succeeded:
        result["renderable_text_found"] = True

    if emit:
        emit({
            "type": "browser.navigation.completed",
            "run_id": run_id,
            "session_id": session_id,
            "url": result["url"],
            "title": result["title"],
            "status_code": result["status_code"],
        })

    return result


def handle_browser_read(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    # Reading is navigate-and-extract for this stateless implementation —
    # there is no separate "already open page" to re-read without a real
    # browser process, so we make that explicit rather than pretending.
    result = handle_browser_navigate(params, context)
    if context.get("emit") and result.get("success"):
        context["emit"]({
            "type": "browser.page.read",
            "run_id": context.get("run_id", ""),
            "session_id": result.get("session_id"),
            "url": result.get("url"),
            "chars_read": len(result.get("text", "")),
        })
    return result


def handle_browser_follow_link(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    base_url = str(params.get("base_url", "")).strip()
    href = str(params.get("href", "")).strip()
    if not href:
        return {"error": "No link href provided", "success": False}

    target = urllib.parse.urljoin(base_url, href) if base_url else href
    result = handle_browser_navigate({"url": target}, context)
    if context.get("emit") and result.get("success"):
        context["emit"]({
            "type": "browser.link.followed",
            "run_id": context.get("run_id", ""),
            "session_id": result.get("session_id"),
            "from_url": base_url,
            "to_url": result.get("url"),
        })
    return result


def _resolve_ddg_redirect(href: str) -> Optional[str]:
    """DuckDuckGo lite wraps every result as `//duckduckgo.com/l/?uddg=<url-encoded target>&rut=...`
    rather than linking directly. Unwrap it back to the real target URL; a
    plain `http(s)://` link (or anything else) passes through unchanged."""
    if href.startswith("http://") or href.startswith("https://"):
        return href
    if "duckduckgo.com/l/" in href:
        parsed = urllib.parse.urlparse(href if "://" in href else f"https:{href}")
        target = urllib.parse.parse_qs(parsed.query).get("uddg")
        if target:
            return urllib.parse.unquote(target[0])
    return None


def handle_browser_search(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    query = str(params.get("query", "")).strip()
    if not query:
        return {"error": "No search query provided", "success": False}

    # DuckDuckGo's `html.duckduckgo.com` endpoint serves an anti-bot
    # interstitial (HTTP 202, no results) to non-interactive clients even
    # with a browser User-Agent; the older `lite.duckduckgo.com` endpoint
    # reliably returns plain result links instead.
    search_url = "https://lite.duckduckgo.com/lite/?q=" + urllib.parse.quote(query)
    result = handle_browser_navigate({"url": search_url}, context)
    if not result.get("success"):
        return result

    results = []
    for link in result.get("links", []):
        target = _resolve_ddg_redirect(link["href"])
        if target and "duckduckgo.com" not in urllib.parse.urlparse(target).netloc:
            results.append({"href": target, "text": link["text"]})
        if len(results) >= 10:
            break

    result["query"] = query
    result["results"] = results
    return result


def handle_browser_download(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    url = str(params.get("url", "")).strip()
    # Named `path` (not `destination`) deliberately: the Policy Engine's
    # workspace-boundary check already inspects `params["path"]` for every
    # capability, so the normal Run path gets sandboxing for free. The
    # explicit check below is defense-in-depth for any caller that reaches
    # this handler without going through policy evaluation first (as every
    # filesystem handler in registry.py already does for the same reason).
    rel_path = str(params.get("path", "")).strip()
    if not url or not rel_path:
        return {"error": "Both 'url' and destination 'path' are required", "success": False}

    ws_root = Path(context.get("workspace_root", os.getcwd())).resolve()
    target = (ws_root / rel_path).resolve() if not os.path.isabs(rel_path) else Path(rel_path).resolve()
    if target != ws_root and ws_root not in target.parents:
        return {
            "error": f"Path traversal denied: '{rel_path}' resolves outside workspace '{ws_root}'",
            "success": False,
        }

    session_id = _session_id_for(context)
    emit = context.get("emit")
    run_id = context.get("run_id", "")

    if emit:
        emit({"type": "browser.download.started", "run_id": run_id, "session_id": session_id, "url": url, "path": rel_path})

    cancel_flag = context.get("cancel_flag")
    try:
        request = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT, **_ACCEPT_HEADERS})
        # Use _fetch for cancellable download (we only need the body bytes)
        fetched_result: List[bytes] = []
        fetch_error: List[Exception] = []

        def _do_download() -> None:
            try:
                with urllib.request.urlopen(request, timeout=_FETCH_TIMEOUT) as response:
                    fetched_result.append(response.read(_MAX_BYTES + 1))
            except Exception as exc:
                fetch_error.append(exc)

        dl_thread = threading.Thread(target=_do_download, daemon=True)
        dl_thread.start()
        while dl_thread.is_alive():
            dl_thread.join(timeout=1.0)
            if dl_thread.is_alive() and cancel_flag is not None and cancel_flag.is_set():
                if emit:
                    emit({"type": "browser.cancelled", "run_id": run_id, "session_id": session_id, "url": url})
                return {"error": "Download cancelled", "success": False, "cancelled": True}
        if fetch_error:
            raise fetch_error[0]
        data = fetched_result[0]
        truncated = len(data) > _MAX_BYTES
        data = data[:_MAX_BYTES]
    except CancelledError:
        return {"error": "Download cancelled", "success": False, "cancelled": True}
    except (urllib.error.URLError, ValueError, TimeoutError) as exc:
        if emit:
            emit({"type": "browser.error", "run_id": run_id, "session_id": session_id, "url": url, "error": str(exc)})
        return {"error": f"Download failed: {exc}", "success": False}

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)

    if emit:
        emit({
            "type": "browser.download.completed",
            "run_id": run_id,
            "session_id": session_id,
            "url": url,
            "path": rel_path,
            "bytes": len(data),
        })

    return {
        "success": True,
        "session_id": session_id,
        "url": url,
        "path": rel_path,
        "bytes_written": len(data),
        "truncated": truncated,
        "artifact": {
            "type": "downloaded_file",
            "title": Path(rel_path).name,
            "path": rel_path,
            "content_preview": f"Downloaded from {url}",
            "metadata": {"url": url, "bytes": len(data)},
        },
    }


def handle_browser_capture(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    """Persists a snapshot of a page as an artifact. Not a pixel screenshot
    — see module docstring. `url`/`title`/`text` may be supplied directly
    (e.g. chained after a navigate) or a fresh `url` will be fetched."""
    url = str(params.get("url", "")).strip()
    title = params.get("title")
    text = params.get("text")

    if text is None:
        if not url:
            return {"error": "No URL or content provided to capture", "success": False}
        fetched = handle_browser_navigate({"url": url}, context)
        if not fetched.get("success"):
            return fetched
        title = fetched.get("title")
        text = fetched.get("text", "")
        url = fetched.get("url", url)

    session_id = _session_id_for(context)
    run_id = context.get("run_id", "")
    snippet = (text or "")[:2000]

    if context.get("emit"):
        context["emit"]({
            "type": "browser.capture.created",
            "run_id": run_id,
            "session_id": session_id,
            "url": url,
            "title": title,
        })

    return {
        "success": True,
        "session_id": session_id,
        "url": url,
        "title": title,
        "artifact": {
            "type": "browser_capture",
            "title": title or url or "Page capture",
            "content_preview": snippet,
            "metadata": {"url": url, "captured_at": time.time()},
        },
    }
