import logging
import re
import sys
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from neo4j import AsyncGraphDatabase
from qdrant_client import AsyncQdrantClient
from redis.asyncio import Redis

from api import auth, health
from core.config import settings
from core.logging import request_id_var, setup_logging
from infrastructure.db import engine

setup_logging(settings.LOG_LEVEL)
logger = logging.getLogger("agentproof.api")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # All clients connect lazily; nothing here touches the network.
    app.state.redis = Redis.from_url(settings.REDIS_URL)
    app.state.qdrant = AsyncQdrantClient(url=settings.QDRANT_URL, api_key=settings.QDRANT_API_KEY)
    app.state.neo4j = AsyncGraphDatabase.driver(
        settings.NEO4J_URI, auth=(settings.NEO4J_USER, settings.NEO4J_PASSWORD)
    )
    yield
    await app.state.redis.aclose()
    await app.state.qdrant.close()
    await app.state.neo4j.close()
    await engine.dispose()


docs = settings.ENVIRONMENT != "production"
app = FastAPI(
    title="AgentProof API",
    version="0.1.0",
    description=(
        "Inspect AI agent runs, verify behavior against policies and expected workflows, "
        "and gate releases with evidence-backed evaluations."
    ),
    openapi_tags=[
        {"name": "health", "description": "Liveness and readiness probes"},
        {"name": "auth", "description": "Caller identity (Auth0 bearer token)"},
    ],
    docs_url="/api/docs" if docs else None,
    redoc_url="/api/redoc" if docs else None,
    openapi_url="/api/openapi.json" if docs else None,
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_methods=["*"],
    allow_headers=["Authorization", "Content-Type", "X-Request-ID"],
    expose_headers=["X-Request-ID"],
)

_REQUEST_ID = re.compile(r"^[\w.-]{1,128}$")
_API_CSP = "default-src 'none'; frame-ancestors 'none'"
# Swagger UI / ReDoc load their bundles from jsdelivr and fonts from Google.
_DOCS_CSP = (
    "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; "
    "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://fonts.googleapis.com; "
    "font-src https://fonts.gstatic.com; img-src 'self' data: https://fastapi.tiangolo.com; "
    "worker-src blob:; frame-ancestors 'none'"
)


# Registered after CORS, so it is the outermost layer and sees every response.
@app.middleware("http")
async def request_context(request: Request, call_next):
    incoming = request.headers.get("x-request-id", "")
    rid = incoming if _REQUEST_ID.match(incoming) else uuid.uuid4().hex
    token = request_id_var.set(rid)
    start = time.perf_counter()
    try:
        response = await call_next(request)
    except Exception:
        logger.exception(
            "unhandled error", extra={"method": request.method, "path": request.url.path}
        )
        raise
    finally:
        request_id_var.reset(token)

    path = request.url.path
    response.headers["X-Request-ID"] = rid
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Content-Security-Policy"] = (
        _DOCS_CSP if path in ("/api/docs", "/api/redoc") else _API_CSP
    )
    logger.info(
        "request",
        extra={
            "request_id": rid,
            "method": request.method,
            "path": path,
            "status": response.status_code,
            "duration_ms": round((time.perf_counter() - start) * 1000, 1),
        },
    )
    return response


app.include_router(health.router)
app.include_router(auth.router)


if __name__ == "__main__":
    import uvicorn

    # Run as a script (`python src/__main__.py`), not `python src`: the reload worker
    # re-imports "__main__" by file path, which multiprocessing skips for package mains.
    uvicorn.run(
        "__main__:app",
        host="0.0.0.0",
        port=8000,
        reload="--reload" in sys.argv,
        proxy_headers=True,
        forwarded_allow_ips="*",
        access_log=False,
    )
