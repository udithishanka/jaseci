"""Test ModelPool when all models fail — should raise the last exception."""
import from byllm.lib { MockLLM, ModelPool }
import from litellm.exceptions { RateLimitError }

glob llm1 = MockLLM(
    model_name="mockllm",
    config={
        "outputs": ["unused"],
        "errors": [RateLimitError(message="Rate limit model1", model="mock1", llm_provider="mock")]
    }
);

glob llm2 = MockLLM(
    model_name="mockllm",
    config={
        "outputs": ["unused"],
        "errors": [RateLimitError(message="Rate limit model2", model="mock2", llm_provider="mock")]
    }
);

glob pool = ModelPool(models=[llm1, llm2], strategy="fallback");

def get_answer(question: str) -> str by pool();

with entry {
    try {
        result = get_answer("test");
        print(f"UNEXPECTED: {result}");
    } except Exception as e {
        print(f"EXPECTED_ERROR: {type(e).__name__}");
    }
}
