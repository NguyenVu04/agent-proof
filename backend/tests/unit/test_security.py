import asyncio

import pytest
from fastapi import HTTPException

from core.security import Principal, _deny, require_scopes


def test_deny_hides_reason():
    e = _deny(401, "secret reason")
    assert e.detail == "Not authenticated"
    assert e.headers == {"WWW-Authenticate": "Bearer"}

    e = _deny(403, "secret reason")
    assert e.detail == "Forbidden"
    assert e.headers is None


def test_require_scopes():
    p = Principal(sub="user", scopes=frozenset({"a"}), is_machine=False, client_id=None)
    assert asyncio.run(require_scopes("a")(p)) is p

    with pytest.raises(HTTPException) as e:
        asyncio.run(require_scopes("a", "b")(p))
    assert e.value.status_code == 403
