"""Current-source LuaJIT/QPC frame benchmark; the game and native GUI are never started."""
from __future__ import annotations

import argparse
import hashlib
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "work" / "standalone"))
import bench_panel_performance as harness  # noqa: E402


def source_text(source_ref: str | None) -> tuple[str, str]:
    if source_ref:
        text = subprocess.check_output(
            ["git", "show", f"{source_ref}:src/auto_chat.lua"], cwd=ROOT
        ).decode("utf-8")
        return text, f"git:{source_ref}:src/auto_chat.lua"
    path = ROOT / "src" / "auto_chat.lua"
    return path.read_text(encoding="utf-8"), str(path)


def make_runtime(source: str):
    lua, game, mod = harness.make_runtime(source)
    lua.globals().H, lua.globals().M = game, mod
    lua.execute(r"""
        EXTENT_CALLS=0
        local native_extents=stingray.Gui.text_extents
        stingray.Gui.text_extents=function(...)
            EXTENT_CALLS=EXTENT_CALLS+1
            return native_extents(...)
        end
        TASK_SORTS=0
        local native_sort=table.sort
        table.sort=function(list,...)
            if list[1] and list[1].bench_probe then TASK_SORTS=TASK_SORTS+1 end
            return native_sort(list,...)
        end
        function seed_future_tasks(n)
            M.tasks={}
            local due=os.time()+86400
            for i=1,n do M.tasks[i]={id='bench-'..i,name='Future '..i,
                profile='host',mode='once',time='1',message='future message',
                enabled=true,done=false,due=due,bench_probe=true} end
            local role=M.debug_automation().sync()
            assert(role=='host','future tasks must match the active role')
            assert(#M.tasks==n)
            for _,t in ipairs(M.tasks) do
                assert(t.profile==role and t.enabled and not t.done and t.due>os.time())
            end
        end
        function perf_updates(n, force_redraw)
            local start,finish=bench_ffi.new('int64_t[1]'),bench_ffi.new('int64_t[1]')
            local samples={}
            local panel=M.debug_panel()
            for i=1,n do
                if force_redraw then panel.hint=(i%2==0) and 'bench A' or 'bench B' end
                bench_kernel.QueryPerformanceCounter(start)
                _G.update()
                bench_kernel.QueryPerformanceCounter(finish)
                samples[i]=tonumber(finish[0]-start[0])*1000000/PERF_FREQ
            end
            return table.concat(samples,',')
        end
    """)
    return lua, game, mod


def counters(lua, game, mod):
    return {
        "reads": int(game[b"reads"] or 0),
        "world_lists": int(game[b"worlds_reads"] or 0),
        "text": int(game[b"text_drawn"] or 0),
        "extents": int(lua.globals().EXTENT_CALLS or 0),
        "gui_created": int(game[b"gui_created"] or 0),
        "gui_destroyed": int(game[b"gui_destroyed"] or 0),
        "frames": int(mod[b"frames"]),
    }


def percentile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * q))]


def run_case(source: str, name: str, task_count: int, opened: bool,
             force_redraw: bool, frames: int, warmup: int) -> dict:
    lua, game, mod = make_runtime(source)
    lua.globals().BENCH_TASK_COUNT = task_count
    lua.execute("seed_future_tasks(BENCH_TASK_COUNT)")
    mod[b"debug_set_open"](opened)
    lua.execute(f"for i=1,{warmup} do _G.update() end")
    lua.globals().TASK_SORTS = 0
    start = counters(lua, game, mod)
    values = [float(v) for v in lua.eval(
        f"perf_updates({frames},{'true' if force_redraw else 'false'})"
    ).split(",")]
    end = counters(lua, game, mod)
    font = mod[b"debug_font"]()
    font_mode = ("unresolved/no-draw" if not bool(font[b"resolved"])
                 else "engine-font-mock" if bool(font[b"ok"]) else "bitmap/fallback")
    first_frame = start["frames"] + 1
    periodic = [v for i, v in enumerate(values) if (first_frame + i) % 30 == 1]
    steady = [v for i, v in enumerate(values) if (first_frame + i) % 30 != 1]
    return {
        "name": name,
        "mean": statistics.mean(values),
        "steady_mean": statistics.mean(steady),
        "periodic_mean": statistics.mean(periodic),
        "periodic_p99": percentile(periodic, .99),
        "p95": percentile(values, .95),
        "p99": percentile(values, .99),
        "max": max(values),
        "poll_samples": len(periodic),
        "sorts": int(lua.globals().TASK_SORTS),
        "task_count": len(mod[b"tasks"]),
        "active_role": str(mod[b"debug_automation"]().sync()),
        "task_enabled": task_count == 0 or bool(mod[b"tasks"][1][b"enabled"]),
        "future_due": task_count == 0 or float(mod[b"tasks"][1][b"due"]) > lua.eval("os.time()"),
        "open": bool(mod[b"debug_panel"]()[b"open"]),
        "font_mode": font_mode,
        "errors": int(mod[b"panel_errors"] or 0),
        "deltas": {key: end[key] - start[key] for key in
                   ("reads", "world_lists", "text", "extents", "gui_created", "gui_destroyed")},
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-ref", help="git ref for a baseline source; default is working tree")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--frames", type=int, default=12000)
    parser.add_argument("--warmup", type=int, default=1200)
    args = parser.parse_args()
    if args.runs < 1 or args.frames < 60 or args.warmup < 30:
        parser.error("runs >= 1, frames >= 60 and warmup >= 30 are required")
    source, label = source_text(args.source_ref)
    sample_lua, _, sample_mod = make_runtime(source)
    print(f"source={label}; build={sample_mod[b'build_id']}; JIT={sample_lua.eval('jit.status()')}")
    print(f"source_sha256={hashlib.sha256(source.encode('utf-8')).hexdigest()}")
    print(f"warmup={args.warmup}; measured_frames={args.frames}; runs={args.runs}; "
          "timer=LuaJIT QueryPerformanceCounter around _G.update")
    print("GUI text mock counts calls without retaining draw records; native/game APIs are stubbed")
    cases = (
        ("closed-empty", 0, False, False),
        ("open-retained", 0, True, False),
        ("open-forced-redraw", 0, True, True),
        ("closed-future-100", 100, False, False),
        ("closed-future-1000", 1000, False, False),
    )
    runs: dict[str, list[dict]] = {case[0]: [] for case in cases}
    for run_index in range(args.runs):
        for name, task_count, opened, force_redraw in cases:
            row = run_case(source, name, task_count, opened, force_redraw,
                           args.frames, args.warmup)
            assert row["task_count"] == task_count and row["open"] == opened
            assert row["active_role"] == "host" and row["task_enabled"] and row["future_due"]
            assert row["errors"] == 0
            runs[name].append(row)
            print(f"run={run_index+1}/{args.runs} case={name} font={row['font_mode']} "
                  f"mean={row['mean']:.2f}us "
                  f"steady={row['steady_mean']:.2f}us poll_mean={row['periodic_mean']:.2f}us "
                  f"poll_p99={row['periodic_p99']:.2f}us p99={row['p99']:.2f}us "
                  f"max={row['max']:.2f}us sorts={row['sorts']} deltas={row['deltas']}", flush=True)
    print("summary (median across runs):")
    for name, samples in runs.items():
        for metric in ("mean", "steady_mean", "periodic_mean", "periodic_p99", "p99", "max"):
            median = statistics.median(item[metric] for item in samples)
            print(f"  {name}.{metric}={median:.2f}us")
        print(f"  {name}.sorts={statistics.median(item['sorts'] for item in samples):g}; "
              f"task_count={samples[0]['task_count']}; active_role={samples[0]['active_role']}; "
              f"future_due={samples[0]['future_due']}; font={samples[0]['font_mode']}; "
              f"draws={samples[0]['deltas']['text']}; extents={samples[0]['deltas']['extents']}")
    print("Offline LuaJIT timings exclude real game/native GUI/font costs; not in-game ms/frame claims.")


if __name__ == "__main__":
    main()
