"""Test ModelPool load-balancing init: all models share "pool-model" alias."""
import from byllm.lib { MockLLM, ModelPool }

glob m1 = MockLLM(model_name="gpt-3.5-turbo", config={"outputs": []});
glob m2 = MockLLM(model_name="gpt-4o-mini", config={"outputs": []});
glob m3 = MockLLM(model_name="gemini/gemini-2.0-flash", config={"outputs": []});
glob pool = ModelPool(models=[m1, m2, m3], strategy="simple-shuffle");

with entry {
    ml = pool._router.model_list;
    all_same = all(m["model_name"] == "pool-model" for m in ml);
    models = [m["litellm_params"]["model"] for m in ml];
    print(f"alias:{pool.model_name}");
    print(f"deploy_count:{len(ml)}");
    print(f"all_share_alias:{all_same}");
    print(f"models:{models}");
}
