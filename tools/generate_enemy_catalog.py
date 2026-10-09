"""Generate a compact, versioned enemy facts catalog; never touches game memory.

Default sources are pinned. --revision accepts another full RawData commit after
its game version/build compatibility has been reviewed. --refresh downloads the
five small/large source tables to a temporary cache, not into the repository.
This generates facts only; it does not silently change the supported DLL build.
--embed and --check render/verify the checked-in catalog entirely offline.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
from pathlib import Path
import re
import tempfile
import urllib.request

RAW_REVISION = "52056ecb5637bf8d71481a724b019a6bd3b0e9ea"
HASH_REVISION = "9f92623133cde32b1167e13f05ce6c4825805ccf"
RAW_ROOT = "https://raw.githubusercontent.com/Darctor/Helldivers2_RawData/"
HASH_ROOT = "https://raw.githubusercontent.com/xypwn/filediver/"
FILES = {
    "map": "Data/settings/EntityComponentMap.json",
    "health": "Data/entities/HealthComponentData.json",
    "faction": "Data/entities/FactionComponentData.json",
    "encyclopedia": "Data/entities/EncyclopediaEntryComponentData.json",
    "ai": "Data/entities/AiEnemyComponentData.json",
    "sizes": "Data/enums/UnitSize.txt",
}
HOSTILE_FACTIONS = {"FactionType_Bugs", "FactionType_Cyborg", "FactionType_Illuminate"}
SIZE_CATEGORIES = {0: "small_enemy", 1: "medium_enemy", 2: "large_enemy", 3: "giant_enemy"}
FLIGHT_COMPONENTS = {"HoverComponentData", "AirborneNavigationComponentData"}
MASK64 = (1 << 64) - 1
ROOT = Path(__file__).resolve().parents[1]
BLOCK_PATTERN = r"-- BEGIN ENEMY TARGET CATALOG\n.*?\n-- END ENEMY TARGET CATALOG"


def murmur64a(value: str) -> int:
    """Game resource hash: standard MurmurHash64A, seed zero, no trailing NUL."""
    data = value.encode("utf-8")
    multiplier = 0xC6A4A7935BD1E995
    result = (len(data) * multiplier) & MASK64
    stop = len(data) // 8 * 8
    for pos in range(0, stop, 8):
        block = int.from_bytes(data[pos:pos + 8], "little")
        block = (block * multiplier) & MASK64
        block ^= block >> 47
        block = (block * multiplier) & MASK64
        result ^= block
        result = (result * multiplier) & MASK64
    if stop < len(data):
        result ^= int.from_bytes(data[stop:], "little")
        result = (result * multiplier) & MASK64
    result ^= result >> 47
    result = (result * multiplier) & MASK64
    return result ^ (result >> 47)


def entity_table(document: dict) -> dict[str, dict]:
    return {key.removeprefix("0x").upper(): value
            for record in document["entities"] for key, value in record.items()}


def enum_name(value: str) -> str:
    return value.split(" <=> ", 1)[1]


def flight_evidence(components: set[str]) -> list[str]:
    evidence = sorted(components & FLIGHT_COMPONENTS)
    # Gunship and transport craft use flocking/thruster or shuttle movement.
    # Boids alone also appears on nonenemy objects and is insufficient.
    if "BoidsComponentData" in components and (
            "ThrusterGroupComponentData" in components or
            "VehicleCrashComponentData" in components):
        evidence += sorted(components & {
            "BoidsComponentData", "ThrusterGroupComponentData",
            "VehicleCrashComponentData", "VehicleShuttleComponentData"})
    elif "VehicleShuttleComponentData" in components:
        evidence.append("VehicleShuttleComponentData")
    return sorted(set(evidence))


def generate(documents: dict, hashes: str, revision: str,
             hash_revision: str) -> dict:
    component_map = documents["map"][0]["EntityComponentMap"]
    metadata = component_map["_metadata"]
    for name in ("health", "faction", "encyclopedia", "ai"):
        actual = documents[name]["_metadata"]
        if any(actual[key] != metadata[key] for key in ("patch_date", "game_version")):
            raise ValueError(f"Mixed game versions in {name}")
    size_names = documents["sizes"].splitlines()
    if size_names != ["UnitSize_Small", "UnitSize_Medium", "UnitSize_Large",
                      "UnitSize_Massive", "UnitSize_Num"]:
        raise ValueError("UnitSize changed; review categories before regeneration")
    health = entity_table(documents["health"])
    factions = entity_table(documents["faction"])
    encyclopedia = entity_table(documents["encyclopedia"])
    ai = entity_table(documents["ai"])
    entries = []
    excluded_friendly_ai = 0
    for entity in component_map["entities"]:
        resource_id = f"{int(entity['hash']):016X}"
        components = {enum_name(value) for value in entity["components"]}
        entity_factions = {enum_name(value["faction"])
                           for value in factions.get(resource_id, {}).get("factions", [])}
        has_ai = "AiEnemyComponentData" in components
        if has_ai != (resource_id in ai):
            raise ValueError(f"AiEnemy table/map membership mismatch: {resource_id}")
        hostile = sorted(entity_factions & HOSTILE_FACTIONS)
        if has_ai and not hostile:
            excluded_friendly_ai += 1
        if not hostile:
            continue
        # EnemyPackage also covers bosses/Stingray absent from AiEnemy. Shuttle
        # components cover airborne reinforcement transports absent from both.
        role = ("ai_enemy" if has_ai else
                "enemy_package" if "EnemyPackageComponentData" in components else
                "transport" if "VehicleShuttleComponentData" in components else None)
        if role is None:
            continue
        if resource_id not in health:
            raise ValueError(f"Enemy has no Health size: {resource_id}")
        size = health[resource_id]["unit_size"]
        size_value = int(size.split(" ", 1)[0])
        if size_value not in SIZE_CATEGORIES:
            raise ValueError(f"Unsupported enemy UnitSize: {size}")
        evidence = flight_evidence(components)
        loc_name = encyclopedia.get(resource_id, {}).get("loc_name", 0)
        entries.append({
            "resource_id": resource_id,
            "name": entity["name"],
            "name_zh": entity["name_zh"],
            "resource_path": None,
            "factions": hostile,
            "role": role,
            "unit_size": size_value,
            "unit_size_name": enum_name(size),
            "size_category": SIZE_CATEGORIES[size_value],
            "flying": bool(evidence),
            "flight_evidence": evidence,
            "spottable": "SpottableComponentData" in components,
            "localization_key": loc_name,
        })
    needed = {int(entry["resource_id"], 16) for entry in entries}
    paths = {}
    for line in hashes.splitlines():
        path = line.strip()
        if not path.startswith("content/"):
            continue
        hashed = murmur64a(path)
        if hashed in needed:
            if hashed in paths and paths[hashed] != path:
                raise ValueError("Resource path hash collision")
            paths[hashed] = path
    for entry in entries:
        entry["resource_path"] = paths.get(int(entry["resource_id"], 16))
    entries.sort(key=lambda entry: entry["resource_id"])
    counts = collections.Counter(entry["size_category"] for entry in entries)
    spot_counts = collections.Counter(entry["size_category"] for entry in entries if entry["spottable"])
    return {
        "schema_version": 1,
        "scope": "Hostile faction intersect (AiEnemy OR EnemyPackage OR VehicleShuttle); static buildings excluded",
        "game_version": metadata["game_version"],
        "patch_date": metadata["patch_date"],
        "sources": {"rawdata_revision": revision, "filediver_revision": hash_revision,
                    **{key: RAW_ROOT + revision + "/" + path for key, path in FILES.items()},
                    "resource_paths": HASH_ROOT + hash_revision + "/hashes/hashes.txt"},
        "summary": {"resource_count": len(entries),
                    "ai_enemy_count": sum(entry["role"] == "ai_enemy" for entry in entries),
                    "non_ai_exception_count": sum(entry["role"] != "ai_enemy" for entry in entries),
                    "spottable_count": sum(entry["spottable"] for entry in entries),
                    "flying_count": sum(entry["flying"] for entry in entries),
                    "spottable_flying_count": sum(entry["spottable"] and entry["flying"] for entry in entries),
                    "excluded_nonhostile_ai_count": excluded_friendly_ai,
                    "resolved_path_count": sum(entry["resource_path"] is not None for entry in entries),
                    "by_size": dict(sorted(counts.items())),
                    "spottable_by_size": dict(sorted(spot_counts.items()))},
        "entries": entries,
    }


def lua_string(value: str) -> str:
    escaped = []
    for char in value:
        if char in "'\\":
            escaped.append("\\" + char)
        elif ord(char) < 32 or ord(char) == 127:
            escaped.append(f"\\{ord(char):03d}")
        else:
            escaped.append(char)
    return "'" + "".join(escaped) + "'"


def render(catalog: dict | None = None) -> str:
    """Produce runtime markable enemies from reviewed facts without network access."""
    if catalog is None:
        catalog = json.loads((ROOT / "docs/enemy-catalog.json").read_text(encoding="utf-8"))
    if catalog.get("schema_version") != 1:
        raise ValueError("Unsupported enemy catalog schema")
    lines = ["-- BEGIN ENEMY TARGET CATALOG",
             "-- Generated offline by tools/generate_enemy_catalog.py from docs/enemy-catalog.json.",
             f"-- Game {catalog['game_version']}, {catalog['patch_date']}; hostile + Spottable only; flight before size.",
             "local ENEMY_TARGETS = {"]
    seen = set()
    for row in sorted(catalog["entries"], key=lambda value: value["resource_id"]):
        resource = row["resource_id"]
        if not re.fullmatch(r"[0-9A-F]{16}", resource) or resource in seen:
            raise ValueError("Invalid or duplicate enemy resource ID")
        seen.add(resource)
        factions = set(row["factions"])
        if not factions or not factions <= HOSTILE_FACTIONS:
            raise ValueError(f"Unreviewed enemy faction: {resource}")
        size = row["unit_size"]
        if type(size) is not int or size not in SIZE_CATEGORIES:
            raise ValueError(f"Unreviewed enemy UnitSize: {resource}")
        if row["size_category"] != SIZE_CATEGORIES[size]:
            raise ValueError(f"Inconsistent enemy size category: {resource}")
        if type(row["flying"]) is not bool or row["flying"] != bool(flight_evidence(set(row["flight_evidence"]))):
            raise ValueError(f"Missing or inconsistent flight evidence: {resource}")
        if type(row["spottable"]) is not bool:
            raise ValueError(f"Invalid Spottable membership: {resource}")
        if not row["spottable"]:
            continue
        key = row["localization_key"]
        if type(key) is not int or not 0 <= key <= 0xFFFFFFFF:
            raise ValueError(f"Invalid Encyclopedia localization key: {resource}")
        label = next((row[field] for field in ("name_zh", "name")
                      if row[field] and row[field] != "N/A"), "敌方单位")
        category = "flying_enemy" if row["flying"] else SIZE_CATEGORIES[size]
        lines.append(f"    ['{resource}'] = {{{lua_string(category)}, {lua_string(label)}, {key}}},")
    return "\n".join(lines + ["}", "-- END ENEMY TARGET CATALOG"])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--embed", action="store_true", help="Embed checked-in enemy facts into src/ping_events.lua offline")
    action.add_argument("--check", action="store_true", help="Check the embedded runtime facts offline")
    parser.add_argument("--revision", default=RAW_REVISION)
    parser.add_argument("--hashes-revision", default=HASH_REVISION)
    parser.add_argument("--cache-dir", type=Path,
                        default=Path(tempfile.gettempdir()) / "auto-chat-enemy-catalog")
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).resolve().parents[1] / "docs/enemy-catalog.json")
    args = parser.parse_args()
    if args.embed or args.check:
        source_path = ROOT / "src/ping_events.lua"
        source = source_path.read_text(encoding="utf-8")
        block = render()
        match = re.search(BLOCK_PATTERN, source, re.S)
        if args.check:
            if match is None or match.group() != block:
                raise ValueError("Embedded enemy catalog is out of date")
        else:
            if match:
                source, count = re.subn(BLOCK_PATTERN, lambda _: block, source, flags=re.S)
                if count != 1:
                    raise ValueError("Multiple embedded enemy catalog blocks")
            else:
                anchor = "local PING_TARGETS = {"
                if source.count(anchor) != 1:
                    raise ValueError("Cannot find unique enemy catalog insertion point")
                source = source.replace(anchor, block + "\n\n" + anchor, 1)
            source_path.write_text(source, encoding="utf-8")
        print("Enemy target catalog: checked" if args.check else "Enemy target catalog: embedded")
        return
    for revision in (args.revision, args.hashes_revision):
        if not re.fullmatch(r"[a-f0-9]{40}", revision):
            parser.error("Source revisions must be full Git commit SHAs")
    sources = {key: (RAW_ROOT + args.revision + "/" + path, args.revision + "-" + Path(path).name)
               for key, path in FILES.items()}
    sources["hashes"] = (HASH_ROOT + args.hashes_revision + "/hashes/hashes.txt",
                          args.hashes_revision + "-hashes.txt")
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    documents = {}
    fingerprints = {}
    for key, (url, filename) in sources.items():
        cached = args.cache_dir / filename
        if args.refresh or not cached.exists():
            with urllib.request.urlopen(url, timeout=120) as response:
                data = response.read()
            cached.write_bytes(data)
        data = cached.read_bytes()
        fingerprints[key] = hashlib.sha256(data).hexdigest()
        text = data.decode("utf-8-sig")
        documents[key] = json.loads(text) if key not in ("sizes", "hashes") else text
    catalog = generate(documents, documents.pop("hashes"), args.revision, args.hashes_revision)
    catalog["source_sha256"] = fingerprints
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(catalog["summary"], ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
