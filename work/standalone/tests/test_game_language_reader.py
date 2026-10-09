"""Exercise guarded language settings reads with synthetic read-only memory."""
from pathlib import Path
import hashlib
import struct
import tempfile
import unittest

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[5]
SOURCE = ROOT / 'mods/auto-chat/src/game_language_reader.lua'
GAME_HASH = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
EXE_HASH = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
BASE, EXE, SETTINGS, RECORD, TEXT = 0x100000, 0x500000, 0x200000, 0x300000, 0x400000
SIGNATURE = bytes.fromhex('48895c24084889742410574883ec208b')


class GameLanguageReaderTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
        self.assertTrue(SOURCE.exists(), 'guarded game language reader is missing')
        self.memory, self.reads, self.hashes = {}, [], {BASE: GAME_HASH, EXE: EXE_HASH}
        self.game, self.exe, self.signature = BASE, EXE, SIGNATURE
        self.index = 3
        self.put(BASE + 0x14c0350, SIGNATURE)
        self.put(BASE + 0x3326340, struct.pack('<Q', SETTINGS))
        self.put(SETTINGS + 705712, struct.pack('<I', self.index))
        self.put(BASE + 0x37c5650 + self.index * 8, struct.pack('<Q', RECORD))
        self.put(RECORD + 8, struct.pack('<Q', TEXT))
        self.put(TEXT, b'zh-CN\0' + bytes(10))
        build = self.lua.execute(SOURCE.read_bytes())
        self.reader = build(self.lua.table_from({b'env': self.lua.table_from(self.env())}))

    def put(self, address, value):
        self.memory.update({address + i: byte for i, byte in enumerate(value)})

    def read(self, address, size):
        address, size = int(address), int(size)
        self.reads.append((address, size))
        if any(address + i not in self.memory for i in range(size)):
            return None
        return bytes(self.memory[address + i] for i in range(size))

    def env(self):
        return {b'game_module': lambda: self.game,
                b'exe_module': lambda: self.exe,
                b'hash_module': self.hash_module,
                b'read': self.read}

    def hash_module(self, base):
        base = int(base)
        self.hashes.setdefault(base, None)
        value = self.hashes[base]
        return value.encode() if value is not None else None

    def make_reader(self):
        build = self.lua.execute(SOURCE.read_bytes())
        return build(self.lua.table_from({b'env': self.lua.table_from(self.env())}))

    def test_dual_hash_prologue_and_settings_return_chinese(self):
        self.assertEqual(self.reader[b'read'](), b'zh')
        self.assertTrue(self.reader[b'verified']())
        self.assertEqual(self.reads[0], (BASE + 0x14c0350, len(SIGNATURE)))
        self.assertEqual(self.reads[-1], (SETTINGS + 705712, 4))

    def test_english_and_other_valid_language_codes_resolve_to_english(self):
        self.put(TEXT, b'en-US\0' + bytes(10))
        self.assertEqual(self.reader[b'read'](), b'en')
        self.put(TEXT, b'de-DE\0' + bytes(10))
        self.assertEqual(self.reader[b'read'](), b'en')

    def test_mismatch_blocks_memory_reads_and_is_cached_as_unsupported(self):
        self.hashes[EXE] = '0' * 64
        self.assertIsNone(self.reader[b'read']())
        self.assertIsNone(self.reader[b'read']())
        self.assertTrue(self.reader[b'unsupported']())
        self.assertEqual(self.reads, [])

    def test_transient_hash_failure_retries_and_bad_prologue_blocks_offsets(self):
        self.hashes[EXE] = None
        self.assertIsNone(self.reader[b'read']())
        self.hashes[EXE] = EXE_HASH
        self.assertEqual(self.reader[b'read'](), b'zh')
        self.reads.clear()
        reader = self.make_reader()
        self.put(BASE + 0x14c0350, b'X' * len(SIGNATURE))
        self.assertIsNone(reader[b'read']())
        self.assertEqual(self.reads, [(BASE + 0x14c0350, len(SIGNATURE))])

    def test_invalid_index_unreadable_pointers_and_racing_index_return_nil(self):
        self.put(SETTINGS + 705712, struct.pack('<I', 15))
        self.assertIsNone(self.reader[b'read']())
        self.put(SETTINGS + 705712, struct.pack('<I', self.index))
        self.memory.pop(BASE + 0x3326340)
        self.assertIsNone(self.reader[b'read']())

        self.put(BASE + 0x3326340, struct.pack('<Q', SETTINGS))
        original_read = self.read
        def racing_read(address, size):
            result = original_read(address, size)
            if int(address) == TEXT:
                self.put(SETTINGS + 705712, struct.pack('<I', self.index + 1))
            return result
        env = self.env()
        env[b'read'] = racing_read
        build = self.lua.execute(SOURCE.read_bytes())
        self.reader = build(self.lua.table_from({b'env': self.lua.table_from(env)}))
        self.assertIsNone(self.reader[b'read']())


class ProductionFfiReaderTests(unittest.TestCase):
    """Exercise real FFI arrays with a tiny WinAPI shim and real BCrypt hashing."""

    FACTORY = r'''local ffi=require('ffi')
local real=ffi.load('bcrypt')
local data=...
local mode={};local counts={open_file=0,read_file=0,close_file=0,open_alg=0,
    close_alg=0,create_hash=0,destroy_hash=0,hash_data=0,finish_hash=0,
    null_destroy=0,null_close_alg=0,rpm=0}
local memory={};local offset=0
local function put(address,value)
    for i=1,#value do memory[address+i-1]=value:byte(i) end
end
local function at(address,size)
    local out={}
    for i=1,size do
        local value=memory[address+i-1]
        if value==nil then return nil end
        out[i]=string.char(value)
    end
    return table.concat(out)
end
local api={process=ffi.cast('void*',-1)}
api.kernel={}
api.kernel.GetCurrentProcess=function() return api.process end
api.kernel.GetModuleHandleA=function() return ffi.NULL end
api.kernel.GetModuleFileNameW=function() return 0 end
api.kernel.CreateFileW=function()
    counts.open_file=counts.open_file+1
    if mode.bad_file then return ffi.cast('void*',-1) end
    offset=0
    return ffi.cast('void*',0x1111)
end
api.kernel.ReadFile=function(file,buffer,size,received)
    counts.read_file=counts.read_file+1
    if mode.read_zero then return 0 end
    local available=math.max(0,#data-offset)
    local n=math.min(mode.read_short and math.max(0,size-1) or size,available)
    if n>0 then ffi.copy(buffer,data:sub(offset+1,offset+n));offset=offset+n end
    received[0]=n
    return 1
end
api.kernel.CloseHandle=function() counts.close_file=counts.close_file+1;return 1 end
api.kernel.ReadProcessMemory=function(process,address,buffer,size,received)
    counts.rpm=counts.rpm+1
    if mode.rpm_zero then return 0 end
    local base=tonumber(ffi.cast('uintptr_t',address))
    local n=mode.rpm_short and math.max(0,size-1) or size
    local value=at(base,n)
    if not value then return 0 end
    if n>0 then ffi.copy(buffer,value,n) end
    received[0]=n
    return 1
end
api.bcrypt={}
api.bcrypt.BCryptOpenAlgorithmProvider=function(out,name,implementation,flags)
    counts.open_alg=counts.open_alg+1
    if mode.open_fail then return -1 end
    if mode.open_null then out[0]=ffi.NULL;return 0 end
    return real.BCryptOpenAlgorithmProvider(out,name,implementation,flags)
end
api.bcrypt.BCryptCreateHash=function(alg,out,obj,obj_size,secret,secret_size,flags)
    counts.create_hash=counts.create_hash+1
    if mode.create_fail then return -1 end
    if mode.create_null then out[0]=ffi.NULL;return 0 end
    return real.BCryptCreateHash(alg,out,obj,obj_size,secret,secret_size,flags)
end
api.bcrypt.BCryptHashData=function(hash,input,size,flags)
    counts.hash_data=counts.hash_data+1
    return real.BCryptHashData(hash,input,size,flags)
end
api.bcrypt.BCryptFinishHash=function(hash,out,size,flags)
    counts.finish_hash=counts.finish_hash+1
    if mode.finish_fail then return -1 end
    return real.BCryptFinishHash(hash,out,size,flags)
end
api.bcrypt.BCryptDestroyHash=function(hash)
    if hash==nil or hash==ffi.NULL then counts.null_destroy=counts.null_destroy+1;return -1 end
    counts.destroy_hash=counts.destroy_hash+1
    return real.BCryptDestroyHash(hash)
end
api.bcrypt.BCryptCloseAlgorithmProvider=function(alg,flags)
    if alg==nil or alg==ffi.NULL then counts.null_close_alg=counts.null_close_alg+1;return -1 end
    counts.close_alg=counts.close_alg+1
    return real.BCryptCloseAlgorithmProvider(alg,flags)
end
return api,mode,counts,function(address,value) put(address,value) end
'''

    def setUp(self):
        self.lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
        self.build = self.lua.execute(SOURCE.read_bytes())
        self.ffi = self.lua.eval("require('ffi')")
        # Declare and load the real system APIs once; this does not resolve game modules
        # or read process memory. The tested reader uses the injected API table below.
        self.bootstrap = self.build(self.lua.table_from({b'ffi': self.ffi}))
        self.api, self.mode, self.counts, self.put = self.lua.execute(
            self.FACTORY, b'fixture payload for hash and cleanup')

    def reader(self, env=None):
        options = {b'ffi': self.ffi, b'api': self.api}
        if env is not None:
            options[b'env'] = self.lua.table_from(env)
        return self.build(self.lua.table_from(options))

    def hash_path(self, reader):
        path = tempfile.gettempdir() + r'\autochat-language-reader-fixture.bin'
        return reader[b'hash_file_path'](path.encode('ascii'))

    def test_provider_failure_and_null_success_never_call_null_crypto_handles(self):
        for mode in ('open_fail', 'open_null'):
            with self.subTest(mode=mode):
                self.mode[mode.encode()] = True
                reader = self.reader()
                self.assertIsNone(self.hash_path(reader))
                self.assertEqual(self.counts[b'create_hash'], 0)
                self.assertEqual(self.counts[b'null_destroy'], 0)
                self.assertEqual(self.counts[b'null_close_alg'], 0)
                self.assertEqual(self.counts[b'close_file'], 1)
                self.mode[mode.encode()] = False
                if mode!='open_null': self.setUp()

    def test_invalid_file_handle_and_null_function_symbols_are_not_called_or_closed(self):
        self.mode[b'bad_file'] = True
        reader = self.reader()
        self.assertIsNone(self.hash_path(reader))
        self.assertEqual(self.counts[b'close_file'], 0)
        self.setUp()
        self.api[b'kernel'][b'ReadFile'] = self.ffi.NULL
        reader = self.reader()
        self.assertIsNone(self.hash_path(reader))
        self.assertEqual(self.counts[b'open_file'], 0)

    def test_hash_creation_failure_still_closes_algorithm_and_file(self):
        self.mode[b'create_fail'] = True
        reader = self.reader()
        self.assertIsNone(self.hash_path(reader))
        self.assertEqual(self.counts[b'destroy_hash'], 0)
        self.assertEqual(self.counts[b'close_alg'], 1)
        self.assertEqual(self.counts[b'close_file'], 1)
        self.assertEqual(self.counts[b'null_destroy'], 0)

    def test_readfile_and_finish_failures_destroy_only_acquired_handles(self):
        for flag in ('read_zero', 'finish_fail'):
            with self.subTest(flag=flag):
                self.mode[flag.encode()] = True
                reader = self.reader()
                self.assertIsNone(self.hash_path(reader))
                self.assertEqual(self.counts[b'destroy_hash'], 1)
                self.assertEqual(self.counts[b'close_alg'], 1)
                self.assertEqual(self.counts[b'close_file'], 1)
                self.assertEqual(self.counts[b'null_destroy'], 0)
                self.assertEqual(self.counts[b'null_close_alg'], 0)
                self.mode[flag.encode()] = False
                if flag!='finish_fail': self.setUp()

    def test_create_hash_success_with_null_handle_is_rejected(self):
        self.mode[b'create_null'] = True
        reader = self.reader()
        self.assertIsNone(self.hash_path(reader))
        self.assertEqual(self.counts[b'hash_data'], 0)
        self.assertEqual(self.counts[b'destroy_hash'], 0)
        self.assertEqual(self.counts[b'close_alg'], 1)
        self.assertEqual(self.counts[b'close_file'], 1)

    def test_readprocessmemory_bool_zero_and_short_read_return_nil(self):
        env = {b'game_module': lambda: BASE, b'exe_module': lambda: EXE,
               b'hash_module': lambda base: (GAME_HASH if int(base) == BASE else EXE_HASH).encode()}
        self.put(BASE + 0x14c0350, SIGNATURE)
        reader = self.reader(env)
        self.mode[b'rpm_zero'] = True
        self.assertIsNone(reader[b'read']())
        self.mode[b'rpm_zero'] = False
        self.mode[b'rpm_short'] = True
        reader = self.reader(env)
        self.assertIsNone(reader[b'read']())

    def test_real_system_bcrypt_digest_matches_fixture_bytes(self):
        with tempfile.NamedTemporaryFile(prefix='autochat-lang-', suffix='.bin', delete=False) as f:
            fixture = b'AutoChat language reader SHA-256 fixture\x00\x01'
            f.write(fixture)
            path = f.name
        try:
            reader = self.build(self.lua.table_from({b'ffi': self.ffi}))
            digest = reader[b'hash_file_path'](path.encode('ascii')).decode('ascii')
            self.assertEqual(digest, hashlib.sha256(fixture).hexdigest().upper())
        finally:
            Path(path).unlink(missing_ok=True)


if __name__ == '__main__':
    unittest.main()
