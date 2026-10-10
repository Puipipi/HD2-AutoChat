-- Read-only StratagemInfo discovery for Steam build 25480438.
-- env.base() must enforce the supported game.dll fingerprint. Extra pins prove
-- the row/name/icon consumers. Layout facts and provenance: docs/STRATAGEM-REFERENCE-0.8.0.md.
-- No game calls, writes, asset loading, or static native-type identity mapping.
local function build_stratagem_catalog(env)
    local names_zh=type(env.names_zh)=='table' and env.names_zh or {}
    local names_en=type(env.names_en)=='table' and env.names_en or {}
    -- Current native payload -> HellpodRack.payloads.item -> EntityComponentMap
    -- identity graph. Provenance/collisions: docs/stratagem-resource-aliases.json.
    -- Shared variants are absent from this exact-ID index and handled separately
    -- by the visible-rule index without claiming which native ID created them.
    local verified_aliases={
        ['02EECD0B1FA49630']=3343676429, ['09183066C4EBCE28']=272480476,
        ['12C8D71AC3897A5C']=3843705076, ['16474112801385B6']=2002187052,
        ['2152D5147B0AC418']=533318241, ['25AA2FD4643CF4EE']=3923676543,
        ['26E40437EA275296']=2007887745, ['2E9D0BDC48B09E60']=3078242205,
        ['31400A6A3003E29C']=1907808218, ['35A61296619CC47E']=2625074523,
        ['3828E2051AA9E897']=336693041, ['3A50B58B0553056A']=3353508219,
        ['43A58CB89CFA197C']=3455841218, ['5990123D142B16CB']=2232989803,
        ['5F3EC9BDA2BD8553']=3330450692, ['6CFCC7F8801A0266']=774795224,
        ['7617642765AC38C7']=2934950455, ['78A8185F63A70795']=2271469939,
        ['88C2D09AD85A7C9F']=512147393, ['88F61AFFF48AC8A4']=4152191751,
        ['967ED15E0BAE363B']=3353508219, ['96DE9CD50F7306E6']=992079466,
        ['9B2140378640432E']=2636699686, ['9F80D67A12A7E40F']=1298599997,
        ['A4E796F84801B40A']=272480476, ['A6A735ACCB4A327F']=14345846,
        ['A8CFFB316F0B5C5F']=875551083, ['B0F1B354BA1D38D8']=2265180087,
        ['B16C9D490AA59B77']=3288352984, ['B2B5E0D185605F9E']=1813634375,
        ['BF4CFD2AEABFB5A4']=3572024208, ['CC786F6491FE7E65']=890972990,
        ['D54B9505C0F72873']=2822568285, ['DE18775FA447A9BF']=1337271929,
        ['E8D5F49AD7780E54']=4261593827, ['F88D61A8FE1E0766']=3843705076,
        ['FDE262593307CA2F']=2822568285, ['FE3B29B2CFA63F9B']=153819019,
    }
    local verified_candidates={
        ['11C27D3BABB38956']={458198946,1567517764,3868299561},
        ['39AB99895147A3BF']={1432571981,3868299561},
        ['4EF9A47109239A58']={1907808218,3868299561},
        ['5052EC6A928CCF1A']={867876502,1295431756},
        ['80932FA0ED6901D3']={3413606544,3753216434},
        ['89C5493E08CA4207']={2207713849,3868299561},
        ['A94913CA014F7579']={867876502,1295431756},
    }
    local state={ready=false,status='等待战备目录',entries={},rules={},generation=0}
    local api={state=state}
    local by_id,by_name,by_resource={},{},{}
    local rule_names,rule_resources={},{},{}
    local pins={
        {0x66d54c,string.char(0x4b,0x8b,0x84,0xfd,0,0xb6,0x7c,3)},
        {0x179d962,string.char(0x8b,0x75,0x2c)},
        {0x183a1e5,string.char(0x49,0x8b,0x96,0xb0,0,0,0)},
    }
    local function word(s,at)
        local a,b,c,d=s:byte(at+1,at+4);assert(d,'short catalog word')
        return a+b*256+c*65536+d*16777216
    end
    local function pointer(s,at,alignment)
        local n=word(s,at)+word(s,at+4)*4294967296
        assert(n>=65536 and n<2^47 and n%(alignment or 4)==0,'invalid catalog pointer')
        return n
    end
    local function hex(s,at) return string.format('%08X%08X',word(s,at+4),word(s,at)) end
    local function f32(s,at)
        local bits=word(s,at);local sign=bits>=2147483648 and -1 or 1
        local exponent=math.floor(bits/8388608)%256;local fraction=bits%8388608
        assert(exponent<255,'nonfinite catalog float')
        return sign*(exponent==0 and fraction*2^-149 or (1+fraction/8388608)*2^(exponent-127))
    end
    local function group(name)
        -- Same family decisions as StratagemCooldown's classify/in_scope;
        -- beacon_color is red/blue/yellow and cannot identify green equipment.
        -- Correct its broad SHIELD GENERATOR keyword: a shield backpack is
        -- blue support equipment, whereas the deployed relay stays green.
        if name:match('^BACKPACK%.') then return 'blue','support' end
        if name:find('COMBAT WALKER',1,true) then return 'blue','mech' end
        if name:find('MINE',1,true) or name:find('TESLA',1,true)
            or name:find('SHIELD GENERATOR',1,true) or name:find('RELAY',1,true) then return 'green','green' end
        local prefix=name:match('^([^.]+)')
        if prefix=='ORBITAL' then return 'red','orbital' end
        if prefix=='EAGLE' then return 'red','eagle' end
        if prefix=='TEAM WEAPONS' or prefix=='BACKPACK' or prefix=='CONSUMABLES' then return 'blue','support' end
        if prefix=='VEHICLES' then return 'blue','vehicle' end
        if prefix=='SENTRYS' or prefix=='SENTRIES' or prefix=='EMPLACEMENTS' then return 'green','green' end
        if prefix=='PRESIDENT REWARDS' then
            if name:find('MACHINEGUN',1,true) or name:find('BACKPACK',1,true) then return 'blue','support' end
            if name:find('SENTRY',1,true) then return 'green','green' end
        end
        return 'other',(prefix=='MISSIONS' or prefix=='MISSIONS CLAN STATION') and 'mission' or 'other'
    end
    local function capture(base)
        local guards,budget={},0
        local function read(at,n)
            assert(type(at)=='number' and at%1==0 and at>=65536 and at+n<2^47
                and n>0 and n<=65536,'invalid catalog read bounds')
            budget=budget+1;assert(budget<=2048,'catalog read budget')
            local s=env.read(at,n);assert(type(s)=='string' and #s==n,'catalog data unreadable')
            return s
        end
        local function guard(at,n)
            local s=read(at,n);guards[#guards+1]={at,s};return s
        end
        for _,pin in ipairs(pins) do assert(guard(base+pin[1],#pin[2])==pin[2],'catalog signature changed') end
        -- StratagemCooldown scans 0..255; every optional slot is independently
        -- qualified. A non-null pointer is never sufficient proof of a row.
        local slots=guard(base+0x37cb600,256*8)
        local entries,ids,keys,aliases={},{},{},{}
        local function unique(index,key,row)
            if key==0 or key=='0000000000000000' then return end
            if index[key]==nil then index[key]=row elseif index[key]~=row then index[key]=false end
        end
        for kind=1,255 do
            if word(slots,kind*8)~=0 or word(slots,kind*8+4)~=0 then
                local ok,at=pcall(pointer,slots,kind*8)
                local raw=ok and env.read(at,0xb8) or nil
                if type(raw)=='string' and #raw==0xb8 and word(raw,0)==kind and word(raw,4)~=0
                    and word(raw,0x74)<=3 then
                    guards[#guards+1]={at,raw}
                    local name_at=pointer(raw,0x10,1)
                    local text=guard(name_at,160);local ending=text:find('\0',1,true)
                    assert(ending,'unterminated catalog name')
                    local debug_name=text:sub(1,ending-1)
                    assert(#debug_name>=2 and not debug_name:find('[^ -~]'),'invalid catalog name')
                    local id=word(raw,4);assert(not ids[id],'duplicate stable stratagem id')
                    local name_key,upper_key=word(raw,0x2c),word(raw,0x28)
                    local color,family=group(debug_name:upper())
                    local icon=hex(raw,0xb0)
                    local cd=f32(raw,0x68);assert(cd>=0 and cd<=86400,'invalid catalog cooldown')
                    local payload_count=word(raw,0xa0);assert(payload_count<=64,'invalid catalog payload count')
                    -- Use the already validated native debug string. Resolving every
                    -- localization key here calls into a game function during the
                    -- first update; discovery and rule identity do not need it.
                    local name_zh=names_zh[id]
                    if type(name_zh)~='string' or name_zh=='' then name_zh='未知战备' end
                    local name_en=names_en[id]
                    if type(name_en)~='string' or name_en=='' then name_en='Unknown stratagem' end
                    local display_name=names_zh[id]
                    if type(display_name)~='string' or display_name=='' then display_name='战备 #'..tostring(id) end
                    local display_name_en=names_en[id]
                    if type(display_name_en)~='string' or display_name_en=='' then display_name_en='Stratagem #'..tostring(id) end
                    local row={id=id,type=kind,name_key=name_key,name_upper_key=upper_key,name=debug_name,
                        display_name=display_name,display_name_en=display_name_en,
                        target_names={zh=name_zh,en=name_en},
                        debug_name=debug_name,call_type=word(raw,0x74),group=color,family=family,
                        icon=icon~='0000000000000000' and icon or nil,icon_kind='material',
                        cooldown=cd,payload_count=payload_count,resource_aliases={}}
                    entries[#entries+1]=row;ids[id]=row
                    unique(keys,name_key,row);unique(keys,upper_key,row)
                end
            end
        end
        assert(#entries>0,'empty catalog')
        -- Visible configuration identity is stricter than a single marker key:
        -- both native name keys and the call type must match exactly. The rule
        -- ID names the settings representative, never the observed caller ID.
        local groups,rules,rule_keys,rule_aliases={},{},{},{}
        local function preferred(a,b)
            local function variant(row)
                local name=row.debug_name:upper()
                return name:match('^PRESIDENT REWARDS%.') or name:match('^%[TUTORIAL%]')
                    or name:match('^TUTORIAL')
            end
            local av,bv=variant(a) and 1 or 0,variant(b) and 1 or 0
            if av~=bv then return av<bv end
            local ai,bi=a.icon and 1 or 0,b.icon and 1 or 0
            if ai~=bi then return ai>bi end
            return a.id<b.id
        end
        for _,row in ipairs(entries) do
            local identity=row.name_upper_key>0 and row.name_key>0
                and table.concat({row.name_upper_key,row.name_key,row.call_type},':') or 'id:'..row.id
            groups[identity]=groups[identity] or {};local members=groups[identity]
            members[#members+1]=row
        end
        for _,members in pairs(groups) do
            table.sort(members,preferred)
            local representative=members[1];local variants={}
            for _,row in ipairs(members) do variants[#variants+1]=row.id end
            table.sort(variants);representative.variant_ids=variants
            rules[#rules+1]=representative
            for _,row in ipairs(members) do
                row.rule_id=representative.id
                row.group,row.family=representative.group,representative.family
                unique(rule_keys,row.name_key,representative)
                unique(rule_keys,row.name_upper_key,representative)
            end
        end
        table.sort(rules,function(a,b) return a.type<b.type end)
        -- A payload may identify the rack rather than its contained equipment;
        -- package/stratagem identity is not a world target identity. Only the
        -- reviewed entity graph and externally VERIFIED aliases enter this index.
        local function aliases_from(source)
            for resource,id in pairs(source) do
                local row=ids[id]
                if row and type(resource)=='string' and resource:match('^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$') then
                    resource=resource:upper();unique(aliases,resource,row)
                    unique(rule_aliases,resource,ids[row.rule_id])
                    row.resource_aliases[#row.resource_aliases+1]=resource
                end
            end
        end
        aliases_from(verified_aliases)
        aliases_from(env.resource_aliases or {})
        -- A shared resource can resolve only a shared visible policy, and only
        -- when its ENTIRE reviewed candidate set is observed in that one rule.
        -- Missing candidates or different key pairs/call types remain unknown.
        for resource,candidates in pairs(verified_candidates) do
            local representative,complete=nil,true
            for _,id in ipairs(candidates) do
                local row=ids[id]
                if not row then complete=false;break end
                local rule=ids[row.rule_id]
                if representative and representative~=rule then complete=false;break end
                representative=rule
            end
            if complete and representative then unique(rule_aliases,resource,representative)
            else rule_aliases[resource]=false end
        end
        assert(env.base()==base,'catalog build changed')
        for _,g in ipairs(guards) do assert(read(g[1],#g[2])==g[2],'catalog changed during scan') end
        return entries,ids,keys,aliases,rules,rule_keys,rule_aliases
    end
    function api.reset()
        state.ready=false;state.entries={};state.rules={};state.status='等待战备目录'
        state.last_scan=nil;by_id,by_name,by_resource={},{},{}
        rule_names,rule_resources={},{}
    end
    function api.scan(now)
        if now~=nil and (type(now)~='number' or now~=now or math.abs(now)==math.huge) then return 0,state.status end
        local base=env.base()
        if not base then api.reset();state.status='战备目录：不支持的游戏版本';return 0,state.status end
        if now and state.ready and state.base==base and state.last_scan
            and now>=state.last_scan and now-state.last_scan<5 then return #state.entries,state.status end
        local ok,entries,ids,keys,aliases,rules,rule_keys,rule_aliases=pcall(capture,base)
        if not ok then api.reset();state.status='战备目录数据暂不可读';return 0,state.status end
        state.entries,by_id,by_name,by_resource=entries,ids,keys,aliases
        state.rules,rule_names,rule_resources=rules,rule_keys,rule_aliases
        state.base=base;state.ready=true;state.last_scan=now;state.generation=state.generation+1
        state.status='战备目录读取就绪（'..#entries..'）'
        return #entries,state.status
    end
    function api.list() return state.entries end
    function api.list_rules() return state.rules end
    function api.lookup(id) return by_id[tonumber(id)] end
    function api.resolve_name_key(key) return by_name[tonumber(key)] or nil end
    function api.resolve_resource(resource)
        return type(resource)=='string' and by_resource[resource:upper()] or nil
    end
    function api.resolve_rule_name_key(key) return rule_names[tonumber(key)] or nil end
    function api.resolve_rule_resource(resource)
        return type(resource)=='string' and rule_resources[resource:upper()] or nil
    end
    return api
end
