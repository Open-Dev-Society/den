# /// script
# requires-python = ">=3.11"
# dependencies = ["sqlite-utils>=3.38"]
# ///
"""Self-check: a fake home with one of each source, synced twice, then searched.  uv run test_brain.py"""
import json, os, sqlite3, subprocess, tempfile
from pathlib import Path

home = Path(tempfile.mkdtemp())
os.environ["HOME"] = str(home)
os.environ["BRAIN_DB"] = str(home / "brain.db")

# Claude Code transcript: prompt (with a key), reply (with thinking), tool noise, half-written line
proj = home / ".claude/projects/-x-demo"
proj.mkdir(parents=True)
(proj / "s.jsonl").write_text("\n".join(json.dumps(e) for e in [
    {"type": "user", "uuid": "u1", "timestamp": "2026-10-10T10:00:00.000Z", "cwd": "/x/demo",
     "message": {"content": "how do I rotate sqlite backups? export OPENAI_API_KEY=sk-proj-abc123def456ghi789jkl"}},
    {"type": "assistant", "uuid": "h1", "timestamp": "2026-10-10T10:00:04.000Z", "cwd": "/x/demo",
     "message": {"content": [{"type": "thinking", "thinking": "hmm"}]}},  # each block is its own line
    {"type": "assistant", "uuid": "a1", "timestamp": "2026-10-10T10:00:05.000Z", "cwd": "/x/demo",
     "message": {"content": [{"type": "text", "text": "Use the backup API."}],
                 "usage": {"cache_read_input_tokens": 123456}}, "api_key": "live9secret9value"},
    {"type": "user", "uuid": "n1", "timestamp": "2026-10-10T10:00:07.000Z", "cwd": "/x/demo",  # injected, not typed
     "message": {"content": "<task-notification>\n<task-id>b8</task-id>\n<status>failed</status>\n</task-notification>"}},
    {"type": "user", "uuid": "s1", "timestamp": "2026-10-10T10:00:07.500Z", "cwd": "/x/demo",  # a scheduled task, not you
     "message": {"content": "<scheduled-task name=\"scout\" file=\"/x/SKILL.md\">\nlook for trends\n</scheduled-task>"}},
    {"type": "user", "uuid": "c1", "timestamp": "2026-10-10T10:00:08.000Z", "cwd": "/x/demo",  # a typed command
     "message": {"content": "<command-name>/kitbash</command-name>\n<command-args>use it</command-args>"}},
    {"type": "user", "uuid": "t1", "timestamp": "2026-10-10T10:00:06.000Z",
     "message": {"content": [{"type": "tool_result", "content": "noise"}]}},
]) + '\n{"type": "user", "uu')

# zsh history, plain format, with a metafied en dash (E2 80 93 -> E2 80 83 B3)
(home / ".zsh_history").write_bytes(b"git status\necho a\xe2\x80\x83\xb3b\n")

# git repo with a GitHub remote
repo = home / "personal/demo"
repo.mkdir(parents=True)
for cmd in (["init", "-q"], ["remote", "add", "origin", "git@github.com:me/demo.git"],
            ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "add backup rotation"]):
    subprocess.run(["git", "-C", repo, *cmd], check=True)

# Chromium history with one web visit (token in URL) and one internal page
hist = home / "Library/Application Support/Vivaldi/Default/History"
hist.parent.mkdir(parents=True)
con = sqlite3.connect(hist)
con.executescript("""
  create table urls (id integer primary key, url text, title text);
  create table visits (id integer primary key, url integer, visit_time integer);
  insert into urls values (1, 'https://example.com/docs?token=abcdef123456', 'Backup docs'), (2, 'vivaldi://settings', 'Settings');
  insert into visits values (1, 1, 13404000000000000), (2, 2, 13404000000000001);
""")
con.commit()
con.close()

# Den.app's memory, in the app's own format: a journal day, that day's prepared notes, a person
os.environ["BRAIN_MEMORY"] = str(home / "memory.db")
mem = sqlite3.connect(home / "memory.db")
mem.executescript("""
  create table notes (id integer primary key, kind text, key text unique, title text, body text, evidence text, date real, made real, source text);
  create virtual table notes_fts using fts5 (title, body, tokenize = 'porter');
  insert into notes values (1, 'day', 'day:2026-10-10', 'Saturday, 10 October', 'You fixed the presets in demo.', '["db:1"]', 1791590400, 0, 'auto');
  insert into notes values (2, 'digest', 'digest:/x/demo:2026-10-10', 'demo · 10 Oct', '- Fixed Particles palette ⟦db:1⟧\n- Read the docs', '[]', 1791590400, 0, 'auto');
  insert into notes values (3, 'person', 'person:urvish', 'Urvish Mali', 'Works in demo with you: 3 commits.', '[]', 1791590400, 0, 'auto');
  insert into notes_fts (rowid, title, body) select id, title, body from notes;
""")
mem.commit()
mem.close()

# a file with a download stamp, and one with history in the git repo
download = home / "Downloads/invoice.pdf"
download.parent.mkdir(parents=True)
download.write_bytes(b"%PDF-1.4")
subprocess.run(["xattr", "-w", "com.apple.quarantine", "0081;6705a1b2;Vivaldi;X", download], check=True)
(repo / "notes.md").write_text("hello")
for cmd in (["add", "notes.md"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "write the notes"]):
    subprocess.run(["git", "-C", repo, *cmd], check=True)

import brain


def dump_all():
    return json.dumps(list(brain.DB["items"].rows))


assert not brain.sync()
n = brain.DB["items"].count
assert not brain.sync()
assert brain.DB["items"].count == n == 8, n  # 3 claude + 2 zsh + 2 commits + 1 visit, no dupes on re-sync
assert "task-notification" not in dump_all() and "scheduled-task" not in dump_all() and {r["title"] for r in brain.search(source="claude-code")} >= {"[demo] /kitbash"}

assert {r["source"] for r in brain.search("backups")} == {"claude-code", "git", "browser"}  # porter stemming
assert {r["source"] for r in brain.search("backu")} == {"claude-code", "git", "browser"}  # last word is a prefix
assert brain.search('"foo-bar (') == []  # FTS syntax in the query doesn't crash
assert len(brain.search(limit=4)) == 4 and len(brain.search(limit=4, offset=4)) == 4  # paging
dump = json.dumps(list(brain.DB["items"].rows))
assert "sk-proj" not in dump and "abcdef123456" not in dump and "hmm" not in dump and "noise" not in dump
assert "live9secret9value" not in dump  # secret-looking keys inside raw records
raws = [json.loads(r["raw"]) for r in brain.DB["items"].rows]  # raw is still valid JSON after redaction...
assert any(r and r.get("message", {}).get("usage") == {"cache_read_input_tokens": 123456} for r in raws)  # ...and counts survive
assert {r["title"] for r in brain.search(source="zsh")} == {"git status", "echo a–b"}
assert brain.search(source="git")[0]["url"].startswith("https://github.com/me/demo/commit/")
assert {r["source"]: r["dir"] for r in brain.DB.query("select source, dir from items where dir is not null")} == \
       {"claude-code": "/x/demo", "git": str(repo)}  # where each piece of work happened, as a column
assert brain.search(source="browser")[0]["ts"] == "2025-10-03T21:20:00+00:00"
assert [r["kind"] for r in brain.search(source="claude-code", since="2026-10-10T10:00:01", until="2026-10-10T10:00:06")] == ["reply"]
assert brain.get(brain.search("rotation")[0]["id"])["raw"]
brain.DB.execute("delete from items where source = 'git'")
assert brain.DB["items_fts"].count == brain.DB["items"].count == 6  # FTS index follows deletes
assert {r["source"] for r in brain.search("rotation")} == {"claude-code"}  # "rotate" stems the same
# What Claude gets from Den.app's memory
assert [r["title"] for r in brain.recall("presets")] == ["Saturday, 10 October"]
assert brain.recall(kind="person")[0]["body"].startswith("Works in demo") and brain.recall("nothing-like-this") == []
d = brain.day("2026-10-10")
assert d["journal"] == "You fixed the presets in demo." and d["notes"]["demo"][0] == {"text": "Fixed Particles palette", "source": "db:1"}
assert d["notes"]["demo"][1]["source"] is None and brain.day("2026-10-10", project="other")["notes"] == {}
story = brain.file_story(str(download))
assert story["downloaded_with"] == "Vivaldi" and story["downloaded_at"].startswith("2024-10-08"), story
assert any("write the notes" in c for c in brain.file_story(str(repo / "notes.md"))["commits"])
assert "error" in brain.file_story("/no/such/file")
real = Path.home().parent / os.environ.get("USER", "") / "Downloads/star-history-20261010.png"  # on the dev Mac: added == downloaded
if real.exists():
    s = brain.file_story(str(real))
    assert s["dates"].get("added", "")[:15] == s["downloaded_at"][:15], s
print("ok")
