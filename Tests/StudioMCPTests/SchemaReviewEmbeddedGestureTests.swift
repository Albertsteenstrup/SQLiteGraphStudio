import Foundation
import WebKit
import XCTest
@testable import StudioMCP

/// Exercises the HTML served to MCP App hosts with delayed frame replies.
@MainActor
final class SchemaReviewEmbeddedGestureTests: XCTestCase {
    func testPanKeepsLastCompleteFrameAndClicksMatchWhatIsStillVisible() async throws {
        let html = try XCTUnwrap(MCPAppResources.schemaReviewHTML)
        let escaped = html
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        func frame(_ fill: String) -> String {
            Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1 1' preserveAspectRatio='none'><rect width='1' height='1' fill='\(fill)'/></svg>".utf8).base64EncodedString()
        }
        let host = """
        <!doctype html><html><body style="margin:0">
        <script>
        window.frameRequests = [];
        window.frameReplies = 0;
        window.messages = [];
        window.pendingFrames = [];
        window.releaseFrames = () => window.pendingFrames.splice(0).forEach(send => send());
        const frameData = ["\(frame("#b8cfff"))", "\(frame("#ffd1b8"))"];
        const review = {
          format: "sqlite-graph-studio/schema-review-view", path: "/tmp/gesture.sgreview", revision: "test",
          title: "Gesture", summary: { modifiedTables: 1 },
          changeSets: [{ label: "users", tables: 1, kind: "modified" }]
        };
        window.addEventListener("message", event => {
          const message = event.data;
          if (!message || message.jsonrpc !== "2.0") return;
          window.messages.push(`${message.method || `reply ${message.id}`} child=${event.source === document.getElementById('review')?.contentWindow}`);
          if (message.method === "ui/initialize") {
            event.source.postMessage({ jsonrpc: "2.0", id: message.id, result: { hostContext: { theme: "light" } } }, "*");
          } else if (message.method === "tools/call" && message.params.name === "studio_review_frame") {
            const args = message.params.arguments;
            window.frameRequests.push(args.actions || []);
            const index = window.frameRequests.length;
            const send = () => {
              window.frameReplies += 1;
              event.source.postMessage({ jsonrpc: "2.0", id: message.id, result: {
                isError: false, content: [{ type: "image", mimeType: "image/svg+xml", data: frameData[Math.min(index - 1, 1)] }],
                structuredContent: { width: args.width, height: args.height, sets: 1,
                  setTables: [["users"]], set: null, selection: [] }
              } }, "*");
            };
            if (index === 1) send(); else window.pendingFrames.push(send);
          }
        });
        window.addEventListener("load", () => document.getElementById("review").contentWindow.postMessage({
          jsonrpc: "2.0", method: "ui/notifications/tool-result",
          params: { isError: false, structuredContent: review, content: [] }
        }, "*"), { once: true });
        </script>
        <iframe id="review" style="display:block;width:640px;height:520px;border:0" srcdoc="\(escaped)"></iframe>
        </body></html>
        """

        let browser = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 520))
        browser.loadHTMLString(host, baseURL: nil)
        try await waitUntil("!!document.getElementById('review')?.contentDocument?.querySelector('img.frame')", in: browser)
        _ = try await browser.evaluateJavaScript("window.initialFrameSrc = document.getElementById('review').contentDocument.querySelector('img.frame').src; true")

        // Keep the frame request outstanding to inspect the canvas during a drag.
        _ = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            const canvas = doc.getElementById('canvas');
            const bounds = canvas.getBoundingClientRect();
            canvas.setPointerCapture = () => {};
            const start = { pointerId: 1, button: 0, clientX: bounds.left + 120,
              clientY: bounds.top + 120, bubbles: true };
            const end = { ...start, clientX: start.clientX + 180.5, clientY: start.clientY - 0.5 };
            canvas.dispatchEvent(new PointerEvent('pointerdown', start));
            canvas.dispatchEvent(new PointerEvent('pointermove', end));
            canvas.dispatchEvent(new PointerEvent('pointerup', end));
            return true; })()
        """)
        let offset = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            return doc.querySelector('img.frame').getBoundingClientRect().left
              - doc.getElementById('canvas').getBoundingClientRect().left; })()
        """)
        XCTAssertLessThan(abs(try XCTUnwrap(offset as? NSNumber).doubleValue), 3,
                          "Panning must not expose the canvas background beside a shifted frame")

        try await waitUntil("window.frameRequests.length >= 2", in: browser)
        let transform = try await browser.evaluateJavaScript("window.frameRequests[1][0]") as? [String: Any]
        XCTAssertEqual(transform?["type"] as? String, "transform")
        XCTAssertEqual((transform?["tx"] as? NSNumber)?.doubleValue ?? 0, 180.5, accuracy: 0.01)

        // A quick click before the new frame arrives is on the stationary image. The
        // renderer receives it after the pan, so its hit point must move with that pan.
        _ = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            const canvas = doc.getElementById('canvas');
            const bounds = canvas.getBoundingClientRect();
            canvas.setPointerCapture = () => {};
            const input = { pointerId: 1, button: 0, clientX: bounds.left + canvas.clientLeft + 50,
              clientY: bounds.top + canvas.clientTop + 50, bubbles: true };
            canvas.dispatchEvent(new PointerEvent('pointerdown', input));
            canvas.dispatchEvent(new PointerEvent('pointerup', input));
            return true; })()
        """)
        _ = try await browser.evaluateJavaScript("window.releaseFrames(); true")
        try await waitUntil("window.frameRequests.length >= 3", in: browser)
        let click = try await browser.evaluateJavaScript("window.frameRequests[2][0]") as? [String: Any]
        XCTAssertEqual(click?["type"] as? String, "click")
        XCTAssertEqual((click?["x"] as? NSNumber)?.doubleValue ?? 0, 230.5, accuracy: 0.01)
        XCTAssertEqual((click?["y"] as? NSNumber)?.doubleValue ?? 0, 49.5, accuracy: 0.01)

        try await waitUntil("window.frameReplies >= 2 && document.getElementById('review').contentDocument.querySelector('img.frame')?.src !== window.initialFrameSrc", in: browser)
        let settledOffset = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            return doc.querySelector('img.frame').getBoundingClientRect().left
              - doc.getElementById('canvas').getBoundingClientRect().left; })()
        """)
        XCTAssertLessThan(abs(try XCTUnwrap(settledOffset as? NSNumber).doubleValue), 3)
        _ = try await browser.evaluateJavaScript("window.releaseFrames(); true")
    }

    private func waitUntil(_ expression: String, in browser: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let value = try? await browser.evaluateJavaScript(expression),
               (value as? NSNumber)?.boolValue == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let diagnostic = (try? await browser.evaluateJavaScript("""
          JSON.stringify({ ready: document.readyState, frame: !!document.getElementById('review'),
            child: !!document.getElementById('review')?.contentDocument,
            status: document.getElementById('review')?.contentDocument?.getElementById('status')?.textContent,
            childTitle: document.getElementById('review')?.contentDocument?.title,
            childScripts: document.getElementById('review')?.contentDocument?.scripts.length,
            messages: window.messages, requests: window.frameRequests.length })
        """)) ?? "no diagnostics"
        XCTFail("The embedded review did not reach: \(expression); \(diagnostic)")
        throw WaitTimeout()
    }

    private struct WaitTimeout: Error {}
}
