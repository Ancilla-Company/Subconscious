"""Local API for the account profiles hosted by this engine process."""

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route


async def list_profiles(request: Request) -> Response:
    manager = getattr(request.app.state, "profile_manager", None)
    if manager is None:
        return JSONResponse({"current": None, "profiles": []})
    return JSONResponse(
        {
            "current": request.app.state.profile_id,
            "profiles": manager.list_profiles(),
        }
    )


def profile_routes() -> list[Route]:
    return [Route("/api/v1/profiles", list_profiles, methods=["GET"])]
