"""
Tests for the Browser capability layer.

Most tests mock the network boundary (`urllib.request.urlopen`) to stay fast
and deterministic. A couple of tests hit real, stable public endpoints
(example.com) the same way the project's existing bridge/Flutter tests
already exercise the real SysAI/Ollama stack — this is a documented,
accepted convention here, not an accident.
"""
from __future__ import annotations

import io
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from capabilities.registry import get_default_registry


def _fake_response(body: bytes, status: int = 200, content_type: str = "text/html; charset=utf-8", url: str = "https://example.com/"):
    resp = io.BytesIO(body)
    resp.status = status
    resp.headers = mock.Mock()
    resp.headers.get = lambda key, default=None: content_type if key == "Content-Type" else default
    resp.headers.get_content_charset = lambda: "utf-8"
    resp.geturl = lambda: url
    resp.__enter__ = lambda self=resp: resp
    resp.__exit__ = lambda *a: False
    return resp


class TestBrowserCapabilityRegistration(unittest.TestCase):
    def test_all_browser_capabilities_are_registered(self) -> None:
        registry = get_default_registry()
        for cap_id in ("browser.search", "browser.navigate", "browser.read",
                       "browser.follow_link", "browser.download", "browser.capture"):
            self.assertIsNotNone(registry.get(cap_id), f"{cap_id} not registered")


class TestBrowserNavigateMocked(unittest.TestCase):
    def setUp(self) -> None:
        self.capability = get_default_registry().get("browser.navigate")

    def test_extracts_title_text_and_links(self) -> None:
        html = b"""
        <html><head><title>Example Page</title></head>
        <body>
          <p>Hello world.</p>
          <a href="https://sub.example.com/next">Next page</a>
        </body></html>
        """
        events = []
        with mock.patch("urllib.request.urlopen", return_value=_fake_response(html)):
            result = self.capability.execute({"url": "https://example.com"}, {"run_id": "r1", "emit": events.append})

        self.assertTrue(result["success"])
        self.assertEqual(result["title"], "Example Page")
        self.assertIn("Hello world.", result["text"])
        self.assertEqual(result["links"], [{"href": "https://sub.example.com/next", "text": "Next page"}])
        self.assertEqual([e["type"] for e in events],
                          ["browser.session.created", "browser.navigation.started", "browser.navigation.completed"])

    def test_non_http_scheme_is_refused(self) -> None:
        result = self.capability.execute({"url": "file:///etc/passwd"}, {"run_id": "r1", "emit": lambda e: None})
        self.assertFalse(result["success"])
        self.assertIn("error", result)

    def test_network_failure_emits_browser_error_and_reports_failure(self) -> None:
        import urllib.error
        events = []
        with mock.patch("urllib.request.urlopen", side_effect=urllib.error.URLError("no route")):
            result = self.capability.execute({"url": "https://unreachable.example"}, {"run_id": "r1", "emit": events.append})
        self.assertFalse(result["success"])
        self.assertIn("browser.error", [e["type"] for e in events])

    def test_timeout_is_reported_as_timed_out_rather_than_a_generic_error(self) -> None:
        events = []
        with mock.patch("urllib.request.urlopen", side_effect=TimeoutError("timed out")):
            result = self.capability.execute({"url": "https://slow.example"}, {"run_id": "r1", "emit": events.append})
        self.assertFalse(result["success"])
        self.assertTrue(result["timed_out"])
        self.assertTrue(any(e.get("timed_out") for e in events if e["type"] == "browser.error"))

    def test_non_text_content_is_an_honest_failure_not_a_silent_empty_success(self) -> None:
        # A PDF/image response: nothing here could ever have extracted
        # text from it, so this must not come back as success:true with
        # text="".
        with mock.patch(
            "urllib.request.urlopen",
            return_value=_fake_response(b"%PDF-1.4 binary bytes", content_type="application/pdf"),
        ):
            result = self.capability.execute({"url": "https://example.com/report.pdf"}, {"run_id": "r1", "emit": lambda e: None})
        self.assertFalse(result["success"])
        self.assertEqual(result["reason"], "not_text_renderable")
        self.assertNotIn("text", result)

    def test_a_2xx_html_response_with_almost_no_extractable_text_is_flagged_honestly(self) -> None:
        # Simulates a JS-rendered SPA shell: 200 OK, content-type text/html,
        # but the server-rendered body has essentially no readable text.
        html = b"<html><head><title>App</title></head><body><div id='root'></div></body></html>"
        with mock.patch("urllib.request.urlopen", return_value=_fake_response(html)):
            result = self.capability.execute({"url": "https://spa.example"}, {"run_id": "r1", "emit": lambda e: None})
        self.assertTrue(result["success"])  # the fetch itself worked
        self.assertFalse(result["renderable_text_found"])
        self.assertIn("note", result)

    def test_normal_html_with_real_text_is_not_flagged(self) -> None:
        html = b"<html><body><p>" + b"A" * 200 + b"</p></body></html>"
        with mock.patch("urllib.request.urlopen", return_value=_fake_response(html)):
            result = self.capability.execute({"url": "https://example.com"}, {"run_id": "r1", "emit": lambda e: None})
        self.assertTrue(result["success"])
        self.assertTrue(result["renderable_text_found"])
        self.assertNotIn("note", result)


class TestBrowserSearchMocked(unittest.TestCase):
    def test_unwraps_duckduckgo_lite_redirect_links_into_real_urls(self) -> None:
        html = (
            b'<html><head><title>q at DuckDuckGo</title></head><body>'
            b'<a href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdocs.flutter.dev%2Finstall&rut=abc">Flutter install docs</a>'
            b'<a href="//duckduckgo.com/y.js">tracker</a>'
            b'</body></html>'
        )
        registry = get_default_registry()
        with mock.patch("urllib.request.urlopen", return_value=_fake_response(html)):
            result = registry.get("browser.search").execute({"query": "flutter install"}, {"run_id": "r1", "emit": lambda e: None})

        self.assertTrue(result["success"])
        self.assertEqual(result["results"], [{"href": "https://docs.flutter.dev/install", "text": "Flutter install docs"}])

    def test_empty_query_is_rejected(self) -> None:
        registry = get_default_registry()
        result = registry.get("browser.search").execute({"query": ""}, {"run_id": "r1", "emit": lambda e: None})
        self.assertFalse(result["success"])


class TestBrowserDownload(unittest.TestCase):
    def setUp(self) -> None:
        self.capability = get_default_registry().get("browser.download")
        self.temp_dir = tempfile.mkdtemp(prefix="sysai_browser_dl_test_")
        self.workspace_root = Path(self.temp_dir).resolve()

    def tearDown(self) -> None:
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _ctx(self):
        return {"workspace_root": str(self.workspace_root), "run_id": "r1", "emit": lambda e: None}

    def test_downloads_into_workspace_and_creates_an_artifact(self) -> None:
        with mock.patch("urllib.request.urlopen", return_value=_fake_response(b"file-bytes")):
            result = self.capability.execute({"url": "https://example.com/f.zip", "path": "downloads/f.zip"}, self._ctx())

        self.assertTrue(result["success"])
        self.assertTrue((self.workspace_root / "downloads" / "f.zip").exists())
        self.assertEqual(result["artifact"]["type"], "downloaded_file")

    def test_rejects_path_traversal_outside_the_workspace_even_without_policy_layer(self) -> None:
        # Defense-in-depth: the handler itself must refuse this, not rely
        # solely on the Policy Engine catching it upstream. Use a target
        # that provably did not exist before the call, so a false pass
        # (writing outside the workspace) would be unambiguous.
        canary = self.workspace_root.parent / f"sysai_canary_{os.getpid()}.txt"
        self.assertFalse(canary.exists())
        try:
            result = self.capability.execute(
                {"url": "https://example.com/f", "path": f"../{canary.name}"}, self._ctx()
            )
            self.assertFalse(result["success"])
            self.assertIn("error", result)
            self.assertFalse(canary.exists())
        finally:
            canary.unlink(missing_ok=True)

    def test_missing_url_or_path_is_rejected(self) -> None:
        result = self.capability.execute({"url": "https://example.com/f"}, self._ctx())
        self.assertFalse(result["success"])


class TestBrowserCaptureMocked(unittest.TestCase):
    def test_capture_from_explicit_text_creates_a_browser_capture_artifact(self) -> None:
        registry = get_default_registry()
        result = registry.get("browser.capture").execute(
            {"url": "https://example.com", "title": "Example", "text": "some content"},
            {"run_id": "r1", "emit": lambda e: None},
        )
        self.assertTrue(result["success"])
        self.assertEqual(result["artifact"]["type"], "browser_capture")
        self.assertIn("some content", result["artifact"]["content_preview"])


class TestBrowserRealNetwork(unittest.TestCase):
    """A small number of tests against a real, stable public endpoint —
    matching this project's existing convention of testing against real
    infrastructure rather than mocking everything."""

    def test_navigate_reads_a_real_page(self) -> None:
        registry = get_default_registry()
        result = registry.get("browser.navigate").execute({"url": "https://example.com"}, {"run_id": "r1", "emit": lambda e: None})
        self.assertTrue(result["success"])
        self.assertIn("Example", result["title"])


if __name__ == "__main__":
    unittest.main()
