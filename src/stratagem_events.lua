-- Read-only observer for non-thrown stratagem successes on Steam build 25480438.
-- env.base enforces the game.dll fingerprint. The success-writer instructions
-- below additionally pin the per-peer record layout; no native calls or writes.
-- Stable IDs/name keys/call types: current StratagemInfo RawData, not build enums.
-- https://github.com/Darctor/Helldivers2_RawData/tree/main/Data/settings
-- Records +347CE50, stride1690, entries+1C0 x30, count+7C0; manager count+2D200.
-- 135C5D0 writes start+10 and activation+20 only after confirmed success.
-- 135C2C0 can also update start/cooldown on failure and mirrors shared cooldowns
-- to other peers. Activation changes prove success; mirrored records do NOT
-- prove which player called it, so ambiguous events explicitly name the squad.
local function build_stratagem_events(env)
    local catalog = {
        [3837064536]={'重新武装“飞鹰”',2109771423,'use',3},
        [2186648412]={'战术摄像机',2363192702,'summon',3},
        [115737856]={'撤离信标',1171875332,'summon',2},
        [1503060624]={'虫洞封堵装置',621653032,'summon',3},
        [1606251952]={'货运集装箱',2486779978,'summon',3},
        [2670122272]={'货运集装箱',2486779978,'summon',3},
        [705279885]={'移动通信中继站',3593734022,'summon',3},
        [3722314010]={'超级地球旗帜',2281165846,'summon',3},
        [599201298]={'超级地球旗帜',2281165846,'summon',3},
        [2720892179]={'虫族震动装置',1923094316,'summon',3},
        [685210453]={'勘探钻机',2631236711,'summon',3},
        [650447969]={'地震探测器',2198451684,'summon',3},
        [871315230]={'撤离信标',822640880,'summon',3},
        [509712523]={'紧急撤离信标',3901583393,'summon',3},
        [716088572]={'紧急撤离信标',822640880,'summon',3},
        [3300666223]={'上传数据',2087215146,'use',3},
        [681028671]={'数据接口',1159822780,'summon',3},
        [65564476]={'提取燃料',1360402559,'use',3},
        [913592461]={'毒素钻机',966239659,'summon',3},
        [101457192]={'装填高爆弹',2664466741,'use',3},
        [3702563421]={'装填反坦克弹',3778618418,'use',3},
        [4264661046]={'装填霰弹',527728115,'use',3},
    }
    local pins = {
        {0x135c63c,string.char(0x45,0x84,0xc9,0x0f,0x84,0x1e,1,0,0)},
        {0x135c69c,string.char(0x48,0x89,0x8c,0xfd,0xd0,1,0,0)},
        {0x135c6f9,string.char(0x48,0x89,0x8c,0xfd,0xe0,1,0,0)},
    }
    local state = {status='等待任务战备数据', previous={}, seen={}, pending={}}
    local api = {state=state}
    function api.reset()
        state.scene,state.clock,state.previous,state.seen,state.pending,state.last_poll=nil,nil,{},{},{},nil
        state.status='等待任务战备数据'
    end
    local function word(s, at)
        local a,b,c,d=s:byte(at+1,at+4);assert(d,'short task record')
        return a+b*256+c*65536+d*16777216
    end
    local function number(s,at)
        local n=word(s,at)+word(s,at+4)*4294967296
        assert(n<2^53,'inexact task timestamp');return n
    end
    local function peer(s) return string.format('%08X%08X',word(s,4),word(s,0)) end
    local function capture(base)
        local guards,budget={},0
        local function read(at,n)
            assert(type(at)=='number' and at%1==0 and at>=65536 and at+n<2^47
                and n>0 and n<=65536,'invalid task read bounds')
            budget=budget+1;assert(budget<=2048,'task read budget')
            local s=env.read(at,n);assert(type(s)=='string' and #s==n,'task data unreadable');return s
        end
        local function guard(at,n)
            local s=read(at,n);guards[#guards+1]={at,s};return s
        end
        local function ptr(at,alignment)
            local n=number(guard(at,8),0)
            assert(n>=65536 and n%(alignment or 8)==0 and n<2^47,'invalid task pointer');return n
        end
        for _,pin in ipairs(pins) do assert(guard(base+pin[1],#pin[2])==pin[2],'task success signature changed') end
        local session=env.session and env.session()
        assert(session~=nil and session~=false,'task session unavailable')
        local ctx,world,players,records,clock=ptr(base+0x347cef0),ptr(base+0x346bf98),
            ptr(base+0x3326468),ptr(base+0x347ce50),ptr(base+0x3326348)
        local own=peer(guard(ctx+0xb398,8))
        local count=word(guard(players+0x84,4),0)
        assert(count>=1 and count<=4,'invalid task roster')
        local roster,roster_order={},{}
        for i=0,count-1 do
            local p=peer(guard(players+0x2c8+i*0x38,8))
            assert(p~='0000000000000000' and not roster[p],'invalid task peer')
            roster[p]=true;roster_order[#roster_order+1]=p
        end
        assert(roster[own],'local task peer absent')
        local now=number(read(clock+0x18,8),0)
        local record_count=word(guard(records+0x2d200,4),0)
        assert(record_count<=32,'invalid task record count')
        local entries,groups,found={},{},{}
        for i=0,record_count-1 do
            local at=records+i*0x1690
            local p=peer(guard(at,8))
            if roster[p] then
                assert(not found[p],'duplicate task record peer');found[p]=true
                local n=word(guard(at+0x7c0,4),0);assert(n<=16,'invalid task entry count')
                if n>0 then
                    local data=guard(at+0x1c0,n*0x30)
                    for slot=0,n-1 do
                        local offset=slot*0x30;local kind=word(data,offset)
                        assert(kind<512,'invalid task type')
                        -- Current Info structures contain 32-bit fields and are
                        -- only 4-aligned; manager pointers above remain 8-aligned.
                        local row=ptr(base+0x37cb600+kind*8,4)
                        local info=guard(row,0x78);local id=word(info,4);local known=catalog[id]
                        local discovered=env.catalog and env.catalog.lookup(id)
                        -- Thrown call-ins already have a confirmed HUD producer;
                        -- observe non-thrown successes here to avoid duplicate warnings.
                        if not known and discovered and (discovered.call_type==2 or discovered.call_type==3) then
                            known={discovered.name,discovered.name_key,
                                (discovered.call_type==2 or (discovered.payload_count or 0)>0) and 'summon' or 'use',discovered.call_type}
                        end
                        if known and word(info,0)==kind and word(info,0x74)==known[4] then
                            local key=p..':'..id
                            assert(not entries[key],'duplicate task slot')
                            local item={peer=p,id=id,definition=known,name_key=word(info,0x2c),
                                start=number(data,offset+0x10),activation=number(data,offset+0x20)}
                            entries[key]=item
                            local group=id..':'..string.format('%.0f',item.activation)
                            groups[group]=groups[group] or {};groups[group][#groups[group]+1]=item
                        end
                    end
                end
            end
        end
        -- Commit a complete, consistent snapshot before publishing any event.
        local function validate()
            assert(env.base()==base and env.session()==session,'task session changed')
            for _,g in ipairs(guards) do assert(read(g[1],#g[2])==g[2],'task observation changed') end
        end
        validate()
        return {scene=table.concat({tostring(base),tostring(session),tostring(ctx),tostring(world),
            tostring(records),own,table.concat(roster_order,','),tostring(record_count)},'|'),
            clock=now,entries=entries,groups=groups,validate=validate}
    end
    function api.poll(now)
        if type(now)~='number' or now~=now or math.abs(now)==math.huge then return 0,state.status end
        if state.last_poll and now>=state.last_poll and now-state.last_poll<0.2 then return 0,state.status end
        state.last_poll=now
        local base=env.base()
        if not base then api.reset();state.status='任务战备：不支持的游戏版本';return 0,state.status end
        local ok,snapshot=pcall(capture,base)
        if not ok then api.reset();state.last_poll=now;state.status='任务战备数据暂不可读';return 0,state.status end
        local baseline=state.scene~=snapshot.scene or not state.clock or snapshot.clock<state.clock
        local previous,previous_clock=state.previous,state.clock
        state.scene,state.clock,state.previous=snapshot.scene,snapshot.clock,snapshot.entries
        if baseline then state.seen,state.pending={},{};state.status='任务战备读取就绪';return 0,state.status end
        for key,expiry in pairs(state.seen) do if now>expiry then state.seen[key]=nil end end
        local emitted=0
        if next(state.pending) then
            for key,pending in pairs(state.pending) do
                local item=snapshot.entries[key]
                local token=item and item.id..':'..string.format('%.0f',item.activation) or nil
                if not item or token~=pending.token or now>pending.expires then
                    state.pending[key]=nil
                else
                    local valid=pcall(snapshot.validate)
                    if not valid then api.reset();state.status='任务战备数据切换中';return emitted,state.status end
                    local delivered,accepted,disposition=pcall(env.emit,pending.event,now)
                    if delivered and accepted==true then
                        state.pending[key]=nil;emitted=emitted+1
                    elseif not (delivered and accepted==false and disposition=='retry') then
                        state.pending[key]=nil
                    end
                end
            end
        end
        for key,item in pairs(snapshot.entries) do
            local old=previous[key]
            local token=item.id..':'..string.format('%.0f',item.activation)
            -- Mission entries can unlock between polls. A new slot is fresh only
            -- when its confirmed start is later than the previous game snapshot.
            local changed=old and item.activation>old.activation
                or not old and item.start>previous_clock and item.activation>0
            if changed and item.start>0 and item.start<=snapshot.clock
                and snapshot.clock-item.start<=15000000 and item.activation>=item.start
                and item.activation<=snapshot.clock+120000000 and not state.seen[token] then
                state.seen[token]=now+30
                local localized,name=pcall(function() return env.localize and env.localize(item.name_key) end)
                if not localized then name=nil end
                if type(name)~='string' or name=='' or #name>200 or name:find('[%c<>]') then name=item.definition[1] end
                local anonymous=#snapshot.groups[token]>1
                local event={key='task:'..token,category='stratagem',action=item.definition[3],target=name,
                    source='mission_stratagem',stratagem_id=item.id,localization_key=item.name_key,
                    anonymous=anonymous,creator_id=not anonymous and item.peer or nil}
                event.id=event.key
                if not pcall(snapshot.validate) then api.reset();state.status='任务战备数据切换中';return emitted,state.status end
                local delivered,accepted,disposition=pcall(env.emit,event,now)
                if delivered and accepted==true then emitted=emitted+1
                elseif delivered and accepted==false and disposition=='retry' then
                    state.pending[key]={token=token,event=event,expires=now+15}
                end
            end
        end
        state.status='任务战备读取就绪'
        return emitted,state.status
    end
    return api
end
