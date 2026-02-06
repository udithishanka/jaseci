"""Test Model with fallbacks parameter — convenience API for fallback."""
import from byllm.lib { Model, MockLLM }
import from litellm.exceptions { RateLimitError }

# Primary model that will fail with rate limit
glob primary = Model(
    model_name="mockllm",
    config={
        "outputs": ["should_not_reach"],
        "errors": [RateLimitError(message="Rate limit primary", model="mock_primary", llm_provider="mock")]
    },
    fallbacks=[
        MockLLM(
            model_name="mockllm",
            config={"outputs": ["fallback_via_convenience"]}
        )
    ]
);

def get_answer(question: str) -> str by primary();

with entry {
    result = get_answer("test");
    print(result);
}
