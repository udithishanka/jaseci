"""JobQueue implementation."""

impl JobQueue.submit(payload: dict) -> int {
    return self.db.lpush(self.queue_key, json.dumps(payload));
}

impl JobQueue.consume(timeout: int = 5) -> dict | None {
    result = self.db.brpop([self.queue_key], timeout=timeout);
    if result is None {
        return None;
    }
    return json.loads(result[1]);
}

impl JobQueue.depth() -> int {
    return self.db.llen(self.queue_key);
}
