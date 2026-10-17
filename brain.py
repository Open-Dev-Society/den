# /// script
# requires-python = ">=3.11"
# dependencies = ["sqlite-utils>=3.38", "mcp>=2.3"]
# ///
"""Personal brain: one SQLite file of everything you touch, searchable by you and by Claude.

  uv run brain.py sync            pull new items from every source
  uv run brain.py search <words>  quick look from the terminal
  uv run brain.py mcp             MCP server (stdio) for Claude
  uv run brain.py ui              Finder-style app on http://127.0.0.1:7777

Every item keeps source + source_id + url + raw, so any answer traces back to the original.
For Claude (MCP): search and get over this activity; recall, day and file_story over what Den.app has learned.
Data lives in ~/.brain/brain.db (override with BRAIN_DB).

Schedule:  cp local.brain.sync.plist ~/Library/LaunchAgents/ && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.brain.sync.plist
Claude:    claude mcp add brain -s user -- uv run --quiet ~/personal/brain/brain.py mcp
"""
import hashlib, json, os, plistlib, re, shutil, sqlite3, subprocess, sys, tempfile
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlsplit

import sqlite_utils

HOME = Path.home()
APP_SUPPORT = HOME / "Library/Application Support"
REPO_ROOTS = [HOME / d for d in ("personal", "work", "onto", "opendevsociety")]
BROWSERS = ["Vivaldi", "Aside", "Google/Chrome", "BraveSoftware/Brave-Browser", "Arc/User Data"]
SKIP_HOSTS = ()  # domains never ingested, e.g. ("mybank.com",)

# ponytail: regex redaction catches common key shapes, not every secret. Tool output is never ingested.
SECRET = re.compile("|".join([
    r"\b(?:sk|pk|rk)[-_][\w-]{20,}",                      # OpenAI / Anthropic / Stripe style
    r"\bgh[pousr]_\w{30,}|\bgithub_pat_\w{30,}",
    r"\bxox[abpr]-[\w-]{10,}",                            # Slack
    r"\bAKIA[0-9A-Z]{16}\b|\bAIza[\w-]{35}",              # AWS, Google
    r"\beyJ[\w-]{10,}\.[\w-]{10,}\.[\w-]{10,}",           # JWT
    r"-----BEGIN[A-Z ]*PRIVATE KEY-----[\s\S]*?-----END[A-Z ]*PRIVATE KEY-----",
    r"(?i:bearer)\s+[\w.~+/-]{20,}",
    r"(?i:api[_-]?key|token|secret|passw(?:or)?d)[\w-]*[\"']?\s*[:=]\s*[\"']?(?=[^\s\"'&,;]*\d)(?=[^\s\"'&,;]*[A-Za-z])[^\s\"'&,;]{6,}",  # letters+digits, so counts like tokens=123456 survive
    r"[?&](?:code|state|sig|signature|key)=[^&#\s]{6,}",  # OAuth codes / signed URLs
]))

DB_PATH = Path(os.environ.get("BRAIN_DB", HOME / ".brain/brain.db"))
DB_PATH.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
DB = sqlite_utils.Database(sqlite3.connect(DB_PATH, check_same_thread=False))  # MCP runs tools on worker threads
DB.enable_wal()  # MCP reads while launchd writes
if "items" not in DB.table_names():
    DB["items"].create({"id": int, "source": str, "source_id": str, "kind": str, "ts": str,
                        "title": str, "body": str, "url": str, "raw": str},
                       pk="id", not_null={"source", "source_id", "ts"})
    DB["items"].create_index(["source", "source_id"], unique=True)  # makes every re-sync idempotent
    DB["items"].create_index(["ts"])
    DB["items"].enable_fts(["title", "body"], create_triggers=True, tokenize="porter")
    DB["cursors"].create({"name": str, "value": str}, pk="name")
if "dir" not in DB["items"].columns_dict:  # where the work happened: a Claude session's folder, a commit's repo
    DB["items"].add_column("dir", str)     # (a column, so readers never parse every row's JSON to find it)
    with DB.conn:
        DB.execute("update items set dir = coalesce(json_extract(raw, '$.cwd'), json_extract(raw, '$.repo')) "
                   "where source in ('claude-code', 'git')")


def redact(s):
    return SECRET.sub("[REDACTED]", s)


SECRET_KEY = re.compile(r"(?i)api[_-]?key|access[_-]?key|token|secret|passw(or)?d|authorization")


def scrub(v, key=""):
    """Redact inside the strings of a JSON value, never across its syntax, so `raw` stays valid JSON."""
    if isinstance(v, str):
        return "[REDACTED]" if SECRET_KEY.search(key) and re.search(r"\d", v) and len(v) >= 6 else redact(v)
    if isinstance(v, list):
        return [scrub(x, key) for x in v]
    if isinstance(v, dict):
        return {k: scrub(x, k) for k, x in v.items()}
    return v  # numbers (token counts!) and booleans are never secrets


def iso(t):
    """Unix seconds or ISO string -> UTC ISO 8601, so comparing strings compares times."""
    d = datetime.fromisoformat(t) if isinstance(t, str) else datetime.fromtimestamp(t, UTC)
    return d.astimezone(UTC).isoformat(timespec="seconds")


def item(source, source_id, kind, ts, title, body, url=None, raw=None, dir=None):
    return {"source": source, "source_id": str(source_id), "kind": kind, "ts": ts,
            "title": redact(title or "")[:200], "body": redact(body or ""),
            "url": url and redact(url), "raw": json.dumps(scrub(raw), default=str, ensure_ascii=False), "dir": dir}


# --- sources: each yields items and updates its own cursor `state` -------------------------------

# Claude Code puts its own text into "user" messages: reminders, task notifications, command output.
INJECTED = re.compile(r"<(system-reminder|task-notification|local-command-caveat|local-command-stdout|local-command-stderr"
                      r"|bash-stdout|bash-stderr|scheduled-task)\b[^>]*>[\s\S]*?</\1>")
COMMAND_TAGS = re.compile(r"</?(command-name|command-message|command-args|bash-input)>")  # keep what was typed, drop the markup


def said(e):
    """The words of a transcript event: text blocks only (no tool output, no thinking), minus injected context."""
    content = (e.get("message") or {}).get("content")
    text = content if isinstance(content, str) else "\n".join(
        b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text")
    text = INJECTED.sub("", text)
    return (COMMAND_TAGS.sub("", text) if e.get("type") == "user" else text).strip()


def claude_title(e, text):
    return f"[{Path(e.get('cwd') or '').name}] {text.splitlines()[0]}"


def claude_code(state):
    newest = seen = state.get("mtime", 0)
    for path in (HOME / ".claude/projects").glob("*/*.jsonl"):
        if (mtime := path.stat().st_mtime) <= seen:
            continue
        newest = max(newest, mtime)
        for line in path.open(errors="replace"):
            try:
                e = json.loads(line)
            except ValueError:
                continue  # half-written last line of a live session; picked up next sync
            if e.get("type") not in ("user", "assistant") or e.get("isMeta") or e.get("isSidechain") or e.get("isCompactSummary"):
                continue
            if text := said(e):
                e.setdefault("cwd", path.parent.name)
                yield item("claude-code", e["uuid"], "prompt" if e["type"] == "user" else "reply",
                           iso(e["timestamp"]), claude_title(e, text), text, path.as_uri(), e, dir=e.get("cwd"))
    state["mtime"] = newest


WEBKIT_EPOCH = 11644473600  # seconds from 1601-01-01 (Chromium's epoch) to 1970-01-01


def browser(state):
    for name in BROWSERS:
        for hist in (APP_SUPPORT / name).glob("*/History"):
            key, profile = str(hist), hist.parent.name
            since = state.get(key, 0) - 3600 * 10**6  # re-read the last hour: Chromium flushes visits late
            with tempfile.TemporaryDirectory() as tmp:
                for suffix in ("", "-wal", "-journal"):  # the live file is locked while the browser runs
                    if (f := hist.with_name(hist.name + suffix)).exists():
                        shutil.copy(f, tmp)
                con = sqlite3.connect(Path(tmp) / "History")
                rows = con.execute("select v.id, v.visit_time, u.url, u.title from visits v "
                                   "join urls u on u.id = v.url where v.visit_time > ?", (since,)).fetchall()
                con.close()
            for vid, vt, url, title in rows:
                state[key] = max(state.get(key, 0), vt)
                host = urlsplit(url).hostname or ""
                if url.startswith(("http://", "https://")) and not host.endswith(SKIP_HOSTS):
                    yield item("browser", f"{name}/{profile}/{vid}/{vt}", "visit",
                               iso(vt / 1e6 - WEBKIT_EPOCH), title or url, f"{title}\n{url}", url,
                               {"browser": name, "profile": profile, "visit_id": vid})


def sh(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True,
                          encoding="utf-8", errors="replace").stdout


def git(state):
    for root in REPO_ROOTS:
        for gitdir in (p for pat in (".git", "*/.git", "*/*/.git", "*/*/*/.git") for p in root.glob(pat)):
            repo = gitdir.parent
            if not gitdir.is_dir():
                continue  # worktree/submodule: its commits come from the main clone
            if state.get(str(repo)) == (tips := sh(repo, "rev-parse", "--branches")):
                continue  # no new commits since last sync
            remote = re.search(r"github\.com[:/](.+?)(?:\.git)?/?$", sh(repo, "remote", "get-url", "origin").strip())
            for rec in sh(repo, "log", "--branches", "--format=%H%x1f%aI%x1f%an%x1f%s%x1f%b%x1e").split("\x1e"):
                if len(f := rec.strip("\n").split("\x1f")) < 5:
                    continue
                sha, ts, author, subject, body = f
                url = f"https://github.com/{remote[1]}/commit/{sha}" if remote else repo.as_uri()
                yield item("git", sha, "commit", iso(ts), f"[{repo.name}] {subject}",
                           f"{subject}\n\n{body}".strip(), url, {"repo": str(repo), "author": author}, dir=str(repo))
            state[str(repo)] = tips


def zsh(state):
    path = HOME / ".zsh_history"
    if not path.exists():
        return
    data, out = iter(path.read_bytes()), bytearray()
    for b in data:  # undo zsh "metafication": 0x83 means the next byte is XOR 32
        out.append(next(data, 0) ^ 32 if b == 0x83 else b)
    now = iso(datetime.now(UTC).timestamp())
    for entry in re.split(r"(?<!\\)\n", out.decode(errors="replace")):
        m = re.match(r": (\d+):\d+;(.*)", entry, re.S)  # EXTENDED_HISTORY; without it, ts = first seen
        ts, cmd = (iso(int(m[1])), m[2]) if m else (now, entry)
        if cmd.strip():
            yield item("zsh", hashlib.sha1(f"{ts if m else ''}{cmd}".encode()).hexdigest(), "command",
                       ts, cmd.strip().splitlines()[0], cmd)


SOURCES = {"zsh": zsh, "git": git, "browser": browser, "claude-code": claude_code}


def sync():
    failed = False
    for name, ingest in SOURCES.items():
        row = DB.execute("select value from cursors where name = ?", [name]).fetchone()
        state = json.loads(row[0]) if row else {}
        before = DB["items"].count
        try:  # batches commit as they go; the cursor only moves once the source finished cleanly
            DB["items"].insert_all(ingest(state), ignore=True, batch_size=500)
        except Exception as e:  # one broken source shouldn't stop the others
            print(f"{name}: failed: {e!r}", file=sys.stderr)
            failed = True
            continue
        DB["cursors"].upsert({"name": name, "value": json.dumps(state)}, pk="name")
        print(f"{name}: +{DB['items'].count - before}")
    return failed


# --- query: the two MCP tools ---------------------------------------------------------------------

def fts_query(q):
    """Each word quoted (so FTS syntax can't error), the last one a prefix (so search-as-you-type works)."""
    words = [w for w in q.split() if any(c.isalnum() for c in w)]
    return " ".join('"' + w.replace('"', '""') + '"' for w in words) + "*" if words else ""


def search(q: str = "", source: str | None = None, since: str | None = None,
           until: str | None = None, limit: int = 20, offset: int = 0) -> list[dict]:
    """Search everything the user has done: Claude Code prompts/replies, browser visits, git commits, shell commands.

    q: words to find (stemmed, all must match, last word may be partial). Empty q lists the most recent items.
    source: optional, one of "claude-code", "browser", "git", "zsh".
    since / until: optional UTC ISO dates or datetimes, e.g. "2026-10-01" or "2026-10-01T09:00".
    limit / offset: page through results (limit max 100).
    Returns id, source, kind, ts (UTC), title, url and the first 300 chars of body.
    Use get(id) for the full item. Cite the url when answering so the user can open the original.
    """
    clauses = {"source = :source": source, "ts >= :since": since, "ts < :until": until}
    where = " and ".join(c for c, v in clauses.items() if v) or None
    args = {"source": source, "since": since, "until": until}
    cols = ["id", "source", "kind", "ts", "title", "url", "body"]
    page = {"limit": min(limit, 100), "offset": offset}
    rows = (DB["items"].search(fts, columns=cols, where=where, where_args=args, **page) if (fts := fts_query(q))
            else DB["items"].rows_where(where, args, select=", ".join(cols), order_by="ts desc", **page))
    return [{k: (v[:300] if k == "body" else v) for k, v in r.items() if k in cols} for r in rows]


def get(id: int) -> dict:
    """One item in full, including `raw`: the untouched record from its source."""
    return DB["items"].get(id)


# --- memory: what Den.app has written, for Claude (journal, projects, people, notes, prepared day notes) ---------

MEMORY_DB = Path(os.environ.get("BRAIN_MEMORY", HOME / "Library/Application Support/Den/memory.db"))


def memory():
    """Den.app's memory, read-only (the app owns it); None until the app has written some."""
    if not MEMORY_DB.exists():
        return None
    con = sqlite3.connect(f"file:{MEMORY_DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def recall(about: str = "", kind: str | None = None, limit: int = 10) -> list[dict]:
    """What Den has learned about the user, written on their Mac from their own activity: journal entries (one per
    day), project pages (what each project is and what's happening lately), people pages (who they build with or follow,
    and how), and notes (their own, and Claude Code's memory files). Check this before asking the user for context.

    about: words to look for (any may match, best first). Empty lists the most recent pages.
    kind: optional, one of "day", "project", "person", "note", "claude".
    Each page has title, kind, date, body and evidence: ids of what it was made from ("db:123" means get(123)).
    """
    con = memory()
    if con is None:
        return []
    kinds = [kind] if kind else ["day", "project", "person", "note", "claude"]
    marks = ",".join("?" * len(kinds))
    if words := [w for w in re.findall(r"\w+", about) if len(w) > 1]:
        rows = con.execute(f"select n.* from notes_fts join notes n on n.id = notes_fts.rowid where notes_fts match ? "
                           f"and n.kind in ({marks}) order by notes_fts.rank limit ?",
                           [" OR ".join(f'"{w}"*' for w in words), *kinds, min(limit, 50)])
    else:
        rows = con.execute(f"select * from notes where kind in ({marks}) order by date desc limit ?", [*kinds, min(limit, 50)])
    return [{"title": r["title"], "kind": r["kind"], "date": datetime.fromtimestamp(r["date"], UTC).date().isoformat(),
             "body": r["body"], "evidence": json.loads(r["evidence"] or "[]")} for r in rows]


def day(date: str, project: str | None = None) -> dict:
    """One day in detail: Den's journal entry for it, plus its prepared notes — every concrete thing that happened,
    in order, per project ("everything else" holds pages read, files opened and work outside projects).

    date: the user's local date, e.g. "2026-10-10".  project: optional project folder name, e.g. "thrine".
    Every note line carries the id of what it came from ("db:123" means get(123) for the full commit or prompt).
    Notes exist for the last 30 days, once Den.app has prepared them; otherwise use search(since=, until=).
    """
    d = datetime.fromisoformat(date).date()
    key = f"{d.year}-{d.month}-{d.day}"  # how Den.app keys days
    con = memory()
    if con is None:
        return {"date": date, "journal": None, "notes": {}}
    journal = con.execute("select body from notes where key = ?", ["day:" + key]).fetchone()
    notes = {}
    for r in con.execute("select title, body from notes where kind = 'digest' and key like ?", [f"digest:%:{key}"]):
        name = r["title"].split(" · ")[0]
        if project and name.lower() != project.lower():
            continue
        notes[name] = [{"text": m[1], "source": m[2]} for line in r["body"].splitlines()
                       if (m := re.match(r"- (.*?)(?: ⟦(.+)⟧)?$", line))]
    return {"date": date, "journal": journal["body"] if journal else None, "notes": notes}


def file_story(path: str) -> dict:
    """Everything the Mac knows about one file: where it came from (the download URL and page, with the page's title if
    the user visited it, or a mail sender), which app downloaded it and when, when it was created, added, modified and
    last opened and on how many days, and the git commits that touched it.

    path: absolute, or starting with ~.
    """
    p = Path(path).expanduser()
    if not p.exists():
        return {"error": f"no such file: {p}"}
    meta = plistlib.loads(subprocess.run(["mdls", "-plist", "-", str(p)], capture_output=True).stdout or b"<plist><dict/></plist>")
    story = {"path": str(p), "kind": meta.get("kMDItemKind"), "bytes": meta.get("kMDItemFSSize")}
    utc = lambda d: (d if d.tzinfo else d.replace(tzinfo=UTC)).astimezone(UTC)  # plistlib hands back UTC without saying so
    story["dates"] = {label: utc(meta[k]).isoformat(timespec="minutes") for label, k in
                      [("created", "kMDItemContentCreationDate"), ("added", "kMDItemDateAdded"),
                       ("modified", "kMDItemContentModificationDate"), ("last_opened", "kMDItemLastUsedDate")]
                      if isinstance(meta.get(k), datetime)}
    if used := meta.get("kMDItemUsedDates"):
        story["opened_on_days"] = len(used)
    story["came_from"] = [{"url": u, "page": (r[0] if (r := DB.execute(
        "select title from items where source = 'browser' and url = ? order by ts desc limit 1", [u]).fetchone()) else None)}
        for u in meta.get("kMDItemWhereFroms") or []]
    if q := subprocess.run(["xattr", "-p", "com.apple.quarantine", str(p)], capture_output=True, text=True).stdout.strip():
        _, stamp, agent, *_ = q.split(";") + ["", "", ""]  # flags;hex unix time;app;id
        story["downloaded_with"] = agent or None
        story["downloaded_at"] = datetime.fromtimestamp(int(stamp, 16), UTC).isoformat(timespec="minutes") if stamp else None
    if repo := next((d for d in [p.parent, *p.parent.parents] if (d / ".git").exists()), None):
        story["repo"] = str(repo)
        story["commits"] = sh(repo, "log", "-n", "5", "--format=%h %s (%ar)", "--", str(p)).splitlines()
    return story


def serve():
    from mcp.server.mcpserver import MCPServer
    mcp = MCPServer("brain")
    for tool in (search, get, recall, day, file_story):
        mcp.tool()(tool)
    mcp.run()


# --- ui: local bridge between ui.html and the brain -----------------------------------------------

PORT = 7777


def ui():
    import threading, webbrowser
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import parse_qs, unquote

    lock = threading.Lock()  # threads so idle browser preconnects can't stall it; one DB connection, so one at a time

    class Bridge(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, code, body, ctype="application/json"):
            body = body if isinstance(body, bytes) else json.dumps(body, default=str).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            self.route()

        def do_POST(self):
            self.route()

        def route(self):
            # Only answer this machine's own page: the Host check stops DNS-rebinding sites, and the custom
            # header forces a CORS preflight (never granted), so other origins can't call the API.
            if self.headers.get("Host") not in (f"127.0.0.1:{PORT}", f"localhost:{PORT}"):
                return self.reply(403, {"error": "bad host"})
            url = urlsplit(self.path)
            if url.path == "/":
                return self.reply(200, (Path(__file__).parent / "ui.html").read_bytes(), "text/html; charset=utf-8")
            if self.headers.get("X-Brain") != "1":
                return self.reply(403, {"error": "missing X-Brain header"})
            q = {k: v[0] for k, v in parse_qs(url.query).items()}
            with lock:
                return self.api(url.path, q)

        def api(self, path, q):
            try:
                if path == "/api/search":
                    return self.reply(200, search(q.get("q", ""), q.get("source"), q.get("since"), q.get("until"),
                                                  int(q.get("limit", 100)), int(q.get("offset", 0))))
                if path == "/api/item":
                    return self.reply(200, get(int(q["id"])))
                if path == "/api/stats":
                    return self.reply(200, dict(DB.execute("select source, count(*) from items group by source")))
                if path == "/api/reveal" and self.command == "POST":  # only paths the brain itself stored
                    if (link := get(int(q["id"]))["url"] or "").startswith("file://"):
                        subprocess.run(["open", "-R", unquote(urlsplit(link).path)])
                    return self.reply(200, {"ok": True})
                return self.reply(404, {"error": "not found"})
            except (KeyError, ValueError, sqlite_utils.db.NotFoundError) as e:
                return self.reply(400, {"error": repr(e)})

    try:
        server = ThreadingHTTPServer(("127.0.0.1", PORT), Bridge)
    except OSError:  # already running: just open it
        return webbrowser.open(f"http://127.0.0.1:{PORT}")
    print(f"brain ui on http://127.0.0.1:{PORT}  (ctrl-c to stop)")
    webbrowser.open(f"http://127.0.0.1:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "sync"
    if cmd == "sync":
        sys.exit(sync())
    elif cmd == "mcp":
        serve()
    elif cmd == "ui":
        ui()
    elif cmd == "search":
        for r in search(" ".join(sys.argv[2:])):
            print(r["ts"], r["source"], r["title"], r["url"] or "", sep="  ")
    else:
        sys.exit(__doc__)
