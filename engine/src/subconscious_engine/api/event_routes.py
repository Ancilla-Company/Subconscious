"""Server-sent event fan-out endpoint."""

import json

from starlette.requests import Request
from starlette.responses import StreamingResponse
from starlette.routing import Route


async def event_stream(request: Request) -> StreamingResponse:
    async def generate():
        async with request.app.state.event_bus.subscribe() as queue:
            while True:
                event = await queue.get()
                yield f"data: {json.dumps(event, separators=(',', ':'))}\n\n"
    return StreamingResponse(generate(), media_type="text/event-stream", headers={
        "Cache-Control": "no-cache", "Connection": "keep-alive", "X-Accel-Buffering": "no"})


def event_routes() -> list[Route]:
    return [Route("/api/v1/stream", event_stream, methods=["GET"])]
