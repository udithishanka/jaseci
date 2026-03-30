"""ModelPool implementation — in-process LiteLLM Router for fallback and load-balancing."""
import from typing { Generator }

"""Build a litellm.Router from the provided models.

For "fallback" strategy: each model gets a unique alias and the Router's
fallbacks list chains them in order (primary -> fallback-1 -> fallback-2 ...).
For load-balancing strategies: all models share the "pool-model" alias so the
Router picks among them using the chosen strategy.
"""
impl ModelPool.postinit -> None {
    import from litellm { Router }
    if not self.models {
        raise ValueError("ModelPool requires at least one model.");
    }
    is_fallback = self.strategy == "fallback";
    model_list: list = [];
    fallback_names: list = [];
    for (i, model) in enumerate(self.models) {
        name = (
            ("pool-primary" if i == 0 else f"pool-fallback-{i}")
                if is_fallback
                else "pool-model"
        );
        litellm_params: dict = {
            "model": model.model_name,
            "api_key": model.api_key or model.config.get("api_key", "") or None,
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
            "model_name": name,
            "litellm_params": litellm_params,
            "model_info": {"id": f"pool-{i}"},
        });
        if is_fallback and i > 0 {
            fallback_names.append(name);
        }
    }
    if is_fallback {
        self._router = Router(
            model_list=model_list,
            fallbacks=[{"pool-primary": fallback_names}],
            num_retries=self.num_retries,
            timeout=self.timeout,
        );
        self.model_name = "pool-primary";
    } else {
        self._router = Router(
            model_list=model_list,
            routing_strategy=self.strategy,
            num_retries=self.num_retries,
            timeout=self.timeout,
        );
        self.model_name = "pool-model";
    }
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
