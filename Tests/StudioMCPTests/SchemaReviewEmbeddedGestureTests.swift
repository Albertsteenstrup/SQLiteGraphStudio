import Foundation
import WebKit
import XCTest
@testable import StudioMCP

/// Exercises the HTML served to MCP App hosts with delayed frame replies.
@MainActor
final class SchemaReviewEmbeddedGestureTests: XCTestCase {
    func testExplanationDisclosureIsSharedAcrossViewsAndReviewRefreshes() async throws {
        let html = try XCTUnwrap(MCPAppResources.schemaReviewHTML)
        let escaped = html.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let frameData = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1 1'><rect width='1' height='1' fill='#fff'/></svg>".utf8).base64EncodedString()
        let host = """
        <!doctype html><html><body>
        <script>
        const ids = ['users', 'audits'];
        window.currentSet = 0;
        window.detailRequests = 0;
        window.frameRevisions = [];
        window.review = {
          format:'sqlite-graph-studio/schema-review-view', path:'/tmp/disclosure.sgreview',
          revision:'test', summary:{ modifiedTables:2 },
          author:'Codex · Improve embedded view performance', authorLabel:'Improve embedded view performance',
          changeSets:ids.map(label => ({ label, tables:1, kind:'modified' }))
        };
        window.resendReview = () => document.getElementById('review').contentWindow.postMessage({
          jsonrpc:'2.0', method:'ui/notifications/tool-result',
          params:{ isError:false, content:[], structuredContent:window.review }
        }, '*');
        window.addEventListener('message', event => {
          const message = event.data;
          if (!message || message.jsonrpc !== '2.0') return;
          const reply = result => event.source.postMessage({ jsonrpc:'2.0', id:message.id, result }, '*');
          if (message.method === 'ui/initialize') {
            reply({ hostContext:{ theme:'light' } });
          } else if (message.method === 'tools/call' && message.params.name === 'studio_review_frame') {
            const args = message.params.arguments;
            window.frameRevisions.push(args.revision);
            window.currentSet = args.view_set;
            for (const action of args.actions || []) if (action.type === 'set') window.currentSet = action.index;
            reply({ isError:false, content:[{ type:'image', mimeType:'image/svg+xml', data:'\(frameData)' }],
              structuredContent:{ width:args.width, height:args.height, set:window.currentSet,
                setTables:ids.map(id => [id]), selection:[] } });
          } else if (message.method === 'tools/call' && message.params.name === 'studio_review_detail') {
            window.detailRequests += 1;
            reply({ isError:false, content:[], structuredContent:{
              format:'sqlite-graph-studio/schema-review-detail', revision:message.params.arguments.revision,
              changeSets:ids.map(id => [id]), relations:[],
              tables:ids.map(id => ({ id, name:id, kind:'modified', columns:[
                { name:'note', kind:'added', description:'TEXT NULL' }
              ] }))
            } });
          }
        });
        window.addEventListener('load', window.resendReview, { once:true });
        </script>
        <iframe id="review" style="display:block;width:640px;height:600px;border:0" srcdoc="\(escaped)"></iframe>
        </body></html>
        """
        let browser = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 600))
        browser.loadHTMLString(host, baseURL: nil)
        try await waitUntil("!!document.getElementById('review')?.contentDocument?.querySelector('img.frame')", in: browser)
        let author = try await browser.evaluateJavaScript("document.getElementById('review').contentDocument.getElementById('author').textContent") as? String
        XCTAssertEqual(author, "Improve embedded view performance")
        let provenance = try await browser.evaluateJavaScript("document.getElementById('review').contentDocument.getElementById('author').title") as? String
        XCTAssertEqual(provenance, "Produced by Codex · Improve embedded view performance")
        _ = try await browser.evaluateJavaScript("document.getElementById('review').contentDocument.querySelector('#changes summary').click(); true")
        try await waitUntil("document.getElementById('review').contentDocument.querySelector('#changes[open] #changes-body')?.textContent.includes('users')", in: browser)

        _ = try await browser.evaluateJavaScript("document.getElementById('review').contentDocument.getElementById('next').click(); true")
        try await waitUntil("document.getElementById('review').contentDocument.querySelector('#changes[open] #changes-body')?.textContent.includes('audits')", in: browser)
        let staysCollapsed = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            doc.querySelector('#changes summary').click();
            doc.getElementById('prev').click();
            return !doc.getElementById('changes').open && doc.getElementById('position').textContent.includes('View 1'); })()
        """) as? Bool
        XCTAssertEqual(staysCollapsed, true, "Collapsing in View 2 must also collapse the panel in View 1")

        _ = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            doc.getElementById('next').click();
            doc.querySelector('#changes summary').click();
            doc.getElementById('prev').click();
            return true; })()
        """)
        try await waitUntil("document.getElementById('review').contentDocument.querySelector('#changes[open] #changes-body')?.textContent.includes('users')", in: browser)
        let throughFullModel = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            doc.getElementById('prev').click();
            const hiddenInZero = doc.getElementById('changes').hidden;
            doc.getElementById('next').click();
            return hiddenInZero && !doc.getElementById('changes').hidden && doc.getElementById('changes').open; })()
        """) as? Bool
        XCTAssertEqual(throughFullModel, true, "View 0 should temporarily hide explanations without discarding the open state")

        // Hosts may resend the review result while updating an existing iframe.
        // Keep the reader's choice and reload the newly supplied schema facts.
        _ = try await browser.evaluateJavaScript("window.review.revision = 'updated'; window.resendReview(); true")
        try await waitUntil("window.detailRequests === 2 && document.getElementById('review').contentDocument.querySelector('#changes[open] #changes-body')?.textContent.includes('users')", in: browser)
        _ = try await browser.evaluateJavaScript("""
          document.getElementById('review').contentDocument.querySelector('#changes summary').click();
          window.review.revision = 'collapsed';
          window.resendReview(); true
        """)
        try await waitUntil("window.frameRevisions.includes('collapsed') && !!document.getElementById('review').contentDocument.querySelector('img.frame')", in: browser)
        let remainsCollapsedAfterRefresh = try await browser.evaluateJavaScript("!document.getElementById('review').contentDocument.getElementById('changes').open") as? Bool
        XCTAssertEqual(remainsCollapsedAfterRefresh, true)
        // Older hosts can supply just the provenance string. An absent author hides the row.
        _ = try await browser.evaluateJavaScript("delete window.review.authorLabel; window.review.author = 'Codex'; window.resendReview(); true")
        try await waitUntil("document.getElementById('review').contentDocument.getElementById('author').textContent === 'Codex'", in: browser)
        _ = try await browser.evaluateJavaScript("delete window.review.author; window.resendReview(); true")
        try await waitUntil("document.getElementById('review').contentDocument.getElementById('author').hidden", in: browser)
    }

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
        window.holdFrames = false;
        window.pendingFrames = [];
        window.frameRequests = 0;
        window.selection = [];
        window.releaseFrames = () => { window.holdFrames = false; window.pendingFrames.splice(0).forEach(send => send()); };
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
            if (selected) window.selection = [selected];
            const data = btoa(atob("\(frameData)").replace('</svg>', `<!-- frame ${++window.frameRequests} --></svg>`));
            const result = {
              isError: false, content: [{ type: "image", mimeType: "image/svg+xml", data }],
              structuredContent: { width: args.width, height: args.height, sets: 1,
                setTables: [["users"]], set: 0, selection: window.selection }
            };
            const send = () => event.source.postMessage({ jsonrpc: "2.0", id: message.id, result }, "*");
            if (window.holdFrames) window.pendingFrames.push(send); else send();
          } else if (message.method === "tools/call" && message.params.name === "studio_review_detail") {
            event.source.postMessage({ jsonrpc: "2.0", id: message.id, result: {
              isError: false, content: [], structuredContent: {
                format: "sqlite-graph-studio/schema-review-detail", revision: "test", changeSets: [["users"]],
                tables: [{ id: "users", name: "users", kind: "modified", objectKind: "table",
                  columns: [{ name: "email", kind: "modified", before: "TEXT NULL", description: "TEXT NOT NULL" },
                    { name: "team_id", kind: "unchanged", description: "INTEGER" }].concat(
                      Array.from({ length: 30 }, (_, index) => ({ name: `field_${index}`, kind: "unchanged", description: "TEXT NULL" }))) },
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
        let scrollsInsidePanel = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            const body = doc.querySelector('.detail-body');
            const close = doc.querySelector('button[aria-label="Close table details"]');
            if (!body || !close) return false;
            body.focus();
            const before = doc.getElementById('position').textContent;
            const key = new doc.defaultView.KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true, cancelable: true });
            body.dispatchEvent(key);
            body.scrollTop = body.scrollHeight;
            return body.clientHeight <= 360 && body.scrollHeight > body.clientHeight
              && close.getBoundingClientRect().bottom <= body.getBoundingClientRect().top
              && doc.getElementById('position').textContent === before && !key.defaultPrevented; })()
        """) as? Bool
        XCTAssertEqual(scrollsInsidePanel, true, "Long field lists should scroll with Close still visible, without arrow keys changing views")
        _ = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            window.holdFrames = true;
            [...doc.querySelectorAll('.changes-body a.jump')].find(link => link.textContent === 'team relation').click();
            return true; })()
        """)
        try await waitUntil("document.getElementById('review').contentDocument.querySelector('#detail .relation-row.focused')?.textContent?.includes('users')", in: browser)
        try await waitUntil("window.pendingFrames.length > 0", in: browser)
        try await waitUntil("document.getElementById('review').contentDocument.querySelector('button[aria-label=\"Close table details\"]') !== null", in: browser)

        // Dismiss locally while the graph is still rendering the linked selection.
        // Closing must shrink the host immediately and must survive that late reply.
        try await waitUntil("Number.parseInt(document.getElementById('review').style.height, 10) > 600", in: browser)
        let dismissedImmediately = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            window.expandedDetailHeight = Number.parseInt(document.getElementById('review').style.height, 10);
            window.frameBeforeClose = doc.querySelector('img.frame').src;
            window.requestsBeforeClose = window.frameRequests;
            const close = doc.querySelector('button[aria-label="Close table details"]');
            close.focus(); close.click();
            return doc.getElementById('detail').hidden && doc.activeElement.id === 'canvas'; })()
        """) as? Bool
        XCTAssertEqual(dismissedImmediately, true)
        try await waitUntil("Number.parseInt(document.getElementById('review').style.height, 10) < window.expandedDetailHeight - 60", in: browser)
        _ = try await browser.evaluateJavaScript("window.releaseFrames(); true")
        try await waitUntil("document.getElementById('review').contentDocument.querySelector('img.frame').src !== window.frameBeforeClose", in: browser)
        let remainedClosed = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            return doc.getElementById('detail').hidden && window.frameRequests === window.requestsBeforeClose
              && doc.getElementById('position').textContent.includes('View 1 of 1'); })()
        """) as? Bool
        XCTAssertEqual(remainedClosed, true, "Dismissing details must not send a camera action or be undone by a late frame")

        // The same link reopens details. Escape works even with focus on a button.
        _ = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            [...doc.querySelectorAll('.changes-body a.jump')].find(link => link.textContent === 'team relation').click();
            return true; })()
        """)
        try await waitUntil("!document.getElementById('review').contentDocument.getElementById('detail').hidden", in: browser)
        let escapedDetail = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            const close = doc.querySelector('button[aria-label="Close table details"]');
            close.focus();
            close.dispatchEvent(new doc.defaultView.KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
            return doc.getElementById('detail').hidden && doc.activeElement.id === 'canvas'; })()
        """) as? Bool
        XCTAssertEqual(escapedDetail, true)
        _ = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            [...doc.querySelectorAll('.changes-body a.jump')].find(link => link.textContent === 'email').click();
            return true; })()
        """)
        try await waitUntil("!document.getElementById('review').contentDocument.getElementById('detail').hidden && document.getElementById('review').contentDocument.querySelector('#detail tr.focused')?.textContent?.includes('email')", in: browser)
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

    func testGesturesMoveImmediatelyAndPendingFramesPreserveNewerInput() async throws {
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
                  setTables: [["users"]], set: null, selection: [],
                  camera: { zoom: [0.5, 0.5, 0.625, 0.12][index - 1], minZoom: 0.12, maxZoom: 2.4 } }
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
            canvas.dispatchEvent(new PointerEvent('pointerdown', start));
            for (let i = 1; i <= 20; i++) canvas.dispatchEvent(new PointerEvent('pointermove',
              { ...start, clientX: start.clientX + 180.5 * i / 20, clientY: start.clientY - 0.5 * i / 20 }));
            const end = { ...start, clientX: start.clientX + 180.5, clientY: start.clientY - 0.5 };
            canvas.dispatchEvent(new PointerEvent('pointerup', end));
            return true; })()
        """)
        func preview() async throws -> [String: Double] {
            let result = try await browser.evaluateJavaScript("""
              (() => { const doc = document.getElementById('review').contentDocument;
                const canvas = doc.getElementById('canvas'), bounds = canvas.getBoundingClientRect();
                const image = doc.querySelector('img.frame').getBoundingClientRect();
                return { x: image.left - bounds.left - canvas.clientLeft,
                  y: image.top - bounds.top - canvas.clientTop, scale: image.width / canvas.clientWidth }; })()
            """)
            return try XCTUnwrap(result as? [String: Double])
        }
        let panned = try await preview()
        XCTAssertEqual(try XCTUnwrap(panned["x"]), 180.5, accuracy: 0.01,
                       "Dragging must move the visible graph before a renderer reply")
        XCTAssertEqual(try XCTUnwrap(panned["y"]), -0.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(panned["scale"]), 1, accuracy: 0.001)

        try await waitUntil("window.frameRequests.length >= 2", in: browser)
        let transform = try await browser.evaluateJavaScript("window.frameRequests[1][0]") as? [String: Any]
        XCTAssertEqual(transform?["type"] as? String, "transform")
        XCTAssertEqual((transform?["tx"] as? NSNumber)?.doubleValue ?? 0, 180.5, accuracy: 0.01)
        let requestCount = try await browser.evaluateJavaScript("window.frameRequests.length") as? Int
        XCTAssertEqual(requestCount, 2,
                       "A burst of pointer moves should be coalesced into one camera request")

        func pinch(_ factor: Double) async throws {
            _ = try await browser.evaluateJavaScript("""
              (() => { const doc = document.getElementById('review').contentDocument;
                const canvas = doc.getElementById('canvas'), bounds = canvas.getBoundingClientRect();
                canvas.dispatchEvent(new doc.defaultView.WheelEvent('wheel', { ctrlKey: true,
                  clientX: bounds.left + canvas.clientLeft + 50, clientY: bounds.top + canvas.clientTop + 50,
                  deltaY: -Math.log(\(factor)) / 0.01, bubbles: true, cancelable: true }));
                return true; })()
            """)
        }
        try await pinch(1.25)
        let zoomed = try await preview()
        XCTAssertEqual(try XCTUnwrap(zoomed["scale"]), 1.25, accuracy: 0.001,
                       "Pinching must scale the visible graph while the pan reply is outstanding")
        XCTAssertEqual(try XCTUnwrap(zoomed["x"]), 213.125, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(zoomed["y"]), -13.125, accuracy: 0.01)
        try await pinch(0.8)
        let zoomedOut = try await preview()
        XCTAssertEqual(try XCTUnwrap(zoomedOut["scale"]), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(zoomedOut["x"]), 180.5, accuracy: 0.01,
                       "Zooming back out at the same pointer must preserve the original pan")
        XCTAssertEqual(try XCTUnwrap(zoomedOut["y"]), -0.5, accuracy: 0.01)
        try await pinch(1.25)

        // Hit-test the graph where the reader sees it. More movement before this click
        // is sent must carry its hit point along with the same table.
        _ = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            const canvas = doc.getElementById('canvas');
            const bounds = canvas.getBoundingClientRect();
            canvas.setPointerCapture = () => {};
            const input = { pointerId: 1, button: 0, clientX: bounds.left + canvas.clientLeft + 50,
              clientY: bounds.top + canvas.clientTop + 50, bubbles: true };
            canvas.dispatchEvent(new PointerEvent('pointerdown', input));
            canvas.dispatchEvent(new PointerEvent('pointerup', input));
            const start = { ...input, clientX: input.clientX + 100, clientY: input.clientY + 100 };
            const end = { ...start, clientX: start.clientX + 30, clientY: start.clientY + 15 };
            canvas.dispatchEvent(new PointerEvent('pointerdown', start));
            canvas.dispatchEvent(new PointerEvent('pointermove', end));
            canvas.dispatchEvent(new PointerEvent('pointerup', end));
            return true; })()
        """)
        _ = try await browser.evaluateJavaScript("window.releaseFrames(); true")
        try await waitUntil("window.frameRequests.length >= 3", in: browser)
        let nextTransform = try await browser.evaluateJavaScript("window.frameRequests[2][0]") as? [String: Any]
        XCTAssertEqual(nextTransform?["type"] as? String, "transform")
        XCTAssertEqual((nextTransform?["scale"] as? NSNumber)?.doubleValue ?? 0, 1.25, accuracy: 0.001)
        XCTAssertEqual((nextTransform?["tx"] as? NSNumber)?.doubleValue ?? 0, 17.5, accuracy: 0.01)
        XCTAssertEqual((nextTransform?["ty"] as? NSNumber)?.doubleValue ?? 0, 2.5, accuracy: 0.01)
        let click = try await browser.evaluateJavaScript("window.frameRequests[2][1]") as? [String: Any]
        XCTAssertEqual(click?["type"] as? String, "click")
        XCTAssertEqual((click?["x"] as? NSNumber)?.doubleValue ?? 0, 80, accuracy: 0.01)
        XCTAssertEqual((click?["y"] as? NSNumber)?.doubleValue ?? 0, 65, accuracy: 0.01)

        try await waitUntil("window.frameReplies >= 2 && document.getElementById('review').contentDocument.querySelector('img.frame')?.src !== window.initialFrameSrc", in: browser)
        let rebased = try await preview()
        XCTAssertEqual(try XCTUnwrap(rebased["scale"]), 1.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(rebased["x"]), 17.5, accuracy: 0.01,
                       "A late pan frame must preserve the newer zoom and drag without applying the old pan twice")
        XCTAssertEqual(try XCTUnwrap(rebased["y"]), 2.5, accuracy: 0.01)
        _ = try await browser.evaluateJavaScript("window.releaseFrames(); true")
        try await waitUntil("window.frameReplies === 3 && getComputedStyle(document.getElementById('review').contentDocument.querySelector('img.frame')).transform === 'none'", in: browser)
        let settled = try await preview()
        XCTAssertEqual(try XCTUnwrap(settled["x"]), 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(settled["y"]), 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(settled["scale"]), 1, accuracy: 0.001)

        // Respect the renderer's limits before a frame comes back, so zooming at
        // either bound cannot overshoot locally and snap back on the next image.
        try await pinch(100)
        let maximum = try await preview()
        XCTAssertEqual(try XCTUnwrap(maximum["scale"]), 3.84, accuracy: 0.001)
        try await pinch(2)
        let stillMaximum = try await preview()
        XCTAssertEqual(try XCTUnwrap(stillMaximum["scale"]), 3.84, accuracy: 0.001)
        try await pinch(0.000001)
        let minimum = try await preview()
        XCTAssertEqual(try XCTUnwrap(minimum["scale"]), 0.192, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(minimum["x"]), 40.4, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(minimum["y"]), 40.4, accuracy: 0.01)
        try await waitUntil("window.frameRequests.length === 4", in: browser)
        let bounded = try await browser.evaluateJavaScript("window.frameRequests[3][0]") as? [String: Any]
        XCTAssertEqual((bounded?["scale"] as? NSNumber)?.doubleValue ?? 0, 0.192, accuracy: 0.001)
        _ = try await browser.evaluateJavaScript("window.releaseFrames(); true")
        try await waitUntil("window.frameReplies === 4 && getComputedStyle(document.getElementById('review').contentDocument.querySelector('img.frame')).transform === 'none'", in: browser)
    }

    func testSimplifiedViewKeepsOmittedSetNumberingAndExplanation() async throws {
        let html = try XCTUnwrap(MCPAppResources.schemaReviewHTML)
        let escaped = html.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let host = """
        <html><body><script>
        window.addEventListener('message', event => {
          const message = event.data;
          const reply = result => event.source.postMessage({jsonrpc:'2.0', id:message.id, result}, '*');
          if (message.method === 'ui/initialize') reply({hostContext:{theme:'light'}});
          if (message.method === 'tools/call') {
            if (message.params.name === 'studio_review_frame') reply({isError:true,
              content:[{type:'text', text:'Renderer unavailable'}]});
            if (message.params.name === 'studio_review_detail') reply({isError:false, structuredContent:{
              format:'sqlite-graph-studio/schema-review-detail', revision:'test',
              changeSets:[[], ['users'], ...Array.from({length:500}, () => [])], omitted:{changedTables:301}, relations:[],
              tables:[{id:'users', name:'users', kind:'added', columns:[]}]}});
          }
        });
        window.addEventListener('load', () => document.getElementById('review').contentWindow.postMessage({
          jsonrpc:'2.0', method:'ui/notifications/tool-result', params:{isError:false, structuredContent:{
            format:'sqlite-graph-studio/schema-review-view', path:'/tmp/large.sgreview', revision:'test',
            summary:{addedTables:302}, changeSets:[
              {label:'omitted group', tables:301, kind:'added'}, {label:'users', tables:1, kind:'added'}],
            explanations:[{set:1, paragraphs:[[{text:'Users belong to the second change set.'}]]}]
          }}}, '*'), {once:true});
        </script><iframe id="review" style="width:640px;height:600px" srcdoc="\(escaped)"></iframe></body></html>
        """
        let browser = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 600))
        browser.loadHTMLString(host, baseURL: nil)
        try await waitUntil("document.getElementById('review')?.contentDocument?.getElementById('note')?.textContent.includes('301 changed tables not drawn')", in: browser)
        _ = try await browser.evaluateJavaScript("document.getElementById('review').contentDocument.querySelector('#changes summary').click(); true")
        try await waitUntil("document.getElementById('review').contentDocument.getElementById('changes-body').textContent.includes('outside the embedded detail limit')", in: browser)
        _ = try await browser.evaluateJavaScript("document.getElementById('review').contentDocument.getElementById('next').click(); true")
        try await waitUntil("document.getElementById('review').contentDocument.getElementById('changes-body').textContent.includes('Users belong to the second')", in: browser)
        let correctView = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            return doc.getElementById('position').textContent.includes('View 2')
              && doc.getElementById('others').textContent.includes('omitted group')
              && doc.querySelectorAll('#others button').length === 1; })()
        """) as? Bool
        XCTAssertEqual(correctView, true)
        _ = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            for (let i = 0; i < 40; i++) doc.getElementById('next').click();
            return true; })()
        """)
        try await waitUntil("document.getElementById('review').contentDocument.getElementById('position').textContent.includes('View 42') && document.getElementById('review').contentDocument.getElementById('changes-body').textContent.includes('outside the embedded detail limit')", in: browser)
    }

    /// The view sits in a scrolling conversation: scrolling that arrives because the
    /// conversation moved the graph under a still pointer must keep scrolling it. And a
    /// reader who closed a table's details clicks that table to see them again.
    func testScrollingPassesThroughUntilTheGraphIsUsedAndClosedDetailsReopen() async throws {
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
        window.actions = [];
        window.selection = [];
        window.addEventListener("message", event => {
          const message = event.data;
          if (!message || message.jsonrpc !== "2.0") return;
          if (message.method === "ui/initialize") {
            event.source.postMessage({ jsonrpc: "2.0", id: message.id, result: { hostContext: { theme: "light" } } }, "*");
          } else if (message.method === "tools/call" && message.params.name === "studio_review_frame") {
            const args = message.params.arguments;
            for (const action of args.actions || []) {
              window.actions.push(action);
              // Stands in for the renderer: every click here lands on the users table,
              // which the app un-chooses when it is already chosen.
              if (action.type === "click") {
                const chosen = window.selection.length === 1;
                window.selection = chosen && !action.keepChosen ? [] : ["users"];
              }
            }
            event.source.postMessage({ jsonrpc: "2.0", id: message.id, result: {
              isError: false, content: [{ type: "image", mimeType: "image/svg+xml", data: "\(frameData)" }],
              structuredContent: { width: args.width, height: args.height, sets: 1,
                setTables: [["users"]], set: 0, selection: window.selection } } }, "*");
          } else if (message.method === "tools/call" && message.params.name === "studio_review_detail") {
            event.source.postMessage({ jsonrpc: "2.0", id: message.id, result: {
              isError: false, content: [], structuredContent: {
                format: "sqlite-graph-studio/schema-review-detail", revision: "test", changeSets: [["users"]],
                tables: [{ id: "users", name: "users", kind: "modified", objectKind: "table",
                  columns: [{ name: "email", kind: "modified", before: "TEXT NULL", description: "TEXT NOT NULL" }] }],
                relations: [] } } }, "*");
          }
        });
        window.addEventListener("load", () => document.getElementById("review").contentWindow.postMessage({
          jsonrpc: "2.0", method: "ui/notifications/tool-result", params: { isError: false, content: [],
            structuredContent: { format: "sqlite-graph-studio/schema-review-view", path: "/tmp/wheel.sgreview",
              revision: "test", summary: { modifiedTables: 1 },
              changeSets: [{ label: "users", tables: 1, kind: "modified" }] } }
        }, "*"), { once: true });
        </script>
        <iframe id="review" style="display:block;width:640px;height:700px;border:0" srcdoc="\(escaped)"></iframe>
        </body></html>
        """
        let browser = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 700))
        browser.loadHTMLString(host, baseURL: nil)
        try await waitUntil("!!document.getElementById('review')?.contentDocument?.querySelector('img.frame')", in: browser)
        _ = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            const view = doc.defaultView, canvas = doc.getElementById('canvas');
            canvas.setPointerCapture = () => {};
            const bounds = canvas.getBoundingClientRect();
            const at = { clientX: bounds.left + 200, clientY: bounds.top + 150, bubbles: true, cancelable: true };
            window.wheel = (extra = {}) => {
              const event = new view.WheelEvent('wheel', { ...at, deltaX: 0, deltaY: 24.5, deltaMode: 0, ...extra });
              canvas.dispatchEvent(event);
              return event.defaultPrevented;
            };
            window.move = (screenX, screenY) => canvas.dispatchEvent(new view.PointerEvent('pointermove',
              { ...at, pointerId: 1, screenX, screenY }));
            window.leave = () => canvas.dispatchEvent(new view.PointerEvent('pointerleave', { pointerId: 1 }));
            window.click = () => {
              canvas.dispatchEvent(new view.PointerEvent('pointerdown', { ...at, pointerId: 1, button: 0 }));
              canvas.dispatchEvent(new view.PointerEvent('pointerup', { ...at, pointerId: 1, button: 0 }));
            };
            window.detailShown = () => !doc.getElementById('detail').hidden;
            return true; })()
        """)

        func prevented(_ script: String) async throws -> Bool {
            let value = try await browser.evaluateJavaScript(script)
            return try XCTUnwrap(value as? NSNumber).boolValue
        }
        let untouched = try await prevented("window.wheel()")
        XCTAssertFalse(untouched, "Scrolling onto a graph the reader hasn't used scrolls the conversation")
        let stillPointer = try await prevented("window.move(300, 400); window.move(300, 400); window.wheel()")
        XCTAssertFalse(stillPointer, "Moves at the same screen point come from content scrolling under the pointer")
        let pinch = try await prevented("window.wheel({ ctrlKey: true, deltaY: -8 })")
        XCTAssertTrue(pinch, "A pinch always zooms the graph")
        let moved = try await prevented("window.move(312, 404); window.wheel()")
        XCTAssertTrue(moved, "Once the reader moves onto the graph, scrolling moves the graph")
        try await waitUntil("window.actions.some(action => action.type === 'transform' && action.ty < 0)", in: browser)
        let left = try await prevented("window.leave(); window.wheel()")
        XCTAssertFalse(left, "Leaving the graph gives scrolling back to the conversation")

        // Choose users: its details open. A click with them open un-chooses it, as in the app.
        _ = try await browser.evaluateJavaScript("window.click(); true")
        try await waitUntil("window.detailShown() && window.selection.length === 1", in: browser)
        _ = try await browser.evaluateJavaScript("window.click(); true")
        try await waitUntil("!window.detailShown() && window.selection.length === 0", in: browser)
        let clicks = try await browser.evaluateJavaScript("JSON.stringify(window.actions.filter(action => action.type === 'click').map(action => !!action.keepChosen))") as? String
        XCTAssertEqual(clicks, "[true,false]", "Only a click made while details are closed keeps the chosen table")

        // Close the details with the table still chosen; the next click brings them back.
        _ = try await browser.evaluateJavaScript("window.click(); true")
        try await waitUntil("window.detailShown() && window.selection.length === 1", in: browser)
        _ = try await browser.evaluateJavaScript("""
          (() => { const doc = document.getElementById('review').contentDocument;
            doc.dispatchEvent(new doc.defaultView.KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
            return true; })()
        """)
        try await waitUntil("!window.detailShown() && window.selection.length === 1", in: browser)
        _ = try await browser.evaluateJavaScript("window.click(); true")
        try await waitUntil("window.detailShown() && window.selection.length === 1", in: browser)
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
