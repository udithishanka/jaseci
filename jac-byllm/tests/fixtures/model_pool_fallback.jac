"""Test ModelPool fallback: primary fails, Router falls back to secondary.

Patches litellm.completion (the function the Router calls internally) so
the Router's actual fallback logic runs. Primary model raises an error,
secondary returns a canned response — proving the fallback chain works.
"""
import from byllm.lib { MockLLM, ModelPool }
import unittest.mock;
import from litellm.exceptions { RateLimitError }

glob m1 = MockLLM(model_name="gpt-3.5-turbo", config={"outputs": []});
glob m2 = MockLLM(model_name="gpt-4", config={"outputs": []});
glob pool = ModelPool(models=[m1, m2], strategy="fallback");

def get_answer(question: str) -> str by pool();

glob _call_count = 0;

def _mock_litellm_completion(*args: object, **kwargs: object) -> dict {
    global _call_count;
    _call_count += 1;
    model = kwargs.get("model", "");
    if "gpt-3.5-turbo" in str(model) {
        raise RateLimitError(
            message="Rate limit exceeded",
            model="gpt-3.5-turbo",
            llm_provider="openai",
        );
    }
    return {
        "id": "mock",
        "model": "gpt-4",
        "object": "chat.completion",
        "choices": [{
            "message": {
                "content": "fallback_success",
                "role": "assistant",
                "tool_calls": None,
            },
            "finish_reason": "stop",
            "index": 0,
        }],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
    };
}

with entry {
    # Verify router structure
    ml = pool._router.model_list;
    aliases = [m["model_name"] for m in ml];
    fb_list = pool._router.fallbacks;
    print(f"alias:{pool.model_name}");
    print(f"aliases:{aliases}");
    print(f"has_fallbacks:{len(fb_list) > 0}");
    print(f"primary_in_fallbacks:{'pool-primary' in fb_list[0]}");

    # Patch litellm.completion so the Router's internal fallback runs
    with unittest.mock.patch("litellm.completion", side_effect=_mock_litellm_completion) {
        result = get_answer("test question");
        print(f"result:{result}");
        print(f"calls:{_call_count}");
    }
}
