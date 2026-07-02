import Foundation

// talkie-mcp — a local, stdio MCP server over the on-disk Talkie stores.
// Newline-delimited JSON-RPC 2.0: read one message per line from stdin, write one
// response per line to stdout (logs, if any, go to stderr — never stdout).
// Zero dependencies, zero network. Exits on EOF (host closes the pipe).

#if DEBUG
// `talkie-mcp --selftest` — a pure-logic parity check for the mirrored semantic
// scoring core. No test target is added (that would require editing Package.swift,
// which G3 must not do), so the scoring invariants are asserted here instead and
// run on demand. Exits nonzero on any failed assertion so CI/agents can gate on it.
if CommandLine.arguments.contains("--selftest") {
    SemanticSelfTest.run()
}
if let idx = CommandLine.arguments.firstIndex(of: "--selftest-timing") {
    let n = (idx + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[idx + 1]) : nil) ?? 200
    SemanticSelfTest.timing(count: n)
}
#endif

let server = MCPServer(store: TalkieStore())

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let data = trimmed.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }

    guard let response = server.handle(obj),
          let out = try? JSONSerialization.data(withJSONObject: response),
          let text = String(data: out, encoding: .utf8)
    else { continue }

    print(text)
    fflush(stdout)
}
