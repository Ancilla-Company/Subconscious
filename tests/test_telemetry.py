import asyncio

from subconscious_engine.telemetry import (
    ExecutionTelemetry, FrictionSignal, RunStatus, TelemetryStore, ToolInvocation,
)


def run(coro):
    return asyncio.run(coro)


def test_subconscious_trigger_filter_exact_truth_table_and_claims(tmp_path):
    async def scenario():
        store = TelemetryStore(tmp_path / "telemetry.db")
        await store.initialize()
        runs = [
            ExecutionTelemetry(run_id="success", graph_id="g", final_status=RunStatus.SUCCESS),
            ExecutionTelemetry(
                run_id="retry-two", graph_id="g", final_status=RunStatus.SUCCESS,
                tool_invocations=[ToolInvocation(tool_name="x", retry_count=2)],
            ),
            ExecutionTelemetry(
                run_id="retry-three", graph_id="g", final_status=RunStatus.SUCCESS,
                tool_invocations=[ToolInvocation(tool_name="x", retry_count=3)],
            ),
            ExecutionTelemetry(run_id="failed", graph_id="g", final_status=RunStatus.FAILED),
            ExecutionTelemetry(
                run_id="friction", graph_id="g", final_status=RunStatus.SUCCESS,
                friction_signals=[FrictionSignal(kind="rejected_tool")],
            ),
            ExecutionTelemetry(run_id="aborted", graph_id="g", final_status=RunStatus.ABORTED),
        ]
        for item in runs:
            await store.record(item)
        assert not await store.needs_reflection("success")
        assert not await store.needs_reflection("retry-two")
        assert await store.needs_reflection("retry-three")
        assert await store.needs_reflection("failed")
        assert await store.needs_reflection("friction")
        assert not await store.needs_reflection("aborted")
        claimed = await store.claim_reflection_candidates()
        assert set(claimed) == {"retry-three", "failed", "friction"}
        assert await store.claim_reflection_candidates() == []
        await store.complete_reflection(claimed, succeeded=False)
        assert set(await store.claim_reflection_candidates()) == set(claimed)
    run(scenario())
