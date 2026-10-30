import asyncio
import json

from subconscious_engine.tool_events import tool_call_event, tool_progress_event
from subconscious_engine.turn_log import TurnLog


def run(coro):
    return asyncio.run(coro)


class Store:
    def __init__(self):
        self.items = []

    async def __call__(self, role, content):
        self.items.append((role, content))

    def tool(self, index):
        return json.loads([c for r, c in self.items if r == "tool"][index])

    @property
    def shape(self):
        return [(r, json.loads(c)["toolName"] if r == "tool" else c) for r, c in self.items]


def delta(text):
    return {"type": "model.delta", "delta": text}


def call(call_id, status, name="read_note", **fields):
    return tool_call_event(tool_call_id=call_id, tool_name=name, status=status, **fields)


def test_text_before_a_tool_call_is_kept_and_order_is_preserved():
    async def scenario():
        store = Store()
        log = TurnLog(store)
        for event in (delta("Let me look. "), delta("One moment."),
                      call("1", "in_progress", arguments={"id": 3}),
                      call("1", "completed", output="note body"),
                      delta("Here is what I found.")):
            await log.record(event)
        await log.finish("Here is what I found.")
        assert store.shape == [("assistant", "Let me look. One moment."), ("tool", "read_note"),
                               ("assistant", "Here is what I found.")]
        record = store.tool(0)
        assert record["v"] == 2 and record["status"] == "completed" and record["input"] == {"id": 3}
        assert record["output"] == "note body" and record["approval"] == "not_required"

    run(scenario())


def test_approval_decisions_are_stored_with_the_call_and_denial_is_a_failure():
    async def scenario():
        store = Store()
        log = TurnLog(store)
        await log.record(call("a", "pending", name="delete_note", arguments={"id": 1}))
        log.note_approval("a", True)
        await log.record(call("a", "in_progress"))
        await log.record(call("a", "completed", output="deleted"))
        await log.record(call("b", "pending", name="remove_skill", arguments={"name": "x"}))
        log.note_approval("b", False)
        await log.record(call("b", "failed", name="remove_skill", error="The tool call was denied."))
        await log.finish("done")
        first, second = store.tool(0), store.tool(1)
        assert first["approval"] == "approved" and first["approvalAt"] and first["status"] == "completed"
        assert second["approval"] == "denied" and second["status"] == "failed"
        assert second["error"] == "The tool call was denied."

    run(scenario())


def test_subagent_steps_are_stored_in_order_and_updates_replace_by_id():
    async def scenario():
        store = Store()
        log = TurnLog(store)
        await log.record(call("s", "in_progress", name="ask_helper", arguments={"prompt": "hi"}))
        await log.record(tool_progress_event("s", {"id": "tool-1", "kind": "tool", "title": "read file",
                                                    "status": "pending"}))
        await log.record(tool_progress_event("s", {"id": "tool-1", "kind": "tool", "status": "completed"}))
        await log.record(tool_progress_event("s", {"id": "message-0", "kind": "message", "text": "answer"}))
        await log.record(tool_progress_event("nope", {"id": "x", "kind": "message", "text": "ignored"}))
        await log.record(call("s", "completed", name="ask_helper", output={"output": "answer"}))
        await log.finish("final")
        steps = store.tool(0)["steps"]
        assert [s["id"] for s in steps] == ["tool-1", "message-0"]
        assert steps[0] == {"id": "tool-1", "kind": "tool", "title": "read file", "status": "completed"}

    run(scenario())


def test_an_interrupted_turn_keeps_partial_text_and_marks_open_calls():
    async def scenario():
        store = Store()
        log = TurnLog(store)
        await log.record(delta("Working on it."))
        await log.record(call("1", "in_progress", name="run_command", arguments={"command": "x"}))
        await log.record(delta(" partial"))
        await log.interrupt()
        assert [r for r, _ in store.items] == ["assistant", "tool", "assistant"]
        record = store.tool(0)
        assert record["status"] == "interrupted" and "before this tool finished" in record["error"]
        await log.interrupt()  # idempotent: nothing is stored twice
        assert len(store.items) == 3

    run(scenario())


def test_final_answer_is_authoritative_and_not_repeated():
    async def scenario():
        store = Store()
        log = TurnLog(store)
        await log.record(delta("streamed tail"))
        await log.finish("The real answer")
        assert store.items == [("assistant", "The real answer")]

        fallback = Store()
        log = TurnLog(fallback)
        await log.record(delta("I will check."))
        await log.record(call("1", "completed", name="get_note", output="x"))
        await log.finish("I will check.")  # model ended empty; the engine reuses its earlier text
        assert [r for r, _ in fallback.items] == ["assistant", "tool"]

        nothing_streamed = Store()
        await TurnLog(nothing_streamed).finish("answer only")
        assert nothing_streamed.items == [("assistant", "answer only")]

    run(scenario())


def test_legacy_records_are_stored_only_when_no_tool_event_was_seen():
    async def scenario():
        records = [{"toolName": "x", "output": "1", "outcome": "success"}]
        quiet = Store()
        await TurnLog(quiet).finish("hi", records)
        assert [r for r, _ in quiet.items] == ["tool", "assistant"]

        seen = Store()
        log = TurnLog(seen)
        await log.record(call("1", "completed", name="x", output="1"))
        await log.finish("hi", records)
        assert [r for r, _ in seen.items] == ["tool", "assistant"] and seen.tool(0)["v"] == 2

    run(scenario())
