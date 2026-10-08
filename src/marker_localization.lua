-- Read-only marker localization for Steam build 25480438.
-- game.dll SHA256: 2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E
-- Proof: work/fork/foundation.lua Localization.bind / extra_localized_text.
-- The complete 99-byte wrapper signature uniquely matches current DLL RVA 17802E0.
-- 17802E6: mov rax,[rip+1BA601B] => engine_root global RVA 3326308.
-- 17802EF: mov rcx,[rax+10]; 17802F3: mov rax,[rcx+3E8].
-- 17802FA: mov ecx,ebx; 17802FC: call rax => const char* (*)(uint32_t).
-- Never call the wrapper: its missing-name fallback writes a shared scratch buffer.
-- env.base() supplies only an already fingerprint-verified game base.
-- env.read(address,n) performs guarded RPM; executable(address) must accept only
-- executable pages belonging to this supported image. env.call invokes the proven
-- lookup ABI and returns a numeric string pointer. This fragment performs no writes.
local function build_marker_localization(env)
 local signature_hex='40534883ec20488b051b60ba018bd9488b4810488b81e80300008bcbffd04885c074058038007555488b1549c0b9014c8d0526050502488d0d93040502448bcb488d420e493bc04c8d05c26cb800480f42caba0e00000048890d1ac0b901e8ddd5d6fe'
 local signature=signature_hex:gsub('..',function(h)return string.char(tonumber(h,16))end)
 local function address(n)
  return type(n)=='number' and n==n and n%1==0 and n>=65536 and n<140737488355328
 end
 local function read(at,n)
  if not address(at) or at+n>=140737488355328 then return nil end
  local ok,s=pcall(env.read,at,n)
  if ok and type(s)=='string' and #s==n then return s end
 end
 local function pointer(at)
  local s=read(at,8);if not s then return nil end
  local a,b,c,d,e,f,g,h=s:byte(1,8)
  if h~=0 or g>=128 then return nil end
  local n=a+b*256+c*65536+d*16777216+e*4294967296+f*1099511627776+g*281474976710656
  return address(n) and n or nil
 end
 local function proof()
  local ok,base=pcall(env.base)
  if not ok or not address(base) or read(base+0x17802e0,#signature)~=signature then return nil end
  local root=pointer(base+0x3326308);if not root then return nil end
  local engine=pointer(root+0x10);if not engine then return nil end
  local target=pointer(engine+0x3e8);if not target then return nil end
  local executable,yes=pcall(env.executable,target)
  if not executable or yes~=true then return nil end
  return {base,root,engine,target}
 end
 local function unchanged(before)
  local after=proof();if not after then return false end
  for i=1,4 do if before[i]~=after[i] then return false end end
  return true
 end
 local function utf8(s)
  local i=1
  while i<=#s do
   local a=s:byte(i);local n,lo,hi=0,128,191
   if a<128 then n=0
   elseif a>=194 and a<=223 then n=1
   elseif a>=224 and a<=239 then
    n=2;if a==224 then lo=160 elseif a==237 then hi=159 end
   elseif a>=240 and a<=244 then
    n=3;if a==240 then lo=144 elseif a==244 then hi=143 end
   else return false end
   if i+n>#s then return false end
   for j=1,n do
    local b=s:byte(i+j)
    if b<(j==1 and lo or 128) or b>(j==1 and hi or 191) then return false end
   end
   i=i+n+1
  end
  return true
 end
 local function lookup(key)
  if type(key)~='number' or key%1~=0 or key<=0 or key>4294967295 then return nil end
  local before=proof();if not before then return nil end
  local ok,at=pcall(env.call,before[4],key)
  if not ok or not address(at) or not unchanged(before) then return nil end
  local chunks,offset={},0
  while offset<1024 do
   local s=read(at+offset,math.min(32,1024-offset)) or read(at+offset,1)
   if not s then return nil end
   local stop=s:find('\0',1,true)
   if stop then
    chunks[#chunks+1]=s:sub(1,stop-1)
    if not unchanged(before) then return nil end
    local value=table.concat(chunks)
    if not utf8(value) then return nil end
    value=value:gsub('[%c]',' ')
    if value=='' or value:match('^#ID%[') then return nil end
    return value
   end
   chunks[#chunks+1]=s;offset=offset+#s
  end
  return nil
 end
 return {lookup=function(key)
  local ok,value=pcall(lookup,key);if ok then return value end
 end}
end
