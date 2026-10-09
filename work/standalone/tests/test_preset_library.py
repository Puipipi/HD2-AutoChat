"""Behavioral tests for the data-only saved-preset library fragment."""
import unittest
from pathlib import Path

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[5]
FRAGMENT = ROOT / "mods/auto-chat/src/preset_library.lua"


class PresetLibraryTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
        self.disk = None
        self.files = {}
        self.capture_value = b"valid:default"
        self.apply_calls = []
        self.write_ok = True
        self.export_ok = True
        self.write_count = 0
        self.builtins = None
        self.library = self.new_library()

    def new_library(self, data="__disk__"):
        if data == "__disk__":
            data = self.disk
        env = self.lua.table()
        env[b"read_file"] = lambda: data

        def write(value):
            self.write_count += 1
            if self.write_ok:
                self.disk = value
                return True
            return False, b"disk full"

        def capture(_role, _old_payload=None):
            return self.capture_value

        def validate(value):
            return isinstance(value, bytes) and value.startswith(b"valid:")

        def apply(value, role):
            self.apply_calls.append((value, role))
            return value.startswith(b"valid:")

        def export_file(filename, value):
            if not self.export_ok:
                return False, b"export denied"
            filename = filename.decode() if isinstance(filename, bytes) else filename
            self.files[filename] = value
            self.files["portable/" + filename] = value
            return True, b"portable/" + filename.encode()

        def import_file(path):
            path = path.decode() if isinstance(path, bytes) else path
            return self.files.get(path)

        env[b"write_file"] = write
        if self.builtins is not None:
            env[b"builtins"] = self.builtins
        env[b"capture"] = capture
        env[b"validate"] = validate
        env[b"apply"] = apply
        env[b"export_file"] = export_file
        env[b"import_file"] = import_file
        build = self.lua.execute(FRAGMENT.read_bytes() + b"\nreturn build_preset_library")(env)
        return build

    def test_multiple_presets_mutate_roundtrip_and_ids_survive_deletion(self):
        result = self.library[b"save"]("默认配置".encode(), b"host")
        self.assertTrue(result[0])
        first = result[2]
        self.capture_value = b"valid:second\nwith%bytes"
        result = self.library[b"save"]("第二套".encode(), b"client")
        self.assertTrue(result[0])
        second = result[2]
        self.assertEqual(self.library[b"list"]()[2][b"payload"], self.capture_value)
        self.assertTrue(self.library[b"apply"](second, b"client"))
        self.assertEqual(self.apply_calls[-1], (self.capture_value, b"client"))

        self.capture_value = b"valid:replacement"
        self.assertTrue(self.library[b"replace"](first, b"host"))
        self.assertEqual(self.library[b"list"]()[1][b"payload"], b"valid:replacement")
        self.assertTrue(self.library[b"rename"](second, "改名".encode()))
        self.assertTrue(self.library[b"remove"](first))

        reopened = self.new_library()
        listing = reopened[b"list"]()
        self.assertEqual(len(listing), 1)
        self.assertEqual(listing[1][b"id"], second)
        self.assertEqual(listing[1][b"name"], "改名".encode())
        self.capture_value = b"valid:third"
        third = reopened[b"save"]("第三套".encode(), b"host")[2]
        self.assertEqual(third, b"P00000003")

    def test_user_presets_exceed_32_per_role_and_reload_without_counting_builtins(self):
        # Keep this behavioral: save crosses the former cap, a fresh library
        # parses every record, and virtual built-ins never enter persistence.
        env_builtins = self.lua.table()
        env_builtins[b"host"] = self.lua.table_from([
            self.lua.table_from({b"id": b"builtin-host-zh", b"name": "中文默认预设".encode(), b"payload": b"valid:zh-host"}),
            self.lua.table_from({b"id": b"builtin-host-en", b"name": b"English Default Preset", b"payload": b"valid:en-host"}),
        ])
        env_builtins[b"client"] = self.lua.table_from([
            self.lua.table_from({b"id": b"builtin-client-zh", b"name": "中文默认预设".encode(), b"payload": b"valid:zh-client"}),
            self.lua.table_from({b"id": b"builtin-client-en", b"name": b"English Default Preset", b"payload": b"valid:en-client"}),
        ])
        self.builtins = env_builtins
        for i in range(33):
            result = self.library[b"save"]((f"host {i}".encode()), b"host")
            self.assertTrue(result[0], result[1])
        reopened = self.new_library()
        listing = reopened[b"list"](b"host")
        self.assertEqual(35, len(listing))
        self.assertTrue(listing[1][b"builtin"])
        self.assertNotIn(b"builtin-host-zh", self.disk)
        self.assertIn(b"# AutoChat preset library v2\n33\n", self.disk)
        self.assertEqual(2, len(reopened[b"list"](b"client")))
        self.assertTrue(reopened[b"apply"](b"builtin-client-zh", b"client"))
        self.assertEqual((b"valid:zh-client", b"client"), self.apply_calls[-1])
        for operation in ("remove", "rename", "replace"):
            if operation == "rename": result = reopened[b"rename"](b"builtin-host-en", b"changed")
            elif operation == "replace": result = reopened[b"replace"](b"builtin-host-en", b"host")
            else: result = reopened[b"remove"](b"builtin-host-en")
            self.assertFalse(result[0], operation)
        self.assertTrue(reopened[b"save"](b"English Default Preset copy", b"host")[0])

    def test_public_list_is_detached_from_cached_ui_view_and_builtin_export_is_role_specific(self):
        builtins=self.lua.table()
        builtins[b"host"]=self.lua.table_from([
            self.lua.table_from({b"id":b"builtin-host-en",b"name":b"English Default Preset",b"payload":b"valid:host-squad"})])
        builtins[b"client"]=self.lua.table_from([
            self.lua.table_from({b"id":b"builtin-client-en",b"name":b"English Default Preset",b"payload":b"valid:client-local"})])
        self.builtins=builtins
        library=self.new_library()
        public=library[b"list"](b"host")
        public[1][b"name"]=b"corrupted"
        public[1][b"payload"]=b"valid:corrupted"
        self.assertEqual(b"English Default Preset",library[b"_list_view"](b"host")[1][b"name"])
        self.assertTrue(library[b"export"](b"builtin-client-en",b"client")[0])
        exported=self.files["preset-builtin-client-en.autochat"]
        self.assertIn(b"valid:client-local",exported)
        self.assertNotIn(b"valid:host-squad",exported)

    def test_same_name_is_allowed_once_in_each_role_pool(self):
        host = self.library[b"save"]("同名预设".encode(), b"host")
        self.assertTrue(host[0])
        client = self.library[b"save"]("同名预设".encode(), b"client")
        self.assertTrue(client[0])
        self.assertEqual(1, len(self.library[b"list"](b"host")))
        self.assertEqual(1, len(self.library[b"list"](b"client")))
        self.assertNotEqual(host[2], client[2])

    def test_v1_shared_entries_migrate_losslessly_into_both_role_pools(self):
        payload = b"valid:legacy profile"
        name = "原有 111".encode()
        self.disk = (b"# AutoChat preset library v1\n1\n1\nP00000001\n"
                     + str(len(name)).encode() + b"\n" + str(len(payload)).encode() + b"\n"
                     + name + payload)
        library = self.new_library()
        host = library[b"list"](b"host")
        client = library[b"list"](b"client")
        self.assertEqual(1, len(host))
        self.assertEqual(1, len(client))
        self.assertEqual(name, host[1][b"name"])
        self.assertEqual(name, client[1][b"name"])
        self.assertEqual(payload, host[1][b"payload"])
        self.assertEqual(payload, client[1][b"payload"])
        self.assertNotEqual(host[1][b"id"], client[1][b"id"])
        self.assertEqual(b"client", client[1][b"role"])
        self.assertIn(b"# AutoChat preset library v2\n", self.disk)
        reopened = self.new_library()
        self.assertEqual(1, len(reopened[b"list"](b"host")))
        self.assertEqual(1, len(reopened[b"list"](b"client")))

    def test_oversized_v1_migration_preserves_original_file(self):
        # Fifteen valid 1 MiB entries fit under the v1 16 MiB read cap, but
        # duplicating them into both role pools cannot fit in the v2 cap.
        payload = b"valid:" + b"x" * (1024 * 1024 - 6)
        rows = [b"# AutoChat preset library v1\n15\n15\n"]
        for index in range(1, 16):
            name = ("legacy-%02d" % index).encode()
            rows.extend((("P%08d\n" % index).encode(), str(len(name)).encode() + b"\n",
                         str(len(payload)).encode() + b"\n", name, payload))
        self.disk = b"".join(rows)
        self.assertLessEqual(len(self.disk), 16 * 1024 * 1024)
        original = self.disk
        writes_before = self.write_count

        library = self.new_library()

        self.assertTrue(library[b"state"][b"error"])
        self.assertEqual(original, self.disk)
        self.assertEqual(writes_before, self.write_count)
        self.assertEqual(0, len(library[b"list"]()))

    def test_export_import_roundtrip_and_failures_are_reported(self):
        self.capture_value = b"valid:line one\nline two%"
        saved = self.library[b"save"]("中文% name".encode(), b"host")
        self.assertTrue(saved[0])
        pid = saved[2]
        exported = self.library[b"export"](pid)
        self.assertTrue(exported[0])
        self.assertIn(b"preset-P00000001.autochat", exported[2])
        imported = self.library[b"import"](b"portable/preset-P00000001.autochat")
        self.assertFalse(imported[0])  # Same name must be renamed before import.
        self.assertIn("重命名".encode(), imported[1])
        self.assertTrue(self.library[b"rename"](pid, "原配置".encode()))
        imported = self.library[b"import"](b"portable/preset-P00000001.autochat")
        self.assertTrue(imported[0])
        imported_id = imported[2]
        self.assertEqual(self.library[b"list"]()[2][b"name"], "中文% name".encode())

        self.export_ok = False
        failed = self.library[b"export"](imported_id)
        self.assertFalse(failed[0])
        self.assertIn(b"export denied", failed[1])

    def test_write_failure_does_not_change_memory_or_consume_id(self):
        self.write_ok = False
        revision = self.library[b"state"][b"revision"]
        failed = self.library[b"save"]("一".encode(), b"host")
        self.assertFalse(failed[0])
        self.assertEqual(len(self.library[b"list"]()), 0)
        self.assertEqual(self.library[b"state"][b"revision"], revision)
        self.write_ok = True
        saved = self.library[b"save"]("一".encode(), b"host")
        self.assertTrue(saved[0])
        self.assertEqual(saved[2], b"P00000001")
        self.assertEqual(self.library[b"state"][b"revision"], revision + 1)

        before = self.disk
        self.write_ok = False
        self.assertFalse(self.library[b"remove"](saved[2])[0])
        self.assertEqual(len(self.library[b"list"]()), 1)
        self.assertEqual(self.disk, before)
        self.assertEqual(self.library[b"state"][b"revision"], revision + 1)

    def test_invalid_name_or_payload_never_saves_or_applies(self):
        for name in ("", "   ", "a\x01b", "x" * 97, b"\xff"):
            if isinstance(name, str): name = name.encode()
            result = self.library[b"save"](name, b"host")
            self.assertFalse(result[0], repr(name))
        self.capture_value = b"not-a-config"
        self.assertFalse(self.library[b"save"](b"bad", b"host")[0])
        self.assertEqual(len(self.library[b"list"]()), 0)
        self.assertFalse(self.library[b"apply"](b"P00000001", b"host")[0])
        self.assertEqual(self.apply_calls, [])

    def test_corrupt_files_are_rejected_and_never_overwritten(self):
        bad_libraries = [
            b"# AutoChat preset library v1\n0\n0\ntrailing",
            b"# AutoChat preset library v1\n0\n1\nP00000001\n2\n7\n\xff\xffvalid:x",
            b"# AutoChat preset library v1\n0\n1\nP00000001\n1\n7\nxvalid:x",
            b"# AutoChat preset library v1\n0\n1\nP00000001\n1\n7\nainvalid!",
            b"# AutoChat preset library v1\n0\n1\nP00000000\n1\n7\na valid:x",
            b"# AutoChat preset library v1\n0\n1\nP00000001\n1\n7\na valid:xjunk",
            b"# AutoChat preset library v1\n0\n1\nP00000001\n1\n7\na valid:x",
        ]
        for corrupt in bad_libraries:
            with self.subTest(corrupt=corrupt):
                self.disk = corrupt
                lib = self.new_library()
                self.assertTrue(lib[b"state"][b"error"])
                result = lib[b"save"](b"will not overwrite", b"host")
                self.assertFalse(result[0])
                self.assertEqual(self.disk, corrupt)

    def test_import_rejects_trailing_or_invalid_utf8_and_payload(self):
        good = b"# AutoChat preset v1\n1\n7\nAvalid:x"
        self.files["good"] = good
        self.assertTrue(self.library[b"import"](b"good")[0])
        for path, raw in (
            ("tail", good + b"junk"),
            ("bad-name", b"# AutoChat preset v1\n1\n7\n\xffvalid:x"),
            ("bad-payload", b"# AutoChat preset v1\n1\n6\nXbroken"),
            ("bad-length", b"# AutoChat preset v1\n99999999\n7\nAvalid:x"),
        ):
            self.files[path] = raw
            before = self.disk
            self.assertFalse(self.library[b"import"](path.encode())[0], path)
            self.assertEqual(len(self.library[b"list"]()), 1)
            self.assertEqual(self.disk, before)

    def test_serial_limit_and_missing_callbacks_fail_safely(self):
        maximum = (b"# AutoChat preset library v2\n9007199254740991\n1\nP9007199254740991\nhost\n"
                   b"1\n7\nAvalid:x")
        self.disk = maximum
        lib = self.new_library()
        before = self.disk
        result = lib[b"save"](b"next", b"host")
        self.assertFalse(result[0])
        self.assertIn("用尽".encode(), result[1])
        self.assertEqual(self.disk, before)
        self.assertEqual(lib[b"state"][b"revision"], 0)

        env = self.lua.table()
        env[b"validate"] = lambda value: value == b"valid:x"
        env[b"read_file"] = lambda: (b"# AutoChat preset library v1\n1\n1\n"
                                     b"P00000001\n1\n7\nAvalid:x")
        env[b"write_file"] = lambda _value: True
        no_callbacks = self.lua.execute(FRAGMENT.read_bytes() + b"\nreturn build_preset_library")(env)
        self.assertFalse(no_callbacks[b"save"](b"missing capture", b"host")[0])
        self.assertFalse(no_callbacks[b"apply"](b"P00000001", b"host")[0])


if __name__ == "__main__":
    unittest.main()
