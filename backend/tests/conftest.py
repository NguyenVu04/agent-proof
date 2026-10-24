import pytest


@pytest.fixture(scope="session")
def app():
    from main import app

    return app
