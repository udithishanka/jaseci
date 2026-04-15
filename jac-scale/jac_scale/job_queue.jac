"""JobQueue — Redis List-backed job queue for cross-service work distribution.

Producer calls submit() to enqueue jobs (LPUSH).
Consumer calls consume() to dequeue jobs (BRPOP — blocking pop from tail).
"""
import json;
import from jac_scale.db { Db }


obj JobQueue {
    has queue_key: str = "ai:jobs",
        db: Db;

    """Submit a job payload dict. Returns current queue depth."""
    def submit(payload: dict) -> int;

    """Blocking consume — waits up to timeout seconds for a job.
    Returns the job payload dict, or None if timeout expires."""
    def consume(timeout: int = 5) -> dict | None;

    """Current number of jobs waiting in the queue."""
    def depth() -> int;
}
