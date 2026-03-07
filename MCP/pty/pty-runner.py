# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

#!/usr/bin/env python3
import os, sys, json, time, select, subprocess, fcntl, struct, termios, traceback, signal, threading, re
import pty

# ---------------- Tuning (non-security) ----------------
MAX_SESSIONS = 20
IDLE_TIMEOUT_SEC = 15 * 60            # 15 minutes
GC_INTERVAL_SEC = 5                   # run GC at most once per 5s
RING_MAX_BYTES = 1 * 1024 * 1024      # 1 MiB per session
DEFAULT_READ_TIMEOUT_MS = 300         # gentle polling for interactive UI
DEFAULT_MAX_CHARS = 8000

FRAMING = None  # "lsp" (Content-Length) or "line" (NDJSON)

_last_gc = 0.0
_log_rate = {}  # key -> last_ts

def _log(*a):
    print(*a, file=sys.stderr, flush=True)

def _log_limited(key: str, *a, interval_sec: float = 5.0):
    现在 = time.time()
    last = _log_rate.get(key, 0.0)
    if now - last >= interval_sec:
        _log_rate[key] = now
        _log(*a)

def read_messages():
    global FRAMING
    fd = sys.stdin.fileno()
    buf = b""
    while True:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            return
        if not chunk:
            return
        buf += chunk
        if FRAMING is None:
            head = buf.lstrip()
            if head.startswith(b"Content-Length:") or b"\r\n\r\n" in buf[:512]:
                FRAMING = "lsp"
                _log("pty-runner(py) detected framing: lsp(Content-Length)")
            elif head.startswith(b"{") and (b"\n" in buf or b"\r\n" in buf):
                FRAMING = "line"
                _log("pty-runner(py) detected framing: line(NDJSON)")
        progressed = True
        while progressed:
            progressed = False
            if FRAMING in (None, "lsp"):
                header_end = buf.find(b"\r\n\r\n")
                if header_end != -1:
                    header = buf[:header_end].decode("utf-8", errors="replace")
                    rest = buf[header_end + 4:]
                    content_length = None
                    for line in header.split("\r\n"):
                        if line.lower().startswith("content-length:"):
                            try:
                                content_length = int(line.split(":", 1)[1].strip())
                            except Exception:
                                content_length = None
                    if content_length is not None and len(rest) >= content_length:
                        body = rest[:content_length]
                        buf = rest[content_length:]
                        try:
                            yield json.loads(body.decode("utf-8", errors="replace"))
                        except Exception:
                            _log_limited("parse_lsp", "failed to parse LSP JSON body:", body[:200])
                        progressed = True
                        continue
            if FRAMING in (None, "line"):
                nl = buf.find(b"\n")
                if nl != -1:
                    line = buf[:nl]
                    buf = buf[nl + 1:]
                    line = line.strip()
                    if not line:
                        progressed = True
                        continue
                    try:
                        yield json.loads(line.decode("utf-8", errors="replace"))
                    except Exception:
                        _log_limited("parse_line", "failed to parse line JSON:", line[:200])
                    progressed = True
                    continue

def send(msg: dict):
    raw = json.dumps(msg, ensure_ascii=False).encode("utf-8")
    framing = FRAMING or "lsp"
    if framing == "line":
        sys.stdout.buffer.write(raw + b"\n")
    else:
        sys.stdout.buffer.write(f"Content-Length: {len(raw)}\r\n\r\n".encode("ascii") + raw)
    sys.stdout.buffer.flush()

def ok(id_, result):
    send({"jsonrpc": "2.0", "id": id_, "result": result})

def err(id_, code, message, data=None):
    e = {"jsonrpc": "2.0", "id": id_, "error": {"code": code, "message": message}}
    if data is not None:
        e["error"]["data"] = data
    send(e)

def _intish(v, default):
    if v is None: return default
    try: return int(v)
    except Exception: return default

def _strish(v, default=None):
    if v is None: return default
    return str(v)

def _now():
    return time.time()

sessions = {}

def new_id():
    return f"{int(time.time()*1000)}-{os.getpid()}-{os.urandom(4).hex()}"

def set_winsz(fd, rows, cols):
    winsz = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsz)

def _touch(s):
    s["last_active"] = _now()

def _append_ring(s, data: bytes):
    if not data: return
    b = s["buf"]
    b.extend(data)
    if len(b) > RING_MAX_BYTES:
        drop = len(b) - RING_MAX_BYTES
        del b[:drop]

def _reader_loop(session_id: str):
    s = sessions.get(session_id)
    if not s: return
    fd = s["master_fd"]
    proc = s["proc"]
    cond = s["cond"]
    while True:
        with cond:
            if s["closed"]: return
        try:
            r, _, _ = select.select([fd], [], [], 0.2)
        except Exception:
            r = []
        if r:
            try:
                chunk = os.read(fd, 4096)
            except Exception:
                chunk = b""
            if chunk:
                with cond:
                    _append_ring(s, chunk)
                    cond.notify_all()
        if proc.poll() is not None:
            with cond: cond.notify_all()
            time.sleep(0.05)

def _cleanup_session(session_id, s):
    with s["cond"]:
        s["closed"] = True
        s["cond"].notify_all()
    proc = s["proc"]
    try:
        if proc.poll() is None:
            try: os.killpg(s["pgid"], signal.SIGTERM)
            except Exception:
                try: proc.terminate()
                except Exception: pass
            deadline = _now() + 1.0
            while _now() < deadline and proc.poll() is None:
                time.sleep(0.05)
            if proc.poll() is None:
                try: os.killpg(s["pgid"], signal.SIGKILL)
                except Exception:
                    try: proc.kill()
                    except Exception: pass
    except Exception: pass
    try: os.close(s["master_fd"])
    except Exception: pass

def gc_sessions(force=False):
    global _last_gc
    now = _now()
    if not force and (now - _last_gc) < GC_INTERVAL_SEC: return
    _last_gc = now
    to_close = []
    for sid, s in list(sessions.items()):
        if now - s["last_active"] > IDLE_TIMEOUT_SEC:
            to_close.append(sid)
    for sid in to_close:
        s = sessions.pop(sid, None)
        if s: _cleanup_session(sid, s)
    if len(sessions) > MAX_SESSIONS:
        exited, running = [], []
        for sid, s in sessions.items():
            if s["proc"].poll() is None: running.append((sid, s))
            else: exited.append((sid, s))
        exited.sort(key=lambda kv: kv[1]["last_active"])
        running.sort(key=lambda kv: kv[1]["last_active"])
        ordered = exited + running
        need = len(sessions) - MAX_SESSIONS
        for sid, _s in ordered[:need]:
            s = sessions.pop(sid, None)
            if s: _cleanup_session(sid, s)

def pty_spawn(command, cwd=None, cols=120, rows=30):
    gc_sessions()
    if len(sessions) >= MAX_SESSIONS: raise RuntimeError(f"too many sessions (max {MAX_SESSIONS})")
    command = _strish(command, "")
    if not command: raise RuntimeError("command is required")
    cols = _intish(cols, 120)
    rows = _intish(rows, 30)
    cwd = _strish(cwd, None)
    master_fd, slave_fd = pty.openpty()
    try: set_winsz(slave_fd, rows, cols)
    except Exception: pass
    fl = fcntl.fcntl(master_fd, fcntl.F_GETFL)
    fcntl.fcntl(master_fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    proc = subprocess.Popen(
        ["bash", "-lc", command],
        stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
        cwd=cwd or os.getcwd(), env=os.environ.copy(),
        start_new_session=True, close_fds=True,
    )
    os.close(slave_fd)
    try: pgid = os.getpgid(proc.pid)
    except Exception: pgid = proc.pid
    sid = new_id()
    cond = threading.Condition()
    s = {
        "master_fd": master_fd, "proc": proc, "pid": proc.pid, "pgid": pgid,
        "created_at": _now(), "last_active": _now(), "command": command,
        "cwd": cwd or os.getcwd(), "cols": cols, "rows": rows, "buf": bytearray(),
        "closed": False, "cond": cond,
    }
    sessions[sid] = s
    t = threading.Thread(target=_reader_loop, args=(sid,), daemon=True)
    s["reader_thread"] = t
    t.start()
    return sid

def pty_read(session_id, max_chars=DEFAULT_MAX_CHARS, timeout_ms=DEFAULT_READ_TIMEOUT_MS):
    gc_sessions()
    s = sessions.get(session_id)
    if not s: raise RuntimeError("unknown session_id")
    _touch(s)
    max_chars = _intish(max_chars, DEFAULT_MAX_CHARS)
    timeout_ms = _intish(timeout_ms, DEFAULT_READ_TIMEOUT_MS)
    deadline = _now() + (timeout_ms / 1000.0) if timeout_ms and timeout_ms > 0 else _now()
    with s["cond"]:
        while not s["buf"] and not s["closed"] and timeout_ms and timeout_ms > 0:
            remaining = deadline - _now()
            if remaining <= 0: break
            s["cond"].wait(timeout=min(0.2, remaining))
        if not s["buf"]: return ""
        take = min(len(s["buf"]), max_chars)
        data = bytes(s["buf"][:take])
        del s["buf"][:take]
    return data.decode("utf-8", errors="replace")

def pty_read_until(session_id, pattern: str, timeout_ms=10000, max_chars=DEFAULT_MAX_CHARS, regex=False):
    gc_sessions()
    s = sessions.get(session_id)
    if not s: raise RuntimeError("unknown session_id")
    _touch(s)
    pattern = _strish(pattern, "")
    if not pattern: raise RuntimeError("pattern is required")
    timeout_ms = _intish(timeout_ms, 10000)
    max_chars = _intish(max_chars, DEFAULT_MAX_CHARS)
    regex = bool(regex)
    deadline = _now() + (timeout_ms / 1000.0)
    collected = bytearray()
    rx = re.compile(pattern) if regex else None
    def _matches(text: str) -> bool:
        return rx.search(text) is not None if rx else (pattern in text)
    while True:
        step_timeout = int(min(300, max(0, (deadline - _now()) * 1000)))
        chunk = pty_read(session_id, max_chars=max_chars, timeout_ms=step_timeout)
        if chunk:
            collected.extend(chunk.encode("utf-8", errors="replace") if isinstance(chunk, str) else chunk)
            if len(collected) > max_chars: collected = collected[-max_chars:]
            text = collected.decode("utf-8", errors="replace")
            if _matches(text): return {"matched": True, "text": text}
        if _now() >= deadline:
            text = collected.decode("utf-8", errors="replace")
            return {"matched": False, "text": text}

def pty_write(session_id, data: str):
    gc_sessions()
    s = sessions.get(session_id)
    if not s: raise RuntimeError("unknown session_id")
    _touch(s)
    data = _strish(data, "")
    os.write(s["master_fd"], data.encode("utf-8", errors="replace"))

def pty_resize(session_id, cols: int, rows: int):
    gc_sessions()
    s = sessions.get(session_id)
    if not s: raise RuntimeError("unknown session_id")
    _touch(s)
    cols = _intish(cols, s["cols"])
    rows = _intish(rows, s["rows"])
    s["cols"], s["rows"] = cols, rows
    try: set_winsz(s["master_fd"], rows, cols)
    except Exception: pass

def pty_close(session_id):
    s = sessions.pop(session_id, None)
    if s: _cleanup_session(session_id, s)

def pty_close_all():
    for sid in list(sessions.keys()):
        try: pty_close(sid)
        except Exception: pass

def pty_status(session_id):
    gc_sessions()
    s = sessions.get(session_id)
    if not s: raise RuntimeError("unknown session_id")
    _touch(s)
    proc = s["proc"]
    code = proc.poll()
    return {
        "session_id": session_id, "pid": s["pid"], "pgid": s["pgid"],
        "running": code is None, "exit_code": code, "command": s["command"],
        "cwd": s["cwd"], "cols": s["cols"], "rows": s["rows"],
        "created_at": s["created_at"], "last_active": s["last_active"],
        "buffer_bytes": len(s["buf"]),
    }

def pty_wait(session_id, timeout_ms=10000):
    gc_sessions()
    s = sessions.get(session_id)
    if not s: raise RuntimeError("unknown session_id")
    _touch(s)
    timeout_ms = _intish(timeout_ms, 10000)
    proc = s["proc"]
    deadline = _now() + (timeout_ms / 1000.0)
    while _now() < deadline:
        code = proc.poll()
        if code is not None: return {"running": False, "exit_code": code}
        time.sleep(0.05)
    return {"running": True, "exit_code": None}

_SIGMAP = { "SIGINT": signal.SIGINT, "SIGTERM": signal.SIGTERM, "SIGKILL": signal.SIGKILL, "SIGHUP": signal.SIGHUP, "SIGQUIT": signal.SIGQUIT }

def pty_signal(session_id, sig: str):
    gc_sessions()
    s = sessions.get(session_id)
    if not s: raise RuntimeError("unknown session_id")
    _touch(s)
    sig = _strish(sig, "SIGTERM").upper()
    if not sig.startswith("SIG"): sig = "SIG" + sig
    if sig not in _SIGMAP: raise RuntimeError(f"unsupported signal: {sig}")
    proc = s["proc"]
    if proc.poll() is not None: return {"ok": True, "note": "already exited", "exit_code": proc.poll()}
    try: os.killpg(s["pgid"], _SIGMAP[sig])
    except Exception as e: return {"ok": False, "error": str(e)}
    return {"ok": True}

def pty_list():
    gc_sessions()
    out = []
    for sid, s in sessions.items():
        code = s["proc"].poll()
        out.append({
            "session_id": sid, "pid": s["pid"], "pgid": s["pgid"],
            "running": code is None, "exit_code": code, "command": s["command"],
            "cwd": s["cwd"], "cols": s["cols"], "rows": s["rows"],
            "created_at": s["created_at"], "last_active": s["last_active"],
            "buffer_bytes": len(s["buf"]),
        })
    out.sort(key=lambda x: x["last_active"])
    return out

TOOLS = [
    {"name": "pty_spawn", "description": "Spawn a command in a pseudo-terminal. Returns session_id.",
     "inputSchema": {"type": "object", "properties": {"command": {"type": "string"}, "cwd": {"type": ["string", "null"]}, "cols": {"type": ["integer", "string", "null"]}, "rows": {"type": ["integer", "string", "null"]}}, "required": ["command"], "additionalProperties": False}},
    {"name": "pty_read", "description": "Read and consume output from the PTY session ring buffer.",
     "inputSchema": {"type": "object", "properties": {"session_id": {"type": "string"}, "max_chars": {"type": ["integer", "string", "null"]}, "timeout_ms": {"type": ["integer", "string", "null"]}}, "required": ["session_id"], "additionalProperties": False}},
    {"name": "pty_read_until", "description": "Read until substring/regex is matched or timeout.",
     "inputSchema": {"type": "object", "properties": {"session_id": {"type": "string"}, "pattern": {"type": "string"}, "regex": {"type": ["boolean", "null"]}, "timeout_ms": {"type": ["integer", "string", "null"]}, "max_chars": {"type": ["integer", "string", "null"]}}, "required": ["session_id", "pattern"], "additionalProperties": False}},
    {"name": "pty_write", "description": "Write text to the PTY session (include \\n for Enter).",
     "inputSchema": {"type": "object", "properties": {"session_id": {"type": "string"}, "data": {"type": "string"}}, "required": ["session_id", "data"], "additionalProperties": False}},
    {"name": "pty_resize", "description": "Resize the PTY session.",
     "inputSchema": {"type": "object", "properties": {"session_id": {"type": "string"}, "cols": {"type": ["integer", "string"]}, "rows": {"type": ["integer", "string"]}}, "required": ["session_id", "cols", "rows"], "additionalProperties": False}},
    {"name": "pty_close", "description": "Close the PTY session.",
     "inputSchema": {"type": "object", "properties": {"session_id": {"type": "string"}}, "required": ["session_id"], "additionalProperties": False}},
    {"name": "pty_close_all", "description": "Close all PTY sessions.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"name": "pty_status", "description": "Get status of the session process and metadata.",
     "inputSchema": {"type": "object", "properties": {"session_id": {"type": "string"}}, "required": ["session_id"], "additionalProperties": False}},
    {"name": "pty_wait", "description": "Wait for process exit up to timeout_ms.",
     "inputSchema": {"type": "object", "properties": {"session_id": {"type": "string"}, "timeout_ms": {"type": ["integer", "string", "null"]}}, "required": ["session_id"], "additionalProperties": False}},
    {"name": "pty_signal", "description": "Send a signal to the session process group.",
     "inputSchema": {"type": "object", "properties": {"session_id": {"type": "string"}, "sig": {"type": "string"}}, "required": ["session_id", "sig"], "additionalProperties": False}},
    {"name": "pty_list", "description": "List all sessions.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
]

def handle_tools_call(name, args):
    args = args or {}
    if name == "pty_spawn": return {"content": [{"type": "text", "text": pty_spawn(args.get("command"), cwd=args.get("cwd"), cols=args.get("cols"), rows=args.get("rows"))}]}
    if name == "pty_read": return {"content": [{"type": "text", "text": pty_read(args.get("session_id"), max_chars=args.get("max_chars", DEFAULT_MAX_CHARS), timeout_ms=args.get("timeout_ms", DEFAULT_READ_TIMEOUT_MS))}]}
    if name == "pty_read_until": return {"content": [{"type": "text", "text": json.dumps(pty_read_until(args.get("session_id"), pattern=args.get("pattern"), regex=args.get("regex", False), timeout_ms=args.get("timeout_ms", 10000), max_chars=args.get("max_chars", DEFAULT_MAX_CHARS)), ensure_ascii=False)}]}
    if name == "pty_write": pty_write(args.get("session_id"), args.get("data")); return {"content": [{"type": "text", "text": "ok"}]}
    if name == "pty_resize": pty_resize(args.get("session_id"), args.get("cols"), args.get("rows")); return {"content": [{"type": "text", "text": "ok"}]}
    if name == "pty_close": pty_close(args.get("session_id")); return {"content": [{"type": "text", "text": "ok"}]}
    if name == "pty_close_all": pty_close_all(); return {"content": [{"type": "text", "text": "ok"}]}
    if name == "pty_status": return {"content": [{"type": "text", "text": json.dumps(pty_status(args.get("session_id")), ensure_ascii=False)}]}
    if name == "pty_wait": return {"content": [{"type": "text", "text": json.dumps(pty_wait(args.get("session_id"), args.get("timeout_ms", 10000)), ensure_ascii=False)}]}
    if name == "pty_signal": return {"content": [{"type": "text", "text": json.dumps(pty_signal(args.get("session_id"), args.get("sig")), ensure_ascii=False)}]}
    if name == "pty_list": return {"content": [{"type": "text", "text": json.dumps(pty_list(), ensure_ascii=False)}]}
    raise RuntimeError("unknown tool")

def shutdown():
    try: pty_close_all()
    except Exception: pass

def _sig_handler(signum, _frame):
    shutdown(); sys.exit(0)

def main():
    _log("pty-runner(py) boot")
    signal.signal(signal.SIGTERM, _sig_handler); signal.signal(signal.SIGINT, _sig_handler)
    try:
        for msg in read_messages():
            try:
                method, id_, params = msg.get("method"), msg.get("id"), msg.get("params") or {}
                if method in ("initialized",): continue
                if method == "initialize":
                    ok(id_, {"protocolVersion": params.get("protocolVersion") or "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "pty-runner-py", "version": "1.0.0"}})
                    continue
                if method == "tools/list": ok(id_, {"tools": TOOLS}); continue
                if method == "tools/call":
                    tool_name, args = params.get("name"), params.get("arguments") or {}
                    if not tool_name: err(id_, -32602, "Missing tool name"); continue
                    ok(id_, handle_tools_call(tool_name, args)); continue
                if id_ is not None: err(id_, -32601, f"Method not found: {method}")
            except Exception as e:
                if msg.get("id") is not None: err(msg["id"], -32000, str(e), data={"trace": traceback.format_exc()})
                else: _log_limited("notif_err", "notification error:", traceback.format_exc(), interval_sec=2.0)
    finally: shutdown()

if __name__ == "__main__":
    main()

