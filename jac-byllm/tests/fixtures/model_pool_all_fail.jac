"""Test ModelPool: all models fail, exception propagates to caller.

Patches litellm.completion to always raise, so the Router exhausts all
deployments and the error reaches the caller.
"""
import from byllm.lib { MockLLM, ModelPool }
import unittest.mock;
import from litellm.exceptions { RateLimitError }

glob m1 = MockLLM(model_name="gpt-3.5-turbo", config={"outputs": []});
glob m2 = MockLLM(model_name="gpt-4", config={"outputs": []});
glob pool = ModelPool(models=[m1, m2], strategy="fallback");

def get_answer(question: str) -> str by pool();

def _mock_always_fail(*args: object, **kwargs: object) -> object {
    raise RateLimitError(
        message="All deployments exhausted",
        model="test",
        llm_provider="openai",
    );
}

with entry {
    with unittest.mock.patch("litellm.completion", side_effect=_mock_always_fail) {
        try {
            result = get_answer("test");
            print(f"UNEXPECTED: {result}");
        } except Exception as e {
            print(f"EXPECTED_ERROR: {type(e).__name__}");
        }
    }
}
