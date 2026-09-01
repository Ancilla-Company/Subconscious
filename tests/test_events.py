import asyncio
from unittest.mock import Mock

from subconscious_engine.events import EventBus


def run(coro):
    return asyncio.run(coro)


def test_publish_fans_out_to_each_subscriber_and_unsubscribes():
    async def scenario():
        bus = EventBus()
        async with bus.subscribe() as first:
            async with bus.subscribe() as second:
                await bus.publish("changed", {"id": 7})
                left, right = await first.get(), await second.get()
                assert left == right
                assert left["type"] == "changed"
                assert left["data"] == {"id": 7}
                assert left["timestamp"].endswith("+00:00")
            assert second not in bus._subscribers
        assert not bus._subscribers
    run(scenario())


def test_bounded_queue_drops_oldest_event_only_for_slow_subscriber():
    async def scenario():
        bus = EventBus(capacity=1)
        async with bus.subscribe() as queue:
            await bus.publish("old", {})
            await bus.publish("new", {"value": 2})
            event = queue.get_nowait()
            assert event["type"] == "new"
            assert queue.empty()
    run(scenario())


def test_publish_without_subscribers_is_a_noop():
    run(EventBus().publish("unused", {}))


def test_queueempty_race_does_not_lose_new_event():
    async def scenario():
        bus = EventBus()
        queue = Mock()
        queue.full.return_value = True
        queue.get_nowait.side_effect = asyncio.QueueEmpty
        bus._subscribers.add(queue)
        await bus.publish("new", {})
        queue.put_nowait.assert_called_once()
    run(scenario())


def test_exception_inside_subscription_still_removes_queue():
    async def scenario():
        bus = EventBus()
        try:
            async with bus.subscribe() as queue:
                assert queue in bus._subscribers
                raise RuntimeError("consumer failed")
        except RuntimeError:
            pass
        assert not bus._subscribers
    run(scenario())
