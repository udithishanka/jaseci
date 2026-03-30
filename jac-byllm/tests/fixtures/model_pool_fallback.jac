"""Test ModelPool fallback strategy: unique aliases + fallback chain.

Verifies the Router is configured with pool-primary and pool-fallback-N
aliases, and that the fallbacks list chains them correctly.
"""
import from byllm.lib { MockLLM, ModelPool }

glob m1 = MockLLM(model_name="gpt-3.5-turbo", config={"outputs": []});
glob m2 = MockLLM(model_name="gpt-4", config={"outputs": []});
glob m3 = MockLLM(model_name="gpt-4o", config={"outputs": []});
glob pool = ModelPool(models=[m1, m2, m3], strategy="fallback");

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
    aliases = [m["model_name"] for m in ml];
    fb_list = pool._router.fallbacks;
    print(f"alias:{pool.model_name}");
    print(f"deploy_count:{len(ml)}");
    print(f"aliases:{aliases}");
    print(f"has_fallbacks:{len(fb_list) > 0}");
    print(f"primary_in_fallbacks:{'pool-primary' in fb_list[0]}");

    pool._router.completion = mock_completion;
    result = get_answer("test question");
    print(result);
}
