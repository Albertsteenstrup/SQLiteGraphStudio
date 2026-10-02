import Foundation
import WebKit
import XCTest
@testable import StudioMCP

@MainActor
final class DataEmbeddedViewTests: XCTestCase {
    func testInitializeIdentifiesTheAppUsingTheOfficialAppInfoField() async throws {
        let browser = try host(data: tablePage(), route: ["context_id": "task-one", "table_id": "payments", "limit": 2])
        try await wait("!!window.initializeParams && window.initializeAccepted === true", in: browser)
        let parameters = try await browser.evaluateJavaScript("window.initializeParams") as? [String: Any]
        XCTAssertEqual(parameters?["protocolVersion"] as? String, "2026-01-26")
        let appInfo = parameters?["appInfo"] as? [String: Any]
        XCTAssertEqual(appInfo?["name"] as? String, "SQLite Graph Studio data")
        XCTAssertEqual(appInfo?["version"] as? String, "1.0.0")
        XCTAssertNil(parameters?["clientInfo"], "MCP Apps initialization identifies an app, rather than an MCP client")
        XCTAssertEqual((parameters?["appCapabilities"] as? [String: Any])?["availableDisplayModes"] as? [String], ["inline"])
        try await wait("gridDocument()?.getElementById('title').textContent === 'Payments'", in: browser)
    }

    func testGridPreservesDuplicateColumnsExactValuesAndLiteralDatabaseText() async throws {
        let data: [String: Any] = [
            "format": "sqlite-graph-studio/data-view", "kind": "query", "title": "Captured values",
            "result_id": "result:one", "workspace_id": "workspace-one", "offset": 0, "page_size": 1,
            "row_count": 1, "has_more": false, "source_truncated": true, "executed_sql": "SELECT values FROM source",
            "columns": [["id": 0, "name": "value"], ["id": 1, "name": "value"],
                        ["id": 2, "name": "amount"], ["id": 3, "name": "memo"], ["id": 4, "name": "bytes"]],
            "rows": [["values": [["type": "null", "value": NSNull()], ["type": "text", "value": "NULL"],
                                   ["type": "numeric", "value": "9007199254740993.00"],
                                   ["type": "text", "value": "<img src=x onerror=alert('unsafe')></script>", "truncated": true],
                                   ["type": "blob", "value": NSNull(), "byte_count": 128]]]],
        ]
        let browser = try host(data: data, route: ["context_id": "task-one", "result_id": "result:one", "limit": 1])
        try await wait("gridDocument()?.querySelectorAll('#rows .cell').length === 5", in: browser)
        let labels = try await browser.evaluateJavaScript("Array.from(gridDocument().querySelectorAll('#head th')).map(node => node.textContent)") as? [String]
        XCTAssertEqual(labels, ["Row", "value", "value", "amount", "memo", "bytes"])
        let values = try await browser.evaluateJavaScript("Array.from(gridDocument().querySelectorAll('#rows .cell')).map(node => node.textContent)") as? [String]
        XCTAssertEqual(values, ["NULL", "NULL", "9007199254740993.00", "<img src=x onerror=alert('unsafe')></script>", "Binary · 128 bytes"])
        let safe = try await browser.evaluateJavaScript("gridDocument().querySelectorAll('#grid img, #grid script').length === 0 && gridDocument().querySelectorAll('.cell.special').length === 2") as? Bool
        XCTAssertEqual(safe, true, "SQL NULL and binary are styled separately from the text NULL")
        let scope = try await browser.evaluateJavaScript("gridDocument().getElementById('warning').textContent") as? String
        XCTAssertTrue(scope?.contains("Partial query result") == true)
        let sql = try await browser.evaluateJavaScript("gridDocument().getElementById('selection-text').textContent") as? String
        XCTAssertEqual(sql, "SELECT values FROM source")
        _ = try await browser.evaluateJavaScript("gridDocument().querySelectorAll('#rows .cell')[3].click(); true")
        try await wait("!gridDocument().getElementById('detail').hidden", in: browser)
        let detail = try await browser.evaluateJavaScript("gridDocument().getElementById('detail-value').textContent") as? String
        XCTAssertEqual(detail, values?[3])
        let partial = try await browser.evaluateJavaScript("gridDocument().getElementById('detail-note').textContent.includes('Partial value')") as? Bool
        XCTAssertEqual(partial, true)
        _ = try await browser.evaluateJavaScript("(() => { const doc = gridDocument(); doc.dispatchEvent(new doc.defaultView.KeyboardEvent('keydown', {key:'Escape', bubbles:true})); return true; })()")
        try await wait("gridDocument().getElementById('detail').hidden", in: browser)
        let callCount = try await browser.evaluateJavaScript("window.calls.length") as? Int
        XCTAssertEqual(callCount, 0)
    }

    func testPagingKeepsTheExactSelectionAndRetainsTheLastPageOnSourceFailure() async throws {
        let route: [String: Any] = ["context_id": "task-one", "workspace_id": "workspace-one", "table_id": "payments",
                                    "source_id": "sqlite:/one", "source_revision": "revision-one", "limit": 2,
                                    "column_ids": ["amount"], "filters": [["column_name": "amount", "comparison": "greaterThan", "value": "5"]],
                                    "sort": [["column_name": "amount", "direction": "descending"]]]
        let browser = try host(data: tablePage(), route: route, onCall: """
          const args = message.params.arguments;
          const result = window.fail
            ? { isError:true, content:[], structuredContent:{ error:{ code:'STALE_SOURCE', message:'The source changed.' } } }
            : { isError:false, content:[], structuredContent:{ ...window.initial, offset:args.offset,
                has_more:args.offset === 0, rows:[{values:[{type:'integer',value:String(10 + args.offset)}]},
                                               {values:[{type:'integer',value:String(9 + args.offset)}]}] },
                _meta:{ dataView:{ arguments:args } } };
          event.source.postMessage({jsonrpc:'2.0',id:message.id,result}, '*');
        """)
        try await wait("gridDocument()?.getElementById('position').textContent.includes('Rows 1–2')", in: browser)
        _ = try await browser.evaluateJavaScript("gridDocument().getElementById('next').click(); true")
        try await wait("gridDocument().getElementById('position').textContent.includes('Rows 3–4') && !gridDocument().getElementById('prev').disabled", in: browser)
        let args = try await browser.evaluateJavaScript("window.calls[0].arguments") as? [String: Any]
        XCTAssertEqual(args?["context_id"] as? String, "task-one")
        XCTAssertEqual(args?["workspace_id"] as? String, "workspace-one")
        XCTAssertEqual(args?["source_id"] as? String, "sqlite:/one")
        XCTAssertEqual(args?["source_revision"] as? String, "revision-one")
        XCTAssertEqual(args?["offset"] as? Int, 2)
        XCTAssertEqual(args?["column_ids"] as? [String], ["amount"])
        XCTAssertEqual((args?["filters"] as? [[String: String]])?.first?["value"], "5")
        let lastPage = try await browser.evaluateJavaScript("gridDocument().getElementById('next').disabled") as? Bool
        XCTAssertEqual(lastPage, true)
        _ = try await browser.evaluateJavaScript("gridDocument().getElementById('prev').click(); true")
        try await wait("window.calls.length === 2 && gridDocument().getElementById('position').textContent.includes('Rows 1–2')", in: browser)
        _ = try await browser.evaluateJavaScript("window.fail = true; gridDocument().getElementById('reload').click(); true")
        try await wait("gridDocument().getElementById('status').textContent.includes('The source changed.')", in: browser)
        let retainedValue = try await browser.evaluateJavaScript("gridDocument().querySelector('#rows .cell').textContent") as? String
        let blocked = try await browser.evaluateJavaScript("gridDocument().getElementById('next').disabled && gridDocument().getElementById('reload').disabled") as? Bool
        XCTAssertEqual(retainedValue, "10")
        XCTAssertEqual(blocked, true)
        let names = try await browser.evaluateJavaScript("window.calls.map(call => call.name)") as? [String]
        XCTAssertEqual(names, ["studio_data_page", "studio_data_page", "studio_data_page"])
    }

    func testAReplacementResultSupersedesAnOutstandingPageAndSavedRowsRemainReadable() async throws {
        let browser = try host(data: tablePage(), route: ["context_id": "task-one", "table_id": "payments", "limit": 2], onCall: """
          window.delayedReply = () => event.source.postMessage({jsonrpc:'2.0',id:message.id,
            result:{isError:false,content:[],structuredContent:{...window.initial,title:'Old delayed page'},
                    _meta:{dataView:{arguments:message.params.arguments}}}}, '*');
        """)
        try await wait("gridDocument()?.getElementById('title').textContent === 'Payments'", in: browser)
        _ = try await browser.evaluateJavaScript("gridDocument().getElementById('next').click(); true")
        try await wait("window.calls.length === 1", in: browser)
        _ = try await browser.evaluateJavaScript("window.sendResult({...window.initial,title:'New selection'}, {context_id:'task-new',table_id:'payments',limit:2}); true")
        try await wait("gridDocument().getElementById('title').textContent === 'New selection'", in: browser)
        _ = try await browser.evaluateJavaScript("window.delayedReply(); true")
        try await Task.sleep(for: .milliseconds(100))
        let title = try await browser.evaluateJavaScript("gridDocument().getElementById('title').textContent") as? String
        XCTAssertEqual(title, "New selection")
        _ = try await browser.evaluateJavaScript("window.sendResult({...window.initial,title:'Saved page'}, null); true")
        try await wait("gridDocument().getElementById('title').textContent === 'Saved page'", in: browser)
        let saved = try await browser.evaluateJavaScript("gridDocument().getElementById('reload').disabled && gridDocument().querySelectorAll('#rows tr').length === 2") as? Bool
        XCTAssertEqual(saved, true)
    }

    private func tablePage() -> [String: Any] {
        ["format": "sqlite-graph-studio/data-view", "kind": "table", "title": "Payments", "table_id": "payments",
         "workspace_id": "workspace-one", "source_id": "sqlite:/one", "source_revision": "revision-one",
         "offset": 0, "page_size": 2, "has_more": true, "columns": ["amount"],
         "rows": [["values": [["type": "integer", "value": "10"]]], ["values": [["type": "integer", "value": "9"]]]]]
    }

    private func host(data: [String: Any], route: [String: Any], onCall: String = "") throws -> WKWebView {
        let html = try XCTUnwrap(MCPAppResources.dataHTML)
        let escaped = html.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        func literal(_ value: [String: Any]) throws -> String {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            return text.replacingOccurrences(of: "<", with: "\\u003c")
        }
        let host = """
        <!doctype html><html><body><script>
        window.initial = \(try literal(data)); window.route = \(try literal(route)); window.calls = [];
        window.gridDocument = () => document.getElementById('data')?.contentDocument;
        window.sendResult = (data,args) => document.getElementById('data').contentWindow.postMessage({
          jsonrpc:'2.0',method:'ui/notifications/tool-result',params:{isError:false,content:[],structuredContent:data,
            ...(args ? {_meta:{dataView:{arguments:args}}} : {})}}, '*');
        window.addEventListener('message', event => {
          const message = event.data;
          if (!message || message.jsonrpc !== '2.0') return;
          if (message.method === 'ui/initialize') {
            window.initializeParams=message.params;
            window.initializeAccepted=!!message.params.appInfo?.name && !!message.params.appInfo?.version && !message.params.clientInfo;
            event.source.postMessage(window.initializeAccepted
              ? {jsonrpc:'2.0',id:message.id,result:{hostContext:{theme:'light'}}}
              : {jsonrpc:'2.0',id:message.id,error:{code:-32602,message:'ui/initialize requires appInfo'}}, '*');
          }
          if (message.method === 'tools/call') { window.calls.push(message.params); \(onCall) }
        });
        window.addEventListener('load', () => window.sendResult(window.initial,window.route), {once:true});
        </script><iframe id="data" style="width:640px;height:600px;border:0" srcdoc="\(escaped)"></iframe></body></html>
        """
        let browser = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 600))
        browser.loadHTMLString(host, baseURL: nil)
        return browser
    }

    private func wait(_ expression: String, in browser: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let result = try? await browser.evaluateJavaScript(expression), (result as? NSNumber)?.boolValue == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let diagnostic = (try? await browser.evaluateJavaScript("gridDocument()?.getElementById('status')?.textContent")) ?? "No loaded view"
        XCTFail("Data view did not reach: \(expression). \(diagnostic)")
        throw Timeout()
    }

    private struct Timeout: Error {}
}
