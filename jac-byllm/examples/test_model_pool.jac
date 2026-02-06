"""Test ModelPool — hammer free-tier key to hit rate limit, show fallback to paid key."""
import os;
import from byllm.lib { Model, ModelPool }

# KEY1: free-tier key (will rate-limit quickly)
# KEY2: paid key (fallback)
glob llm1 = Model(model_name="gemini/gemini-2.5-flash", api_key=os.getenv("GEMINI_API_KEY_1", "")),
     llm2 = Model(model_name="gemini/gemini-2.5-flash", api_key=os.getenv("GEMINI_API_KEY_2", "")),
     pool = ModelPool(models=[llm1, llm2], strategy="fallback", cooldown_seconds=30.0);

def answer(question: str) -> str by pool();

with entry {
    # Fire 60 rapid requests to try to hit the free-tier rate limit
    for i in range(60) {
        try {
            result = answer(f"Say just the number {i}. Nothing else.");
            print(f"[{i}] OK: {result.strip()[:40]}");
        } except Exception as e {
            print(f"[{i}] FAILED: {type(e).__name__}: {str(e)[:60]}");
        }
    }
}
