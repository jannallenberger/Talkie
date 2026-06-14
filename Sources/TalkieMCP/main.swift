import Foundation

// talkie-mcp — a local, stdio MCP server over the on-disk Talkie stores.
// Newline-delimited JSON-RPC 2.0: read one message per line from stdin, write one
// response per line to stdout (logs, if any, go to stderr — never stdout).
// Zero dependencies, zero network. Exits on EOF (host closes the pipe).

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
