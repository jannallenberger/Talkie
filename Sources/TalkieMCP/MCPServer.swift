import Foundation

/// A minimal MCP server (JSON-RPC 2.0 over newline-delimited stdio) exposing the
/// Talkie stores read-mostly. Vendored — no SDK dependency. Synchronous and
/// single-threaded (driven by the stdin loop in `main.swift`), so there's no
/// concurrency surface and nothing leaves the machine.
struct MCPServer {
    let store: TalkieStore
    let protocolVersion = "2024-11-05"

    /// Handle one parsed JSON-RPC message; returns the response object, or nil for
    /// notifications (which get no reply).
    func handle(_ req: [String: Any]) -> [String: Any]? {
        let method = req["method"] as? String ?? ""
        let id = req["id"]
        switch method {
        case "initialize":
            return ok(id, [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "talkie", "version": "0.1.0"],
            ])
        case "notifications/initialized", "initialized", "notifications/cancelled":
            return nil
        case "ping":
            return ok(id, [:])
        case "tools/list":
            return ok(id, ["tools": Self.toolSpecs])
        case "tools/call":
            return callTool(req, id: id)
        default:
            guard id != nil else { return nil }
            return err(id, -32601, "Method not found: \(method)")
        }
    }

    private func callTool(_ req: [String: Any], id: Any?) -> [String: Any]? {
        let params = req["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        func intArg(_ k: String, _ def: Int) -> Int {
            if let i = args[k] as? Int { return i }
            // A JSON number like 1e400 parses as a non-finite/out-of-range Double;
            // Int(_:Double) traps on those, which would abort the whole stdio
            // server. isFinite rejects ±Inf/NaN and Int(exactly:) returns nil
            // (→ def) on overflow instead of trapping. No change for in-range ints.
            if let d = args[k] as? Double, d.isFinite { return Int(exactly: d.rounded()) ?? def }
            return def
        }
        func strArg(_ k: String) -> String? { (args[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func strArr(_ k: String) -> [String]? { args[k] as? [String] }

        let text: String
        switch name {
        case "list_meetings":
            text = store.listMeetings(limit: intArg("limit", 10), query: strArg("query"))
        case "get_meeting":
            let selector: TalkieStore.MeetingSelector
            if let v = strArg("id") { selector = .id(v) }
            else if let v = strArg("title") { selector = .title(v) }
            else if let v = strArg("date") { selector = .date(v) }
            else { return toolErr(id, "get_meeting requires id, title, or date") }
            text = store.getMeeting(selector: selector)
        case "get_brief":
            text = store.getBrief()
        case "list_commitments":
            text = store.listCommitments(limit: intArg("limit", 20))
        case "lookup_entity":
            guard let q = strArg("query") else { return toolErr(id, "lookup_entity requires query") }
            text = store.lookupEntity(query: q, kinds: strArr("kinds"))
        case "search":
            guard let q = strArg("query") else { return toolErr(id, "search requires query") }
            text = store.search(query: q, limit: intArg("limit", 15), sources: strArr("sources"))
        default:
            return err(id, -32602, "Unknown tool: \(name)")
        }
        return ok(id, ["content": [["type": "text", "text": text]], "isError": false])
    }

    // MARK: JSON-RPC envelope helpers

    private func ok(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
        var r: [String: Any] = ["jsonrpc": "2.0", "result": result]
        r["id"] = id ?? NSNull()
        return r
    }
    private func err(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
    private func toolErr(_ id: Any?, _ message: String) -> [String: Any] {
        ok(id, ["content": [["type": "text", "text": "Error: \(message)"]], "isError": true])
    }

    // MARK: Tool schemas (computed so the static isn't shared mutable state under .v6)

    static var toolSpecs: [[String: Any]] {
        [
            spec("list_meetings", "List recent meetings (id, title, date, duration, participants, one-line summary).",
                 ["limit": numProp("Max meetings to return (default 10)."),
                  "query": strProp("Filter by text in title/summary/transcript.")]),
            spec("get_meeting", "Get a meeting's full summary + transcript by id prefix, title match, or calendar day.",
                 ["id": strProp("Meeting id (or 8-char prefix)."),
                  "title": strProp("Title substring."),
                  "date": strProp("Calendar day (yyyy-MM-dd) — returns a meeting that started that day.")]),
            spec("get_brief", "Today's on-device brief (what you worked on, commitments, open threads).", [:]),
            spec("list_commitments", "Open commitments / action items from the context graph, newest first.",
                 ["limit": numProp("Max commitments (default 20).")]),
            spec("lookup_entity", "Look up people / projects / terms by name or alias, with provenance.",
                 ["query": strProp("Name or alias to look up."),
                  "kinds": arrProp("Filter to kinds: person|project|term|commitment.")]),
            spec("search", "Keyword search across meetings, dictations, and entities; returns jump-to-source refs.",
                 ["query": strProp("Search text."),
                  "limit": numProp("Max hits (default 15)."),
                  "sources": arrProp("Restrict to: meetings|dictations|entities.")]),
        ]
    }

    private static func spec(_ name: String, _ desc: String, _ props: [String: [String: Any]]) -> [String: Any] {
        ["name": name, "description": desc,
         "inputSchema": ["type": "object", "properties": props, "required": [String]()]]
    }
    private static func strProp(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func numProp(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    private static func arrProp(_ d: String) -> [String: Any] { ["type": "array", "items": ["type": "string"], "description": d] }
}
