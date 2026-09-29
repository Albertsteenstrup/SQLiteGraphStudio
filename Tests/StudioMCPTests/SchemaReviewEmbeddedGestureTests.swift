import Foundation
import WebKit
import XCTest
@testable import StudioMCP

/// Exercises the HTML served to MCP App hosts with delayed frame replies.
@MainActor
final class SchemaReviewEmbeddedGestureTests: XCTestCase {
    func testViewZeroPrecedesTheDefaultChangeViewEvenWithOneSet() async throws {
        let html = try XCTUnwrap(MCPAppResources.schemaReviewHTML)
        let escaped = html
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let frameData = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1 1'><rect width='1' height='1' fill='#fff'/></svg>".utf8).base64EncodedString()
        let host = """
        <!doctype html><html><body>
        <script>
        window.currentSet = 0;
        window.currentSelection = [];
        window.frameActions = [];
        window.addEventListener("message", event => {
          const message = event.data;
          if (!message || message.jsonrpc !== "2.0") return;
          if (message.method === "ui/initialize") {
            event.source.postMessage({ jsonrpc: "2.0", id: message.id, result: { hostContext: { theme: "light" } } }, "*");
          } else if (message.method === "tools/call" && message.params.name === "studio_review_frame") {
            const args = message.params.arguments;
            for (const action of args.actions || []) {
              window.frameActions.push(action);
              if (action.type === "set") { window.currentSet = action.index; window.currentSelection = []; }
              if (action.type === "step") { window.currentSet = Math.max(-1, Math.min(0, window.currentSet + action.direction)); window.currentSelection = []; }
              if (action.type === "click" && window.currentSet === -1) window.currentSelection = ["teams"];
            }
            event.source.postMessage({ jsonrpc: "2.0", id: message.id, result: {
              isError: false, content: [{ type: "image", mimeType: "image/svg+xml", data: "\(frameData)" }],
              structuredContent: { width: args.width, height: args.height, sets: 1,
                setTables: [["users"]], set: window.currentSet, selection: window.currentSelection }
            } }, "*");
          } else if (message.method === "tools/call" && message.params.name === "studio_review_detail") {
            event.source.postMessage({ jsonrpc: "2.0", id: message.id, result: {
              isError: false, content: [], structuredContent: {
                format: "sqlite-graph-studio/schema-review-full-model", revision: "test",
                tables: [{ id: "users", name: "users", kind: "modified", fullModel: true, columns: [] },
                  { id: "teams", name: "teams", kind: "unchanged", fullModel: true,
                    columns: [{ name: "quiet_field", kind: "unchanged", description: "TEXT · NULL" }] }],
                relations: [] }
            } }, "*");
          }
        });
        window.addEventListener("load", () => document.getElementById("review").contentWindow.postMessage({
          jsonrpc: "2.0", method: "ui/notifications/tool-result", params: { isError: false, content: [],
            structuredContent: { format: "sqlite-graph-studio/schema-review-view", path: "/tmp/one.sgreview",
              revision: "test", summary: { modifiedTables: 1 },
              changeSets: [{ label: "users", tables: 1, kind: "modified" }] } }
        }, "*"), { once: true });
        </script>
        <iframe id="review" style="display:block;width:640px;height:600px;border:0" srcdoc="\(escaped)"></iframe>
        </body></html>
        """
        let browser = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 600))
        browser.loadHTMLString(host, baseURL: nil)
        try await waitUntil("document.getElementById('review')?.contentDocument?.getElementById('position')?.textContent?.includes('View 1 of 1')", in: browser)
        let initial = try await browser.evaluateJavaScript("(() => { const doc = document.getElementById('review').contentDocument; return !doc.getElementById('prev').disabled && !doc.getElementById('changes').hidden; })()") as? Bool
        XCTAssertEqual(initial, true)
        _ = try await browser.evaluateJavaScript("document.getElementById('review').contentDocument.getElementById('prev').click(); true")
        try await waitUntil("document.getElementById('review').contentDocument.getElementById('position').textContent.includes('View 0')", in: browser)
        let zero = try await browser.evaluateJavaScript("(() => { const doc = document.getElementById('review').contentDocument; return doc.getElementById('prev').disabled && doc.getElementById('changes').hidden && !doc.getElementById('next').disabled; })()") as? Bool
        XCTAssertEqual(zero, true)
        _ = try await browser.evaluateJavaScript("""
          (() => { const canvas = document.getElementById('review').contentDocument.getElementById('canvas');
            canvas.setPointerCapture = () => {};
            const rect = canvas.getBoundingClientRect();
            const input = { pointerId: 1, button: 0, clientX: rect.left + 50, clientY: rect.top + 50, bubbles: true };
            canvas.dispatchEvent(new PointerEvent('pointerdown', input));
            canvas.dispatchEvent(new PointerEvent('pointerup', input));
            return true; })()
        """)
        try await waitUntil("document.getElementById('review').contentDocument.getElementById('detail').textContent.includes('quiet_field')", in: browser)
        _ = try await browser.evaluateJavaScript("document.getElementById('review').contentDocument.getElementById('next').click(); true")
        try await waitUntil("document.getElementById('review').contentDocument.getElementById('position').textContent.includes('View 1 of 1')", in: browser)
        let actions = try await browser.evaluateJavaScript("window.frameActions.filter(action => action.type === 'set').map(action => action.index)") as? [Int]
        XCTAssertEqual(actions, [-1, 0])
    }

    func testRapidNavigationSkipsStaleFramesAndRestoresVisitedViewsImmediately() async throws {
        let html = try XCTUnwrap(MCPAppResources.schemaReviewHTML)
        let escaped = html.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let host = """
        <!doctype html><html><body>
        <script>
        window.currentSet = 0;
        window.frameRequests = [];
        window.pendingFrames = [];
        window.releaseFrame = () => window.pendingFrames.shift()?.();
        window.addEventListener('message', event => {
          const message = event.data;
          if (!message || message.jsonrpc !== '2.0') return;
          if (message.method === 'ui/initialize') {
            event.source.postMessage({ jsonrpc:'2.0', id:message.id, result:{ hostContext:{ theme:'light' } } }, '*');
          } else if (message.method === 'tools/call' && message.params.name === 'studio_review_frame') {
            const args = message.params.arguments;
            window.frameRequests.push(args);
            for (const action of args.actions || []) if (action.type === 'set') window.currentSet = action.index;
            const renderedSet = window.currentSet;
            const fill = ['#ddd','#fff','#b8cfff','#cfffba'][renderedSet + 1];
            const data = btoa(`<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1 1'><rect width='1' height='1' fill='${fill}'/></svg>`);
            const send = () => event.source.postMessage({ jsonrpc:'2.0', id:message.id, result:{
              isError:false, content:[{ type:'image', mimeType:'image/svg+xml', data }],
              structuredContent:{ width:args.width, height:args.height, set:renderedSet,
                setTables:[['users'],['audits'],['tokens']], selection:[] }
            } }, '*');
            if (window.frameRequests.length === 1) send(); else window.pendingFrames.push(send);
          }
        });
        window.addEventListener('load', () => document.getElementById('review').contentWindow.postMessage({
          jsonrpc:'2.0', method:'ui/notifications/tool-result', params:{ isError:false, content:[],
            structuredContent:{ format:'sqlite-graph-studio/schema-review-view', path:'/tmp/navigation.sgreview',
              revision:'test', summary:{ modifiedTables:3 },
              changeSets:['users','audits','tokens'].map(label => ({ label, tables:1, kind:'modified' })) }
          }
        }, '*'), { once:true });
        </script>
        <iframe id="review" style="display:block;width:640px;height:600px;border:0" srcdoc="\(escaped)"></iframe>
        </body></html>
        """
        let browser = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 600))
        browser.loadHTMLString(host, baseURL: nil)
        try await waitUntil("!!document.getElementById('review')?.contentDocument?.querySelector('img.frame')", in: browser)
        _ = try await browser.evaluateJavaScript("""
          window.firstFrame = document.getElementById('review').contentDocument.querySelector('img.frame').src;
          document.getElementById('review').contentDocument.getElementById('prev').click(); true
        """)
        try await waitUntil("window.frameRequests.length === 2", in: browser)
        _ = try await browser.evaluateJavaScript("""
          document.getElementById('review').contentDocument.getElementById('next').click();
          document.getElementById('review').contentDocument.getElementById('next').click(); true
        """)
        let destination = try await browser.evaluateJavaScript("document.getElementById('review').contentDocument.getElementById('position').textContent") as? String
        XCTAssertEqual(destination, "View 2 of 3 · Changes", "Navigation responds while the earlier frame is pending")
        _ = try await browser.evaluateJavaScript("window.releaseFrame(); true")
        try await waitUntil("window.frameRequests.length === 3", in: browser)
        let queued = try await browser.evaluateJavaScript("window.frameRequests[2].actions.map(action => action.index)") as? [Int]
        XCTAssertEqual(queued, [1], "Only the latest destination should be sent")
        let staleLabel = try await browser.evaluateJavaScript("document.getElementById('review').contentDocument.getElementById('position').textContent") as? String
        XCTAssertEqual(staleLabel, destination, "An old response must not put the reader back in View 0")
        _ = try await browser.evaluateJavaScript("window.releaseFrame(); true")
        try await waitUntil("document.getElementById('review').contentDocument.querySelector('img.frame').src !== window.firstFrame", in: browser)
        let restored = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            doc.getElementById('prev').click();
            return doc.querySelector('img.frame').src === window.firstFrame; })()
        """) as? Bool
        XCTAssertEqual(restored, true, "A visited view should appear before the next renderer response")
        try await waitUntil("window.frameRequests.length === 4", in: browser)
        let isolated = try await browser.evaluateJavaScript("window.frameRequests.every(request => !!request.view_id && request.view_id === window.frameRequests[0].view_id)") as? Bool
        XCTAssertEqual(isolated, true)
        _ = try await browser.evaluateJavaScript("window.releaseFrame(); true")
    }

    func testResizingTheGraphNeverExposesTheCanvasBacking() async throws {
        let html = try XCTUnwrap(MCPAppResources.schemaReviewHTML)
        let escaped = html
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let frameData = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1 1' preserveAspectRatio='none'><rect width='1' height='1' fill='#f5f6f7'/></svg>".utf8).base64EncodedString()
        let host = """
        <!doctype html><html><body style="margin:0">
        <script>
        window.frameRequests = [];
        window.addEventListener("message", event => {
          const message = event.data;
          if (!message || message.jsonrpc !== "2.0") return;
          if (message.method === "ui/initialize") {
            event.source.postMessage({ jsonrpc: "2.0", id: message.id, result: { hostContext: { theme: "light" } } }, "*");
          } else if (message.method === "tools/call" && message.params.name === "studio_review_frame") {
            const args = message.params.arguments;
            window.frameRequests.push(args);
            if (window.frameRequests.length === 1) event.source.postMessage({ jsonrpc: "2.0", id: message.id, result: {
              isError: false, content: [{ type: "image", mimeType: "image/svg+xml", data: "\(frameData)" }],
              structuredContent: { width: args.width, height: args.height, sets: 1,
                setTables: [["users"]], set: 0, selection: [] }
            } }, "*");
          }
        });
        window.addEventListener("load", () => document.getElementById("review").contentWindow.postMessage({
          jsonrpc: "2.0", method: "ui/notifications/tool-result", params: { isError: false, content: [],
            structuredContent: { format: "sqlite-graph-studio/schema-review-view", path: "/tmp/resize.sgreview",
              revision: "test", summary: { modifiedTables: 1 },
              changeSets: [{ label: "users", tables: 1, kind: "modified" }] } }
        }, "*"), { once: true });
        </script>
        <iframe id="review" style="display:block;width:640px;height:800px;border:0" srcdoc="\(escaped)"></iframe>
        </body></html>
        """
        let browser = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 800))
        browser.loadHTMLString(host, baseURL: nil)
        try await waitUntil("!!document.getElementById('review')?.contentDocument?.querySelector('img.frame')", in: browser)
        let size = try await browser.evaluateJavaScript("""
          (() => { const canvas = document.getElementById('review').contentDocument.getElementById('canvas');
            const original = canvas.clientHeight;
            canvas.style.height = (original + 180) + 'px';
            return canvas.clientHeight; })()
        """)
        let enlargedHeight = try XCTUnwrap(size as? NSNumber).intValue
        let coverage = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            const canvas = doc.getElementById('canvas');
            const image = canvas.querySelector('img.frame');
            return image.getBoundingClientRect().bottom - (canvas.getBoundingClientRect().bottom - canvas.clientTop); })()
        """)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(coverage as? NSNumber).doubleValue, -1,
                                    "The last graph frame should cover the canvas until the resized frame arrives")
        let background = try await browser.evaluateJavaScript("""
          document.getElementById('review').contentDocument.documentElement.style.setProperty('--color-background-primary', '#f6f5f1');
          getComputedStyle(document.getElementById('review').contentDocument.getElementById('canvas')).backgroundColor
        """) as? String
        XCTAssertEqual(background, "rgb(245, 247, 250)", "The graph should not inherit the host's beige backing")
        try await waitUntil("window.frameRequests.some(request => request.height === \(enlargedHeight))", in: browser)
    }

    func testNarrativeLinksAndCollapsingShrinksTheEmbeddedView() async throws {
        let html = try XCTUnwrap(MCPAppResources.schemaReviewHTML)
        let escaped = html
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let frameData = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1 1'><rect width='1' height='1' fill='#f5f6f7'/></svg>".utf8).base64EncodedString()
        let host = """
        <!doctype html><html><body style="margin:0">
        <script>
        window.heights = [];
        window.addEventListener("message", event => {
          const message = event.data;
          if (!message || message.jsonrpc !== "2.0") return;
          if (message.method === "ui/initialize") {
            event.source.postMessage({ jsonrpc: "2.0", id: message.id, result: { hostContext: { theme: "light" } } }, "*");
          } else if (message.method === "ui/notifications/size-changed") {
            const height = message.params.height;
            window.heights.push(height);
            document.getElementById("review").style.height = height + "px";
          } else if (message.method === "tools/call" && message.params.name === "studio_review_frame") {
            const args = message.params.arguments;
            const selected = (args.actions || []).find(action => action.type === "select")?.table;
            event.source.postMessage({ jsonrpc: "2.0", id: message.id, result: {
              isError: false, content: [{ type: "image", mimeType: "image/svg+xml", data: "\(frameData)" }],
              structuredContent: { width: args.width, height: args.height, sets: 1,
                setTables: [["users"]], set: 0, selection: selected ? [selected] : [] }
            } }, "*");
          } else if (message.method === "tools/call" && message.params.name === "studio_review_detail") {
            event.source.postMessage({ jsonrpc: "2.0", id: message.id, result: {
              isError: false, content: [], structuredContent: {
                format: "sqlite-graph-studio/schema-review-detail", revision: "test", changeSets: [["users"]],
                tables: [{ id: "users", name: "users", kind: "modified", objectKind: "table",
                  columns: [{ name: "email", kind: "modified", before: "TEXT NULL", description: "TEXT NOT NULL" },
                    { name: "team_id", kind: "unchanged", description: "INTEGER" }] },
                  { id: "teams", name: "teams", kind: "unchanged", context: true, columns: [{ name: "id", kind: "unchanged", description: "INTEGER" }] }],
                relations: [{ id: "fk_users_team", kind: "modified", source: "users", target: "teams",
                  sourceColumns: ["team_id"], targetColumns: ["id"] }] }
            } }, "*");
          }
        });
        window.addEventListener("load", () => document.getElementById("review").contentWindow.postMessage({
          jsonrpc: "2.0", method: "ui/notifications/tool-result", params: { isError: false, content: [],
            structuredContent: { format: "sqlite-graph-studio/schema-review-view", path: "/tmp/resize.sgreview",
              revision: "test", summary: { modifiedTables: 1 },
              changeSets: [{ label: "users", tables: 1, kind: "modified" }],
              explanations: [{ set: 0, paragraphs: [[
                { text: "The " }, { text: "email", table: "users", field: "email" },
                { text: " field is now required. The " }, { text: "team relation", relation: "fk_users_team" },
                { text: " also changes." }
              ]] }] } }
        }, "*"), { once: true });
        </script>
        <iframe id="review" style="display:block;width:640px;height:520px;border:0" srcdoc="\(escaped)"></iframe>
        </body></html>
        """
        let browser = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 900))
        browser.loadHTMLString(host, baseURL: nil)
        try await waitUntil("!!document.getElementById('review')?.contentDocument?.getElementById('changes') && !document.getElementById('review').contentDocument.getElementById('changes').hidden", in: browser)
        _ = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            doc.defaultView.requestAnimationFrame = callback => setTimeout(callback, 0);
            doc.getElementById('changes').open = true;
            return true; })()
        """)
        try await waitUntil("document.getElementById('review').contentDocument.querySelector('.changes-body p')?.textContent?.includes('field is now required')", in: browser)
        _ = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            [...doc.querySelectorAll('.changes-body a.jump')].find(link => link.textContent === 'email').click();
            return true; })()
        """)
        try await waitUntil("document.getElementById('review').contentDocument.querySelector('#detail tr.focused')?.textContent?.includes('email')", in: browser)
        _ = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            [...doc.querySelectorAll('.changes-body a.jump')].find(link => link.textContent === 'team relation').click();
            return true; })()
        """)
        try await waitUntil("document.getElementById('review').contentDocument.querySelector('#detail .relation-row.focused')?.textContent?.includes('users')", in: browser)
        _ = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            doc.getElementById('changes-body').appendChild(Object.assign(doc.createElement('div'), { style: 'height:240px' }));
            return true; })()
        """)
        try await Task.sleep(for: .milliseconds(350))
        try await waitUntil("window.heights.some(height => height > 700)", in: browser)
        let expandedValue = try await browser.evaluateJavaScript("Number.parseInt(document.getElementById('review').style.height, 10)")
        let expanded = try XCTUnwrap(expandedValue as? NSNumber).intValue
        _ = try await browser.evaluateJavaScript("document.getElementById('review').contentDocument.getElementById('changes').open = false; true")
        try await waitUntil("window.heights.length > 2", in: browser)
        try await Task.sleep(for: .milliseconds(200))
        let collapsedValue = try await browser.evaluateJavaScript("Number.parseInt(document.getElementById('review').style.height, 10)")
        let collapsed = try XCTUnwrap(collapsedValue as? NSNumber).intValue
        XCTAssertLessThan(collapsed, expanded - 100, "The host should reclaim the space used by expanded changes")
    }

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
