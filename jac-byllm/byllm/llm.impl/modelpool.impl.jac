"""ModelPool implementation — in-process LiteLLM Router for fallback and load-balancing."""
import from typing { Generator }

"""Build a litellm.Router from the provided models."""
impl ModelPool.postinit -> None {
    import from litellm { Router }
    if not self.models {
        raise ValueError("ModelPool requires at least one model.");
    }
    model_list: list = [];
    for (i, model) in enumerate(self.models) {
        litellm_params: dict = {
            "model": model.model_name,
            "api_key": model.api_key or model.config.get("api_key", "") or None,
            "order": i,
        };
        base_url = (
            model.config.get("base_url")
            or model.config.get("host")
            or model.config.get("api_base")
        );
        if base_url {
            litellm_params["api_base"] = base_url;
        }
        model_list.append({
            "model_name": "pool-model",
            "litellm_params": litellm_params,
            "model_info": {"id": f"pool-{i}"},
        });
    }
    self._router = Router(
        model_list=model_list,
        routing_strategy=self.strategy,
        num_retries=self.num_retries,
        timeout=self.timeout,
    );
    self.model_name = "pool-model";
    if any(m.config.get("verbose", False) for m in self.models) {
        self.config["verbose"] = True;
    }
    logger.info(
        f"ModelPool initialized with {len(self.models)} models, "
        f"strategy='{self.strategy}'"
    );
}

"""Route a non-streaming call through the LiteLLM Router."""
impl ModelPool.model_call_no_stream(params: dict) -> dict {
    return self._router.completion(**params);
}

"""Route a streaming call through the LiteLLM Router."""
impl ModelPool.model_call_with_stream(params: dict) -> Generator[str, None, None] {
    return self._router.completion(stream=True, **params);
}
