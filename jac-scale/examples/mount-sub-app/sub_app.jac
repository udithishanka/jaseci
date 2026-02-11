"""A simple FastAPI sub-application to test mounting."""
import from fastapi { FastAPI }

glob app = FastAPI(title="Mounted Sub-App");

@app.get("/")
def root -> dict {
    return {"message": "Hello from mounted sub-app!"};
}

@app.get("/health")
def health -> dict {
    return {"status": "ok"};
}
