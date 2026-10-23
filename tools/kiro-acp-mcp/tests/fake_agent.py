"""A scripted ACP agent (newline-delimited JSON-RPC on stdio) for the tests.

Prompt keywords: "approve" asks permission for an edit, "read" asks for a read-only
tool, "slow" works until cancelled, "crash" exits, anything else just answers.
"""
import json
import sys
import time


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def update(session, **fields):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": fields}})


def chunk(session, text):
    update(session, sessionUpdate="agent_message_chunk", content={"type": "text", "text": text})


def read_message():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    return json.loads(line)


def ask(session, call_id, title, kind):
    update(session, sessionUpdate="tool_call", toolCallId=call_id, title=title, kind=kind, status="pending")
    send(
        {
            "jsonrpc": "2.0",
            "id": 900,
            "method": "session/request_permission",
            "params": {
                "sessionId": session,
                "toolCall": {"toolCallId": call_id, "title": title, "rawInput": {"path": "hello.txt"}},
                "options": [
                    {"optionId": "allow_once", "name": "Yes", "kind": "allow_once"},
                    {"optionId": "allow_always", "name": "Always", "kind": "allow_always"},
                    {"optionId": "reject_once", "name": "No", "kind": "reject_once"},
                ],
            },
        }
    )
    while True:
        message = read_message()
        if message.get("id") == 900:
            return message["result"]["outcome"]


def handle_prompt(request):
    session = request["params"]["sessionId"]
    text = request["params"]["prompt"][0]["text"]
    if "crash" in text:
        sys.exit(3)
    if "slow" in text:
        chunk(session, "working...")
        while True:
            time.sleep(0.02)
            # The only thing we expect while busy is a cancel notification.
            message = read_message()
            if message.get("method") == "session/cancel":
                send({"jsonrpc": "2.0", "id": request["id"], "result": {"stopReason": "cancelled"}})
                return
    if "approve" in text or "read" in text:
        kind = "edit" if "approve" in text else "read"
        outcome = ask(session, "tc1", "Creating hello.txt" if kind == "edit" else "Reading hello.txt", kind)
        allowed = outcome.get("outcome") == "selected" and outcome.get("optionId", "").startswith("allow")
        update(session, sessionUpdate="tool_call_update", toolCallId="tc1", status="completed" if allowed else "failed")
        chunk(session, "done: allowed" if allowed else "done: denied")
    else:
        chunk(session, "hello from fake kiro: " + text)
    send({"hello": "not json-rpc noise"})
    send({"jsonrpc": "2.0", "method": "_kiro.dev/metadata", "params": {"sessionId": session, "contextUsagePercentage": 3.5, "meteringUsage": [{"value": 0.25, "unit": "credit"}]}})
    send({"jsonrpc": "2.0", "id": request["id"], "result": {"stopReason": "end_turn"}})


def main():
    while True:
        message = read_message()
        method = message.get("method")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": message["id"], "result": {"protocolVersion": 1, "agentCapabilities": {}}})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": message["id"], "result": {"sessionId": "s1"}})
        elif method == "session/prompt":
            handle_prompt(message)


main()
