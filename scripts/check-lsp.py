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
    root = Path(directory) / "workspace"
    (root / "src").mkdir(parents=True)
    (root / "pooka.toml").write_text('name = "demo"\nversion = "1.0.0"\n')
    source = root / "src/main.pooka"
    original = "module main\n\nmain() { 1 }\n"
    source.write_text(original)
    uri = source.as_uri()
    outside = Path(directory) / "outside"
    outside.mkdir()
    help_result = subprocess.run([binary, "lsp", "--help"], cwd=outside, capture_output=True, timeout=10)
    assert help_result.returncode == 0 and b"Usage: pooka lsp" in help_result.stdout
    unexpected = subprocess.run([binary, "lsp", "--unexpected"], cwd=outside, capture_output=True, timeout=10)
    assert unexpected.returncode == 2 and unexpected.stdout == b""
    disconnected = subprocess.run([binary, "lsp"], cwd=outside, input=b"", capture_output=True, timeout=10)
    assert disconnected.returncode != 0 and disconnected.stdout == b""
    assert b"disconnected" in disconnected.stderr

    # Deliberately launch outside the source directory and pass a document URI
    # belonging to an independent project.
    server = subprocess.Popen([binary, "lsp"], cwd=outside, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    events = queue.Queue()

    def read():
        while header := server.stdout.readline():
            assert header.startswith(b"Content-Length: "), header
            length = int(header.split(b":", 1)[1])
            assert server.stdout.readline() == b"\r\n"
            events.put(json.loads(server.stdout.read(length)))

    threading.Thread(target=read, daemon=True).start()

    def frame(method, params=None, request=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if request is not None:
            message["id"] = request
        body = json.dumps(message, ensure_ascii=False).encode()
        return f"Content-Length: {len(body)}\r\n\r\n".encode() + body

    def send(method, params=None, request=None):
        server.stdin.write(frame(method, params, request))
        server.stdin.flush()

    try:
        startup = frame("initialize", {}, 1)
        for start, end in ((0, 7), (7, 24), (24, len(startup))):
            server.stdin.write(startup[start:end])
            server.stdin.flush()
        assert events.get(timeout=10)["result"]["capabilities"]["documentFormattingProvider"]
        server.stdin.write(frame("unknown/one", request=90) + frame("unknown/two", request=91))
        server.stdin.flush()
        for request in (90, 91):
            unknown = events.get(timeout=10)
            assert unknown["id"] == request and unknown["error"]["code"] == -32601
        text = 'module main\r\nmain() { "🦌e\u0301";\r\n  1;\r\n}\r\n'
        send("textDocument/didOpen", {"textDocument": {"uri": uri, "text": text, "version": 1}})
        result = events.get(timeout=15)["params"]
        assert result["version"] == 1
        assert any(d["range"]["start"] == {"line": 1, "character": 15}
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
        send("textDocument/didChange", {"textDocument": {"uri": uri, "version": 7},
                                       "contentChanges": [{"text": "module main\n\nimport asdf\n\nmain() {\n  let n = 1\n}\n\nlet s = jjj\n\nlet a = sdsda\n"}]})
        result = events.get(timeout=15)["params"]
        assert result["version"] == 7
        errors = [d for d in result["diagnostics"] if d["severity"] == 1]
        warnings = [d for d in result["diagnostics"] if d["severity"] == 2]
        assert {d["range"]["start"]["line"] for d in errors} == {2, 8, 10}, result
        warning, = warnings
        assert warning["range"]["start"] == {"line": 5, "character": 6}, result
        assert warning["data"]["code"] == "analysis.unused_local_binding", result
        send("textDocument/didChange", {"textDocument": {"uri": uri, "version": 8},
                                       "contentChanges": [{"text": "module main\nmain() {\n  let n = 1\n  let n = 2\n  echo n\n  Nil\n}\n"}]})
        result = events.get(timeout=15)["params"]
        shadowed = [d for d in result["diagnostics"] if d["data"]["code"] == "analysis.unused_local_binding"]
        assert [d["range"]["start"]["line"] for d in shadowed] == [2], result
        for version in range(9, 19):
            send("textDocument/didChange", {"textDocument": {"uri": uri, "version": version},
                                           "contentChanges": [{"text": original}]})
        report = events.get(timeout=15)["params"]
        assert report["version"] == 18 and report["diagnostics"] == [], report
        send("textDocument/didChange", {"textDocument": {"uri": uri, "version": 19},
                                       "contentChanges": [{"text": "module main\nfoo() { 1 }\nfoo() { 2 }\n"}]})
        report = events.get(timeout=15)["params"]
        duplicate, = [d for d in report["diagnostics"] if d["data"]["code"] == "analysis.duplicate_declaration"]
        related, = duplicate["relatedInformation"]
        assert related["location"]["uri"] == uri
        assert related["location"]["range"]["start"] == {"line": 1, "character": 0}
        assert related["message"]
        isolated = Path(directory) / "another project"
        (isolated / "src").mkdir(parents=True)
        manifest = isolated / "pooka.toml"
        clean_manifest = 'name = "another"\nversion = "1.0.0"\n'
        manifest.write_text(clean_manifest + '[dependencies]\npooka_lsp_missing_fixture = "== 1.0.0"\n')
        other = isolated / "src/main.pooka"
        other.write_text(original)
        other_uri = other.as_uri()
        send("textDocument/didOpen", {"textDocument": {"uri": other_uri, "text": original, "version": 1}})
        reports = [events.get(timeout=15)["params"] for _ in range(2)]
        by_uri = {document["uri"]: document["diagnostics"] for document in reports}
        assert any("pooka deps download" in d["message"] for d in by_uri[other_uri]), by_uri
        assert any(d["data"]["code"] == "analysis.duplicate_declaration" for d in by_uri[uri]), by_uri
        manifest.write_text(clean_manifest)
        send("textDocument/didSave", {"textDocument": {"uri": other_uri}})
        reports = [events.get(timeout=15)["params"] for _ in range(2)]
        by_uri = {document["uri"]: document["diagnostics"] for document in reports}
        assert by_uri[other_uri] == [], by_uri
        send("textDocument/didClose", {"textDocument": {"uri": other_uri}})
        assert events.get(timeout=10)["params"]["uri"] == other_uri
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
