import Foundation
import WebKit
import XCTest
@testable import StudioMCP

@MainActor
final class WorkspaceEmbeddedViewTests: XCTestCase {
    func testInitialViewportPreparationRetriesWithoutAnotherToolResultNotification() async throws {
        let browser = try host(onCall: """
          const first=window.calls.length===1;
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:first
            ? {isError:true,content:[],structuredContent:{error:{code:'VIEW_NOT_RENDERED',message:'Initial graph is preparing.'}}}
            : window.initial}, '*');
        """, setup: """
          window.initial.structuredContent.render_surface='graph';
          window.initial.structuredContent.graph={width:1000,height:440,zoom:1,min_zoom:.12,max_zoom:2.4};
        """)
        try await wait("doc()?.getElementById('status').textContent.includes('Initial graph is preparing.')", browser)
        let hidden = try await browser.evaluateJavaScript("doc().getElementById('frame').hidden") as? Bool
        XCTAssertEqual(hidden, true, "This failure must occur before the first frame or metadata is installed")
        try await Task.sleep(for: .milliseconds(150))
        let immediateCalls = try await browser.evaluateJavaScript("window.calls.length") as? Int
        XCTAssertEqual(immediateCalls, 1, "Preparation retries must use reconnect backoff instead of a busy loop")
        try await wait("!doc().getElementById('frame').hidden && !doc().getElementById('fit').disabled && doc().getElementById('status').textContent===''", browser)
        let recovered = try await browser.evaluateJavaScript("window.calls.length>=2 && !window.calls.some(x=>x.arguments.inline_view_state==='released')") as? Bool
        XCTAssertEqual(recovered, true, "An initial mount must reconnect without requiring another host notification")
        let route = try await browser.evaluateJavaScript("window.calls[1].arguments") as? [String: Any]
        XCTAssertEqual(route?["context_id"] as? String, "my-context")
        XCTAssertEqual(route?["viewer_id"] as? String, "my-viewer")
        XCTAssertEqual(route?["source_revision"] as? String, "my-source-revision")
    }

    func testInitialRecoveryTimerStopsWhenTheHostTearsDownTheView() async throws {
        let browser = try host(onCall: """
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:{isError:true,content:[],
            structuredContent:{error:{code:'VIEW_NOT_RENDERED',message:'Initial graph is preparing.'}}}}, '*');
        """, setup: """
          window.initial.structuredContent.render_surface='graph';
          window.initial.structuredContent.graph={width:1000,height:440,zoom:1,min_zoom:.12,max_zoom:2.4};
        """)
        try await wait("doc()?.getElementById('status').textContent.includes('Initial graph is preparing.')", browser)
        _ = try await browser.evaluateJavaScript("document.getElementById('workspace').contentWindow.postMessage({jsonrpc:'2.0',id:999,method:'ui/resource-teardown',params:{}},'*'); true")
        try await wait("window.calls.some(x=>x.arguments.inline_view_state==='released')", browser)
        try await Task.sleep(for: .milliseconds(2300))
        let reads = try await browser.evaluateJavaScript("window.calls.filter(x=>!x.arguments.inline_view_state).length") as? Int
        XCTAssertEqual(reads, 1, "A queued mount retry must never revive a torn-down viewer")
    }

    func testActualBridgeTransportFailureRetainsTheFrameAndResumesPolling() async throws {
        let browser = try host(onCall: """
          if(window.failBridge && !window.bridgeErrorSent) {
            window.bridgeErrorSent=true;
            event.source.postMessage({jsonrpc:'2.0',id:m.id,result:{isError:true,content:[],
              structuredContent:{error:{code:'APP_BRIDGE_UNAVAILABLE',message:'Bridge temporarily unavailable.'}}}}, '*');
          } else {
            if(window.bridgeErrorSent) {
              window.initial.structuredContent.frame_revision='bridge-recovered';
              window.initial.content[0].data=window.secondImage;
            }
            event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
          }
        """, setup: """
          window.failBridge=false; window.bridgeErrorSent=false;
          window.initial.structuredContent.render_surface='graph';
          window.initial.structuredContent.graph={width:700,height:440,zoom:1,min_zoom:.12,max_zoom:2.4};
        """)
        try await wait("doc()?.getElementById('fit').disabled===false", browser)
        let original = try await browser.evaluateJavaScript("doc().getElementById('frame').src") as? String
        _ = try await browser.evaluateJavaScript("window.failBridge=true; true")
        try await wait("doc().getElementById('status').textContent.includes('Bridge temporarily unavailable.')", browser)
        let retained = try await browser.evaluateJavaScript("doc().getElementById('frame').src") as? String
        XCTAssertEqual(retained, original, "A transient socket failure must keep the last visible evidence intact")
        try await wait("doc().getElementById('frame').src.endsWith(window.secondImage) && doc().getElementById('status').textContent==='' && !doc().getElementById('fit').disabled", browser)
        let routes = try await browser.evaluateJavaScript("window.calls.every(x=>x.arguments.context_id==='my-context' && x.arguments.viewer_id==='my-viewer' && x.arguments.source_revision==='my-source-revision') && !window.calls.some(x=>x.arguments.inline_view_state==='released')") as? Bool
        XCTAssertEqual(routes, true, "Recovery must preserve the pinned viewer and source")
    }

    func testAppShortcutSelectsThePinnedWorkspaceBeforeBringingTheAppForward() async throws {
        let browser = try host(onCall: """
          if(m.params.name==='studio_update_workspace') window.activation={source:event.source,id:m.id};
          else event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
        """, presentation: true, stripMetadata: true)
        try await wait("doc()?.getElementById('open-app').disabled===false", browser)
        _ = try await browser.evaluateJavaScript("doc().getElementById('open-app').click(); doc().getElementById('open-app').click(); true")
        try await wait("!!window.activation", browser)
        let selections = try await browser.evaluateJavaScript("window.calls.filter(x=>x.name==='studio_update_workspace').length") as? Int
        XCTAssertEqual(selections, 1, "Repeated clicks must not issue another selection while opening")
        let beforeSelection = try await browser.evaluateJavaScript("window.calls.some(x=>x.name==='studio_launch')") as? Bool
        XCTAssertEqual(beforeSelection, false, "The app must not be brought forward before validating this card's workspace")
        let arguments = try await browser.evaluateJavaScript("window.calls.find(x=>x.name==='studio_update_workspace').arguments") as? [String: Any]
        XCTAssertEqual(arguments?["context_id"] as? String, "my-context")
        XCTAssertEqual(arguments?["workspace_id"] as? String, "my-workspace")
        XCTAssertEqual(arguments?["source_id"] as? String, "sqlite:/sample")
        XCTAssertEqual(arguments?["source_revision"] as? String, "my-source-revision")
        XCTAssertEqual((arguments?["changes"] as? [String: Any])?["activate"] as? Bool, true)
        XCTAssertFalse((arguments?["request_id"] as? String ?? "").isEmpty)
        _ = try await browser.evaluateJavaScript("window.activation.source.postMessage({jsonrpc:'2.0',id:window.activation.id,result:{isError:false,content:[],structuredContent:{}}},'*'); true")
        try await wait("window.calls.some(x=>x.name==='studio_launch') && !doc().getElementById('open-app').disabled", browser)
        let launch = try await browser.evaluateJavaScript("window.calls.find(x=>x.name==='studio_launch').arguments") as? [String: Any]
        XCTAssertEqual(launch?["foreground_intent"] as? Bool, true)
        let changedStep = try await browser.evaluateJavaScript("window.calls.some(x=>x.name==='studio_control_presentation')") as? Bool
        XCTAssertEqual(changedStep, false, "Opening the app must preserve the explanation's step")
    }

    func testAppShortcutDoesNotBringTheAppForwardWhenThePinnedSourceIsObsolete() async throws {
        let browser = try host(onCall: """
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:m.params.name==='studio_update_workspace'
            ? {isError:true,content:[],structuredContent:{error:{code:'STALE_SOURCE',message:'This source changed.'}}}
            : window.initial}, '*');
        """)
        try await wait("doc()?.getElementById('open-app').disabled===false", browser)
        _ = try await browser.evaluateJavaScript("doc().getElementById('open-app').click(); true")
        try await wait("window.calls.some(x=>x.name==='studio_update_workspace') && !doc().getElementById('open-app').disabled && doc().getElementById('status').textContent.includes('This source changed.')", browser)
        let launched = try await browser.evaluateJavaScript("window.calls.some(x=>x.name==='studio_launch')") as? Bool
        XCTAssertEqual(launched, false)
    }

    func testGraphFirstLayoutShowsOnlyRequestedRowsWithoutCoercingOrExecutingCellText() async throws {
        let browser = try host(onCall: """
          window.initial.structuredContent.data_view=window.rowsRequested?{
            title:'posts',offset:0,historical:true,columns:[{name:'id',type:'INTEGER'},{name:'editor_id',type:'INTEGER'},{name:'title',type:'TEXT'},{name:'secret',type:'TEXT'}],
            rows:[{index:0,values:[{type:'integer',value:'9007199254740993'},{type:'null',value:null},{type:'text',value:'<img src=x onerror=alert(1)>'},{type:'redacted',value:null}]}],has_more:true
          }:null;
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
        """, presentation: true, setup: """
          window.initial.structuredContent.render_surface='graph';
          window.initial.structuredContent.active_table='posts';
          window.initial.structuredContent.graph={width:700,height:440,zoom:1,min_zoom:.12,max_zoom:2.4};
          window.rowsRequested=false;
        """)
        try await wait("doc()?.getElementById('frame').hidden===false && doc().getElementById('data-panel').hidden", browser)
        let graphWidth = try await browser.evaluateJavaScript("doc().getElementById('canvas').clientWidth") as? Double
        _ = try await browser.evaluateJavaScript("window.rowsRequested=true; true")
        try await wait("!doc().getElementById('data-panel').hidden && doc().getElementById('data-rows').textContent.includes('9007199254740993') && doc().getElementById('surface').getAttribute('aria-busy')==='false'", browser)
        let grid = try await browser.evaluateJavaScript("doc().getElementById('data-rows').textContent") as? String
        XCTAssertTrue(grid?.contains("NULL") == true)
        XCTAssertTrue(grid?.contains("Redacted") == true)
        let provenance = try await browser.evaluateJavaScript("doc().getElementById('data-note').textContent") as? String
        XCTAssertTrue(provenance?.contains("Captured data") == true)
        XCTAssertTrue(grid?.contains("<img src=x onerror=alert(1)>") == true)
        let injected = try await browser.evaluateJavaScript("!!doc().getElementById('data-rows').querySelector('img')") as? Bool
        XCTAssertEqual(injected, false)
        let reducedWidth = try await browser.evaluateJavaScript("doc().getElementById('canvas').clientWidth") as? Double
        XCTAssertLessThan(try XCTUnwrap(reducedWidth), try XCTUnwrap(graphWidth))
        _ = try await browser.evaluateJavaScript("window.rowsRequested=false; true")
        try await wait("doc().getElementById('data-panel').hidden && doc().getElementById('data-rows').children.length===0 && doc().getElementById('surface').getAttribute('aria-busy')==='false'", browser)
    }

    func testGraphGesturesPreviewImmediatelyAndUseThePinnedConnection() async throws {
        let browser = try host(onCall: """
          if(m.params.arguments.graph_actions)window.heldGraph={source:event.source,id:m.id};
          else event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
        """, presentation: true, setup: """
          window.initial.structuredContent.render_surface='graph';
          window.initial.structuredContent.graph={width:700,height:440,zoom:1,min_zoom:.12,max_zoom:2.4};
        """)
        try await wait("doc()?.getElementById('fit').disabled===false", browser)
        _ = try await browser.evaluateJavaScript("doc().getElementById('canvas').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true})); true")
        let preview = try await browser.evaluateJavaScript("doc().getElementById('frame').style.transform") as? String
        XCTAssertTrue(preview?.contains("30") == true, "The graph must move before the native frame request finishes")
        try await wait("!!window.heldGraph", browser)
        let route = try await browser.evaluateJavaScript("window.calls.find(x=>x.arguments.graph_actions).arguments") as? [String: Any]
        XCTAssertEqual(route?["context_id"] as? String, "my-context")
        XCTAssertEqual(route?["workspace_id"] as? String, "my-workspace")
        XCTAssertEqual(route?["source_revision"] as? String, "my-source-revision")
        XCTAssertEqual(route?["render_surface"] as? String, "graph")
        _ = try await browser.evaluateJavaScript("doc().getElementById('next').click(); true")
        try await wait("window.calls.some(x=>x.name==='studio_control_presentation')", browser)
        let reset = try await browser.evaluateJavaScript("doc().getElementById('frame').style.transform") as? String
        XCTAssertEqual(reset, "matrix(1, 0, 0, 1, 0, 0)")
    }

    func testInspectionRemainsInteractiveAfterSelectionChangesTheExplanationView() async throws {
        let browser = try host(onCall: """
          if(m.params.arguments.graph_actions) {
            Object.assign(window.initial.structuredContent.presentation,{view_ready:false,needs_view_replay:true});
            window.initial.structuredContent.frame_revision='inspecting';
          }
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
        """, presentation: true, setup: """
          window.initial.structuredContent.render_surface='graph';
          window.initial.structuredContent.graph={width:700,height:440,zoom:1,min_zoom:.12,max_zoom:2.4,
            nodes:[{table_id:'evidence_claim',x:100,y:100,width:200,height:60,center_x:500,center_y:600}]};
        """)
        try await wait("doc()?.getElementById('fit').disabled===false", browser)
        _ = try await browser.evaluateJavaScript("""
          (()=>{const d=doc(), c=d.getElementById('canvas'), r=c.getBoundingClientRect();
            c.setPointerCapture=()=>{};
            const p={pointerId:1,button:0,clientX:r.left+c.clientLeft+150,clientY:r.top+c.clientTop+120,bubbles:true};
            c.dispatchEvent(new d.defaultView.PointerEvent('pointerdown',p));
            c.dispatchEvent(new d.defaultView.PointerEvent('pointerup',p)); return true;})()
        """)
        try await wait("window.calls.some(x=>x.arguments.graph_actions?.some(a=>a.type==='select')) && doc().getElementById('following').textContent==='Exploring graph'", browser)
        let selected = try await browser.evaluateJavaScript("window.calls.flatMap(x=>x.arguments.graph_actions || []).find(a=>a.type==='select').table_id") as? String
        XCTAssertEqual(selected, "evidence_claim")
        let enabled = try await browser.evaluateJavaScript("!doc().getElementById('fit').disabled && !doc().getElementById('restore').hidden") as? Bool
        XCTAssertEqual(enabled, true, "Inspecting a step must not lock its nodes and camera")
        _ = try await browser.evaluateJavaScript("""
          (()=>{const d=doc(), c=d.getElementById('canvas'), r=c.getBoundingClientRect();
            c.dispatchEvent(new d.defaultView.MouseEvent('dblclick',{button:0,clientX:r.left+c.clientLeft+150,clientY:r.top+c.clientTop+120,bubbles:true})); return true;})()
        """)
        try await wait("window.calls.some(x=>x.arguments.graph_actions?.some(a=>a.type==='expand' && a.table_id==='evidence_claim'))", browser)
        _ = try await browser.evaluateJavaScript("doc().getElementById('canvas').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true})); true")
        try await wait("window.calls.some(x=>x.arguments.graph_actions?.some(a=>a.type==='transform'))", browser)
    }

    func testNodeDraggingMovesItsModelCenterInsteadOfPanningTheGraph() async throws {
        let browser = try host(onCall: """
          if(m.params.arguments.graph_actions)window.heldMove={source:event.source,id:m.id};
          else event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
        """, presentation: true, setup: """
          window.initial.structuredContent.render_surface='graph';
          window.initial.structuredContent.graph={width:700,height:440,zoom:.5,min_zoom:.12,max_zoom:2.4,
            nodes:[{table_id:'evidence_claim',x:100,y:100,width:150,height:60,center_x:1000,center_y:2000}]};
        """)
        try await wait("doc()?.getElementById('fit').disabled===false", browser)
        let preview = try await browser.evaluateJavaScript("""
          (()=>{const d=doc(), c=d.getElementById('canvas'), r=c.getBoundingClientRect();
            c.setPointerCapture=()=>{};
            const p={pointerId:1,button:0,clientX:r.left+c.clientLeft+150,clientY:r.top+c.clientTop+120,bubbles:true};
            const end={...p,clientX:p.clientX+30,clientY:p.clientY-15};
            c.dispatchEvent(new d.defaultView.PointerEvent('pointerdown',p));
            c.dispatchEvent(new d.defaultView.PointerEvent('pointermove',end));
            const ghost=d.getElementById('node-drag');
            const preview={visible:!ghost.hidden,x:parseFloat(ghost.style.left),y:parseFloat(ghost.style.top)};
            c.dispatchEvent(new d.defaultView.PointerEvent('pointerup',end)); return preview;})()
        """) as? [String: Any]
        XCTAssertEqual(preview?["visible"] as? Bool, true, "The dragged table must follow the pointer before the native reply")
        XCTAssertEqual(try XCTUnwrap((preview?["x"] as? NSNumber)?.doubleValue), 130, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap((preview?["y"] as? NSNumber)?.doubleValue), 85, accuracy: 0.01)
        try await wait("!!window.heldMove", browser)
        let actions = try await browser.evaluateJavaScript("window.calls.flatMap(x=>x.arguments.graph_actions || [])") as? [[String: Any]]
        let move = try XCTUnwrap(actions?.first)
        XCTAssertEqual(move["type"] as? String, "move")
        XCTAssertEqual(move["table_id"] as? String, "evidence_claim")
        XCTAssertEqual(try XCTUnwrap((move["x"] as? NSNumber)?.doubleValue), 1060, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap((move["y"] as? NSNumber)?.doubleValue), 1970, accuracy: 0.01)
        XCTAssertEqual(actions?.count, 1, "A node drag must not also pan the camera")
    }

    func testZoomReplacesItsTemporaryBitmapPreviewWithTheFreshNativeFrame() async throws {
        let browser = try host(onCall: """
          if(m.params.arguments.graph_actions)window.heldZoom={source:event.source,id:m.id};
          else event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
        """, presentation: true, setup: """
          window.initial.structuredContent.render_surface='graph';
          window.initial.structuredContent.graph={width:700,height:440,zoom:1,min_zoom:.12,max_zoom:2.4};
        """)
        try await wait("doc()?.getElementById('fit').disabled===false", browser)
        _ = try await browser.evaluateJavaScript("doc().getElementById('canvas').dispatchEvent(new KeyboardEvent('keydown',{key:'+',bubbles:true})); true")
        let preview = try await browser.evaluateJavaScript("doc().getElementById('frame').style.transform") as? String
        XCTAssertTrue(preview?.contains("1.15") == true)
        try await wait("!!window.heldZoom", browser)
        _ = try await browser.evaluateJavaScript("""
          Object.assign(window.initial.structuredContent.graph,{zoom:1.15});
          window.initial.structuredContent.frame_revision='zoomed-native';
          window.initial.content[0].data=window.secondImage;
          window.heldZoom.source.postMessage({jsonrpc:'2.0',id:window.heldZoom.id,result:window.initial},'*'); true
        """)
        try await wait("doc().getElementById('frame').src.endsWith(window.secondImage) && doc().getElementById('frame').style.transform==='matrix(1, 0, 0, 1, 0, 0)'", browser)
        let unstretched = try await browser.evaluateJavaScript("Math.abs(doc().getElementById('frame').getBoundingClientRect().width-doc().getElementById('canvas').clientWidth)<1") as? Bool
        XCTAssertEqual(unstretched, true, "The settled zoom must use newly drawn native pixels, with no leftover CSS enlargement")
    }

    func testFullModelContextCanBeReturnedToDetailDuringManualInspection() async throws {
        let browser = try host(onCall: """
          if(m.params.arguments.graph_actions?.some(a=>a.type==='context')) {
            window.initial.structuredContent.graph.context_mode=!window.initial.structuredContent.graph.context_mode;
            Object.assign(window.initial.structuredContent.presentation,{view_ready:false,needs_view_replay:true});
            window.initial.structuredContent.frame_revision=window.initial.structuredContent.graph.context_mode?'context':'detail';
          }
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
        """, presentation: true, setup: """
          window.initial.structuredContent.render_surface='graph';
          window.initial.structuredContent.graph={width:700,height:440,zoom:1,min_zoom:.12,max_zoom:2.4,nodes:[],context_mode:false};
        """)
        try await wait("doc()?.getElementById('context').hidden===false && doc().getElementById('context').disabled===false", browser)
        _ = try await browser.evaluateJavaScript("doc().getElementById('context').click(); true")
        try await wait("doc().getElementById('context').textContent==='Return to detail' && !doc().getElementById('context').disabled", browser)
        _ = try await browser.evaluateJavaScript("doc().getElementById('context').click(); true")
        try await wait("doc().getElementById('context').textContent==='Show in full model' && window.calls.flatMap(x=>x.arguments.graph_actions || []).filter(a=>a.type==='context').length===2", browser)
    }

    func testCaptionsAndPreparingErrorsDoNotResizeTheConversationCard() async throws {
        let browser = try host(onCall: """
          if(window.preparing)event.source.postMessage({jsonrpc:'2.0',id:m.id,result:{isError:true,content:[],
            structuredContent:{error:{code:'VIEW_NOT_RENDERED',message:'The graph is preparing.'}}}}, '*');
          else {
            if(window.longCaption)window.initial.structuredContent.presentation.current_caption='A long evidence explanation. '.repeat(50);
            event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
          }
        """, presentation: true)
        try await wait("doc()?.getElementById('following').textContent==='Ready' && window.sizes.length>0", browser)
        let originalSize = try await browser.evaluateJavaScript("window.sizes.at(-1)") as? [String: Int]
        let originalCount = try await browser.evaluateJavaScript("window.sizes.length") as? Int
        _ = try await browser.evaluateJavaScript("window.longCaption=true; true")
        try await wait("doc().getElementById('caption').textContent.length>500", browser)
        _ = try await browser.evaluateJavaScript("window.preparing=true; true")
        try await wait("doc().getElementById('status').textContent.includes('The graph is preparing.')", browser)
        let finalSize = try await browser.evaluateJavaScript("window.sizes.at(-1)") as? [String: Int]
        let finalCount = try await browser.evaluateJavaScript("window.sizes.length") as? Int
        XCTAssertEqual(finalSize, originalSize)
        XCTAssertEqual(finalCount, originalCount, "Unchanged card geometry must not repeatedly notify a scrolling host")
        let retainedText = try await browser.evaluateJavaScript("doc().getElementById('caption').scrollHeight>doc().getElementById('caption').clientHeight") as? Bool
        XCTAssertEqual(retainedText, true, "Long captions must remain inspectable inside the fixed caption area")
    }

    func testDecodedPointIsConfirmedImmediatelyWithoutWaitingForAnotherImage() async throws {
        let browser = try host(onCall: """
          if (m.params.arguments.inline_view_state==='acknowledged') {
            window.initial.structuredContent.presentation.point_visible=true;
            window.initial.structuredContent.presentation.status='waiting_for_next';
            event.source.postMessage({jsonrpc:'2.0',id:m.id,result:{isError:false,content:[],structuredContent:{
              ...window.initial.structuredContent,frame_acknowledged:true}}}, '*');
          } else event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
        """, presentation: true, setup: "window.initial.structuredContent.presentation.point_visible=false;")
        try await wait("window.calls.some(x=>x.arguments.inline_view_state==='acknowledged')", browser)
        let receipt = try await browser.evaluateJavaScript("window.calls.find(x=>x.arguments.inline_view_state==='acknowledged').arguments") as? [String: Any]
        XCTAssertEqual(receipt?["after_frame_revision"] as? String, "one")
        XCTAssertEqual(receipt?["rendered_point_id"] as? String, "author")
        let firstOperation = try await browser.evaluateJavaScript("window.calls[0].arguments.inline_view_state") as? String
        XCTAssertEqual(firstOperation, "acknowledged", "Visibility confirmation must precede a second full frame read")
        try await wait("doc().getElementById('following').textContent==='Ready'", browser)
        _ = try await browser.evaluateJavaScript("doc().getElementById('next').click(); true")
        try await wait("window.calls.some(x=>x.name==='studio_control_presentation' && x.arguments.control==='next')", browser)
    }

    func testFinalStepAllowsBackWithoutPlaybackOrEndControls() async throws {
        let browser = try host(onCall: """
          if(m.params.name==='studio_control_presentation') {
            window.initial.structuredContent.presentation.point_number=1;
            window.initial.structuredContent.presentation.can_go_back=false;
            window.initial.structuredContent.presentation.can_go_forward=true;
          }
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
        """, presentation: true, setup: """
          Object.assign(window.initial.structuredContent.presentation,{status:'waiting_for_next',point_number:2,point_count:2,can_go_back:true,can_go_forward:false});
        """)
        try await wait("doc()?.getElementById('position').textContent==='2/2'", browser)
        let final = try await browser.evaluateJavaScript("doc().getElementById('next').disabled && !doc().getElementById('back').disabled && !doc().getElementById('pause') && !doc().getElementById('end')") as? Bool
        XCTAssertEqual(final,true)
        _ = try await browser.evaluateJavaScript("doc().getElementById('back').click(); true")
        try await wait("window.calls.some(x=>x.name==='studio_control_presentation' && x.arguments.control==='back')", browser)
        try await wait("doc().getElementById('position').textContent==='1/2' && doc().getElementById('back').disabled && !doc().getElementById('next').disabled", browser)
    }

    func testHostWithoutPrivateMetadataStillFollowsAndAdvancesTheNativeFrame() async throws {
        let browser = try host(onCall: """
          if (m.params.name === 'studio_control_presentation') {
            window.initial.structuredContent.presentation.current_point_id='editor';
            window.initial.structuredContent.presentation.current_caption='An editor is optional.';
            window.initial.structuredContent.frame_revision='editor-frame';
            window.initial.content[0].data=window.secondImage;
          }
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
        """, presentation: true, stripMetadata: true)
        try await wait("window.calls.some(x => x.arguments.rendered_point_id==='author')", browser)
        _ = try await browser.evaluateJavaScript("doc().getElementById('next').click(); true")
        try await wait("doc().getElementById('caption').textContent === 'An editor is optional.' && doc().getElementById('frame').src.endsWith(window.secondImage)", browser)
        try await wait("window.calls.some(x => x.arguments.rendered_point_id==='editor' && x.arguments.after_frame_revision==='editor-frame')", browser)
        let call = try await browser.evaluateJavaScript("window.calls.find(x => x.name==='studio_control_presentation').arguments") as? [String: Any]
        XCTAssertEqual(call?["context_id"] as? String, "my-context")
        XCTAssertEqual(call?["viewer_id"] as? String, nil)
        let playerOnly = try await browser.evaluateJavaScript("!doc().getElementById('refresh') && !doc().getElementById('follow')") as? Bool
        XCTAssertEqual(playerOnly, true)
    }

    func testStepNavigationCanInterruptASlowFrameWithoutShowingItsStaleCaption() async throws {
        let browser = try host(onCall: """
          if (m.params.name === 'studio_workspace_frame' && !window.held) {
            window.held={source:event.source,id:m.id};
          } else {
            if (m.params.name === 'studio_control_presentation') {
              window.initial.structuredContent.presentation.current_caption='An editor is optional.';
            }
            event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
          }
        """, presentation: true)
        try await wait("window.held && doc()?.getElementById('navigation').hidden === false", browser)
        let nextEnabled = try await browser.evaluateJavaScript("!doc().getElementById('next').disabled") as? Bool
        XCTAssertEqual(nextEnabled, true,
                       "Automatic frame reads must not disable step navigation")
        _ = try await browser.evaluateJavaScript("doc().getElementById('next').click(); true")
        try await wait("window.calls.some(x => x.name==='studio_control_presentation')", browser)
        try await wait("doc().getElementById('caption').textContent === 'An editor is optional.'", browser)
        _ = try await browser.evaluateJavaScript("""
          window.held.source.postMessage({jsonrpc:'2.0',id:window.held.id,result:{...window.initial,
            structuredContent:{...window.initial.structuredContent,presentation:{...window.initial.structuredContent.presentation,current_caption:'Obsolete caption.'}}}}, '*'); true
        """)
        try await Task.sleep(for: .milliseconds(150))
        let caption = try await browser.evaluateJavaScript("doc().getElementById('caption').textContent") as? String
        XCTAssertEqual(caption, "An editor is optional.")
    }

    func testDataTransitionWaitsForTheFinalViewportAndSettlesBeforeAcknowledgingThePoint() async throws {
        let browser = try host(onCall: """
          const a=m.params.arguments, d=window.initial.structuredContent;
          if(m.params.name==='studio_control_presentation') {
            Object.assign(d.presentation,{current_point_id:'editor',current_caption:'An editor is optional.',point_number:2,point_visible:false});
            d.frame_revision='editor-frame'; window.initial.content[0].data=window.secondImage;
            d.graph.zoom=.8; d.graph.pan_x=40;
            d.data_view={title:'posts',columns:[{name:'editor_id',type:'INTEGER'}],rows:[{values:[{type:'null',value:null}]}]};
          }
          if(m.params.name==='studio_workspace_frame' && !a.inline_view_state && a.width<500 && !window.heldLayout) {
            window.heldLayout={source:event.source,id:m.id};
          } else {
            if(a.inline_view_state==='acknowledged') {
              window.receipts.push({point:a.rendered_point_id,animations:doc().getAnimations().filter(a=>a.playState==='running'||a.playState==='paused').length,
                width:doc().getElementById('canvas').clientWidth,graphWidth:d.graph.width});
              d.presentation.point_visible=true;
            }
            event.source.postMessage({jsonrpc:'2.0',id:m.id,result:{...window.initial,structuredContent:{...d,frame_acknowledged:a.inline_view_state==='acknowledged'}}}, '*');
          }
        """, presentation: true, motionPreference: false, setup: """
          window.receipts=[];
          window.initial.structuredContent.render_surface='graph';
          window.initial.structuredContent.graph={width:700,height:440,zoom:1,pan_x:0,pan_y:0,min_zoom:.12,max_zoom:2.4};
          Object.assign(window.initial.structuredContent.presentation,{point_visible:false,point_number:1,point_count:3,can_go_back:false,can_go_forward:true});
        """)
        try await wait("window.receipts.some(x=>x.point==='author') && doc().getElementById('following').textContent==='Ready'", browser)
        let originalWidth = try await browser.evaluateJavaScript("doc().getElementById('canvas').clientWidth") as? Int
        _ = try await browser.evaluateJavaScript("doc().getElementById('next').click(); true")
        try await wait("!!window.heldLayout", browser)
        let retained = try await browser.evaluateJavaScript("doc().getElementById('caption').textContent==='Authors write posts.' && doc().getElementById('data-panel').hidden && !window.receipts.some(x=>x.point==='editor')") as? Bool
        XCTAssertEqual(retained, true, "Keep the previous evidence intact until the new graph is sized for its data panel")
        let stillFullWidth = try await browser.evaluateJavaScript("doc().getElementById('canvas').clientWidth") as? Int
        XCTAssertEqual(stillFullWidth, originalWidth)
        _ = try await browser.evaluateJavaScript("window.heldLayout.source.postMessage({jsonrpc:'2.0',id:window.heldLayout.id,result:window.initial},'*'); true")
        try await wait("doc().getElementById('caption').textContent==='An editor is optional.' && doc().getAnimations().some(a=>a.playState==='running')", browser)
        _ = try await browser.evaluateJavaScript("doc().getAnimations().forEach(a=>a.pause()); true")
        let midTransition = try await browser.evaluateJavaScript("!window.receipts.some(x=>x.point==='editor') && doc().getElementById('following').textContent!=='Ready' && !doc().getElementById('next').disabled") as? Bool
        XCTAssertEqual(midTransition, true, "Visibility acknowledgement must wait for motion without blocking Next")
        _ = try await browser.evaluateJavaScript("doc().getAnimations().forEach(a=>a.finish()); true")
        try await wait("window.receipts.some(x=>x.point==='editor') && doc().getElementById('following').textContent==='Ready'", browser)
        let receipt = try await browser.evaluateJavaScript("window.receipts.find(x=>x.point==='editor')") as? [String: Any]
        XCTAssertEqual(receipt?["animations"] as? Int, 0)
        XCTAssertEqual(receipt?["width"] as? Int, receipt?["graphWidth"] as? Int)
    }

    func testNextSupersedesAnUnfinishedTransitionWithoutAcknowledgingItsObsoletePoint() async throws {
        let browser = try host(onCall: """
          const a=m.params.arguments, d=window.initial.structuredContent;
          if(m.params.name==='studio_control_presentation') {
            const last=d.presentation.current_point_id==='editor';
            Object.assign(d.presentation,{current_point_id:last?'last':'editor',current_caption:last?'The final evidence.':'An editor is optional.',point_number:last?3:2,point_visible:false,can_go_forward:!last});
            d.frame_revision=last?'last-frame':'editor-frame'; window.initial.content[0].data=last?window.firstImage:window.secondImage;
            d.graph.zoom=last?1.1:.8; d.graph.pan_x=last?80:40;
          }
          if(a.inline_view_state==='acknowledged') { window.receipts.push(a.rendered_point_id); d.presentation.point_visible=true; }
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:{...window.initial,structuredContent:{...d,frame_acknowledged:a.inline_view_state==='acknowledged'}}}, '*');
        """, presentation: true, motionPreference: false, setup: """
          window.receipts=[]; window.firstImage=window.initial.content[0].data;
          window.initial.structuredContent.render_surface='graph';
          window.initial.structuredContent.graph={width:700,height:440,zoom:1,pan_x:0,pan_y:0,min_zoom:.12,max_zoom:2.4};
          Object.assign(window.initial.structuredContent.presentation,{point_visible:false,point_number:1,point_count:3,can_go_forward:true});
        """)
        try await wait("window.receipts.includes('author')", browser)
        _ = try await browser.evaluateJavaScript("doc().getElementById('next').click(); true")
        try await wait("doc().getElementById('caption').textContent==='An editor is optional.' && doc().getAnimations().some(a=>a.playState==='running')", browser)
        _ = try await browser.evaluateJavaScript("doc().getAnimations().forEach(a=>a.pause()); doc().getElementById('next').click(); true")
        try await wait("doc().getElementById('caption').textContent==='The final evidence.' && window.receipts.includes('last')", browser)
        try await Task.sleep(for: .milliseconds(400))
        let obsolete = try await browser.evaluateJavaScript("window.receipts.includes('editor')") as? Bool
        XCTAssertEqual(obsolete, false, "The canceled animation must never acknowledge the superseded point")
        let final = try await browser.evaluateJavaScript("doc().getElementById('position').textContent==='3/3' && doc().getElementById('caption').textContent==='The final evidence.' && doc().getAnimations().length===0") as? Bool
        XCTAssertEqual(final, true)
    }

    func testAGraphGestureInterruptsMotionAndAcknowledgesOnlyItsUpdatedFrame() async throws {
        let browser = try host(onCall: """
          const a=m.params.arguments, d=window.initial.structuredContent;
          if(m.params.name==='studio_control_presentation') {
            Object.assign(d.presentation,{current_point_id:'editor',current_caption:'An editor is optional.',point_visible:false});
            d.frame_revision='editor-frame'; window.initial.content[0].data=window.secondImage; d.graph.pan_x=40;
          }
          if(a.graph_actions) { d.frame_revision='gesture-frame'; d.graph.pan_x+=a.graph_actions[0].tx; }
          if(a.inline_view_state==='acknowledged') { window.receipts.push({point:a.rendered_point_id,frame:a.after_frame_revision}); d.presentation.point_visible=true; }
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:{...window.initial,structuredContent:{...d,frame_acknowledged:a.inline_view_state==='acknowledged'}}}, '*');
        """, presentation: true, motionPreference: false, setup: """
          window.receipts=[];
          window.initial.structuredContent.render_surface='graph';
          window.initial.structuredContent.graph={width:700,height:440,zoom:1,pan_x:0,pan_y:0,min_zoom:.12,max_zoom:2.4};
          window.initial.structuredContent.presentation.point_visible=false;
        """)
        try await wait("window.receipts.some(x=>x.point==='author')", browser)
        _ = try await browser.evaluateJavaScript("doc().getElementById('next').click(); true")
        try await wait("doc().getElementById('caption').textContent==='An editor is optional.' && doc().getAnimations().some(a=>a.playState==='running')", browser)
        let immediate = try await browser.evaluateJavaScript("doc().getAnimations().forEach(a=>a.pause()); doc().getElementById('canvas').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true})); doc().getElementById('frame').style.transform") as? String
        XCTAssertTrue(immediate?.contains("30") == true, "Panning must take control immediately")
        try await wait("window.receipts.some(x=>x.point==='editor' && x.frame==='gesture-frame')", browser)
        let stale = try await browser.evaluateJavaScript("window.receipts.some(x=>x.point==='editor' && x.frame==='editor-frame')") as? Bool
        XCTAssertEqual(stale, false)
    }

    func testReducedMotionChangesTheGraphAndDataWithoutAnimation() async throws {
        let browser = try host(onCall: """
          const a=m.params.arguments, d=window.initial.structuredContent;
          if(m.params.name==='studio_control_presentation') {
            Object.assign(d.presentation,{current_point_id:'editor',current_caption:'An editor is optional.',point_visible:false});
            d.frame_revision='editor-frame'; window.initial.content[0].data=window.secondImage;
            d.data_view={title:'posts',columns:[{name:'editor_id',type:'INTEGER'}],rows:[{values:[{type:'null',value:null}]}]};
          }
          if(a.inline_view_state==='acknowledged') {
            window.receipts.push({point:a.rendered_point_id,animations:doc().getAnimations().length,width:doc().getElementById('canvas').clientWidth,graphWidth:d.graph.width});
            d.presentation.point_visible=true;
          }
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:{...window.initial,structuredContent:{...d,frame_acknowledged:a.inline_view_state==='acknowledged'}}}, '*');
        """, presentation: true, motionPreference: true, setup: """
          window.receipts=[];
          window.initial.structuredContent.render_surface='graph';
          window.initial.structuredContent.graph={width:700,height:440,zoom:1,pan_x:0,pan_y:0,min_zoom:.12,max_zoom:2.4};
          window.initial.structuredContent.presentation.point_visible=false;
        """)
        try await wait("window.receipts.some(x=>x.point==='author')", browser)
        _ = try await browser.evaluateJavaScript("doc().getElementById('next').click(); true")
        try await wait("window.receipts.some(x=>x.point==='editor') && doc().getElementById('following').textContent==='Ready'", browser)
        let receipt = try await browser.evaluateJavaScript("window.receipts.find(x=>x.point==='editor')") as? [String: Any]
        XCTAssertEqual(receipt?["animations"] as? Int, 0)
        XCTAssertEqual(receipt?["width"] as? Int, receipt?["graphWidth"] as? Int)
        let rows = try await browser.evaluateJavaScript("doc().getElementById('data-rows').textContent") as? String
        XCTAssertTrue(rows?.contains("NULL") == true)
    }

    func testFollowsPinnedNativeFramesAndRetainsALabelledLastFrameWhenWorkspaceChanges() async throws {
        let browser = try host(onCall: """
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.fail
            ? {isError:true,content:[],structuredContent:{error:{code:'WORKSPACE_NOT_ACTIVE',message:'Another workspace is selected.'}}}
            : {...window.initial,structuredContent:{...window.initial.structuredContent,frame_revision:'two',presentation:{presentation_id:'explain',status:'waiting_for_next',current_point_id:'author',view_ready:true,current_caption:'Authors write posts.'}}}}, '*');
        """)
        try await wait("doc()?.getElementById('frame').hidden === false && window.calls.length > 0", browser)
        let call = try await browser.evaluateJavaScript("window.calls[0]") as? [String: Any]
        XCTAssertEqual(call?["name"] as? String, "studio_workspace_frame")
        let args = call?["arguments"] as? [String: Any]
        XCTAssertEqual(args?["context_id"] as? String, "my-context")
        XCTAssertEqual(args?["workspace_id"] as? String, "my-workspace")
        XCTAssertEqual(args?["source_revision"] as? String, "my-source-revision")
        XCTAssertEqual(args?["maximum_frame_age_ms"] as? Int, 5000)
        XCTAssertEqual(args?["defer_until_ready"] as? Bool, true)
        try await wait("doc().getElementById('caption').textContent === 'Authors write posts.'", browser)
        _ = try await browser.evaluateJavaScript("window.fail=true; true")
        try await wait("doc().getElementById('status').textContent.includes('last captured view')", browser)
        let retained = try await browser.evaluateJavaScript("!doc().getElementById('frame').hidden && doc().getElementById('following').textContent === 'Last captured view' && doc().getElementById('next').disabled") as? Bool
        XCTAssertEqual(retained, true)
        let count = try await browser.evaluateJavaScript("window.calls.length") as? Int
        try await Task.sleep(for: .milliseconds(1200))
        let after = try await browser.evaluateJavaScript("window.calls.length") as? Int
        XCTAssertEqual(count, after, "Unavailable workspaces must stop automatic capture requests")
    }

    func testPresentationControlsTargetTheSameContextAndSavedFramesRemainReadable() async throws {
        let browser = try host(onCall: """
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:m.params.name==='studio_control_presentation'
            ? {isError:false,content:[],structuredContent:{status:'paused'}} : window.initial}, '*');
        """, presentation: true)
        try await wait("doc()?.getElementById('navigation').hidden === false", browser)
        _ = try await browser.evaluateJavaScript("doc().getElementById('next').click(); true")
        try await wait("window.calls.some(x => x.name==='studio_control_presentation')", browser)
        let call = try await browser.evaluateJavaScript("window.calls.find(x => x.name==='studio_control_presentation').arguments") as? [String: Any]
        XCTAssertEqual(call?["context_id"] as? String, "my-context")
        XCTAssertEqual(call?["workspace_id"] as? String, "my-workspace")
        XCTAssertEqual(call?["source_id"] as? String, "sqlite:/sample")
        XCTAssertEqual(call?["source_revision"] as? String, "my-source-revision")
        XCTAssertEqual(call?["presentation_id"] as? String, "explain")
        XCTAssertEqual(call?["control"] as? String, "next")
        let savedBrowser = try host(onCall: "", presentation: true, savedOnly: true)
        try await wait("doc()?.getElementById('status').textContent.includes('Saved native view')", savedBrowser)
        let saved = try await savedBrowser.evaluateJavaScript("!doc().getElementById('frame').hidden && doc().getElementById('next').disabled && doc().getElementById('open-app').disabled && window.calls.length===0") as? Bool
        XCTAssertEqual(saved, true)
    }

    func testWaitingOnAStepKeepsFramesLiveAndTeardownReleasesTheView() async throws {
        let browser = try host(onCall: """
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
        """, presentation: true, setup: "window.initial.structuredContent.presentation.status='waiting_for_next';")
        try await wait("window.calls.some(x=>x.arguments.rendered_point_id==='author')", browser)
        let count = try await browser.evaluateJavaScript("window.calls.length") as? Int
        try await Task.sleep(for: .milliseconds(1800))
        let after = try await browser.evaluateJavaScript("window.calls.length") as? Int
        XCTAssertGreaterThan(after ?? 0,count ?? 0,"Waiting on a step must retain live frames and the viewer lease")
        let released = try await browser.evaluateJavaScript("window.calls.some(x=>x.arguments.inline_view_state==='released')") as? Bool
        XCTAssertEqual(released,false)
        _ = try await browser.evaluateJavaScript("document.getElementById('workspace').contentWindow.postMessage({jsonrpc:'2.0',id:999,method:'ui/resource-teardown',params:{}},'*'); true")
        try await wait("window.calls.some(x=>x.arguments.inline_view_state==='released')",browser)
    }

    func testRepeatedHostNotificationsDoNotReleaseOrResetTheViewer() async throws {
        let browser = try host(onCall: """
          event.source.postMessage({jsonrpc:'2.0',method:'ui/notifications/tool-result',params:window.initial}, '*');
          event.source.postMessage({jsonrpc:'2.0',id:m.id,result:window.initial}, '*');
        """, presentation: true, stripMetadata: true)
        try await wait("window.calls.filter(x=>x.name==='studio_workspace_frame').length >= 3", browser)
        let live = try await browser.evaluateJavaScript("!doc().getElementById('next').disabled && !window.calls.some(x=>x.arguments.inline_view_state==='released')") as? Bool
        XCTAssertEqual(live, true)
    }

    private func host(onCall: String, presentation: Bool = false, stripMetadata: Bool = false, savedOnly: Bool = false, motionPreference: Bool? = nil, setup: String = "") throws -> WKWebView {
        var html = try XCTUnwrap(MCPAppResources.workspaceHTML)
        if let motionPreference {
            // Supply a browser preference, while using WebKit's real animations.
            html = html.replacingOccurrences(of: "<head>", with: """
              <head><script>
              const originalMatchMedia=window.matchMedia.bind(window);
              window.matchMedia=q=>q==='(prefers-reduced-motion: reduce)'?{matches:\(motionPreference),addEventListener(){}}:originalMatchMedia(q);
              </script>
              """)
        }
        let escaped = html.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        // A valid small PNG tests image decoding without fabricating native render behavior.
        let image = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="
        let host = """
        <html><body><script>
        window.calls=[]; window.sizes=[]; window.fail=false;
        window.secondImage='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
        window.initial={isError:false,content:[{type:'image',mimeType:'image/png',data:'\(image)'}],
          structuredContent:{format:'sqlite-graph-studio/workspace-view',title:'Sample',workspace_id:'my-workspace',source_id:'sqlite:/sample',source_revision:'my-source-revision',frame_revision:'one',
          viewer:{context_id:'my-context',viewer_id:'my-viewer',width:700},
          \(presentation ? "presentation:{presentation_id:'explain',status:'applied_waiting_for_render',view_ready:true,current_point_id:'author',current_caption:'Authors write posts.'}" : "unused:null")},
          _meta:{workspaceView:{arguments:{context_id:'my-context',workspace_id:'my-workspace',source_id:'sqlite:/sample',source_revision:'my-source-revision',width:700,viewer_id:'my-viewer'}}}};
        \(stripMetadata ? "delete window.initial._meta;" : "")
        \(savedOnly ? "delete window.initial._meta; delete window.initial.structuredContent.viewer;" : "")
        \(setup)
        window.doc=()=>document.getElementById('workspace')?.contentDocument;
        window.send=r=>document.getElementById('workspace').contentWindow.postMessage({jsonrpc:'2.0',method:'ui/notifications/tool-result',params:r},'*');
        window.addEventListener('message',event=>{const m=event.data;if(!m||m.jsonrpc!=='2.0')return;
          if(m.method==='ui/notifications/size-changed')window.sizes.push(m.params);
          if(m.method==='ui/initialize')event.source.postMessage({jsonrpc:'2.0',id:m.id,result:{hostContext:{theme:'light'}}},'*');
          if(m.method==='tools/call'){
            window.calls.push(m.params);
            if(m.params.name==='studio_workspace_frame' && !m.params.arguments.inline_view_state && m.params.arguments.width && window.initial.structuredContent.graph)
              Object.assign(window.initial.structuredContent.graph,{width:m.params.arguments.width,height:m.params.arguments.height || 440});
            \(onCall)
          }
        });
        window.addEventListener('load',()=>window.send(window.initial),{once:true});
        </script><iframe id="workspace" style="width:700px;height:600px" srcdoc="\(escaped)"></iframe></body></html>
        """
        let browser = WKWebView(frame: .init(x: 0, y: 0, width: 720, height: 600))
        browser.loadHTMLString(host, baseURL: nil)
        return browser
    }

    private func wait(_ expression: String, _ browser: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let value = try? await browser.evaluateJavaScript(expression), (value as? NSNumber)?.boolValue == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let diagnostic = (try? await browser.evaluateJavaScript("doc()?.getElementById('status').textContent")) ?? "not loaded"
        XCTFail("Workspace view did not reach \(expression): \(diagnostic)")
        throw Timeout()
    }
    private struct Timeout: Error {}
}
