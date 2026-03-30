"""Test ModelPool exception propagation when all models fail.

Verifies that when the Router exhausts all deployments, the exception
propagates to the caller.
"""
import from byllm.lib { MockLLM, ModelPool }

glob m1 = MockLLM(model_name="gpt-3.5-turbo", config={"outputs": []});
glob m2 = MockLLM(model_name="gpt-4", config={"outputs": []});
glob pool = ModelPool(models=[m1, m2], strategy="simple-shuffle");

def get_answer(question: str) -> str by pool();

def mock_completion(**_kwargs: object) -> object {
    raise Exception("All deployments exhausted");
}

with entry {
    pool._router.completion = mock_completion;
    try {
        result = get_answer("test");
        print(f"UNEXPECTED: {result}");
    } except Exception as e {
        print(f"EXPECTED_ERROR: {type(e).__name__}");
    }
}
