from fastapi.testclient import TestClient


def test_ready_against_datastores(app):
    with TestClient(app) as client:
        r = client.get("/health/ready")
    assert r.status_code == 200, r.json()
