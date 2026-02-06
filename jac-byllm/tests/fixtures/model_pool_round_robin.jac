"""Test ModelPool round-robin: alternates between models across calls."""
import from byllm.lib { MockLLM, ModelPool }

# Both models succeed — round robin should alternate
glob llm1 = MockLLM(
    model_name="mockllm",
    config={"outputs": ["response_from_model_1", "response_from_model_1_again"]}
);

glob llm2 = MockLLM(
    model_name="mockllm",
    config={"outputs": ["response_from_model_2", "response_from_model_2_again"]}
);

glob pool = ModelPool(models=[llm1, llm2], strategy="round_robin");

def get_answer(question: str) -> str by pool();

with entry {
    # First call should go to model at index 0
    result1 = get_answer("question 1");
    print(result1);
    # Second call should go to model at index 1 (round robin)
    result2 = get_answer("question 2");
    print(result2);
}
