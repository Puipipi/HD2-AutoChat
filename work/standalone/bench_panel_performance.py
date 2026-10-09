"""Offline LuaJIT/QPC panel-signature benchmark; never starts the game."""
from __future__ import annotations

import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "work" / "standalone" / "tests"
sys.path.insert(0, str(TESTS))
from test_auto_chat_probe import make_harness  # noqa: E402

FRAMES = 12000
WARMUP = 1200


def extract_function(source: str) -> tuple[str, int, int]:
    start = source.index("local function panel_signature()")
    end = source.index("\nend", start) + len("\nend")
    return source[start:end], start, end


def split_fields(text: str) -> list[str]:
    fields, start = [], 0
    paren = bracket = brace = 0
    quote = None
    escaped = False
    for index, char in enumerate(text):
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in "'\"":
            quote = char
        elif char == "(":
            paren += 1
        elif char == ")":
            paren -= 1
        elif char == "[":
            bracket += 1
        elif char == "]":
            bracket -= 1
        elif char == "{":
            brace += 1
        elif char == "}":
            brace -= 1
        elif char == "," and paren == bracket == brace == 0:
            fields.append(text[start:index].strip())
            start = index + 1
    tail = text[start:].strip()
    if tail:
        fields.append(tail)
    return fields


def build_variants() -> tuple[dict[str, str], int]:
    current_path = ROOT / "src" / "auto_chat.lua"
    current = current_path.read_text(encoding="utf-8")
    old = subprocess.check_output(
        ["git", "show", "v0.8.3:src/auto_chat.lua"], cwd=ROOT
    ).decode("utf-8")
    old_function, _, _ = extract_function(old)
    current_function, start, end = extract_function(current)
    # Keep every other current-source change identical: the control is the current
    # module with only this function replaced by the v0.8.3 uncached implementation.
    legacy = current[:start] + old_function + current[end:]
    fields_start = old_function.index("return table.concat({") + len("return table.concat({")
    fields_end = old_function.index("}, '|')", fields_start)
    return {"legacy panel": legacy, "cached panel": current}, len(
        split_fields(old_function[fields_start:fields_end])
    )


def make_runtime(source_text: str):
    lua, harness = make_harness()
    native_ffi = lua.eval("require('ffi')")
    native_ffi.cdef("int QueryPerformanceCounter(int64_t *); int QueryPerformanceFrequency(int64_t *);")
    lua.globals().bench_ffi = native_ffi
    lua.globals().bench_kernel = native_ffi.load("kernel32")
    harness.clear_options()
    harness.install()
    harness.build_image()
    chunk = lua.eval("loadstring")(source_text, "@panel_performance_bench.lua")
    if isinstance(chunk, tuple):
        raise RuntimeError(f"Lua compile failed: {chunk[1]}")
    mod = chunk()
    lua.execute(r"""
        local frequency=bench_ffi.new('int64_t[1]')
        assert(bench_kernel.QueryPerformanceFrequency(frequency)~=0)
        PERF_FREQ=tonumber(frequency[0])
        function perf_updates(n, force_rebuild)
            local start,finish=bench_ffi.new('int64_t[1]'),bench_ffi.new('int64_t[1]')
            local samples={}
            local panel=HD2AutoChat.debug_panel()
            for i=1,n do
                if force_rebuild then panel.hint=(i%2==0) and 'bench A' or 'bench B' end
                bench_kernel.QueryPerformanceCounter(start)
                _G.update()
                bench_kernel.QueryPerformanceCounter(finish)
                samples[i]=tonumber(finish[0]-start[0])*1000000/PERF_FREQ
            end
            return table.concat(samples,',')
        end
    """)
    return lua, harness, mod


def collect(lua, count: int, force: bool = False) -> list[float]:
    return [float(item) for item in lua.eval(
        f"perf_updates({count}, {'true' if force else 'false'})"
    ).split(",")]


def percentile(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * quantile))]


def run_variant(source: str) -> dict[str, list[float] | str]:
    lua, _, mod = make_runtime(source)
    lua.execute(f"for i=1,{WARMUP} do update() end")
    closed = collect(lua, FRAMES)
    mod[b"debug_set_open"](True)
    lua.execute(f"for i=1,{WARMUP} do update() end")
    opened = collect(lua, FRAMES)
    forced = collect(lua, FRAMES, force=True)
    return {
        "closed": closed,
        "open": opened,
        "forced": forced,
        "signature": mod[b"debug_panel_signature"](),
        "jit": str(bool(lua.eval("jit.status()"))),
    }


def report(results: dict[str, list[dict]]) -> None:
    for name, runs in results.items():
        print(name)
        for scenario in ("closed", "open", "forced"):
            samples = [run[scenario] for run in runs]
            means = [statistics.mean(row) for row in samples]
            p95s = [percentile(row, .95) for row in samples]
            p99s = [percentile(row, .99) for row in samples]
            print(f"  {scenario}: median(run mean)={statistics.median(means):.2f}us; "
                  f"p95 range={min(p95s):.2f}-{max(p95s):.2f}us; "
                  f"p99 median={statistics.median(p99s):.2f}us")
        print(f"  LuaJIT active={runs[0]['jit']}")


def main() -> None:
    variants, field_count = build_variants()
    results = {name: [] for name in variants}
    # Three interleaved measurements per variant to reduce order/thermal bias.
    order = ["legacy panel", "cached panel", "cached panel",
             "legacy panel", "legacy panel", "cached panel",
             "cached panel", "legacy panel", "cached panel"]
    signatures = {}
    for index, name in enumerate(order, 1):
        result = run_variant(variants[name])
        signatures.setdefault(name, result["signature"])
        if signatures[name] != result["signature"]:
            raise RuntimeError(f"{name} signature changed across runs")
        results[name].append(result)
        print(f"run {index}/{len(order)} {name}: complete", flush=True)
    if signatures["legacy panel"] != signatures["cached panel"]:
        raise RuntimeError("legacy and cached signatures differ")
    print(f"fields={field_count}; warmup={WARMUP}; frames/scenario/run={FRAMES}; "
          "scenarios=closed,open,forced; timer=QueryPerformanceCounter")
    report(results)
    print("signature exact-match; native/game/UI APIs remain stubbed")


if __name__ == "__main__":
    main()
