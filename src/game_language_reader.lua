-- Read-only Text Language reader for one reviewed Helldivers 2 build.
-- Production process access is built from kernel32/bcrypt; tests may inject a fake env.
local function build_game_language_reader(options)
    options=type(options)=='table' and options or {}
    local env=options.env or {}
    if type(env)~='table' then env={} end
    local ffi=options.ffi
    local kernel,bcrypt,process

    local function production_setup()
        if not ffi then return false end
        -- cdef declarations are process-global and may already exist in the loader.
        -- Declare each one separately so a duplicate cannot suppress later APIs.
        local declarations={
            'void *GetCurrentProcess(void);',
            'void *GetModuleHandleA(const char *module_name);',
            'uint32_t GetModuleFileNameW(void *module, uint16_t *filename, uint32_t size);',
            'void *CreateFileW(const uint16_t *name, uint32_t access, uint32_t share, void *security, uint32_t creation, uint32_t flags, void *template_file);',
            'int ReadFile(void *file, void *buffer, uint32_t size, uint32_t *received, void *overlapped);',
            'int CloseHandle(void *handle);',
            'int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *received);',
            'int32_t BCryptOpenAlgorithmProvider(void **algorithm, const uint16_t *name, const uint16_t *implementation, uint32_t flags);',
            'int32_t BCryptCreateHash(void *algorithm, void **hash, uint8_t *object, uint32_t object_size, uint8_t *secret, uint32_t secret_size, uint32_t flags);',
            'int32_t BCryptHashData(void *hash, uint8_t *input, uint32_t input_size, uint32_t flags);',
            'int32_t BCryptFinishHash(void *hash, uint8_t *output, uint32_t output_size, uint32_t flags);',
            'int32_t BCryptDestroyHash(void *hash);',
            'int32_t BCryptCloseAlgorithmProvider(void *algorithm, uint32_t flags);',
        }
        for _,declaration in ipairs(declarations) do pcall(ffi.cdef,declaration) end
        if options.api then
            kernel=options.api.kernel
            bcrypt=options.api.bcrypt
            if not kernel or not bcrypt then return false end
        else
            local loaded,k=pcall(ffi.load,'kernel32')
            if not loaded then return false end
            kernel=k
            loaded,bcrypt=pcall(ffi.load,'bcrypt')
            if not loaded then kernel=nil;return false end
        end
        local symbols={'GetCurrentProcess','GetModuleHandleA','GetModuleFileNameW','CreateFileW',
            'ReadFile','CloseHandle','ReadProcessMemory'}
        for _,name in ipairs(symbols) do
            local good,value=pcall(function() return kernel[name] end)
            if not good or (type(value)~='cdata' and type(value)~='function')
                or (type(value)=='cdata' and value==ffi.NULL) then
                kernel,bcrypt=nil,nil;return false
            end
        end
        local crypto={'BCryptOpenAlgorithmProvider','BCryptCreateHash','BCryptHashData',
            'BCryptFinishHash','BCryptDestroyHash','BCryptCloseAlgorithmProvider'}
        for _,name in ipairs(crypto) do
            local good,value=pcall(function() return bcrypt[name] end)
            if not good or (type(value)~='cdata' and type(value)~='function')
                or (type(value)=='cdata' and value==ffi.NULL) then
                kernel,bcrypt=nil,nil;return false
            end
        end
        process=options.api and options.api.process or kernel.GetCurrentProcess()
        return process~=nil and process~=ffi.NULL
    end

    local function is_handle(value)
        if not ffi then return false end
        local ok,result=pcall(function()
            return value~=nil and value~=ffi.NULL and value~=ffi.cast('void*',-1)
        end)
        return ok and result
    end
    local function wide_ascii(value)
        local out=ffi.new('uint16_t[?]',#value+1)
        for i=1,#value do out[i-1]=value:byte(i) end
        out[#value]=0
        return out
    end
    local function module_path(module)
        local path=ffi.new('uint16_t[32768]')
        local length=kernel.GetModuleFileNameW(module,path,32768)
        if length==0 or length>=32768 then return nil end
        return path
    end
    local function hash_file(path)
        if not path then return nil end
        local file=kernel.CreateFileW(path,0x80000000,7,nil,3,0x08000000,nil)
        if not is_handle(file) then return nil end
        local algorithm,hash=ffi.new('void*[1]'),ffi.new('void*[1]')
        local digest
        local ok,result=pcall(function()
            local name=wide_ascii('SHA256')
            assert(bcrypt.BCryptOpenAlgorithmProvider(algorithm,name,nil,0)==0,'SHA256 provider')
            assert(algorithm[0]~=nil and algorithm[0]~=ffi.NULL,'SHA256 provider handle')
            assert(bcrypt.BCryptCreateHash(algorithm[0],hash,nil,0,nil,0,0)==0,'SHA256 hash')
            assert(hash[0]~=nil and hash[0]~=ffi.NULL,'SHA256 hash handle')
            local buffer,received=ffi.new('uint8_t[1048576]'),ffi.new('uint32_t[1]')
            while true do
                assert(kernel.ReadFile(file,buffer,1048576,received,nil)~=0,'module read')
                if received[0]==0 then break end
                assert(bcrypt.BCryptHashData(hash[0],buffer,received[0],0)==0,'SHA256 update')
            end
            local bytes=ffi.new('uint8_t[32]')
            assert(bcrypt.BCryptFinishHash(hash[0],bytes,32,0)==0,'SHA256 finish')
            local hex={}
            for i=0,31 do hex[#hex+1]=string.format('%02X',bytes[i]) end
            return table.concat(hex)
        end)
        if hash[0]~=nil and hash[0]~=ffi.NULL then
            pcall(function() bcrypt.BCryptDestroyHash(hash[0]) end)
        end
        if algorithm[0]~=nil and algorithm[0]~=ffi.NULL then
            pcall(function() bcrypt.BCryptCloseAlgorithmProvider(algorithm[0],0) end)
        end
        pcall(function() kernel.CloseHandle(file) end)
        if not ok then return nil end
        digest=result
        return digest
    end

    local setup_ok=false
    if ffi and (options.api or not env.game_module or not env.exe_module
        or not env.hash_module or not env.read) then
        setup_ok=production_setup()
    end
    if setup_ok then
        if env.game_module==nil then env.game_module=function()
                local p=kernel.GetModuleHandleA('game.dll')
                if not is_handle(p) then return nil end
                return tonumber(ffi.cast('uintptr_t',p))
            end end
        if env.exe_module==nil then env.exe_module=function()
                local p=kernel.GetModuleHandleA(nil)
                if not is_handle(p) then return nil end
                return tonumber(ffi.cast('uintptr_t',p))
            end end
        if env.hash_module==nil then env.hash_module=function(base)
                local p=ffi.cast('void*',base)
                return hash_file(module_path(p))
            end end
        if env.read==nil then env.read=function(address,size)
                local buffer,received=ffi.new('uint8_t[?]',size),ffi.new('size_t[1]')
                local ok=kernel.ReadProcessMemory(process,ffi.cast('const void*',address),buffer,size,received)
                if ok==0 or tonumber(received[0])~=size then return nil end
                return ffi.string(buffer,size)
            end end
    end
    env=type(env)=='table' and env or {}
    local expected_game='2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
    local expected_exe='F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
    local prologue='\x48\x89\x5c\x24\x08\x48\x89\x74\x24\x10\x57\x48\x83\xec\x20\x8b'
    local checked,verified,unsupported=false,false,false
    local game_base
    local M={}

    local function read(address,size)
        if env.read==nil then return nil end
        local ok,value=pcall(env.read,address,size)
        if not ok or type(value)~='string' or #value~=size then return nil end
        return value
    end
    local function u32(bytes)
        if type(bytes)~='string' or #bytes<4 then return nil end
        local a,b,c,d=bytes:byte(1,4)
        return a+b*256+c*65536+d*16777216
    end
    local function u64ptr(bytes)
        if type(bytes)~='string' or #bytes<8 then return nil end
        local a,b,c,d,e,f,g,h=bytes:byte(1,8)
        -- The reviewed game's user-mode pointers are canonical low 47-bit addresses.
        if g~=0 or h~=0 then return nil end
        local p=a+b*256+c*65536+d*16777216+e*4294967296+f*1099511627776
        if p<65536 or p>=140737488355328 then return nil end
        return p
    end
    local function ptr(at) return u64ptr(read(at,8)) end

    local function verify()
        if checked then return verified end
        local ok,result=pcall(function()
            if env.game_module==nil or env.exe_module==nil or env.hash_module==nil then return nil end
            local game=env.game_module()
            local exe=env.exe_module()
            if type(game)~='number' or type(exe)~='number' then return nil end
            local game_hash=env.hash_module(game)
            local exe_hash=env.hash_module(exe)
            if type(game_hash)~='string' or type(exe_hash)~='string'
                then return nil end
            if game_hash:upper()~=expected_game or exe_hash:upper()~=expected_exe then return 'unsupported' end
            local signature=read(game+0x14c0350,#prologue)
            if not signature then return nil end
            if signature~=prologue then return 'unsupported' end
            game_base=game
            return true
        end)
        if ok and result=='unsupported' then checked=true;unsupported=true end
        verified=ok and result==true
        if verified then checked=true end
        return verified
    end

    function M.read()
        if not verify() then return nil end
        local settings=ptr(game_base+0x3326340)
        if not settings then return nil end
        local index_bytes=read(settings+705712,4)
        local index=index_bytes and u32(index_bytes)
        if not index or index>=15 then return nil end
        local record=ptr(game_base+0x37c5650+index*8)
        local text=record and ptr(record+8)
        local bytes=text and (read(text,16) or read(text,8))
        if not bytes or read(settings+705712,4)~=index_bytes then return nil end
        local ending=bytes:find('\0',1,true)
        if not ending then return nil end
        local code=bytes:sub(1,ending-1)
        if #code<2 or #code>12 or not code:match('^%a[%a%-]*$') then return nil end
        code=code:lower()
        if code=='cn' or code=='tw' or code=='zh' or code=='zhs' or code=='zht'
            or code=='zh-cn' or code=='zh-tw' then return 'zh' end
        return 'en'
    end
    function M.verified() return verified end
    function M.unsupported() return unsupported end
    function M.expected_fingerprints() return expected_game,expected_exe end
    function M.hash_file_path(path)
        if not setup_ok or type(path)~='string' or path=='' then return nil end
        for i=1,#path do if path:byte(i)>127 then return nil end end
        return hash_file(wide_ascii(path))
    end
    return M
end

return build_game_language_reader
