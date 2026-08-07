#!/usr/bin/env python3
"""Check whether an in-house LLM gateway can drive Claude Code.

Run this from a machine that can reach the gateway (VPN / prod host):

    ./llm-gateway/probe.py --base-url http://gateway.internal/v1 \
                           --token "$INHOUSE_LLM_TOKEN" --model admin

or with llm-gateway/gateway.env filled in:

    ./llm-gateway/probe.py

It answers three questions, in order of importance:

  1. Does the gateway speak the Anthropic Messages API (/v1/messages) directly?
     If yes you do NOT need the LiteLLM sidecar — point Claude Code straight at it.
  2. Does /chat/completions work with the RooCode headers?
  3. Does the model support OpenAI *function calling* and *streaming*?
     Claude Code is unusable without tool calls, so this is the make-or-break test.

Only stdlib — no pip install needed.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

# Same identifying headers the portal sends (api/articles/llm.py INHOUSE_LLM_HEADERS).
INHOUSE_LLM_HEADERS = {
    "User-Agent": "RooCode/3.52.3",
    "X-Title": "Roo Code",
    "HTTP-Referer": "https://github.com/RooVetGit/Roo-Cline",
}

OK, FAIL, WARN = "\033[32m✓\033[0m", "\033[31m✗\033[0m", "\033[33m!\033[0m"


def request(url, token, body=None, method=None, timeout=60, stream=False):
    """Return (status, text). Never raises for HTTP errors."""
    headers = {"Content-Type": "application/json", **INHOUSE_LLM_HEADERS}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method=method or ("POST" if data else "GET"))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if stream:
                # Read a few SSE lines, stopping at [DONE] — the connection is
                # usually kept alive, so reading to EOF would just block.
                chunks = []
                for _ in range(40):
                    line = resp.readline()
                    if not line:
                        break
                    text = line.decode(errors="replace")
                    chunks.append(text)
                    if "[DONE]" in text:
                        break
                return resp.status, "".join(chunks)
            return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:800]
    except Exception as e:  # noqa: BLE001
        return 0, f"{type(e).__name__}: {e}"


def short(text, n=300):
    text = " ".join((text or "").split())
    return text[:n] + ("…" if len(text) > n else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default=os.environ.get("INHOUSE_LLM_BASE_URL"))
    ap.add_argument("--token", default=os.environ.get("INHOUSE_LLM_TOKEN"))
    ap.add_argument("--model", default=os.environ.get("INHOUSE_LLM_MODEL", "admin"))
    args = ap.parse_args()

    if not args.base_url:
        # Fall back to gateway.env sitting next to this script.
        env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gateway.env")
        if os.path.exists(env_path):
            for line in open(env_path):
                if "=" in line and not line.strip().startswith("#"):
                    k, v = line.strip().split("=", 1)
                    os.environ.setdefault(k, v)
            args.base_url = args.base_url or os.environ.get("INHOUSE_LLM_BASE_URL")
            args.token = args.token or os.environ.get("INHOUSE_LLM_TOKEN")
            args.model = os.environ.get("INHOUSE_LLM_MODEL", args.model)
    if not args.base_url:
        sys.exit("probe: no --base-url and no gateway.env — nothing to probe")

    base = args.base_url.rstrip("/")
    root = base[:-3].rstrip("/") if base.endswith("/v1") else base
    print(f"gateway: {base}\nmodel:   {args.model}\n")

    verdict = {}

    # 1. Anthropic Messages API — if this works, the sidecar is unnecessary.
    print("[1] Anthropic Messages API (/v1/messages)")
    for url in dict.fromkeys([f"{root}/v1/messages", f"{base}/messages"]):
        status, text = request(url, args.token, {
            "model": args.model,
            "max_tokens": 16,
            "messages": [{"role": "user", "content": "say hi"}],
        })
        native = status == 200 and '"content"' in text
        print(f"    {OK if native else FAIL} POST {url} → {status} {short(text, 160)}")
        if native:
            verdict["anthropic_native"] = url
            break

    # 2. OpenAI chat completions.
    print("\n[2] OpenAI chat completions (/chat/completions)")
    status, text = request(f"{base}/chat/completions", args.token, {
        "model": args.model,
        "messages": [{"role": "user", "content": "Reply with the single word: OK"}],
        "stream": False,
    })
    verdict["chat"] = status == 200
    print(f"    {OK if status == 200 else FAIL} → {status} {short(text, 200)}")

    # 3. Function calling — Claude Code cannot work without it.
    print("\n[3] Function calling (the make-or-break test)")
    status, text = request(f"{base}/chat/completions", args.token, {
        "model": args.model,
        "messages": [{"role": "user", "content": "What is the weather in Seoul? Use the tool."}],
        "tools": [{
            "type": "function",
            "function": {
                "name": "get_weather",
                "description": "Get the weather for a city",
                "parameters": {
                    "type": "object",
                    "properties": {"city": {"type": "string"}},
                    "required": ["city"],
                },
            },
        }],
        "tool_choice": "auto",
        "stream": False,
    })
    has_tool_calls = status == 200 and "tool_calls" in text
    verdict["tools"] = has_tool_calls
    mark = OK if has_tool_calls else (WARN if status == 200 else FAIL)
    print(f"    {mark} → {status} {short(text, 300)}")
    if status == 200 and not has_tool_calls:
        print("      (200 but no tool_calls: the model may have answered in prose —"
              " re-run; if it never emits tool_calls, Claude Code will not work)")

    # 4. Streaming.
    print("\n[4] Streaming (SSE)")
    status, text = request(f"{base}/chat/completions", args.token, {
        "model": args.model,
        "messages": [{"role": "user", "content": "count to three"}],
        "stream": True,
    }, stream=True)
    streaming = status == 200 and "data:" in text
    verdict["stream"] = streaming
    print(f"    {OK if streaming else WARN} → {status} {short(text, 200)}")

    # Summary
    print("\n" + "=" * 70)
    if verdict.get("anthropic_native"):
        print(f"{OK} The gateway speaks the Anthropic API at {verdict['anthropic_native']}")
        print("  You can SKIP the LiteLLM sidecar. In llm-gateway/gateway.env set the")
        print("  base URL, then run claude-box with:")
        print("    ANTHROPIC_BASE_URL=<that URL without /messages>")
        print("    ANTHROPIC_AUTH_TOKEN=<token>")
        print("    ANTHROPIC_CUSTOM_HEADERS='User-Agent: RooCode/3.52.3'  (etc.)")
    elif verdict.get("chat") and verdict.get("tools"):
        print(f"{OK} OpenAI-compatible with function calling → use the LiteLLM sidecar:")
        print("    ./llm-gateway/gateway.sh up && claude-box --inhouse")
    elif verdict.get("chat"):
        print(f"{WARN} Chat works but no tool_calls were returned.")
        print("  Claude Code needs function calling for every file read and edit.")
        print("  Confirm with your gateway team that the model supports tools.")
    else:
        print(f"{FAIL} The gateway did not answer /chat/completions.")
        print("  Check the base URL (with and without /v1), the token, and network access.")
    print("=" * 70)
    return 0 if (verdict.get("anthropic_native") or verdict.get("chat")) else 1


if __name__ == "__main__":
    sys.exit(main())
