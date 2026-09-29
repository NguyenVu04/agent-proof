import asyncio
import logging

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from sqlalchemy import text

from infrastructure.db import engine

logger = logging.getLogger("agentproof.api")
router = APIRouter(prefix="/health", tags=["health"])


@router.get("/live")
async def live() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/ready")
async def ready(request: Request) -> JSONResponse:
    s = request.app.state

    async def postgres():
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))

    checks = {
        "postgres": postgres(),
        "redis": s.redis.ping(),
        "qdrant": s.qdrant.get_collections(),
        "neo4j": s.neo4j.verify_connectivity(),
    }
    results = await asyncio.gather(
        *(asyncio.wait_for(c, timeout=3) for c in checks.values()), return_exceptions=True
    )
    status = {
        name: "ok" if not isinstance(r, BaseException) else f"error: {type(r).__name__}"
        for name, r in zip(checks, results)
    }
    healthy = all(v == "ok" for v in status.values())
    if not healthy:
        logger.warning("readiness failed", extra={"dependencies": status})
    return JSONResponse({"ready": healthy, "dependencies": status}, 200 if healthy else 503)
