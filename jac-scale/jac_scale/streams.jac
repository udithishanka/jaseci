"""EventStream — Redis Streams-backed event delivery for cross-service communication.

Replaces in-memory EventBus patterns with a distributed, persistent stream.
Multiple consumers each track their own cursor (last-seen stream ID) externally.
"""
import json;
import from jac_scale.db { Db }


obj EventStream {
    has stream_key: str,
        db: Db,
        max_size: int = 5000;

    """Publish an event dict to the stream. Auto-trims at max_size.
    Returns the stream entry ID."""
    def publish(event: dict) -> str;

    """Read events newer than last_id.
    Returns (events: list[dict], new_last_id: str).
    Caller stores new_last_id externally and passes it on the next call."""
    def read_new(last_id: str = "0-0", count: int = 100, block_ms: int = 0) -> tuple;

    """Trim stream to max_size. Returns number of entries removed."""
    def trim() -> int;

    """Get current stream length."""
    def length() -> int;

    """Delete the entire stream."""
    def clear() -> None;
}
