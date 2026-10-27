"""A scripted ACP agent for tests. The prompt text picks the behaviour:

* ``write``  - asks permission for an edit, then reports what the client answered
* ``read``   - asks permission for a read, then reports what the client answered
* ``hang``   - never answers the prompt
* anything else is echoed back.
"""
import json
import sys


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def update(session, body):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": body}})


def chunk(session, text):
    update(session, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})


def ask(session, rpc_id, kind, title):
    update(session, {"sessionUpdate": "tool_call", "toolCallId": "c1", "title": title, "kind": kind,
                     "status": "pending"})
    send({"jsonrpc": "2.0", "id": rpc_id, "method": "session/request_permission", "params": {
        "sessionId": session, "toolCall": {"toolCallId": "c1", "title": title, "kind": kind},
        "options": [{"optionId": "a", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "aa", "name": "Always", "kind": "allow_always"},
                    {"optionId": "r", "name": "Reject", "kind": "reject_once"}]}})


pending_prompt = None
for line in sys.stdin:
    message = json.loads(line)
    method, rpc_id = message.get("method"), message.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": rpc_id, "result": {
            "protocolVersion": 1, "agentCapabilities": {},
            "agentInfo": {"name": "fake", "title": "Fake Agent", "version": "9.9"}}})
    elif method == "session/new":
        send({"jsonrpc": "2.0", "id": rpc_id, "result": {"sessionId": "s1"}})
    elif method == "session/prompt":
        text = message["params"]["prompt"][0]["text"]
        if text == "hang":
            continue
        if text in ("write", "read"):
            pending_prompt = rpc_id
            ask("s1", 900, "edit" if text == "write" else "read", f"{text} file")
        else:
            chunk("s1", "echo: " + text)
            send({"jsonrpc": "2.0", "id": rpc_id, "result": {"stopReason": "end_turn"}})
    elif rpc_id == 900 and "result" in message:
        outcome = message["result"]["outcome"]
        chunk("s1", "outcome=" + json.dumps(outcome, sort_keys=True))
        send({"jsonrpc": "2.0", "id": pending_prompt, "result": {"stopReason": "end_turn"}})
