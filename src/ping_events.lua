-- Third-party reference license (etxp HD2-G60-Smart-Targeting):
--[[
MIT License

Copyright (c) 2026 etxp

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]
-- Read-only native ping adapter for Steam build 25480438 only.
-- game.dll SHA256: 2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E
-- env.base() must already enforce that supported build; no native calls or writes here.
-- Observed ring/entity layouts (MIT):
-- https://github.com/etxp/HD2-G60-Smart-Targeting/blob/main/src/g60/native_ping.lua
-- https://github.com/etxp/HD2-G60-Smart-Targeting/blob/main/src/g60/native_target_data.lua
-- Player/peer/avatar layouts, same DLL fingerprint:
-- https://github.com/SkyeShade/HD2Runtime/blob/master/runtime/event_world.lua
-- https://github.com/SkyeShade/HD2Runtime/blob/master/domains/event_natives.lua
-- Classification facts: current-build enemy kind intersected with AiEnemyComponentData;
-- HealthComponentData.unit_size: 1 Medium, 2 Large, 3 Massive (2026-09-22 data).
-- https://github.com/Darctor/Helldivers2_RawData/tree/main/Data/entities
-- https://github.com/Darctor/Helldivers2_RawData/blob/main/Data/enums/UnitSize.txt
-- Tactical map pins use replicated actor state, not the HUD ping ring. Current
-- DLL 18B97A0 writes actor+547830 (stride78); 18B3A90 renders those same pins.
-- Objective names: 1255D60 resolves entity -> definition (32EF870,153 x A0),
-- 18B4AEC selects definition+38 or runtime+1050. Importance is runtime+1038,
-- populated from the CURRENT mission by 5D0DF0, never inferred from the name.
-- Local Custom UI confirms enemy material A1919FA085C97B18, ground 4B81B73A36657DC9;
-- Better Map Markers shares map material EA6C3908C95DD015. These asset hashes do NOT
-- prove a numeric ring-kind enum and are never used as one.
-- Special identities: current RawData EncyclopediaEntryComponentData / EntityComponentMap,
-- HD2Runtime SupportWeaponCapabilities and FileDiver actual resource paths.
-- https://github.com/Darctor/Helldivers2_RawData/blob/main/Data/settings/EntityComponentMap.json
-- https://github.com/SkyeShade/HD2Runtime/blob/master/sdk/SupportWeaponCapabilities.json
-- https://github.com/xypwn/filediver/blob/master/hashes/hashes.txt
-- Enum: https://github.com/shalzuth/HelldiversData/blob/master/data/enums/HudMarkerType.json
-- Historical HUD enum is corroborated by current DLL Map21 producer below.
-- Ordinary ammo, stims, grenades and samples are intentionally excluded.
local EXCLUDED_SUPPLIES = {
    ['9D4935FA69B6B41A']=true, ['307E09E7698881BA']=true, ['4932CBF33CD47EF9']=true,
    ['4C63119F69165321']=true, ['5016EE397FDCFB6C']=true, ['64B49B9D8A445266']=true,
    ['700E9500E95541BF']=true, ['79CCFFD281E3F3A9']=true, ['86F3CB87D97942B4']=true,
    ['92BCC263E751BD45']=true, ['97AF34FBF093409C']=true, ['A9936CBE561E8180']=true,
    ['AD972A2E815A49AA']=true, ['B39FCF5C73D5C383']=true, ['B4CA4C5B922F7965']=true,
    ['BD30758426ED2566']=true, ['BEB2A0F09E36BF72']=true, ['D463836441CD0BA7']=true,
    ['E4EEB96023DF6A99']=true,
}
local PING_TARGETS = {
    -- Current EntityComponentMap Spottable identities, cross-checked with
    -- FileDiver ammo_rack/{ammo_rack,supply_box,ammo_box} and frv_supply paths.
    ['5052EC6A928CCF1A'] = {'stratagem', '重新补给'},
    ['A94913CA014F7579'] = {'stratagem', '重新补给箱'},
    ['49119612EB284A48'] = {'stratagem', '重新补给箱'},
    ['9B2140378640432E'] = {'stratagem', 'M-103 补给车'},
    ['6CFCC7F8801A0266'] = {'stratagem', "40-K Meltagun"},
    ['A8CFFB316F0B5C5F'] = {'stratagem', "AC-8 Autocannon"},
    ['89C5493E08CA4207'] = {'stratagem', "APW-1 Anti-Materiel Rifle"},
    ['96DE9CD50F7306E6'] = {'stratagem', "ARC-3 Arc Thrower"},
    ['78A8185F63A70795'] = {'stratagem', "B/FLAM-80 Cremator"},
    ['9B75217D8312DD67'] = {'stratagem', "B/MD C4 Pack"},
    ['B0F1B354BA1D38D8'] = {'stratagem', "CQC-1 One True Flag"},
    ['5F3EC9BDA2BD8553'] = {'stratagem', "CQC-20 Breaching Hammer"},
    ['BF4CFD2AEABFB5A4'] = {'stratagem', "CQC-9 Defoliation Tool"},
    ['80932FA0ED6901D3'] = {'stratagem', "EAT-17 Expendable Anti-Tank"},
    ['7617642765AC38C7'] = {'stratagem', "EAT-411 Leveller"},
    ['B2B5E0D185605F9E'] = {'stratagem', "EAT-700 Expendable Napalm"},
    ['25AA2FD4643CF4EE'] = {'stratagem', "FAF-14 Spear"},
    ['39AB99895147A3BF'] = {'stratagem', "FLAM-40 Flamethrower"},
    ['02EECD0B1FA49630'] = {'stratagem', "GL-21 Grenade Launcher"},
    ['88C2D09AD85A7C9F'] = {'stratagem', "GL-28 Belt-Fed Grenade Launcher"},
    ['FE3B29B2CFA63F9B'] = {'stratagem', "GL-52 De-Escalator"},
    ['9F80D67A12A7E40F'] = {'stratagem', "GR-8 Recoilless Rifle"},
    ['D54B9505C0F72873'] = {'stratagem', "LAS-98 激光大炮"},
    ['35A61296619CC47E'] = {'stratagem', "LAS-99 Quasar Cannon"},
    ['43A58CB89CFA197C'] = {'stratagem', "M-1000 Maxigun"},
    ['A6A735ACCB4A327F'] = {'stratagem', "M-105 Stalwart"},
    ['2152D5147B0AC418'] = {'stratagem', "MG-206 Heavy Machine Gun"},
    ['11C27D3BABB38956'] = {'stratagem', "MG-43 Machine Gun"},
    ['B16C9D490AA59B77'] = {'stratagem', "MGX-42 Bullet Storm"},
    ['5990123D142B16CB'] = {'stratagem', "MLS-4X Commando"},
    ['DE18775FA447A9BF'] = {'stratagem', "MS-11 Solo Silo"},
    ['E8D5F49AD7780E54'] = {'stratagem', "PLAS-45 Epoch"},
    ['26E40437EA275296'] = {'stratagem', "RL-77 Airburst Rocket Launcher"},
    ['2E9D0BDC48B09E60'] = {'stratagem', "RS-422 Railgun"},
    ['3828E2051AA9E897'] = {'stratagem', "S-11 Speargun"},
    ['52071F49263415E4'] = {'stratagem', "SG-88 Break-Action Shotgun"},
    ['CC786F6491FE7E65'] = {'stratagem', "StA-X3 W.A.S.P. Launcher"},
    ['88F61AFFF48AC8A4'] = {'stratagem', "TX-41 Sterilizer"},
    ['FDE262593307CA2F'] = {'stratagem', "LAS-98 激光大炮装备架"},
    ['16474112801385B6'] = {'stratagem', "堡垒坦克"},
    ['319388D1D8ACB8F3'] = {'building', "TCS 任务终端"},
    ['A09A19371FECD6A3'] = {'building', "TCS 任务终端"},
    ['0722B3A72ADE6CB1'] = {'building', "TCS 主塔"},
    ['BF908A82B8E787AC'] = {'building', "TCS 支撑建筑"},
    ['C3D9B291BD97B935'] = {'building', "TCS 支撑建筑"},
    ['6FDCD0D7F8EAF267'] = {'building', "TCS 支柱"},

    ['3A28A51BAA029E1A'] = {'building', '抽油任务钻机'},
    ['A3D5F183F8A2B768'] = {'building', 'SEAF 火炮装填架'},
    ['B1D938C07E30C5DB'] = {'building', '洲际导弹发射井'},
    ['DF3C4F91E298BFA4'] = {'building', '任务钻机'},
    ['EAE962D85C0C2D4A'] = {'building', '抽油任务钻机'},


    ['08E6FFC2474287BD'] = {1, "Overseer MK2"},
    ['09FE0BE51A23396C'] = {1, "Female Agiator"},
    ['0AB7B92B131C228C'] = {2, "Rupture Charger"},
    ['10081ACEF6163EF6'] = {1, "Bile Warrior"},
    ['137988CEA16458F7'] = {2, "Hulk Bruiser"},
    ['1897BDD32105D2DC'] = {2, "Hulk Scorcher MK2"},
    ['1A7FCDFF98C664B0'] = {2, "Charger"},
    ['1E66EE1F6F7FD00E'] = {2, "Hulk Obliterator"},
    ['20B9C7734DAEAD65'] = {2, "Veracitor"},
    ['282EB766C1FFA6A1'] = {2, "Gunship"},
    ['2CF3488C4845F8BD'] = {2, "Cannon Turret"},
    ['30F2DEE2333F227A'] = {3, "Jammer Factory Strider"},
    ['31BAE74D2F064D8D'] = {2, "Annihilator Tank MK2"},
    ['32541FC4EC7C9CDC'] = {1, "Warrior MK3"},
    ['36AA99CCE5E60146'] = {1, "Bile Spewer"},
    ['3AFF5FD7D5450B99'] = {2, "Charger Behemoth"},
    ['3E0537D606438FEA'] = {2, "Hulk Scorcher"},
    ['453FE22C634EB30F'] = {2, "Gatekeeper"},
    ['4E97FB073BDC7A4B'] = {1, "Warrior MK2 (Captive)"},
    ['53D8919D7B8ABD67'] = {2, "Annihilator Tank"},
    ['54E107DACF6929CB'] = {1, "Berserker MK2"},
    ['57EED0EAC346CD9D'] = {1, "Incendiary Devastator"},
    ['58B2B86C11369241'] = {1, "Incendiary MG Devastator"},
    ['5D142C3A73EBC634'] = {2, "Barrager Tank Ballistic Missile"},
    ['6021E22338333D88'] = {1, "Nursing Spewer"},
    ['604A794EC45BB820'] = {1, "Elevated Overseer"},
    ['63DF3D07B7424588'] = {2, "Barrager Tank"},
    ['67DC32DCA4F02D33'] = {2, "Fleshmob"},
    ['6B202392F4AB605E'] = {2, "Spore Charger"},
    ['6DAB2EADF5D8B692'] = {2, "Hulk Firebomber"},
    ['728421351D440EBC'] = {1, "Spore Burst Warrior"},
    ['746A7F3BEDA32699'] = {1, "Male Radical"},
    ['843D18D4B5512B63'] = {2, "Factory Strider Cannon Turret"},
    ['905809A4C28D8A45'] = {2, "Crusher"},
    ['960B48A421A3FAAA'] = {3, "Dragonroach"},
    ['9647B00CC3A9D36F'] = {1, "Rocket Devastator"},
    ['965EAE5A51ACDD4A'] = {2, "Harvester"},
    ['96BA14C9EBB49CE1'] = {2, "Hulk"},
    ['9D8827FED763650E'] = {1, "Male Agitator"},
    ['9E2E17F2CCCCAFDD'] = {3, "Bile Titan"},
    ['A05BD1EC67B3AC4C'] = {2, "Charger Behemoth MK2"},
    ['A1F37BF2A40FBDE4'] = {1, "Hive Guard"},
    ['A35207C6F2150806'] = {1, "Rupture Warrior"},
    ['A381A11C07D3EB94'] = {1, "Rupture Spewer"},
    ['A6A68D8AF177F3A1'] = {1, "Berserker"},
    ['ABDB2E2A0479D8CA'] = {2, "Cannon Turret MK2"},
    ['AC60E78435098C9D'] = {1, "Watcher"},
    ['AE63E525853D7044'] = {1, "Devastator MK3"},
    ['B2A6FA1E4284C7E6'] = {1, "Warrior (Spawned)"},
    ['B5DBC0C240C921AD'] = {1, "Incendiary Berserker"},
    ['B92435FBF60F0748'] = {1, "Heavy Devastator MK2"},
    ['BC242702FB46B7E7'] = {2, "Vox Engine"},
    ['BE39E313A1E46BB9'] = {1, "Warrior MK2"},
    ['BE743B2FAA3A6E26'] = {1, "Jet Brigade Devastator"},
    ['C626D2BB495A202D'] = {1, "Devastator"},
    ['C6449FFD9EA3779C'] = {2, "Shredder Tank"},
    ['C9BCCCB0A54A82A4'] = {1, "Incendiary Rocket Devastator"},
    ['CBB1BA3366009C3A'] = {1, "Female Radical"},
    ['CC188F0C80505C6C'] = {1, "Wretch"},
    ['CC7022FDD172089B'] = {1, "Nursing Spewer MK2"},
    ['CCAE5264ACD591B7'] = {1, "Bile Spewer MK2"},
    ['CD28A27A79BE53D5'] = {1, "Command Bunker HMG"},
    ['D37E8D120D2836E3'] = {3, "Factory Strider"},
    ['D522FD4748D443A5'] = {2, "Brood Commander"},
    ['D5792F6856B06BA4'] = {1, "Jet Brigade Berserker"},
    ['D63FCBFF0851B7AF'] = {2, "Harvester MK2"},
    ['DA40BB347C7447F2'] = {1, "Overseer"},
    ['DCF8E74212FBEE3B'] = {2, "Impaler"},
    ['E0353177F1329573'] = {1, "Conflagration Devastator"},
    ['E8F19A0AA958E46D'] = {1, "Crescent Overseer"},
    ['EACEE39FA017B495'] = {1, "Warrior"},
    ['EF04CB84D097A497'] = {3, "Spore Burst Bile Titan"},
    ['EF570293245A17C2'] = {2, "War Strider"},
    ['F1610AC48CDC5240'] = {1, "Overseer (No Package)"},
    ['F540CA9D9D4A422E'] = {2, "Stalker"},
    ['F66D0BAD8693779A'] = {1, "Rocket Devastator MK2"},
    ['F79CD8BB654397DF'] = {2, "Alpha Commander"},
    ['F8131632AA867107'] = {2, "Scout Strider"},
    ['F8B5A81A86D5D4EB'] = {1, "Heavy Devastator"},
}

local function build_ping_events(env)
    local ffi = require('ffi')
    local categories = {[1] = 'medium_enemy', [2] = 'large_enemy', [3] = 'giant_enemy'}
    local state = {scene = nil, seen = {}, generation = 0, serial = 0, status = '等待标记数据'}
    local api = {state = state, supported = {medium_enemy = true, large_enemy = true,
        giant_enemy = true, building = true, stratagem = true, map = true}}
    local function reset(reason)
        state.scene, state.session, state.seen = nil, nil, {}
        state.map_scene = nil
        state.status = reason or '等待标记数据'
    end
    function api.reset() reset() end
    local function u32(bytes, at)
        local a,b,c,d = bytes:byte(at + 1, at + 4)
        assert(d, 'short integer read')
        return a + b*256 + c*65536 + d*16777216
    end
    local function hex64(bytes, at)
        return string.format('%08X%08X', u32(bytes, at + 4), u32(bytes, at))
    end
    local function float(bytes, at)
        local value = ffi.new('uint32_t[1]', u32(bytes, at))
        return tonumber(ffi.cast('float *', value)[0])
    end
    local function mul32(a, b)
        local al,bl = a%65536,b%65536
        return (al*bl + ((math.floor(a/65536)*bl + math.floor(b/65536)*al)%65536)*65536)%4294967296
    end

    local function observe(base)
        local session = env.session and env.session() or false
        assert(not env.session or session ~= false and session ~= nil, 'ping session unavailable')
        local calls, mapping_guards = 0, {}
        local function read(address, n)
            assert(type(address) == 'number' and address%1 == 0 and address >= 65536
                and n > 0 and n <= 65536 and address+n < 2^47, 'invalid ping read bounds')
            calls = calls + 1; assert(calls <= 2048, 'ping read budget exceeded')
            local bytes = env.read(address, n)
            assert(type(bytes) == 'string' and #bytes == n, 'ping data unreadable')
            return bytes
        end
        local function ptr(address)
            local bytes = read(address, 8)
            local value = u32(bytes, 0) + u32(bytes, 4)*4294967296
            assert(value >= 65536 and value%8 == 0 and value < 2^47, 'invalid ping pointer')
            return value
        end
        local function word(address) return u32(read(address, 4), 0) end
        local function guarded(address, n)
            local bytes = read(address, n)
            mapping_guards[#mapping_guards+1] = {address, bytes}
            return bytes
        end
        local function guarded_ptr(address)
            local bytes = guarded(address,8)
            local value = u32(bytes,0)+u32(bytes,4)*4294967296
            assert(value >= 65536 and value%8 == 0 and value < 2^47, 'invalid guarded pointer')
            return value
        end
        local function lookup(address, key, limit)
            local header = guarded(address, 20)
            local slots = u32(header, 0) + u32(header, 4)*4294967296
            local cap, empty, factor = u32(header, 8), u32(header, 12), u32(header, 16)
            assert(slots >= 65536 and slots%4 == 0 and slots < 2^47
                and cap > 0 and cap <= 1048576, 'invalid ping entity table')
            local power = cap
            while power > 1 and power%2 == 0 do power = power/2 end
            assert(power == 1, 'invalid ping entity capacity')
            if key == empty then return nil end
            for probe = 0, math.min(cap, 256)-1 do
                local row = guarded(slots + ((mul32(key, factor)+probe)%cap)*8, 8)
                local found, index = u32(row, 0), u32(row, 4)
                if found == empty then return nil end
                if found == key then
                    if index == 0xffffffff then return nil end
                    assert(index < limit, 'invalid ping entity index')
                    return index
                end
            end
            error('ping entity lookup exhausted')
        end
        local ctx, root, players, ring = ptr(base+0x347cef0), ptr(base+0x346bf98),
            ptr(base+0x3326468), ptr(base+0x347ce30)
        if env.context then assert(env.context() == ctx, 'ping network context changed') end
        local own_bytes = read(ctx+0xb398, 8)
        local own = hex64(own_bytes, 0)
        assert(own ~= '0000000000000000', 'local ping peer unavailable')
        local count = word(players+0x84)
        assert(count > 0 and count <= 4, 'invalid ping player count')
        local creators, own_present, roster_guards = {}, false, {}
        local function owned_entity(entity, peer)
            if entity == nil or entity == 0 or entity == 0xffffffff then return end
            -- Ambiguous/recycled player bindings cannot attribute an event.
            if creators[entity] and creators[entity] ~= peer then creators[entity] = false
            elseif creators[entity] == nil then creators[entity] = peer end
        end
        for slot = 0, count-1 do
            local peer_at = players+0x2c8+slot*0x38
            local peer_bytes = read(peer_at, 8)
            local peer = hex64(peer_bytes, 0)
            roster_guards[#roster_guards+1] = {peer_at, peer_bytes}
            if peer ~= '0000000000000000' then
                if peer == own then own_present = true end
                local descriptor_at = players+0xe8+slot*8
                local descriptor_bytes = guarded(descriptor_at, 8)
                local descriptor = u32(descriptor_bytes, 0)+u32(descriptor_bytes, 4)*4294967296
                assert(descriptor >= 65536 and descriptor%8 == 0 and descriptor < 2^47, 'invalid player descriptor')
                local player_entity = read(descriptor+8, 4)
                owned_entity(u32(player_entity, 0), peer)
                roster_guards[#roster_guards+1] = {descriptor+8, player_entity}
                local network_at = players+0x3a8+slot*0x20
                local network_bytes = read(network_at, 4)
                roster_guards[#roster_guards+1] = {network_at, network_bytes}
                local network = u32(network_bytes, 0)
                if network < 0x7fff then
                    local index = lookup(root+0xf22ec8, network, 2048)
                    if index then
                        local identity_at = root+0xf32f18+index*24
                        local identity = read(identity_at, 24)
                        assert(u32(identity, 16) == network, 'ping avatar network identity changed')
                        owned_entity(u32(identity, 8), peer)
                        roster_guards[#roster_guards+1] = {identity_at, identity}
                    end
                end
            end
        end
        assert(own_present, 'local ping peer absent from roster')
        local header = read(ring, 16)
        local head, tail = u32(header, 8), u32(header, 12)
        assert(head < 128 and tail < 128, 'invalid ping ring bounds')
        local entries, entry_guards = {}, {}
        -- Map21's receiver returns before inserting a HUD record. Read the
        -- authoritative replicated actor pins, which also include our own pin.
        local map_scene
        local have_actor_global, actor_global = pcall(read, base+0x3326d20, 8)
        if have_actor_global and hex64(actor_global, 0) ~= '0000000000000000' then
            local actors = ptr(base+0x3326d20)
            mapping_guards[#mapping_guards+1] = {base+0x3326d20, actor_global}
            local actor_count = u32(guarded(actors+0x6c, 4), 0)
            assert(actor_count <= 16, 'invalid map actor count')
            map_scene = string.format('%X', actors)
            for slot = 0, actor_count-1 do
                local descriptor_bytes = guarded(actors+0x110+slot*8, 8)
                local descriptor = u32(descriptor_bytes,0)+u32(descriptor_bytes,4)*4294967296
                assert(descriptor >= 65536 and descriptor%8 == 0 and descriptor < 2^47, 'invalid map actor descriptor')
                local creator = u32(guarded(descriptor+8, 4), 0)
                if creators[creator] then
                    local address = actors+0x547830+slot*0x78
                    -- Guard only the mark bit and pin fields; other actor flags
                    -- can change normally while this read-only snapshot is taken.
                    local flags = read(address, 4)
                    local active = math.floor(u32(flags,0)/4)%2 == 1
                    local pin = guarded(address+0x50, 20)
                    entry_guards[#entry_guards+1] = {map_address=address, active=active}
                    if active and u32(pin,12) ~= 0 then
                        entries[#entries+1] = {slot=128+slot, age=0, kind=21,
                            creator=creator, creator_id=creators[creator], target_id=0xffffffff,
                            target_network=u32(pin,16), map_type=u32(pin,12), localization_key=0,
                            position={x=float(pin,0),y=float(pin,4),z=float(pin,8)},
                            map_source=true, token=string.format('%X:',creator)..pin}
                    end
                end
            end
        end
        assert(header:byte(1) == 1 or map_scene, 'ping UI inactive')
        local function token(bytes)
            return bytes:sub(1,4)..bytes:sub(17,20)..bytes:sub(25,28)..bytes:sub(33,36)
                .. ((u32(bytes,0)==21 or u32(bytes,0)==0) and bytes:sub(5,16) or '')
        end
        for step = 0, (header:byte(1) == 1 and (tail-head)%128 or 0)-1 do
            local slot = (head+step)%128
            local bytes = read(ring+16+slot*0x58, 0x58)
            local duration, age = float(bytes, 0x10), float(bytes, 0x14)
            if (not map_scene or u32(bytes,0) ~= 21)
                and duration == duration and duration > 0 and duration <= 10000
                and age == age and age >= 0 and age < duration then
                local kind, creator, target = u32(bytes, 0), u32(bytes, 0x18), u32(bytes, 0x20)
                entries[#entries+1] = {slot = slot, age = age, kind = kind, creator = creator,
                    creator_id = creators[creator], target_id = target,
                    position = {x=float(bytes,4),y=float(bytes,8),z=float(bytes,12)},
                    localization_key=u32(bytes,0x34), token = token(bytes)}
                entry_guards[#entry_guards+1] = {address=ring+16+slot*0x58, token=token(bytes), age=age, duration=duration}
            end
        end
        local definitions
        local importance_kinds = {[0]='primary', [1]='prerequisite', [2]='optional', [3]='tactical'}
        local function localized_name(key)
            if key == 0 or not env.localize then return nil end
            local okay, value = pcall(env.localize, key)
            if okay and type(value) == 'string' and #value > 0 and #value <= 256 then
                value = value:gsub('[%c<>]', '')
                if value ~= '' then return value end
            end
        end
        local function objective_name(entity)
            local manager = guarded_ptr(base+0x3326da0)
            local objective_count = u32(guarded(manager+0x24,4),0)
            assert(objective_count <= 2048, 'invalid objective count')
            local index = lookup(manager+0x38, entity, 2048)
            if not index or index >= objective_count then return nil end
            local descriptors = guarded_ptr(manager+0x50)
            local descriptor_at = descriptors+index*8
            local descriptor = guarded_ptr(descriptor_at)
            local identity = guarded(descriptor,24)
            if u32(identity,8) ~= entity then return nil end
            local runtimes = guarded_ptr(manager+0x60)
            local runtime = runtimes+index*0x1078
            local importance = u32(guarded(runtime+0x1038,4),0)
            local override = guarded(runtime+0x1054,1):byte(1)
            assert(override <= 1, 'invalid objective name override')
            local key
            if override == 1 then
                key = u32(guarded(runtime+0x1050,4),0)
            else
                definitions = definitions or read(base+0x32ef870,153*0xa0)
                for n=0,152 do
                    local at = n*0xa0
                    if definitions:sub(at+0x19,at+0x20) == identity:sub(1,8) then
                        local definition = definitions:sub(at+1,at+0xa0)
                        mapping_guards[#mapping_guards+1] = {base+0x32ef870+at,definition}
                        key = u32(definition,0x38)
                        break
                    end
                end
            end
            local name = key and localized_name(key)
            if not name then return nil end
            return {target=name, localization_key=key, objective_kind=importance_kinds[importance] or 'unknown',
                objective_importance=importance, objective_name=name}
        end
        local function target(entry)
            if entry.kind == 24 or not entry.creator_id then return nil end
            if entry.kind == 0 then
                for _, value in pairs(entry.position) do
                    if value ~= value or math.abs(value)>1000000 then return nil end
                end
                return {category='map',target='地点标记',position=entry.position,
                    creator_id=entry.creator_id,kind=entry.kind,slot=entry.slot,
                    source='ground_ping',localization_key=entry.localization_key}
            end
            if entry.kind == 21 then
                for _, value in pairs(entry.position) do
                    if value ~= value or math.abs(value)>1000000 then return nil end
                end
                local event = {category='map',target=localized_name(entry.localization_key) or '地图标记',position=entry.position,
                    creator_id=entry.creator_id,kind=entry.kind,slot=entry.slot,
                    source='tactical_map',localization_key=entry.localization_key}
                -- Captured replicated MapMarkerType 6 is the extraction pin.
                if entry.map_type == 6 then event.target = '撤离区' end
                if entry.map_type == 1 then
                    if entry.target_network >= 0x7fff then return nil,'retry' end
                    local index = lookup(root+0xf22ec8,entry.target_network,2048)
                    if not index then return nil,'retry' end
                    local identity = guarded(root+0xf32f18+index*24,24)
                    if u32(identity,16) ~= entry.target_network then return nil,'retry' end
                    local entity = u32(identity,8)
                    local objective = objective_name(entity)
                    if not objective then return nil,'retry' end
                    for key,value in pairs(objective) do event[key]=value end
                    event.target_id = entity
                    event.source = 'map_objective'
                end
                return event
            end
            local localized = localized_name(entry.localization_key)
            -- The game selects these through Spottable.marker_type/override. Only
            -- accept otherwise unknown resources when the native UI label resolves.
            local native_category = (entry.kind==18 or entry.kind==19) and 'building'
                or entry.kind==20 and 'stratagem' or nil
            if native_category and (entry.target_id==0 or entry.target_id==0xffffffff) then
                if not localized then
                    return nil, entry.localization_key > 0 and 'retry' or nil
                end
                return {category=native_category,target=localized,position=entry.position,
                    creator_id=entry.creator_id,kind=entry.kind,slot=entry.slot,
                    localization_key=entry.localization_key,source='native_marker'}
            end
            if entry.target_id == 0 or entry.target_id == 0xffffffff
                or entry.target_id == entry.creator then return nil end
            local index = lookup(root+0xf1aeb0, entry.target_id, 2048)
            if not index then return nil, 'retry' end
            local address = root+0xf32f18+index*24
            local identity = read(address, 24)
            if u32(identity, 8) ~= entry.target_id then return nil, 'retry' end
            local resource = hex64(identity, 0)
            if EXCLUDED_SUPPLIES[resource] then return nil end
            local info = PING_TARGETS[resource]
            if not info and not (native_category and localized) then
                if native_category and entry.localization_key > 0 then return nil, 'retry' end
                return nil
            end
            if read(address, 24) ~= identity then return nil, 'retry' end
            local label = localized or info and info[2]
            if info and info[2]:match('^TCS') and localized and not localized:find('TCS',1,true) then
                label = info[2] .. ' / ' .. localized
            end
            return {category = info and (categories[info[1]] or info[1]) or native_category,
                target = label, target_id = entry.target_id,
                creator_id = entry.creator_id, resource = resource, kind = entry.kind, slot = entry.slot,
                localization_key=entry.localization_key, position=entry.position, source='target'}
        end
        local function validate()
            -- Recheck after target reads as well: a leaving/reordered teammate
            -- must never leave a stale attribution in the outgoing event batch.
            assert((not env.session or env.session() == session) and env.base() == base and ptr(base+0x347cef0) == ctx and ptr(base+0x346bf98) == root
                and ptr(base+0x3326468) == players and ptr(base+0x347ce30) == ring
                and read(ctx+0xb398, 8) == own_bytes and word(players+0x84) == count
                and read(ring, 16) == header, 'ping observation changed')
            for _, guard in ipairs(entry_guards) do
                if guard.map_address then
                    assert((math.floor(word(guard.map_address)/4)%2 == 1) == guard.active, 'map pin changed')
                else
                    local bytes = read(guard.address, 0x58)
                    local age = float(bytes, 0x14)
                    assert(token(bytes) == guard.token and age == age and age >= guard.age
                        and age < guard.duration, 'ping record changed')
                end
            end
            for _, guards in ipairs({roster_guards, mapping_guards}) do
                for _, guard in ipairs(guards) do
                    assert(read(guard[1], #guard[2]) == guard[2], 'ping identity mapping changed')
                end
            end
        end
        validate()
        return {base=base, session=session, scene = string.format('%X:%X:%X:%X:%X:%s', base, ctx, root, players, ring, own),
            entries = entries, map_scene=map_scene, target = target, read = read, ctx = ctx, root = root, ring = ring,
            own = own, header = header, ptr = ptr, validate = validate}
    end

    function api.poll(now)
        if type(now) ~= 'number' or now ~= now or now == math.huge or now == -math.huge then
            reset('标记计时不可用'); return 0, state.status
        end
        local okay, snapshot = pcall(function()
            local base = env.base()
            assert(type(base) == 'number' and base >= 65536 and base < 2^47, 'unverified game build')
            return observe(base)
        end)
        if not okay then reset('标记数据暂不可用'); return 0, state.status end
        local first = state.scene ~= snapshot.scene or state.session ~= snapshot.session
        local first_map = first or state.map_scene ~= snapshot.map_scene
        if first then state.generation = state.generation+1; state.seen = {} end
        local next_seen, events = {}, {}
        for _, entry in ipairs(snapshot.entries) do
            local previous = state.seen[entry.slot]
            local fresh = not previous or previous.pending or previous.token ~= entry.token or entry.age < previous.age
            next_seen[entry.slot] = {token = entry.token, age = entry.age}
            if not first and not (entry.map_source and first_map) and fresh then
                local good, event, reason = pcall(snapshot.target, entry)
                if not good or reason == 'retry' then
                    -- A target can finish streaming after its ping arrives. Preserve
                    -- freshness until it resolves or the native mark expires.
                    next_seen[entry.slot] = {token=entry.token, age=entry.age, pending=true}
                end
                if good and event then
                    state.serial = state.serial+1
                    -- Every legitimate renewal gets a distinct key even for the same
                    -- target and slot; the caller's queue can dedupe repeated polls.
                    event.key = snapshot.scene..':'..state.generation..':'..state.serial
                    event.id = event.key
                    events[#events+1] = event
                end
            end
        end
        -- Target reads may race a world transition; discard the entire batch.
        local valid = pcall(snapshot.validate)
        if not valid then reset('标记数据切换中'); return 0, state.status end
        state.scene, state.session, state.seen = snapshot.scene, snapshot.session, next_seen
        state.map_scene = snapshot.map_scene
        local emitted = 0
        for _, event in ipairs(events) do
            -- A listener may change the room while handling the previous event.
            -- Never recapture old observations as events from the new session.
            local stable, same = pcall(function()
                return env.base() == snapshot.base
                    and (not env.session or env.session() == snapshot.session)
                    and (not env.context or env.context() == snapshot.ctx)
            end)
            if not stable or not same then
                reset('标记数据切换中'); return emitted, state.status
            end
            local success, accepted = pcall(env.emit, event, now)
            if success and accepted == true then emitted = emitted+1 end
        end
        state.status = first and '已记录现有标记' or emitted > 0 and '已识别玩家标记' or '等待新的玩家标记'
        return emitted, state.status
    end
    return api
end
