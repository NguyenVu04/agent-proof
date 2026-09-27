from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    ENVIRONMENT: Literal["local", "staging", "production"] = "local"
    LOG_LEVEL: str = "INFO"

    DATABASE_URL: str = "postgresql+asyncpg://agentproof:agentproof@localhost:5432/agentproof"
    REDIS_URL: str = "redis://localhost:6379/0"
    QDRANT_URL: str = "http://localhost:6333"
    QDRANT_API_KEY: str | None = None
    NEO4J_URI: str = "bolt://localhost:7687"
    NEO4J_USER: str = "neo4j"
    NEO4J_PASSWORD: str = ""

    OLLAMA_BASE_URL: str = "http://localhost:11434"
    LLM_MODEL: str = "llama3.1"

    CORS_ORIGINS: list[str] = ["http://localhost:3000", "http://localhost:5173"]
    # Auth0 issuer must end with "/" (e.g. https://tenant.eu.auth0.com/)
    AUTH0_ISSUER: str = ""
    AUTH0_AUDIENCE: str = ""


settings = Settings()
