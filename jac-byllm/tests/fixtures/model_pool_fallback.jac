"""Test ModelPool fallback: verify router is initialized with correct fallback order.

Checks that model_list entries have the correct order values for
priority-based fallback, and that a successful dispatch works.
"""
import from byllm.lib { MockLLM, ModelPool }

glob m1 = MockLLM(model_name="gpt-3.5-turbo", config={"outputs": []});
glob m2 = MockLLM(model_name="gpt-4", config={"outputs": []});
glob m3 = MockLLM(model_name="gpt-4o", config={"outputs": []});
glob pool = ModelPool(models=[m1, m2, m3], strategy="simple-shuffle");

def get_answer(question: str) -> str by pool();

def mock_completion(**_kwargs: object) -> dict {
    return {
        "model": "gpt-4",
        "choices": [{
            "message": {
                "content": "fallback_success",
                "role": "assistant",
                "tool_calls": None,
            },
            "finish_reason": "stop",
            "index": 0,
        }],
    };
}

with entry {
    ml = pool._router.model_list;
    orders = [m["litellm_params"]["order"] for m in ml];
    print(f"order_values:{orders}");
    print(f"model_count:{len(ml)}");
    print(f"models:{[m['litellm_params']['model'] for m in ml]}");

    pool._router.completion = mock_completion;
    result = get_answer("test question");
    print(result);
}
