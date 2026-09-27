from fastapi.testclient import TestClient

from api.main import app


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
