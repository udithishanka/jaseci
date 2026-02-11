"""Test fixture: a minimal ASGI sub-application for mount testing."""

from fastapi import FastAPI

app = FastAPI()


@app.get("/")
def root() -> dict:
    return {"source": "mounted"}


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}
