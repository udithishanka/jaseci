"""Test ModelPool fallback: first model errors, second succeeds."""
import from byllm.lib { MockLLM, ModelPool }
import from litellm.exceptions { RateLimitError }

# First model: raises RateLimitError then would succeed (but pool moves on)
glob llm1 = MockLLM(
    model_name="mockllm",
    config={
        "outputs": ["should_not_reach"],
        "errors": [RateLimitError(message="Rate limit exceeded", model="mock1", llm_provider="mock")]
    }
);

# Second model: succeeds immediately
glob llm2 = MockLLM(
    model_name="mockllm",
    config={"outputs": ["fallback_success"]}
);

glob pool = ModelPool(models=[llm1, llm2], strategy="fallback");

def get_answer(question: str) -> str by pool();

with entry {
    result = get_answer("test question");
    print(result);
}
