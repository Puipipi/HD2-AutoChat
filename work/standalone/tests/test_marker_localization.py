"""Read-only localization bridge; synthetic memory, no game function calls."""
from pathlib import Path
import struct
import unittest

from lupa.luajit21 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[3] / 'src' / 'marker_localization.lua'
BASE, ROOT, ENGINE, TARGET, TEXT = 0x10000000, 0x20000000, 0x30000000, 0x10100000, 0x40000000
SIGNATURE = bytes.fromhex('40534883ec20488b051b60ba018bd9488b4810488b81e80300008bcbffd04885c074058038007555488b1549c0b9014c8d0526050502488d0d93040502448bcb488d420e493bc04c8d05c26cb800480f42caba0e00000048890d1ac0b901e8ddd5d6fe')


class MarkerLocalizationTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SOURCE.exists(), 'marker localization bridge is not implemented')
        self.mem, self.calls = {}, []
        self.base, self.executable, self.returned = BASE, True, TEXT
        self.on_call = None
        self.raw(BASE + 0x17802e0, SIGNATURE)
        self.ptr(BASE + 0x3326308, ROOT)
        self.ptr(ROOT + 0x10, ENGINE)
        self.ptr(ENGINE + 0x3e8, TARGET)
        self.raw(TEXT, '非法广播'.encode() + bytes(64))
        self.lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        constructor = self.lua.execute(SOURCE.read_bytes() + b'\nreturn build_marker_localization')
        self.bridge = constructor(self.lua.table_from({
            b'base': lambda: self.base, b'read': self.read,
            b'executable': lambda address: self.executable and address == TARGET,
            b'call': self.call,
        }))

    def raw(self, address, value):
        for i, byte in enumerate(value):
            self.mem[address + i] = byte

    def ptr(self, address, value):
        self.raw(address, struct.pack('<Q', value))

    def read(self, address, count):
        address, count = int(address), int(count)
        if any(address + i not in self.mem for i in range(count)):
            return None
        return bytes(self.mem[address + i] for i in range(count))

    def call(self, address, key):
        self.calls.append((address, key))
        if self.on_call:
            self.on_call()
        return self.returned

    def lookup(self, key=123):
        return self.bridge[b'lookup'](key)

    def test_verified_lookup_returns_native_chinese_marker_name(self):
        self.assertEqual(self.lookup(), '非法广播'.encode())
        self.assertEqual(self.calls, [(TARGET, 123)])

    def test_rejects_malformed_utf8_in_native_string(self):
        for value in (b'\xc0\xaf', b'\xed\xa0\x80', b'\xf4\x90\x80\x80', b'\xe4\xb8', b'\x80'):
            with self.subTest(value=value):
                self.raw(TEXT, value + bytes(64))
                self.assertIsNone(self.lookup())

    def test_invalid_keys_never_invoke_native_lookup(self):
        for key in (None, b'123', True, 0, -1, 0.5, 4294967296, float('nan'), float('inf')):
            with self.subTest(key=key):
                self.assertIsNone(self.lookup(key))
        self.assertEqual(self.calls, [])
        self.assertEqual(self.lookup(4294967295), '非法广播'.encode())

    def test_missing_verified_base_or_changed_signature_blocks_call(self):
        self.base = None
        self.assertIsNone(self.lookup())
        self.base = BASE
        self.raw(BASE + 0x17802e0 + 90, b'\x00')
        self.assertIsNone(self.lookup())
        self.assertEqual(self.calls, [])

    def test_unreadable_or_noncanonical_root_and_unexecutable_target_block_call(self):
        self.ptr(BASE + 0x3326308, 0)
        self.assertIsNone(self.lookup())
        self.ptr(BASE + 0x3326308, 0x800000000000)
        self.assertIsNone(self.lookup())
        self.ptr(BASE + 0x3326308, ROOT)
        self.executable = False
        self.assertIsNone(self.lookup())
        self.executable = True
        del self.mem[ENGINE + 0x3e8]
        self.assertIsNone(self.lookup())
        self.assertEqual(self.calls, [])

    def test_root_signature_and_target_changes_during_native_call_discard_result(self):
        for action in (
            lambda: self.ptr(BASE + 0x3326308, ROOT + 0x100),
            lambda: self.raw(BASE + 0x17802e0, b'\x90'),
            lambda: self.ptr(ENGINE + 0x3e8, TARGET + 16),
            lambda: setattr(self, 'base', None),
            lambda: setattr(self, 'executable', False),
        ):
            with self.subTest(action=action):
                self.setUp()
                self.on_call = action
                self.assertIsNone(self.lookup())
                self.assertEqual(len(self.calls), 1)

    def test_does_not_reuse_name_or_root_cache_after_session_chain_changes(self):
        self.assertEqual(self.lookup(), '非法广播'.encode())
        new_root, new_engine = ROOT + 0x1000, ENGINE + 0x1000
        self.ptr(BASE + 0x3326308, new_root)
        self.ptr(new_root + 0x10, new_engine)
        self.ptr(new_engine + 0x3e8, TARGET)
        self.raw(TEXT, '广播塔'.encode() + bytes(64))
        self.assertEqual(self.lookup(), '广播塔'.encode())
        self.assertEqual(len(self.calls), 2)

    def test_rejects_empty_missing_unterminated_and_invalid_string_pointers(self):
        for value in (b'', b'#ID[123]', b'a' * 1024):
            with self.subTest(value=value[:20]):
                self.raw(TEXT, value + bytes(32))
                self.assertIsNone(self.lookup())
        for pointer in (None, 0, 1, 0x800000000000, float('nan'), float('inf')):
            self.returned = pointer
            self.assertIsNone(self.lookup())

    def test_bounded_terminator_and_readable_page_boundary_are_accepted(self):
        self.mem = {k: v for k, v in self.mem.items() if k < TEXT}
        self.raw(TEXT, b'\xe5\xa1\x94\0')
        self.assertEqual(self.lookup(), '塔'.encode())
        self.raw(TEXT, b'a' * 1023 + b'\0')
        self.assertEqual(self.lookup(), b'a' * 1023)

    def test_chain_change_during_text_read_discards_result(self):
        original_read = self.read
        def changed_read(address, size):
            value = original_read(address, size)
            if address == TEXT:
                self.ptr(BASE + 0x3326308, ROOT + 128)
            return value
        self.read = changed_read
        # The already-created bridge captured the original Python bound method.
        constructor = self.lua.execute(SOURCE.read_bytes() + b'\nreturn build_marker_localization')
        self.bridge = constructor(self.lua.table_from({
            b'base': lambda: BASE, b'read': changed_read,
            b'executable': lambda address: True, b'call': self.call,
        }))
        self.assertIsNone(self.lookup())

    def test_native_exceptions_are_contained(self):
        def fail():
            raise RuntimeError('synthetic native failure')
        self.on_call = fail
        self.assertIsNone(self.lookup())

    def test_control_bytes_are_sanitized_but_valid_unicode_is_preserved(self):
        self.raw(TEXT, 'TCS\t塔\r\n🚩'.encode() + bytes(64))
        self.assertEqual(self.lookup(), 'TCS 塔  🚩'.encode())


if __name__ == '__main__':
    unittest.main()
