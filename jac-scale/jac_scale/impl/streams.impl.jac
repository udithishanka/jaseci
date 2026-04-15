"""EventStream implementation."""

impl EventStream.publish(event: dict) -> str {
    return self.db.xadd(
        self.stream_key,
        {"data": json.dumps(event)},
        maxlen=self.max_size,
        approximate=True
    );
}

impl EventStream.read_new(last_id: str = "0-0", count: int = 100, block_ms: int = 0) -> tuple {
    result = self.db.xread(
        {self.stream_key: last_id},
        count=count,
        block=block_ms
    );
    events: list = [];
    new_last_id = last_id;
    for item in result {
        for entry in item[1] {
            (entry_id, fields) = entry;
            data_str = fields.get("data", "{}");
            events.append(json.loads(data_str));
            new_last_id = entry_id;
        }
    }
    return (events, new_last_id);
}

impl EventStream.trim() -> int {
    return self.db.xtrim(self.stream_key, self.max_size);
}

impl EventStream.length() -> int {
    return self.db.xlen(self.stream_key);
}

impl EventStream.clear() -> None {
    self.db.xdel_stream(self.stream_key);
}
