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
        startup = frame("initialize", {"capabilities": {
            "workspace": {
                "didChangeWatchedFiles": {"dynamicRegistration": True},
                "workspaceEdit": {"documentChanges": True},
            },
        }}, 1)
        for start, end in ((0, 7), (7, 24), (24, len(startup))):
            server.stdin.write(startup[start:end])
            server.stdin.flush()
        assert events.get(timeout=10)["result"]["capabilities"]["documentFormattingProvider"]
        send("initialized", {})
        registration = events.get(timeout=10)
        assert registration["method"] == "client/registerCapability"
        registered, = registration["params"]["registrations"]
        assert registered["method"] == "workspace/didChangeWatchedFiles"
        assert {item["globPattern"] for item in registered["registerOptions"]["watchers"]} == {
            "**/pooka.toml", "**/pooka.lock", "**/*.pooka",
        }
        acknowledgement = json.dumps({"jsonrpc": "2.0", "id": registration["id"], "result": None}).encode()
        server.stdin.write(f"Content-Length: {len(acknowledgement)}\r\n\r\n".encode() + acknowledgement)
        server.stdin.flush()
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
        send("workspace/didChangeWatchedFiles", {"changes": [{"uri": manifest.as_uri(), "type": 2}]})
        reports = [events.get(timeout=15)["params"] for _ in range(2)]
        by_uri = {document["uri"]: document["diagnostics"] for document in reports}
        assert by_uri[other_uri] == [], by_uri
        send("textDocument/didClose", {"textDocument": {"uri": other_uri}})
        assert events.get(timeout=10)["params"]["uri"] == other_uri
        dependency = root / "src/dependency.pooka"
        dependency.write_text("module dependency\nvalue() { 1 }\n")
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 20},
            "contentChanges": [{"text": "module main\nimport dependency\nmain() -> Int { dependency.value() }\n"}],
        })
        report = events.get(timeout=15)["params"]
        assert report["version"] == 20 and report["diagnostics"] == [], report
        for value, expected_errors in [('"changed"', 1), ("1", 0)]:
            dependency.write_text(f"module dependency\nvalue() {{ {value} }}\n")
            send("workspace/didChangeWatchedFiles", {"changes": [{"uri": dependency.as_uri(), "type": 2}]})
            report = events.get(timeout=15)["params"]
            assert report["uri"] == uri and report["version"] == 20, report
            assert sum(d["severity"] == 1 for d in report["diagnostics"]) == expected_errors, report
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 21},
            "contentChanges": [{"text": "module main\nimport dependency as dep\nmain() { dep.value() }\n"}],
        })
        report = events.get(timeout=15)["params"]
        assert report["version"] == 21 and report["diagnostics"] == [], report
        for column in (7, 21):
            send("textDocument/definition", {
                "textDocument": {"uri": uri},
                "position": {"line": 1, "character": column},
            }, 22)
            response = events.get(timeout=10)
            assert response["id"] == 22 and response["result"] == {
                "uri": dependency.resolve().as_uri(),
                "range": {"start": {"line": 0, "character": 7}, "end": {"line": 0, "character": 17}},
            }, response
        send("textDocument/definition", {
            "textDocument": {"uri": uri},
            "position": {"line": 1, "character": 1000},
        }, 23)
        assert events.get(timeout=10)["result"] is None
        lockfile = root / "pooka.lock"
        lockfile.write_text("version = 999\n")
        send("workspace/didChangeWatchedFiles", {"changes": [{"uri": lockfile.as_uri(), "type": 1}]})
        report = events.get(timeout=15)["params"]
        assert report["uri"] == uri and report["version"] == 21, report
        assert any(d["severity"] == 1 and "lockfile" in d["message"].lower()
                   for d in report["diagnostics"]), report
        lockfile.unlink()
        send("workspace/didChangeWatchedFiles", {"changes": [{"uri": lockfile.as_uri(), "type": 3}]})
        report = events.get(timeout=15)["params"]
        assert report["uri"] == uri and report["version"] == 21, report
        assert report["diagnostics"] == [], report
        assert source.read_text() == original
        navigation = (
            "module main\n"
            "helper() { 1 }\n"
            "calculate(n: Int) {\n"
            "  let before = n\n"
            "  let n = helper()\n"
            "  before + n\n"
            "}\n"
        )
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 22},
            "contentChanges": [{"text": navigation}],
        })
        assert events.get(timeout=15)["params"]["diagnostics"] == []
        for line, column, target_line, start, end in [
            (3, 15, 2, 10, 11),
            (4, 10, 1, 0, 6),
            (5, 2, 3, 6, 12),
            (5, 11, 4, 6, 7),
        ]:
            send("textDocument/definition", {
                "textDocument": {"uri": uri},
                "position": {"line": line, "character": column},
            }, 24)
            response = events.get(timeout=10)
            assert response["id"] == 24 and response["result"] == {
                "uri": uri,
                "range": {
                    "start": {"line": target_line, "character": start},
                    "end": {"line": target_line, "character": end},
                },
            }, response
        second = root / "src/second.pooka"
        second.write_text("module second\n\nvalue() { 2 }\n")
        imports = [
            "module main",
            "import dependency as dep",
            "import second.{value as other}",
            "first() { dep.value() }",
            "selected() { other() }",
            "shadow(dep: Int, other: Int) { dep + other }",
        ]
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 23},
            "contentChanges": [{"text": "\n".join(imports) + "\n"}],
        })
        assert events.get(timeout=15)["params"]["diagnostics"] == []
        for line, name, target_uri, target_line, start, end in [
            (2, "other", second.resolve().as_uri(), 2, 0, 5),
            (3, "value", dependency.resolve().as_uri(), 1, 0, 5),
            (4, "other", second.resolve().as_uri(), 2, 0, 5),
            (5, "dep +", uri, 5, 7, 10),
            (5, "other }", uri, 5, 17, 22),
        ]:
            send("textDocument/definition", {
                "textDocument": {"uri": uri},
                "position": {"line": line, "character": imports[line].index(name)},
            }, 25)
            response = events.get(timeout=10)
            assert response["id"] == 25 and response["result"] == {
                "uri": target_uri,
                "range": {
                    "start": {"line": target_line, "character": start},
                    "end": {"line": target_line, "character": end},
                },
            }, response
        second_uri = second.as_uri()
        send("textDocument/didOpen", {"textDocument": {
            "uri": second_uri,
            "version": 1,
            "text": "module second\n\n// Inserted in the editor\nvalue() { 2 }\n",
        }})
        reports = [events.get(timeout=15)["params"] for _ in range(2)]
        assert {report["uri"] for report in reports} == {uri, second_uri}
        assert all(report["diagnostics"] == [] for report in reports)
        send("textDocument/definition", {
            "textDocument": {"uri": uri},
            "position": {"line": 4, "character": imports[4].index("other")},
        }, 26)
        response = events.get(timeout=10)
        assert response["id"] == 26 and response["result"] == {
            "uri": second_uri,
            "range": {"start": {"line": 3, "character": 0}, "end": {"line": 3, "character": 5}},
        }, response
        send("textDocument/didClose", {"textDocument": {"uri": second_uri}})
        assert events.get(timeout=10)["params"]["uri"] == second_uri
        assert events.get(timeout=15)["params"]["uri"] == uri
        members = [
            "module main",
            "class Base {",
            "  let value: Int",
            "  new(n: Int) { self.value = n }",
            "  read() -> Int { value }",
            "}",
            "class Child is Base {",
            "  new(n: Int) { super.new(n) }",
            "  inherited() -> Int { read() }",
            "}",
            "actor Counter {",
            "  var value: Int",
            "  be advance() { value += 1 }",
            "  read() -> Int { value }",
            "  tick() { advance() }",
            "  shadow(value: Int) { value }",
            "  new() { self.value = 0 }",
            "}",
            "class Point(x: Int)",
            "construct() { #(Base(1), Counter.new(), Point(2)) }",
        ]
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 24},
            "contentChanges": [{"text": "\n".join(members) + "\n"}],
        })
        report = events.get(timeout=15)["params"]
        assert report["diagnostics"] == [], report
        for line, name, target_line, start, end in [
            (3, "value", 2, 6, 11),
            (4, "value", 2, 6, 11),
            (7, "new(n) }", 3, 2, 5),
            (8, "read", 4, 2, 6),
            (13, "value", 11, 6, 11),
            (14, "advance", 12, 5, 12),
            (15, "value }", 15, 9, 14),
            (19, "Base", 3, 2, 5),
            (19, "new", 16, 2, 5),
            (19, "Point", 18, 6, 11),
        ]:
            send("textDocument/definition", {
                "textDocument": {"uri": uri},
                "position": {"line": line, "character": members[line].index(name)},
            }, 27)
            response = events.get(timeout=10)
            assert response["id"] == 27 and response["result"] == {
                "uri": uri,
                "range": {
                    "start": {"line": target_line, "character": start},
                    "end": {"line": target_line, "character": end},
                },
            }, response
        constructors = root / "src/constructors.pooka"
        constructors.write_text(
            "module constructors\n"
            "class Book { new() { Nil } }\n"
            "actor Worker { new() { Nil } }\n"
        )
        calls = [
            "module main",
            "import constructors as models",
            "import constructors.{Book as Volume, Worker as Job}",
            "build() { #(models.Book(), Volume(), models.Worker.new(), Job.new()) }",
        ]
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 25},
            "contentChanges": [{"text": "\n".join(calls) + "\n"}],
        })
        report = events.get(timeout=15)["params"]
        assert report["diagnostics"] == [], report
        for call, member, target_line, start in [
            ("models.Book()", "Book", 1, 13),
            ("Volume()", "Volume", 1, 13),
            ("models.Worker.new()", "new", 2, 15),
            ("Job.new()", "new", 2, 15),
        ]:
            send("textDocument/definition", {
                "textDocument": {"uri": uri},
                "position": {"line": 3, "character": calls[3].index(call) + call.index(member)},
            }, 28)
            response = events.get(timeout=10)
            assert response["id"] == 28 and response["result"] == {
                "uri": constructors.resolve().as_uri(),
                "range": {
                    "start": {"line": target_line, "character": start},
                    "end": {"line": target_line, "character": start + 3},
                },
            }, response
        local_package = Path(directory) / "local package"
        (local_package / "src").mkdir(parents=True)
        (local_package / "pooka.toml").write_text('name = "local_package"\nversion = "1.0.0"\n')
        external = local_package / "src/catalogue.pooka"
        external_source = (
            "module catalogue\nclass Entry { new() { Nil } }\ncount() { 1 }\n"
            "class Shelf { read() -> Int { 1 } }\n"
        )
        external.write_text(external_source)
        with (root / "pooka.toml").open("a") as manifest:
            manifest.write('\n[dependencies]\nlocal_package = { path = "../local package" }\n')
        dependency_main = "get() { #(catalogue.Entry(), catalogue.count()) }"
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 26},
            "contentChanges": [{"text": f"module main\nimport catalogue\n{dependency_main}\n"}],
        })
        report = events.get(timeout=15)["params"]
        assert report["version"] == 26 and report["diagnostics"] == [], report
        for name, target_line, start, end in [("Entry", 1, 14, 17), ("count", 2, 0, 5)]:
            send("textDocument/definition", {
                "textDocument": {"uri": uri},
                "position": {"line": 2, "character": dependency_main.index(name)},
            }, 29)
            response = events.get(timeout=10)
            assert response["id"] == 29 and response["result"] == {
                "uri": external.resolve().as_uri(),
                "range": {
                    "start": {"line": target_line, "character": start},
                    "end": {"line": target_line, "character": end},
                },
            }, response
        typed_lines = [
            "module main",
            "interface Readable { read() -> Int }",
            "class Base {",
            "  let value: Int",
            "  new(n: Int) { self.value = n }",
            "  read() -> Int { value }",
            "}",
            "class Child is Base {",
            "  new(n: Int) { super.new(n) }",
            "}",
            "actor Counter {",
            "  be advance() { Nil }",
            "}",
            "from_child(item: Child) { #(item.value, item.read()) }",
            "from_interface(item: Readable) { item.read() }",
            "from_actor(item: Counter) { item.advance() }",
            "class Override is Base {",
            "  new(n: Int) { super.new(n) }",
            "  read() -> Int { 2 }",
            "}",
            "from_override(item: Override) { item.read() }",
        ]
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 27},
            "contentChanges": [{"text": "\n".join(typed_lines) + "\n"}],
        })
        report = events.get(timeout=15)["params"]
        assert report["version"] == 27 and report["diagnostics"] == [], report
        for line, member, target, start, end in [
            (13, "value", 3, 6, 11),
            (13, "read", 5, 2, 6),
            (14, "read", 1, 21, 25),
            (15, "advance", 11, 5, 12),
            (20, "read", 18, 2, 6),
        ]:
            send("textDocument/definition", {
                "textDocument": {"uri": uri},
                "position": {"line": line, "character": typed_lines[line].index("." + member) + 1},
            }, 30)
            response = events.get(timeout=10)
            assert response["id"] == 30 and response["result"] == {
                "uri": uri,
                "range": {
                    "start": {"line": target, "character": start},
                    "end": {"line": target, "character": end},
                },
            }, response
        external_uri = external.as_uri()
        send("textDocument/didOpen", {"textDocument": {
            "uri": external_uri, "version": 1,
            "text": external_source.replace("class Shelf", "\nclass Shelf"),
        }})
        reports = [events.get(timeout=15)["params"] for _ in range(2)]
        assert all(report["diagnostics"] == [] for report in reports), reports
        imported_receiver = "from_shelf(item: catalogue.Shelf) { item.read() }"
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 28},
            "contentChanges": [{"text": f"module main\nimport catalogue\n{imported_receiver}\n"}],
        })
        reports = [events.get(timeout=15)["params"] for _ in range(2)]
        assert all(report["diagnostics"] == [] for report in reports), reports
        send("textDocument/definition", {
            "textDocument": {"uri": uri},
            "position": {"line": 2, "character": imported_receiver.index("read")},
        }, 31)
        response = events.get(timeout=10)
        assert response["id"] == 31 and response["result"] == {
            "uri": external_uri,
            "range": {"start": {"line": 4, "character": 14}, "end": {"line": 4, "character": 18}},
        }, response
        send("textDocument/didClose", {"textDocument": {"uri": external_uri}})
        assert events.get(timeout=10)["params"]["uri"] == external_uri
        assert events.get(timeout=15)["params"]["uri"] == uri
        hover_source = [
            "module main",
            "/// Return the default score.",
            "score() -> Int { 42 }",
            "main() {",
            "  let value = score()",
            "  value",
            "}",
        ]
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 29},
            "contentChanges": [{"text": "\n".join(hover_source) + "\n"}],
        })
        report = events.get(timeout=15)["params"]
        assert report["version"] == 29 and report["diagnostics"] == [], report
        for row, name, expected in [
            (4, "score", ["score: fn() -> Int", "Return the default score."]),
            (5, "value", ["value: Int"]),
        ]:
            send("textDocument/hover", {
                "textDocument": {"uri": uri},
                "position": {"line": row, "character": hover_source[row].index(name)},
            }, 32)
            response = events.get(timeout=10)
            contents = response["result"]["contents"]
            assert response["id"] == 32 and contents["kind"] == "markdown", response
            assert all(part in contents["value"] for part in expected), response
        hover_source[2] = 'score() -> String { "changed" }'
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 30},
            "contentChanges": [{"text": "\n".join(hover_source) + "\n"}],
        })
        report = events.get(timeout=15)["params"]
        assert report["version"] == 30 and report["diagnostics"] == [], report
        send("textDocument/hover", {
            "textDocument": {"uri": uri},
            "position": {"line": 5, "character": hover_source[5].index("value")},
        }, 33)
        response = events.get(timeout=10)
        assert response["id"] == 33 and "value: String" in response["result"]["contents"]["value"], response
        for version, code, line, column, expected, start, end in [
            (31, "module main\nmain() {\n  let score = 1\n  scWrong\n}\n",
             3, 4, "score", 2, 9),
            (32, "module main\nimport catalogue as cat\nmain() { cat. }\n",
             2, 13, "count", 13, 13),
            (33, "module main\nimport catalogue\nmain(item: catalogue.Shelf) { item. }\n",
             2, 35, "read", 35, 35),
        ]:
            send("textDocument/didChange", {
                "textDocument": {"uri": uri, "version": version},
                "contentChanges": [{"text": code}],
            })
            report = events.get(timeout=15)["params"]
            assert report["version"] == version, report
            send("textDocument/completion", {
                "textDocument": {"uri": uri},
                "position": {"line": line, "character": column},
            }, 34)
            response = events.get(timeout=15)
            assert response["id"] == 34, response
            assert {
                "label": expected,
                "textEdit": {
                    "newText": expected,
                    "range": {
                        "start": {"line": line, "character": start},
                        "end": {"line": line, "character": end},
                    },
                },
            } in response["result"], response
        typo_line = '  #("🦌", scor)'
        typo = f"module main\nmain() {{\n  let score = 1\n{typo_line}\n}}\n"
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 34},
            "contentChanges": [{"text": typo}],
        })
        report = events.get(timeout=15)["params"]
        assert report["version"] == 34, report
        unknown_name, = [item for item in report["diagnostics"]
                         if item["data"]["code"] == "analysis.unknown_name"]
        utf16_start = len(typo_line.split("scor")[0].encode("utf-16-le")) // 2
        fix_range = {"start": {"line": 3, "character": utf16_start},
                     "end": {"line": 3, "character": utf16_start + 4}}
        action_params = {
            "textDocument": {"uri": uri},
            "range": fix_range,
            "context": {"diagnostics": [unknown_name], "only": ["quickfix"]},
        }
        send("textDocument/codeAction", action_params, 35)
        response = events.get(timeout=10)
        action, = response["result"]
        assert response["id"] == 35 and action["kind"] == "quickfix", response
        assert action["edit"]["documentChanges"] == [{
            "textDocument": {"uri": uri, "version": 34},
            "edits": [{"range": fix_range, "newText": "score"}],
        }], response
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 35},
            "contentChanges": [{"text": typo.replace(typo_line, typo_line.replace("scor", "score"))}],
        })
        send("textDocument/codeAction", action_params, 36)
        reports = [events.get(timeout=15) for _ in range(2)]
        assert any(message.get("id") == 36 and message["result"] == [] for message in reports), reports
        assert any(message.get("params", {}).get("version") == 35 for message in reports), reports
        declarations = (
            "module main\n"
            "pair(first: Int, second: String) -> String { #(first, second).1 }\n"
            "label(value: Int) -> String { match value { _ -> \"name\" } }\n"
        )
        for version, call, marker, label, active in [
            (36, "  pair(1, label(2))", "2", "label(Int) -> String", 0),
            (37, "  pair(1, label(2))", "label", "pair(Int, String) -> String", 1),
            (38, "  pair(1, ", "", "pair(Int, String) -> String", 1),
        ]:
            position = len(call) if not marker else call.index(marker)
            send("textDocument/didChange", {
                "textDocument": {"uri": uri, "version": version},
                "contentChanges": [{"text": declarations + "main() {\n" + call + "\n}\n"}],
            })
            assert events.get(timeout=15)["params"]["version"] == version
            send("textDocument/signatureHelp", {
                "textDocument": {"uri": uri},
                "position": {"line": 4, "character": position},
            }, 37)
            response = events.get(timeout=15)
            signature = response["result"]
            assert response["id"] == 37 and signature["activeParameter"] == active, response
            assert signature["signatures"][0]["label"] == label, response
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 39},
            "contentChanges": [{"text": "module main\nvalue() { 42 }\n"}],
        })
        assert events.get(timeout=15)["params"]["version"] == 39
        send("workspace/symbol", {"query": "VALUE"}, 38)
        response = events.get(timeout=15)
        assert response["id"] == 38, response
        values = [item for item in response["result"] if item["name"] == "value"]
        assert {item["containerName"] for item in values} >= {"main", "dependency", "second"}, response
        unsaved, = [item for item in values if item["location"]["uri"] == uri]
        assert unsaved["location"]["range"]["start"] == {"line": 1, "character": 0}, response
        reference_source = [
            "module main",
            "import second as deps",
            "import second.{value as selected}",
            "use_value() { #(deps.value(), selected()) }",
            "shadow(selected: Int) { selected }",
        ]
        send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 40},
            "contentChanges": [{"text": "\n".join(reference_source) + "\n"}],
        })
        assert events.get(timeout=15)["params"]["version"] == 40
        for include in (False, True):
            send("textDocument/references", {
                "textDocument": {"uri": uri},
                "position": {"line": 3, "character": reference_source[3].index("selected")},
                "context": {"includeDeclaration": include},
            }, 39)
            response = events.get(timeout=15)
            sites = {(item["uri"], item["range"]["start"]["line"],
                      item["range"]["start"]["character"]) for item in response["result"]}
            expected = {
                (uri, 2, reference_source[2].index("value")),
                (uri, 3, reference_source[3].index("deps.value") + len("deps.")),
                (uri, 3, reference_source[3].index("selected")),
            }
            if include:
                expected.add((second.resolve().as_uri(), 2, 0))
            assert response["id"] == 39 and sites == expected, response
        send("textDocument/references", {
            "textDocument": {"uri": uri},
            "position": {"line": 4, "character": reference_source[4].rindex("selected")},
            "context": {"includeDeclaration": True},
        }, 40)
        response = events.get(timeout=15)
        assert response["id"] == 40 and len(response["result"]) == 2, response
        assert all(item["range"]["start"]["line"] == 4 for item in response["result"]), response
        rename_position = {"line": 3, "character": reference_source[3].index("selected")}
        rename_params = {"textDocument": {"uri": uri}, "position": rename_position}
        send("textDocument/prepareRename", rename_params, 41)
        response = events.get(timeout=15)
        assert response["id"] == 41 and response["result"]["placeholder"] == "selected", response
        send("textDocument/rename", rename_params | {"newName": "chosen"}, 42)
        response = events.get(timeout=15)
        change, = response["result"]["documentChanges"]
        assert response["id"] == 42 and change["textDocument"] == {"uri": uri, "version": 40}, response
        assert {edit["range"]["start"]["line"] for edit in change["edits"]} == {2, 3}, response
        assert all(edit["newText"] == "chosen" for edit in change["edits"]), response
        send("textDocument/rename", rename_params | {"newName": "deps"}, 43)
        response = events.get(timeout=15)
        assert response["id"] == 43 and "already occurs" in response["error"]["message"], response
        export_position = {"line": 3, "character": reference_source[3].index("deps.value") + 5}
        send("textDocument/rename", rename_params | {
            "position": export_position,
            "newName": "replacement",
        }, 44)
        response = events.get(timeout=15)
        assert response["id"] == 44, response
        changes = {item["textDocument"]["uri"]: item["edits"]
                   for item in response["result"]["documentChanges"]}
        assert set(changes) == {uri, second.resolve().as_uri()}, response
        assert len(changes[uri]) == 2, response
        assert all(edit["range"]["start"] != rename_position for edit in changes[uri]), response
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
