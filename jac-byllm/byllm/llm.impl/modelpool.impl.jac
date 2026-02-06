"""ModelPool implementation — fallback and load-balancing for multiple LLMs."""
import threading;
import time;
import from litellm.exceptions {
    RateLimitError,
    ServiceUnavailableError,
    APIConnectionError,
    Timeout,
    InternalServerError
}
import from byllm.mtir { MTRuntime }

"""Allow pool() call syntax, storing call_params and returning self."""
impl ModelPool.__call__(**kwargs: object) -> ModelPool {
    self.call_params = kwargs;
    return self;
}

"""Initialize the ModelPool, setting up the threading lock."""
impl ModelPool.postinit -> None {
    self._lock = threading.Lock();
    self._cooldown_until = {};
    if len(self.models) == 0 {
        raise ValueError("ModelPool requires at least one model.") ;
    }
}

"""Invoke with fallback across models.

For each model attempt, creates a fresh MTRuntime from the stored MTIR
to avoid state pollution from partial ReAct loops.
"""
impl ModelPool.invoke(mt_run: MTRuntime) -> object {
    ordered_models = self._select_models_order();
    last_exception: Exception | None = None;
    is_first_attempt = True;
    for (idx, model) in ordered_models {
        for attempt in range(self.max_retries_per_model) {
            try {
                # Create a fresh MTRuntime for retries to avoid state
                # pollution from partial ReAct loops (tool calls, messages).
                # Reuse the original mt_run on the very first attempt.
                if is_first_attempt {
                    current_mt_run = mt_run;
                    is_first_attempt = False;
                } else {
                    current_mt_run = MTRuntime.factory(mt_run.mtir);
                }
                result = model.invoke(mt_run=current_mt_run);
                # Success — update round-robin index for next call
                with self._lock {
                    self._current_index = (idx + 1) % len(self.models);
                }
                return result;
            } except Exception as e {
                if self._is_retriable(e) {
                    last_exception = e;
                    logger.warning(
                        f"ModelPool: {model.model_name} failed "
                        f"(attempt {attempt + 1}/{self.max_retries_per_model}): "
                        f"{type(e).__name__}: {e}. "
                        f"{'Retrying same model...'
                        if attempt + 1 < self.max_retries_per_model
                        else 'Falling back to next model...'}"
                    );
                    if isinstance(e, RateLimitError) {
                        self._mark_cooldown(idx);
                    }
                } else {
                    # Non-retriable error — raise immediately, no fallback
                    raise ;
                }
            }
        }
    }
    # All models exhausted
    if last_exception is not None {
        raise last_exception ;
    }
    raise RuntimeError("All models in ModelPool are unavailable.") ;
}

"""Select model order based on strategy, skipping cooled-down models."""
impl ModelPool._select_models_order -> list {
    result: list = [];
    n = len(self.models);
    if self.strategy == "round_robin" {
        with self._lock {
            start: int = self._current_index;
        }
        for i in range(n) {
            idx = (start + i) % n;
            if not self._is_cooled_down(idx) {
                result.append((idx, self.models[idx]));
            }
        }
    } elif self.strategy == "fallback" {
        for (idx, model) in enumerate(self.models) {
            if not self._is_cooled_down(idx) {
                result.append((idx, model));
            }
        }
    } else {
        raise ValueError(
            f"Unknown ModelPool strategy: '{self.strategy}'. Use 'fallback' or 'round_robin'."
        ) ;
    }
    # If all models are cooled down, try them all anyway
    # (cooldowns may expire during execution)
    if len(result) == 0 {
        logger.warning(
            "ModelPool: All models are cooled down. Trying all models anyway."
        );
        if self.strategy == "round_robin" {
            with self._lock {
                start: int = self._current_index;
            }
            result = [
                ((start + i) % n, self.models[(start + i) % n]) for i in range(n)
            ];
        } else {
            result = [(idx, self.models[idx]) for idx in range(n)];
        }
    }
    return result;
}

"""Check if a model is currently in cooldown."""
impl ModelPool._is_cooled_down(index: int) -> bool {
    with self._lock {
        until = self._cooldown_until.get(index, 0.0);
        return time.time() < until;
    }
}

"""Mark a model as cooled down for cooldown_seconds."""
impl ModelPool._mark_cooldown(index: int) -> None {
    with self._lock {
        self._cooldown_until[index] = time.time() + self.cooldown_seconds;
    }
    logger.info(
        f"ModelPool: Model at index {index} cooled down for {self.cooldown_seconds}s."
    );
}

"""Check if an exception is retriable (transient errors only)."""
impl ModelPool._is_retriable(exc: Exception) -> bool {
    return isinstance(
        exc,
        (
            RateLimitError,
            ServiceUnavailableError,
            APIConnectionError,
            Timeout,
            InternalServerError,

        )
    );
}
