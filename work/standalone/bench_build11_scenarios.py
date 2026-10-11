"""Expanded offline LuaJIT/QPC scenarios for AutoChat's production update path.

Uses the existing fake engine boundary and a curated read-only game catalog layout.
Native localization and GUI/font APIs are deliberately boundary stubs; catalog scan,
panel filtering/render selection, name pump, update and event/scheduler code stay real.
This is not an in-game latency claim.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import statistics
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "work" / "standalone"))
import bench_frame_performance as base_bench  # noqa: E402
import bench_panel_performance as harness  # noqa: E402

FIXTURE = ROOT / "work/standalone/tests/fixtures/stratagem_catalog_20261009.json"
PINS = ((0x66D54C, "4b8b84fd00b67c03"), (0x179D962, "8b752c"),
        (0x183A1E5, "498b96b0000000"))


def source_text(ref: str | None, source_file: str | None = None) -> tuple[str, str, str]:
    if ref and source_file:
        raise ValueError("choose --source-ref or --source-file")
    if source_file:
        path = Path(source_file)
        raw = path.read_bytes()
        return raw.decode("utf-8"), str(path.resolve()), hashlib.sha256(raw).hexdigest()
    if ref:
        raw = subprocess.check_output(["git", "show", f"{ref}:src/auto_chat.lua"], cwd=ROOT)
        return raw.decode(), f"git:{ref}:src/auto_chat.lua", hashlib.sha256(raw).hexdigest()
    path = ROOT / "src/auto_chat.lua"
    raw = path.read_bytes()
    return raw.decode("utf-8"), str(path), hashlib.sha256(raw).hexdigest()


def seed_catalog(lua, game, rows: list[dict]) -> None:
    """Write the static curated native layout into fake memory, then run real scan."""
    base = int(game[b"code_base"])
    slot = base + 0x37CB600
    rows_base = base + 0x4000000
    strings_base = base + 0x4100000
    game[b"region"](slot, 256 * 8, 0x1000, 0x04)
    game[b"region"](rows_base, 256 * 0x200, 0x1000, 0x04)
    game[b"region"](strings_base, 256 * 0x200, 0x1000, 0x04)
    write_lua = lua.eval("function(h,a,t) local r={}; for i=1,#t do r[i]=string.char(t[i]) end; h.bytes(a,table.concat(r)) end")
    def write_bytes(address: int, data: bytes) -> None:
        write_lua(game, address, lua.table_from(data))
    # The production reader guards the complete 256-entry table in one RPM call.
    write_bytes(slot, bytes(256 * 8))
    for offset, hex_bytes in PINS:
        write_bytes(base + offset, bytes.fromhex(hex_bytes))
    fixture_rows = []
    for row in rows:
        kind = int(row.get("kind", len(fixture_rows) + 1))
        if kind < 1 or kind > 255:
            raise ValueError(f"fixture kind out of range: {kind}")
        ptr = rows_base + kind * 0x200 + 4
        name_ptr = strings_base + kind * 0x200
        encoded = row["debug_name"].encode("ascii")
        if len(encoded) >= 160:
            raise ValueError("catalog debug name too long")
        raw = bytearray(0xB8)
        struct.pack_into("<II", raw, 0, kind, int(row["id"]))
        struct.pack_into("<Q", raw, 0x10, name_ptr)
        struct.pack_into("<II", raw, 0x28, int(row["name_upper_key"]), int(row["name_key"]))
        struct.pack_into("<f", raw, 0x68, 15.0)
        struct.pack_into("<I", raw, 0x74, int(row.get("call_type", 0)))
        struct.pack_into("<I", raw, 0xA0, 0)
        struct.pack_into("<Q", raw, 0xB0, 0)
        game[b"u64"](slot + kind * 8, ptr)
        write_bytes(ptr, bytes(raw))
        write_bytes(name_ptr, encoded + b"\0" * (160 - len(encoded)))
        fixture_rows.append(row)
    lua.globals().SEED_COUNT = len(rows)
    count, status = lua.eval("M.debug_stratagem_catalog().scan(os.time())")
    if count != len(rows):
        raise AssertionError(f"production catalog scan got {count}/{len(rows)}: {status}")


def prep_runtime(source: str, task_count: int, case: str, rows: list[dict]):
    clock_boot = "BENCH_TIME=1900000000; os.time=function() return math.floor(BENCH_TIME) end\n"
    lua, game, mod = base_bench.make_runtime(clock_boot + source)
    lua.globals().H, lua.globals().M = game, mod
    seed_catalog(lua, game, rows)
    # Keep the production periodic catalog scan active so all candidates share
    # the same controlled 1/60-second clock and generation invalidations.
    mod[b"options"][b"enabled"] = True
    mod[b"options"][b"ping"] = True
    lua.globals().TASK_SORTS = 0
    lua.execute(f"seed_future_tasks({task_count})")
    if case.startswith("open-"):
        panel = mod[b"debug_panel"]()
        panel[b"rule_view"] = "stratagem"
        panel[b"rule_filter"] = "all"
        panel[b"rule_page"] = 1
        panel[b"version"] = int(panel[b"version"] or 0) + 1
        if case == "open-long-cjk-english":
            lua.execute("""
                local row=M.debug_stratagem_catalog().list_rules()[1]
                assert(row,'long text scenario requires a real stratagem rule row')
                M.debug_panel().rule_selected=row.id
                local chinese=string.rep('玩家标记了目标位置与地狱火战备说明 ',8)
                local english=string.rep('Player marked the objective position and Hellbomb stratagem ',7)
                assert(#chinese<=512 and #english<=512)
                assert(M.debug_automation().set_rule('stratagem',row.id,'mark_message',chinese,'host'))
                local ok,why=M.debug_automation().set_rule('stratagem',row.id,'call_message',english,'host')
                assert(ok,tostring(why)..' length='..#english)
            """)
    lua.execute(r"""
        TEXT_CALLS=0; EXTENT_CALLS=0
        local g=stingray.Gui
        local text, extents=g.text, g.text_extents
        LONG_ZH_DRAWS,LONG_EN_DRAWS=0,0
        g.text=function(gui,value,...)
            TEXT_CALLS=TEXT_CALLS+1
            if type(value)=='string' then
                if value:find('玩家标记了目标位置',1,true) then LONG_ZH_DRAWS=LONG_ZH_DRAWS+1 end
                if value:find('Player marked the objective position',1,true) then LONG_EN_DRAWS=LONG_EN_DRAWS+1 end
            end
            return text(gui,value,...)
        end
        g.text_extents=function(...) EXTENT_CALLS=EXTENT_CALLS+1; return extents(...) end
        function perf_measure(n, dirty)
            local start,finish=bench_ffi.new('int64_t[1]'),bench_ffi.new('int64_t[1]')
            local samples,lookups={},{};local panel=M.debug_panel()
            for i=1,n do
                if dirty then panel.version=panel.version+1 end
                local before=LOCALIZE_CALLS or 0
                if not BENCH_FREEZE then BENCH_TIME=BENCH_TIME+1/60 end
                bench_kernel.QueryPerformanceCounter(start);_G.update();bench_kernel.QueryPerformanceCounter(finish)
                samples[i]=tonumber(finish[0]-start[0])*1000000/PERF_FREQ
                lookups[i]=(LOCALIZE_CALLS or 0)-before
            end
            return table.concat(samples,',')..'|'..table.concat(lookups,',')
        end
        function perf_one()
            local start,finish=bench_ffi.new('int64_t[1]'),bench_ffi.new('int64_t[1]')
            BENCH_TIME=BENCH_TIME+1/60
            bench_kernel.QueryPerformanceCounter(start);_G.update();bench_kernel.QueryPerformanceCounter(finish)
            return tonumber(finish[0]-start[0])*1000000/PERF_FREQ
        end
    """)
    return lua, game, mod


def percentile(vals: list[float], q: float) -> float:
    ordered = sorted(vals)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * q))]


def run_case(source: str, case: str, tasks: int, frames: int, warmup: int,
             rows: list[dict]) -> dict:
    lua, game, mod = prep_runtime(source, tasks, case, rows)
    # The production open guard requires the simulated world to have reached the
    # ready stage first; the panel API call itself remains the real production path.
    lua.execute(f"for i=1,{warmup} do BENCH_TIME=BENCH_TIME+1/60; _G.update() end")
    cold_open_us = None
    cold_open_delta = None
    if case == "open-retained-unresolved":
        # Take one real open draw to register visible candidates. The first
        # measured frame performs the first name-pump lookup.
        if not mod[b"debug_set_open"](True):
            raise AssertionError("production panel open guard refused after world warmup")
        panel = mod[b"debug_panel"]()
        panel[b"rule_view"] = "stratagem"
        panel[b"version"] = int(panel[b"version"] or 0) + 1
        cold_before=(int(game[b"gui_created"] or 0),int(game[b"gui_destroyed"] or 0),int(game[b"text_drawn"] or 0))
        cold_open_us = float(lua.eval("perf_one()"))
        cold_open_delta=(int(game[b"gui_created"] or 0)-cold_before[0],
            int(game[b"gui_destroyed"] or 0)-cold_before[1],int(game[b"text_drawn"] or 0)-cold_before[2])
        if cold_open_delta[0]<1 or cold_open_delta[2]<1:
            raise AssertionError(f"cold open frame did not create and draw: {cold_open_delta}")
    else:
        panel = mod[b"debug_panel"]()
        if case.startswith("open-"):
            if not mod[b"debug_set_open"](True):
                raise AssertionError("production panel open guard refused after world warmup")
            panel[b"rule_view"] = "stratagem"
            panel[b"version"] = int(panel[b"version"] or 0) + 1
            cold_before=(int(game[b"gui_created"] or 0),int(game[b"gui_destroyed"] or 0),int(game[b"text_drawn"] or 0))
            cold_open_us = float(lua.eval("perf_one()"))
            cold_open_delta=(int(game[b"gui_created"] or 0)-cold_before[0],
                int(game[b"gui_destroyed"] or 0)-cold_before[1],int(game[b"text_drawn"] or 0)-cold_before[2])
            if cold_open_delta[0]<1 or cold_open_delta[2]<1:
                raise AssertionError(f"cold open frame did not create and draw: {cold_open_delta}")
            # Stationary cases then use full warmup so the registered names are
            # genuinely cached, or nil retry deadlines have reached steady state.
            lua.execute(f"for i=1,{warmup} do BENCH_TIME=BENCH_TIME+1/60; _G.update() end")
    panel = mod[b"debug_panel"]()
    cached_warmup_successes = 0
    lua.globals().BENCH_FREEZE = case == "open-retained-cached-frozen"
    if case in ("open-retained-cached", "open-retained-cached-frozen", "open-retained-unresolved", "open-retained-permanent-nil"):
        # Find a real production page with a missing native name. Do this before
        # timed samples so each localization scenario exercises visible rows.
        rules = mod[b"debug_stratagem_catalog"]().list_rules()
        for page in range(1, len(rules) + 1):
            panel[b"rule_page"] = page
            panel[b"version"] = int(panel[b"version"] or 0) + 1
            lua.eval("_G.update()")
            if len(panel[b"_native_name_candidates"] or {}) > 0:
                break
        if len(panel[b"_native_name_candidates"] or {}) == 0:
            raise AssertionError("no production page exposed native name candidates")
        # The setup draw may have exercised the real fallback reader. Clear only
        # synthetic per-row resolver state so these named scenarios start in the
        # exact requested cached/unresolved/nil state.
        for i in range(1, len(panel[b"_native_name_candidates"]) + 1):
            panel[b"_native_name_candidates"][i][b"_panel_native_names"] = None
        panel[b"_native_name_retry_by_key"] = lua.table()
        panel[b"_native_name_key_cursor"] = lua.table()
        panel[b"_native_name_fallbacks"] = lua.table()
        panel[b"_native_name_done_signature"] = None
        panel[b"_native_name_retry_frame"] = 0
        lua.globals().LOCALIZE_CALLS = 0
        lua.globals().LOCALIZE_SUCCESS = 0
        if case == "open-retained-permanent-nil":
            lua.execute("M.debug_localization().lookup=function(key) LOCALIZE_CALLS=LOCALIZE_CALLS+1; return nil end")
        else:
            lua.execute("M.debug_localization().lookup=function(key) LOCALIZE_CALLS=LOCALIZE_CALLS+1; LOCALIZE_SUCCESS=LOCALIZE_SUCCESS+1; return 'Resolved localized title '..tostring(key) end")
            if case in ("open-retained-cached", "open-retained-cached-frozen"):
                locale = mod[b"language"][b"current"]()
                locale_key = b"zh" if locale == "zh" else b"en"
                required = sum(1 for i in range(1, len(panel[b"_native_name_candidates"] or {}) + 1)
                               if bool(panel[b"_native_name_candidates"][i][b"native_name_missing"][locale_key]))
                if required < 1:
                    raise AssertionError("cached page has no visible English-missing native names")
                resolver=mod[b"debug_localization"]()[b"lookup"]
                redraw=lua.eval("function()local p=M.debug_panel();p.version=(p.version or 0)+1 end")
                pump=mod[b"pump_alert_panel_native_names"]
                for frame in range(int(mod[b"frames"]),int(mod[b"frames"])+required+8):
                    pump(panel,resolver,locale,locale,int(mod[b"debug_stratagem_catalog"]().state[b"generation"]),frame,redraw)
                    if int(lua.globals().LOCALIZE_SUCCESS or 0) >= required:
                        break
                if int(lua.globals().LOCALIZE_SUCCESS or 0) < required:
                    raise AssertionError(f"cached case resolved {int(lua.globals().LOCALIZE_SUCCESS or 0)}/{required} visible native names for game={locale} panel={mod[b'panel_locale']()} candidates={len(panel[b'_native_name_candidates'])} gen={mod[b'debug_stratagem_catalog']().state[b'generation']} key={panel[b'_native_name_candidate_cache_key']} sig={panel[b'_native_name_candidate_signature']} open={panel[b'open']} view={panel[b'rule_view']} frame={mod[b'frames']}")
                cached_warmup_successes = int(lua.globals().LOCALIZE_SUCCESS or 0)
                lua.globals().LOCALIZE_CALLS = 0
                lua.globals().LOCALIZE_SUCCESS = 0
    if case.startswith("open-") and case != "open-retained-unresolved":
        panel[b"rule_view"] = "stratagem"
        panel[b"version"] = int(panel[b"version"] or 0) + 1
        lua.eval("_G.update()")
    if case.startswith("open-") and not bool(panel[b"open"]):
        raise AssertionError(f"open scenario not actually open: {case}")
    if case in ("open-retained-cached", "open-retained-cached-frozen") and cached_warmup_successes < 1:
        raise AssertionError("cached case did not actually resolve any native display name during warmup")
    if case == "open-long-cjk-english" and (int(lua.globals().LONG_ZH_DRAWS or 0) < 1
            or int(lua.globals().LONG_EN_DRAWS or 0) < 1):
        raise AssertionError("long CJK/English message strings were not rendered by the actual rule detail view")
    start = {
        "reads": int(game[b"reads"] or 0), "text": int(game[b"text_drawn"] or 0),
        "world_lists": int(game[b"worlds_reads"] or 0),
        "gui_created": int(game[b"gui_created"] or 0), "gui_destroyed": int(game[b"gui_destroyed"] or 0),
        "extents": int(lua.globals().EXTENT_CALLS or 0), "localize": int(lua.globals().LOCALIZE_CALLS or 0),
        "localize_success": int(lua.globals().LOCALIZE_SUCCESS or 0),
    }
    start_generation = int(mod[b"debug_stratagem_catalog"]().state[b"generation"])
    timed = lua.eval(f"perf_measure({frames},{'true' if case=='open-dirty' else 'false'})")
    sample_text, lookup_text = timed.split("|")
    samples = [float(v) for v in sample_text.split(",")]
    lookup_samples = [int(v) for v in lookup_text.split(",")]
    lookup_frames = [value for value, count in zip(samples, lookup_samples) if count > 0]
    end = {
        "reads": int(game[b"reads"] or 0), "text": int(game[b"text_drawn"] or 0),
        "world_lists": int(game[b"worlds_reads"] or 0),
        "gui_created": int(game[b"gui_created"] or 0), "gui_destroyed": int(game[b"gui_destroyed"] or 0),
        "extents": int(lua.globals().EXTENT_CALLS or 0), "localize": int(lua.globals().LOCALIZE_CALLS or 0),
        "localize_success": int(lua.globals().LOCALIZE_SUCCESS or 0),
    }
    lookup_delta = end["localize"] - start["localize"]
    success_delta = end["localize_success"] - start["localize_success"]
    if case == "open-retained-unresolved" and (lookup_delta <= 0 or not panel[b"_native_name_candidates"]):
        raise AssertionError("unresolved case had no visible candidates or measured resolver work")
    if case == "open-retained-permanent-nil" and (lookup_delta <= 0 or success_delta != 0):
        raise AssertionError("nil retry case did not retry, or unexpectedly cached a success")
    first = int(mod[b"frames"]) - frames + 1
    periodic = [v for i, v in enumerate(samples) if (first + i) % 30 == 1]
    steady = [v for i, v in enumerate(samples) if (first + i) % 30 != 1]
    return {"case": case, "mean": statistics.mean(samples), "steady_mean": statistics.mean(steady),
            "periodic_mean": statistics.mean(periodic), "p99": percentile(samples, .99),
            "max": max(samples), "steady_p99": percentile(steady,.99), "steady_max": max(steady),
            "periodic_p99": percentile(periodic,.99), "periodic_max": max(periodic),
            "first32_mean": statistics.mean(samples[:min(32,len(samples))]),
            "first32_p99": percentile(samples[:min(32,len(samples))],.99),
            "first64_mean": statistics.mean(samples[:min(64,len(samples))]),
            "first64_p99": percentile(samples[:min(64,len(samples))],.99),
            "lookup_calls": lookup_delta, "lookup_successes": success_delta,
            "lookup_frames": len(lookup_frames),
            "lookup_mean": statistics.mean(lookup_frames) if lookup_frames else 0.0,
            "lookup_p99": percentile(lookup_frames,.99) if lookup_frames else 0.0,
            "lookup_max": max(lookup_frames) if lookup_frames else 0.0,
            "cold_open_us": cold_open_us,
            "cold_open_delta": cold_open_delta,
            "over50_pct": 100*sum(v>50 for v in samples)/len(samples),
            "deltas": {k: end[k]-start[k] for k in start},
            "generation_delta": int(mod[b"debug_stratagem_catalog"]().state[b"generation"])-int(start_generation),
            "task_sorts": int(lua.globals().TASK_SORTS), "catalog_rules": len(mod[b"debug_stratagem_catalog"]().list_rules()),
            "native_candidates": len(panel[b"_native_name_candidates"] or {}),
            "panel_open": bool(panel[b"open"]), "panel_errors": int(mod[b"panel_errors"] or 0)}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source-ref")
    ap.add_argument("--source-file", help="exact frozen source for same-harness comparison")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--frames", type=int, default=12000)
    ap.add_argument("--warmup", type=int, default=1200)
    ap.add_argument("--case", action="append", help="limit case; repeatable")
    ap.add_argument("--smoke", action="store_true", help="short fixture smoke, not final evidence")
    args = ap.parse_args()
    if args.smoke:
        args.runs, args.frames, args.warmup = 1, 600, 650
    source, label, raw_hash = source_text(args.source_ref, args.source_file)
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    rows = fixture["rows"]
    src_hash = hashlib.sha256(source.encode("utf-8")).hexdigest()
    sample, _, mod = base_bench.make_runtime(source)
    print(f"source={label}; build={mod[b'build_id']}; logical_utf8_sha256={src_hash}; raw_file_sha256={raw_hash}; JIT={sample.eval('jit.status()')}")
    print(f"catalog_fixture={FIXTURE}; rows={len(rows)}; source={fixture['source']}")
    print(f"fresh LuaJIT per run; warmup={args.warmup}; frames={args.frames}; runs={args.runs}; QPC inside Lua around _G.update")
    print("production update/catalog scan/panel render-filter/name pump/task scheduler execute; engine memory, localization, GUI/font boundaries are synthetic stubs")
    cases = [("closed-empty",0),("closed-future-100",100),("closed-future-1000",1000),
             ("open-retained-cached",0),("open-retained-cached-frozen",0),
             ("open-retained-unresolved",0),("open-retained-permanent-nil",0),
             ("open-long-cjk-english",0),("open-dirty",0)]
    if args.case:
        cases = [x for x in cases if x[0] in args.case]
    result = {name: [] for name, _ in cases}
    for r in range(args.runs):
        for name, task_count in cases:
            item = run_case(source, name, task_count, args.frames, args.warmup, rows)
            if item["catalog_rules"] <= 0 or item["panel_errors"]:
                raise AssertionError(f"invalid production scenario {name}: {item}")
            result[name].append(item)
            print(f"run={r+1}/{args.runs} case={name} open={item['panel_open']} cold_open={item['cold_open_us']}us cold_delta={item['cold_open_delta']} generation_delta={item['generation_delta']} mean={item['mean']:.2f}us steady={item['steady_mean']:.2f}us steady_p99/max={item['steady_p99']:.2f}/{item['steady_max']:.2f}us periodic={item['periodic_mean']:.2f}us periodic_p99/max={item['periodic_p99']:.2f}/{item['periodic_max']:.2f}us p99/max={item['p99']:.2f}/{item['max']:.2f}us first32/64={item['first32_mean']:.2f}/{item['first64_mean']:.2f}us lookup_calls/success/frames={item['lookup_calls']}/{item['lookup_successes']}/{item['lookup_frames']} lookup_mean/p99/max={item['lookup_mean']:.2f}/{item['lookup_p99']:.2f}/{item['lookup_max']:.2f}us >50us={item['over50_pct']:.2f}% metrics={item['deltas']}", flush=True)
    print("summary median across fresh runs:")
    for name, runs in result.items():
        print(name, " ".join(f"{key}={statistics.median(row[key] for row in runs):.2f}" for key in ("mean","steady_mean","steady_p99","steady_max","periodic_mean","periodic_p99","periodic_max","p99","max","over50_pct","first32_mean","first32_p99","first64_mean","first64_p99","lookup_calls","lookup_successes","lookup_frames","lookup_mean","lookup_p99","lookup_max")),
              f"cold_open_us={statistics.median((row['cold_open_us'] or 0) for row in runs):.2f}; task_sorts={runs[0]['task_sorts']} catalog_rules={runs[0]['catalog_rules']} candidates={runs[0]['native_candidates']} panel_open={runs[0]['panel_open']}")
    print("Synthetic boundaries mean no claim about live engine/native cost or game latency.")


if __name__ == "__main__":
    main()
