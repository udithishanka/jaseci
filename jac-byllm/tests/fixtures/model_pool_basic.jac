"""Test ModelPool router initialization and basic dispatch.

Verifies the Router is constructed with correct model_list structure
and that a mocked completion call returns through the dispatch pipeline.
"""
import from byllm.lib { MockLLM, ModelPool }

glob m1 = MockLLM(model_name="gpt-3.5-turbo", config={"outputs": []});
glob m2 = MockLLM(model_name="gpt-4o-mini", config={"outputs": []});
glob m3 = MockLLM(model_name="gemini/gemini-2.0-flash", config={"outputs": []});
glob pool = ModelPool(models=[m1, m2, m3], strategy="simple-shuffle");

def get_answer(question: str) -> str by pool();

def mock_completion(**_kwargs: object) -> dict {
    return {
        "model": "mock-pool-model",
        "choices": [{
            "message": {
                "content": "basic_success",
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
    all_same = all(m["model_name"] == "pool-model" for m in ml);
    print(f"alias:{pool.model_name}");
    print(f"deploy_count:{len(ml)}");
    print(f"all_share_alias:{all_same}");

    pool._router.completion = mock_completion;
    result = get_answer("test");
    print(result);
}
