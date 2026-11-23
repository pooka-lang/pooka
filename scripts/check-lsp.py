#!/usr/bin/env python3
"""Exercise the exported executable's JSON-RPC session over byte streams."""
import json
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="pooka lsp ") as directory:
    root = Path(directory)
    (root / "src").mkdir()
    (root / "pooka.toml").write_text('name = "demo"\nversion = "1.0.0"\n')
    source = root / "src/main.pooka"
    original = "module main\n\nmain() { 1 }\n"
    source.write_text(original)
    uri = source.as_uri()
    server = subprocess.Popen([binary, "lsp"], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    events = queue.Queue()

    def read():
        while header := server.stdout.readline():
            assert header.startswith(b"Content-Length: "), header
            length = int(header.split(b":", 1)[1])
            assert server.stdout.readline() == b"\r\n"
            events.put(json.loads(server.stdout.read(length)))

    threading.Thread(target=read, daemon=True).start()

    def send(method, params=None, request=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if request is not None:
            message["id"] = request
        body = json.dumps(message, ensure_ascii=False).encode()
        server.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        server.stdin.flush()

    try:
        send("initialize", {}, 1)
        assert events.get(timeout=10)["result"]["capabilities"]["documentFormattingProvider"]
        text = 'module main\nmain() { "🦌";\n  1;\n}\n'
        send("textDocument/didOpen", {"textDocument": {"uri": uri, "text": text, "version": 1}})
        result = events.get(timeout=15)["params"]
        assert result["version"] == 1
        assert any(d["range"]["start"] == {"line": 1, "character": 13}
                   for d in result["diagnostics"]), result
        assert any(d["range"]["start"]["line"] == 2 and d["severity"] == 1
                   for d in result["diagnostics"]), result
        send("textDocument/didChange", {"textDocument": {"uri": uri, "version": 2},
                                       "contentChanges": [{"text": "module main\nmain(){1}"}]})
        send("textDocument/formatting", {"textDocument": {"uri": uri}, "options": {}}, 2)
        edits = events.get(timeout=10)["result"]
        assert len(edits) == 1 and edits[0]["newText"] == "module main\n\nmain() {\n  1\n}\n", edits
        result = events.get(timeout=15)["params"]
        assert result["version"] == 2 and result["diagnostics"] == [], result
        assert source.read_text() == original
        send("textDocument/documentSymbol", {"textDocument": {"uri": uri}}, 4)
        symbols = events.get(timeout=10)["result"]
        assert [symbol["name"] for symbol in symbols] == ["main"], symbols
        assert symbols[0]["selectionRange"]["start"] == {"line": 1, "character": 0}
        send("textDocument/didChange", {"textDocument": {"uri": uri, "version": 3},
                                       "contentChanges": [{"text": "module main\n_unused() { Nil }\nmain() { Nil }\n"}]})
        warnings = events.get(timeout=15)["params"]
        assert warnings["version"] == 3
        warning, = warnings["diagnostics"]
        assert warning["severity"] == 2 and "source" not in warning and "code" not in warning
        assert warning["data"]["code"] == "analysis.unused_private_declaration"
        broken = root / "src/broken.pooka"
        broken.write_text("module broken\n")
        broken_uri = broken.as_uri()
        send("textDocument/didOpen", {"textDocument": {
            "uri": broken_uri, "text": "module broken\nlet x = 1\n", "version": 1,
        }})
        diagnostics = [events.get(timeout=15)["params"] for _ in range(2)]
        by_uri = {document["uri"]: document["diagnostics"] for document in diagnostics}
        assert any(d["severity"] == 2 for d in by_uri[uri]), by_uri
        assert any(d["severity"] == 1 for d in by_uri[broken_uri]), by_uri
        send("textDocument/didChange", {"textDocument": {"uri": uri, "version": 4},
                                       "contentChanges": [{"text": 'module main\n_unused() { Nil }\nmain() -> Int { "wrong" }\n'}]})
        diagnostics = [events.get(timeout=15)["params"] for _ in range(2)]
        by_uri = {document["uri"]: document["diagnostics"] for document in diagnostics}
        assert {d["severity"] for d in by_uri[uri]} == {1, 2}, by_uri
        assert any(d["severity"] == 1 for d in by_uri[broken_uri]), by_uri
        send("textDocument/didClose", {"textDocument": {"uri": broken_uri}})
        assert events.get(timeout=10)["params"]["uri"] == broken_uri
        send("textDocument/didChange", {"textDocument": {"uri": uri, "version": 5},
                                       "contentChanges": [{"text": "module main\nimport absent\nmain() {\n  import first\n  import second\n  Nil\n}\n"}]})
        result = events.get(timeout=15)["params"]
        assert result["version"] == 5
        assert {d["range"]["start"]["line"] for d in result["diagnostics"] if d["severity"] == 1} >= {1, 3, 4}, result
        send("textDocument/didChange", {"textDocument": {"uri": uri, "version": 6},
                                       "contentChanges": [{"text": 'module main\nfirst() -> Int { "wrong" }\nsecond() -> Int { True }\n'}]})
        result = events.get(timeout=15)["params"]
        assert result["version"] == 6
        assert {d["range"]["start"]["line"] for d in result["diagnostics"] if d["severity"] == 1} >= {1, 2}, result
        send("textDocument/didClose", {"textDocument": {"uri": uri}})
        assert events.get(timeout=10)["params"]["diagnostics"] == []
        send("shutdown", request=3)
        assert events.get(timeout=10)["result"] is None
        send("exit")
        assert server.wait(timeout=10) == 0
    finally:
        if server.poll() is None:
            server.kill()
        server.communicate(timeout=5)
print("Pooka LSP stdio, live diagnostics and formatting passed.")
