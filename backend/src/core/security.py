"""Auth0 JWT validation and project-scoped authorization (README: Security, UC-01)."""

import logging
from dataclasses import dataclass
from functools import cache
from typing import Annotated
from uuid import UUID

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.concurrency import run_in_threadpool
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from core.config import settings
from infrastructure.db import get_session

logger = logging.getLogger("agentproof.security")

bearer = HTTPBearer(auto_error=False, description="Auth0 access token")


@dataclass(frozen=True)
class Principal:
    sub: str
    scopes: frozenset[str]
    is_machine: bool
    client_id: str | None  # azp claim; identifies M2M clients


@cache
def _jwks() -> jwt.PyJWKClient:
    return jwt.PyJWKClient(f"{settings.AUTH0_ISSUER}.well-known/jwks.json", cache_keys=True)


def _deny(code: int, reason: str, **ctx: object) -> HTTPException:
    logger.warning("access denied", extra={"reason": reason, **ctx})
    headers = {"WWW-Authenticate": "Bearer"} if code == status.HTTP_401_UNAUTHORIZED else None
    detail = "Not authenticated" if code == status.HTTP_401_UNAUTHORIZED else "Forbidden"
    return HTTPException(code, detail, headers=headers)


async def get_principal(
    creds: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
) -> Principal:
    if creds is None:
        raise _deny(401, "missing bearer token")
    if not settings.AUTH0_ISSUER or not settings.AUTH0_AUDIENCE:
        raise _deny(401, "auth not configured")
    try:
        # PyJWKClient does blocking HTTP on cache miss
        key = await run_in_threadpool(_jwks().get_signing_key_from_jwt, creds.credentials)
        claims = jwt.decode(
            creds.credentials,
            key.key,
            algorithms=["RS256"],
            audience=settings.AUTH0_AUDIENCE,
            issuer=settings.AUTH0_ISSUER,
            options={"require": ["exp", "iss", "aud", "sub"]},
        )
    except jwt.PyJWTError as e:
        raise _deny(401, f"invalid token: {type(e).__name__}") from None

    # M2M tokens carry space-separated "scope"; Auth0 RBAC puts user grants in "permissions"
    scopes = frozenset(claims.get("scope", "").split()) | frozenset(claims.get("permissions", []))
    return Principal(
        sub=claims["sub"],
        scopes=scopes,
        is_machine=claims.get("gty") == "client-credentials",
        client_id=claims.get("azp"),
    )


CurrentPrincipal = Annotated[Principal, Depends(get_principal)]


def require_scopes(*required: str):
    async def check(principal: CurrentPrincipal) -> Principal:
        missing = set(required) - principal.scopes
        if missing:
            raise _deny(403, "missing scopes", sub=principal.sub, missing=sorted(missing))
        return principal

    return check


async def require_project_access(
    project_id: UUID,
    principal: CurrentPrincipal,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> Principal:
    """Scopes never grant cross-project access (BR-03); membership is checked per project."""
    if principal.is_machine:
        stmt = text(
            "SELECT 1 FROM machine_clients WHERE project_id = :p "
            "AND auth0_client_id = :c AND revoked_at IS NULL"
        )
        params = {"p": project_id, "c": principal.client_id}
    else:
        stmt = text(
            "SELECT 1 FROM project_members m JOIN users u ON u.id = m.user_id "
            "WHERE m.project_id = :p AND u.auth0_sub = :s"
        )
        params = {"p": project_id, "s": principal.sub}
    if (await session.execute(stmt, params)).first() is None:
        raise _deny(403, "not a project member", sub=principal.sub, project_id=str(project_id))
    return principal
