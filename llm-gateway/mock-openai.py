#!/usr/bin/env python3
"""A fake OpenAI-compatible gateway, for testing the claude-box → LiteLLM → gateway
pipeline without touching the real in-house endpoint.

    ./llm-gateway/mock-openai.py --port 8899

It implements /v1/models and /v1/chat/completions (streaming and not), logs every
request's headers so you can verify the RooCode headers survive the proxy hop, and
drives one tool-call round trip:

  * a request whose last user message mentions "run bash" (or "use the tool", which
    is what probe.py sends) gets back a tool_call for Claude Code's Bash tool;
  * a request containing a tool result gets back plain text quoting that result.

Only stdlib.
"""
import argparse
import json
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WATCH_HEADERS = ("user-agent", "x-title", "http-referer", "authorization")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quieter default logging
        sys.stderr.write("    %s\n" % (fmt % args))

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _log_headers(self):
        seen = {k.lower(): v for k, v in self.headers.items()}
        print(f"\n>>> {self.command} {self.path}")
        for h in WATCH_HEADERS:
            val = seen.get(h, "<missing>")
            if h == "authorization" and val != "<missing>":
                val = val[:12] + "…"
            print(f"    {h}: {val}")

    def do_GET(self):
        self._log_headers()
        if self.path.rstrip("/").endswith("/models"):
            return self._json(200, {"object": "list", "data": [
                {"id": "admin", "object": "model", "owned_by": "inhouse"}]})
        return self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        self._log_headers()
        length = int(self.headers.get("Content-Length") or 0)
        req = json.loads(self.rfile.read(length) or b"{}")
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self._json(404, {"error": {"message": "not found"}})

        messages = req.get("messages", [])
        tools = req.get("tools") or []
        tool_names = [t.get("function", {}).get("name") for t in tools]
        print(f"    model={req.get('model')} stream={req.get('stream')} "
              f"messages={len(messages)} tools={len(tools)}")
        if tool_names:
            print(f"    tool names: {', '.join(str(n) for n in tool_names[:8])}"
                  f"{'…' if len(tool_names) > 8 else ''}")

        saw_tool_result = any(m.get("role") == "tool" for m in messages)
        last_user = ""
        for m in reversed(messages):
            if m.get("role") == "user":
                c = m.get("content")
                last_user = c if isinstance(c, str) else json.dumps(c)
                break

        if saw_tool_result:
            result = next((m.get("content") for m in reversed(messages)
                           if m.get("role") == "tool"), "")
            message = {"role": "assistant",
                       "content": f"TOOL RESULT SEEN: {str(result).strip()[:200]}"}
            finish = "stop"
        elif tools and ("run bash" in last_user.lower() or "use the tool" in last_user.lower()):
            name = "Bash" if "Bash" in tool_names else tool_names[0]
            message = {"role": "assistant", "content": None, "tool_calls": [{
                "id": f"call_{uuid.uuid4().hex[:8]}",
                "type": "function",
                "function": {"name": name, "arguments": json.dumps(
                    {"command": "echo MOCK_TOOL_OK", "description": "mock tool call"})},
            }]}
            finish = "tool_calls"
        else:
            message = {"role": "assistant", "content": "MOCK GATEWAY OK"}
            finish = "stop"

        if req.get("stream"):
            return self._stream(req, message, finish)
        return self._json(200, {
            "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": req.get("model", "admin"),
            "choices": [{"index": 0, "message": message, "finish_reason": finish}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
        })

    def _stream(self, req, message, finish):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        # Close after the stream: without a Content-Length, a kept-alive connection
        # leaves naive clients blocking on readline after [DONE].
        self.send_header("Connection", "close")
        self.close_connection = True
        self.end_headers()

        cid = f"chatcmpl-{uuid.uuid4().hex[:12]}"
        base = {"id": cid, "object": "chat.completion.chunk",
                "created": int(time.time()), "model": req.get("model", "admin")}

        def send(delta, finish_reason=None):
            chunk = dict(base, choices=[{"index": 0, "delta": delta,
                                         "finish_reason": finish_reason}])
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.flush()

        send({"role": "assistant"})
        if message.get("tool_calls"):
            tc = message["tool_calls"][0]
            send({"tool_calls": [{"index": 0, "id": tc["id"], "type": "function",
                                  "function": {"name": tc["function"]["name"],
                                               "arguments": ""}}]})
            send({"tool_calls": [{"index": 0, "function": {
                "arguments": tc["function"]["arguments"]}}]})
        else:
            for word in (message.get("content") or "").split(" "):
                send({"content": word + " "})
        send({}, finish)
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8899)
    args = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)  # so the log is readable when piped
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"mock OpenAI-compatible gateway on http://{args.host}:{args.port}/v1")
    print("  say 'run bash' in a prompt to make it emit a tool call\n")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
