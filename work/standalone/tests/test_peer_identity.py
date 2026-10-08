"""Read the real Lua fragment against byte-addressed, mutable fake process memory."""
import struct
import unittest
from pathlib import Path

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[5]
FRAGMENT = ROOT / "mods/auto-chat/src/peer_identity.lua"
BASE, ROSTER, CONTEXT = 0x10000000, 0x20000000, 0x30000000
PEER = 0xFEDCBA9876543210  # Deliberately cannot be represented by a Lua double.
COLORS = ["FFFF9D42", "FF81ACFE", "FFF68AFF", "FF6ED754"]


class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(FRAGMENT.exists(), "peer identity fragment is missing")
        self.lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
        self.memory, self.reads = {}, []
        self.session, self.base, self.change = b"session-one", BASE, None
        self.put(BASE + 0x347CED8, struct.pack("<Q", ROSTER))
        self.put(BASE + 0x347CEF0, struct.pack("<Q", CONTEXT))
        self.put(CONTEXT + 0x16390, struct.pack("<I", 4))
        for index in range(8):
            self.put(ROSTER + index * 0xC0, bytes(0xC0))
        for index in range(4):
            self.put(CONTEXT + 0x16398 + index * 0x20,
                     struct.pack("<Q", PEER if index == 2 else index + 1)
                     + bytes(12) + struct.pack("<I", index) + bytes(8))
        self.record(7, PEER, "Alice", b"A3\0")
        env = self.lua.table()
        env[b"base"] = lambda: self.base
        env[b"session"] = lambda: self.session
        env[b"read"] = self.read
        self.controller = self.lua.execute(FRAGMENT.read_bytes() + b"\nreturn build_peer_identity")(env)

    def put(self, address, data):
        self.memory.update({address + offset: value for offset, value in enumerate(data)})

    def record(self, index, peer, name, short):
        data = bytearray(0xC0)
        data[:8] = struct.pack("<Q", peer)
        encoded = name.encode("utf-8") if isinstance(name, str) else name
        data[8:8 + len(encoded)] = encoded
        data[0x89:0x8C] = short
        self.put(ROSTER + index * 0xC0, data)

    def read(self, address, size):
        address, size = int(address), int(size)
        self.reads.append((address, size))
        data = bytes(self.memory.get(address + offset, 0) for offset in range(size))
        if self.change:
            self.change(address, size)
        return data

    def lookup(self, peer=f"{PEER:016X}"):
        value = self.controller[b"lookup"](peer.encode("ascii") if isinstance(peer, str) else peer)
        return {key.decode(): item.decode() if isinstance(item, bytes) else item
                for key, item in value.items()} if value is not None else None

    def test_full_peer_matches_eighth_record_and_actual_slot(self):
        result = self.lookup()
        self.assertEqual(result["peer_id"], f"{PEER:016X}")
        self.assertEqual(result["name"], "Alice")
        self.assertEqual(result["short"], "A3")
        self.assertEqual(result["color"], "FFF68AFF")
        self.assertEqual(result["color_index"], 2)

    def test_four_real_slot_colors(self):
        for index, color in enumerate(COLORS):
            self.put(CONTEXT + 0x16398 + 2 * 0x20 + 0x14, struct.pack("<I", index))
            self.put(ROSTER + 7 * 0xC0 + 0x89, f"A{index + 1}".encode() + b"\0")
            result = self.lookup()
            self.assertEqual((result["short"], result["color"]), (f"A{index + 1}", color))

    def test_lowercase_hex_normalizes_without_float_peer_conversion(self):
        self.assertEqual(self.lookup(f"{PEER:016x}")["name"], "Alice")
        self.assertIsNone(self.lookup(f"{PEER + 1:016X}"))

    def test_invalid_peer_inputs_do_not_read_memory(self):
        for value in [b"", b"FEDCBA98", b"0xFEDCBA9876543210", b"G" * 16, 42, None]:
            self.assertIsNone(self.controller[b"lookup"](value))
        self.assertEqual(self.reads, [])

    def test_invalid_cached_short_falls_back_to_proven_slot(self):
        for short in [b"A1\0", b"A3x", b"<3\0", b"\x003\0", b"\xff3\0"]:
            self.put(ROSTER + 7 * 0xC0 + 0x89, short)
            self.assertEqual(self.lookup()["short"], "P3")

    def test_utf8_name_is_sanitized_and_never_used_as_slot(self):
        self.record(7, PEER, "<c=FF000000>爱丽丝\n\t\x7f\u0085", b"P3\0")
        self.assertEqual(self.lookup()["name"], "爱丽丝")

    def test_unterminated_empty_or_invalid_utf8_names_fail_closed(self):
        for name in [b"\xff", b"\xc0\x80", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"", b"<c=FFFFFFFF>\n"]:
            self.record(7, PEER, name, b"P3\0")
            self.assertIsNone(self.lookup())
        self.put(ROSTER + 7 * 0xC0 + 8, b"A" * 0x81)
        self.assertIsNone(self.lookup())

    def test_missing_inactive_duplicate_or_invalid_slot_fails_closed(self):
        self.put(CONTEXT + 0x16398 + 2 * 0x20, struct.pack("<Q", 12))
        self.assertIsNone(self.lookup())
        self.setUp()
        self.record(0, PEER, "Wrong", b"A3\0")
        self.assertIsNone(self.lookup())
        self.setUp()
        self.put(CONTEXT + 0x16398 + 2 * 0x20 + 0x14, struct.pack("<I", 4))
        self.assertIsNone(self.lookup())

    def test_unreadable_truncated_or_throwing_memory_fails_closed(self):
        for value in [None, b"", b"\0" * 7]:
            self.controller = self.new_controller(lambda address, size: value)
            self.assertIsNone(self.lookup())
        def throwing(address, size):
            raise RuntimeError("unreadable")
        self.controller = self.new_controller(throwing)
        self.assertIsNone(self.lookup())

    def new_controller(self, read):
        env = self.lua.table()
        env[b"base"], env[b"session"], env[b"read"] = lambda: self.base, lambda: self.session, read
        return self.lua.execute(FRAGMENT.read_bytes() + b"\nreturn build_peer_identity")(env)

    def test_session_base_pointer_record_or_slot_change_fails_closed(self):
        mutations = [lambda: setattr(self, "session", b"session-two"),
                     lambda: setattr(self, "base", BASE + 0x1000),
                     lambda: self.put(BASE + 0x347CED8, struct.pack("<Q", ROSTER + 0x1000)),
                     lambda: self.put(BASE + 0x347CEF0, struct.pack("<Q", CONTEXT + 0x1000)),
                     lambda: self.put(ROSTER + 7 * 0xC0, struct.pack("<Q", PEER + 1)),
                     lambda: self.put(CONTEXT + 0x16398 + 2 * 0x20 + 0x14, struct.pack("<I", 1))]
        for mutation in mutations:
            self.setUp()
            def change(address, size):
                if address == ROSTER + 7 * 0xC0:
                    self.change = None
                    mutation()
            self.change = change
            self.assertIsNone(self.lookup())

    def test_null_or_noncanonical_pointers_and_bad_counts_fail_closed(self):
        for ptr in [0, 1, 0xFFFFFFFFFFFFFFFF]:
            self.put(BASE + 0x347CED8, struct.pack("<Q", ptr))
            self.assertIsNone(self.lookup())
        self.setUp()
        for count in [0, 33, 0xFFFFFFFF]:
            self.put(CONTEXT + 0x16390, struct.pack("<I", count))
            self.assertIsNone(self.lookup())

    def test_duplicate_active_peer_cannot_choose_first_slot(self):
        self.put(CONTEXT + 0x16398, struct.pack("<Q", PEER))
        self.assertIsNone(self.lookup())

    def test_missing_verified_base_or_session_cannot_read(self):
        for base, session in [(None, b"session"), (BASE, None), (BASE, False), (BASE + 0.5, b"session")]:
            self.base, self.session = base, session
            self.assertIsNone(self.lookup())
        self.assertEqual(self.reads, [])

    def test_name_change_during_read_is_rejected(self):
        def change(address, size):
            if address == ROSTER + 7 * 0xC0:
                self.change = None
                self.record(7, PEER, "Bob", b"B3\0")
        self.change = change
        self.assertIsNone(self.lookup())


if __name__ == "__main__":
    unittest.main()
