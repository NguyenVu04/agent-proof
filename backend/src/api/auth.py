from fastapi import APIRouter

from core.security import CurrentPrincipal

router = APIRouter(prefix="/api/v1", tags=["auth"])


@router.get("/me")
async def me(principal: CurrentPrincipal) -> dict:
    return {
        "sub": principal.sub,
        "scopes": sorted(principal.scopes),
        "is_machine": principal.is_machine,
    }
