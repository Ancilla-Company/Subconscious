"""A scripted ACP agent for tests. The prompt text picks the behaviour:

* ``write``  - asks permission for an edit, then reports what the client answered
* ``read``   - asks permission for a read, then reports what the client answered
* ``hang``   - never answers the prompt
* ``remember X`` / ``recall`` - keeps X for the rest of the session
* ``slow``   - answers after one second
* ``spawn``  - starts a detached helper process that outlives the agent, and reports its pid
* ``pid``    - reports the agent's own pid
* anything else is echoed back.
"""
import json
import os
import subprocess
import sys
import time


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
memory = []
for line in sys.stdin:
    message = json.loads(line)
    method, rpc_id = message.get("method"), message.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": rpc_id, "result": {
            "protocolVersion": 1, "agentCapabilities": {"sessionCapabilities": {"close": {}}},
            "agentInfo": {"name": "fake", "title": "Fake Agent", "version": "9.9"}}})
    elif method == "session/close":
        send({"jsonrpc": "2.0", "id": rpc_id, "result": {}})
    elif method == "session/new":
        send({"jsonrpc": "2.0", "id": rpc_id, "result": {"sessionId": "s1"}})
    elif method == "session/prompt":
        text = message["params"]["prompt"][0]["text"]
        if text == "hang":
            continue
        if text in ("write", "read"):
            pending_prompt = rpc_id
            ask("s1", 900, "edit" if text == "write" else "read", f"{text} file")
        elif text.startswith("remember "):
            memory.append(text[len("remember "):])
            chunk("s1", "noted")
            send({"jsonrpc": "2.0", "id": rpc_id, "result": {"stopReason": "end_turn"}})
        elif text == "recall":
            chunk("s1", "memory=" + ",".join(memory))
            send({"jsonrpc": "2.0", "id": rpc_id, "result": {"stopReason": "end_turn"}})
        elif text == "slow":
            time.sleep(1.0)
            chunk("s1", "slow done")
            send({"jsonrpc": "2.0", "id": rpc_id, "result": {"stopReason": "end_turn"}})
        elif text == "spawn":
            kwargs = {"creationflags": 0x00000008 | 0x00000200} if os.name == "nt" else {"start_new_session": True}
            child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"],
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, **kwargs)
            chunk("s1", "child=%d" % child.pid)
            send({"jsonrpc": "2.0", "id": rpc_id, "result": {"stopReason": "end_turn"}})
        elif text == "pid":
            chunk("s1", "pid=%d" % os.getpid())
            send({"jsonrpc": "2.0", "id": rpc_id, "result": {"stopReason": "end_turn"}})
        else:
            chunk("s1", "echo: " + text)
            send({"jsonrpc": "2.0", "id": rpc_id, "result": {"stopReason": "end_turn"}})
    elif rpc_id == 900 and "result" in message:
        outcome = message["result"]["outcome"]
        chunk("s1", "outcome=" + json.dumps(outcome, sort_keys=True))
        send({"jsonrpc": "2.0", "id": pending_prompt, "result": {"stopReason": "end_turn"}})
