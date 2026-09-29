import runpy
from pathlib import Path

from fastapi.testclient import TestClient

# A module named __main__ can't be imported, so load it by path.
app = runpy.run_path(str(Path(__file__).parents[1] / "src" / "__main__.py"))["app"]


def test_api_smoke():
    with TestClient(app) as client:
        r = client.get("/health/live")
        assert r.status_code == 200
        assert r.headers["X-Request-ID"]
        assert r.headers["X-Content-Type-Options"] == "nosniff"

        r = client.get("/api/v1/me")
        assert r.status_code == 401
        assert r.headers["WWW-Authenticate"] == "Bearer"

        r = client.get("/api/v1/me", headers={"Authorization": "Bearer not-a-jwt"})
        assert r.status_code == 401

        schemes = client.get("/api/openapi.json").json()["components"]["securitySchemes"]
        assert schemes["HTTPBearer"]["scheme"] == "bearer"
