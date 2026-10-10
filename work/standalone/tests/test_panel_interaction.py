"""Regressions for real panel mouse actions and scheduled sends in a solo ship."""
import unittest
from test_auto_chat_probe import fresh_image, SOURCE


class PanelInteractionTest(unittest.TestCase):
    def test_background_k_cannot_open_or_capture_cursor(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        h.user32.set_foreground_pid(h.own_pid + 1)
        self.assertFalse(mod.debug_request_open(), 'external open requests must also require foreground focus')
        self.assertFalse(mod.debug_cursor_state()['taken'])
        h.user32.set_key(0x4B, True)
        lua.execute('for i=1,3 do update() end')
        self.assertFalse(mod.debug_panel()['open'])
        self.assertFalse(mod.debug_cursor_state()['taken'])
        h.user32.set_foreground_pid(h.own_pid)
        lua.execute('for i=1,3 do update() end')
        self.assertFalse(mod.debug_panel()['open'], 'a background K edge must stay consumed after focus returns')
        h.user32.set_key(0x4B, False); lua.eval('update()')
        h.user32.set_key(0x4B, True); lua.eval('update()')
        self.assertTrue(mod.debug_panel()['open'])

    def test_focus_loss_closes_even_after_panel_error_circuit_breaker(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        self.assertTrue(mod.debug_request_open())
        lua.eval('update()')
        self.assertTrue(mod.debug_panel()['open'])
        mod.debug_panel()['lfail'] = 3
        h.user32.set_foreground_pid(h.own_pid + 1)
        lua.eval('update()')
        self.assertFalse(mod.debug_panel()['open'], 'error throttling must not bypass focus-loss teardown')
        self.assertFalse(mod.debug_cursor_state()['taken'])
        self.assertEqual(0, h.live_guis)

    def test_focus_loss_while_panel_open_closes_and_releases_owned_ui_state(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        self.assertTrue(mod.debug_request_open())
        lua.eval('update()')
        self.assertEqual(1, h.live_guis)
        self.assertTrue(mod.debug_cursor_state()['taken'])

        h.user32.set_foreground_pid(h.own_pid + 1)
        h.user32.set_key(0x4B, True)
        lua.execute('for i=1,12 do update() end')
        self.assertFalse(mod.debug_panel()['open'], 'losing the game window must close its panel')
        self.assertFalse(mod.debug_cursor_state()['taken'], 'focus loss must release cursor ownership')
        self.assertEqual(0, h.live_guis, 'focus loss must destroy the retained native GUI')
        self.assertEqual('none', h.user32_clip_text(), 'focus loss must restore the prior cursor clip')

        h.user32.set_foreground_pid(h.own_pid)
        lua.eval('update()')
        self.assertFalse(mod.debug_panel()['open'], 'K held from background must not recapture after focus returns')
        h.user32.set_key(0x4B, False); lua.eval('update()')
        h.user32.set_key(0x4B, True); lua.eval('update()')
        self.assertTrue(mod.debug_panel()['open'], 'a fresh focused K press may open normally')

    def test_same_vm_resource_reentry_reuses_current_instance(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        self.assertTrue(mod.debug_request_open())
        lua.eval('update()')
        self.assertEqual(1, h.live_guis)
        same_instance = h.load(SOURCE)
        self.assertTrue(lua.eval('rawequal')(mod, same_instance))
        frames_before = mod.frames
        self.assertTrue(same_instance.debug_request_open())
        lua.eval('update()')
        self.assertEqual(frames_before + 1, same_instance.frames, 'resource reentry must not add an update wrapper')
        self.assertEqual(1, h.live_guis)

    def test_main_world_switch_destroys_old_owner_still_in_world_list_before_reopen(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        self.assertTrue(mod.debug_request_open())
        lua.eval('update()')
        old_gui = mod.debug_panel()['gui']
        old_gui_id = old_gui['id']
        self.assertTrue(h.gui_is_live(old_gui_id))
        destroyed_before = h.gui_destroyed

        # The game can retain a world as a non-main overlay during task UI changes.
        # Exercise world_sample, world_ready, close, and native GUI teardown together.
        h.main_world = 'WORLD_NEXT'
        h.worlds = lua.table_from(['WORLD_NEXT', 'WORLD_MAIN', 'WORLD_OVERLAY'])
        lua.eval('update()')
        self.assertFalse(mod.debug_panel()['open'])
        self.assertFalse(mod.debug_cursor_state()['taken'])
        self.assertFalse(h.gui_is_live(old_gui_id),
                         'a still-live GUI owner must be found and destroyed after ceasing to be main')
        self.assertEqual(destroyed_before + 1, h.gui_destroyed)

        lua.execute('for i=1,120 do update() end')
        self.assertTrue(mod.debug_request_open())
        lua.eval('update()')
        self.assertNotEqual(old_gui_id, mod.debug_panel()['gui']['id'])
        self.assertEqual(1, h.live_guis,
                         'the prior owner must be destroyed before the new world GUI is created')

    def test_native_game_chat_view_blocks_hotkey_without_blocking_sender_verification(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        h.u8(h.chat_view + 0x139b8, 1)
        h.user32.set_key(0x4B, True)
        lua.eval('update()')
        self.assertFalse(mod.debug_panel()['open'], 'the game chat view owns keyboard input')
        self.assertEqual('match', mod.signature, 'UI reader failure must not disable sender verification')
        h.user32.set_key(0x4B, False)
        lua.eval('update()')
        h.u8(h.chat_view + 0x139b8, 0)
        h.user32.set_key(0x4B, True)
        lua.eval('update()')
        self.assertTrue(mod.debug_panel()['open'], 'a fresh K press opens when native chat is closed: '+str(mod.panel_context))

    def test_native_chat_blocks_hotkey_and_external_open_request(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        h.u8(h.chat_view + 0x139b8, 1)
        self.assertFalse(mod.debug_request_open())
        self.assertFalse(mod.debug_panel()['open'])
        self.assertFalse(mod.debug_cursor_state()['taken'])
        h.user32.set_key(0x4B, True)
        lua.eval('update()')
        self.assertFalse(mod.debug_panel()['open'])
        self.assertFalse(mod.debug_cursor_state()['taken'])
        self.assertEqual('match', mod.signature)

    def test_open_panel_closes_on_native_chat_and_cancels_message_draft(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        self.assertTrue(mod.debug_request_open())
        original = mod.debug_cfg()['message']
        mod.debug_set_editing(True)
        mod.debug_set_edit_buffer('unconfirmed while chat opens')
        self.assertTrue(mod.debug_cursor_state()['taken'])
        h.u8(h.chat_view + 0x139b8, 1)
        lua.execute('for i=1,6 do update() end')
        self.assertFalse(mod.debug_panel()['open'])
        self.assertEqual(original, mod.debug_cfg()['message'])
        self.assertIsNone(mod.debug_panel()['editing'])
        self.assertFalse(mod.debug_cursor_state()['taken'])
        self.assertEqual('none', h.user32_clip_text())
        self.assertEqual(0, h.call_count(), 'a guard close must not submit the draft')

    def test_autochat_ime_editor_does_not_look_like_native_game_chat(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        self.assertTrue(mod.debug_request_open())
        panel = mod.debug_panel()
        mod.debug_set_editing(True)
        panel['input_edit_field'] = 'task:name'
        panel['edit_text'] = 'local name being typed'
        lua.execute('for i=1,12 do update() end')
        self.assertTrue(panel['open'], 'our own IME editor is independent of the game ChatView flag')
        self.assertEqual('00', h.mem_hex(h.chat_view + 0x139b8, 1))
        self.assertEqual('local name being typed', panel['edit_text'])

    def test_held_k_through_chat_close_is_consumed_until_a_fresh_press(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        h.u8(h.chat_view + 0x139b8, 1)
        h.user32.set_key(0x4B, True)
        lua.eval('update()')
        h.u8(h.chat_view + 0x139b8, 0)
        lua.execute('for i=1,12 do update() end')
        self.assertFalse(mod.debug_panel()['open'], 'a held key never turns into a delayed open')
        h.user32.set_key(0x4B, False); lua.eval('update()')
        h.user32.set_key(0x4B, True); lua.eval('update()')
        self.assertTrue(mod.debug_panel()['open'])

    def test_world_list_change_with_same_main_closes_and_destroys_gui_then_resettles(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        self.assertTrue(mod.debug_request_open())
        lua.eval('update()')
        lua.execute('for i=1,12 do update() end')
        self.assertGreater(h.gui_created, 0)
        destroyed_before = h.gui_destroyed
        h.worlds = lua.table_from(['WORLD_MAIN', 'WORLD_OVERLAY', 'WORLD_OVERLAY_NEXT'])
        lua.execute('for i=1,12 do update() end')
        self.assertFalse(mod.debug_panel()['open'])
        self.assertEqual(destroyed_before + 1, h.gui_destroyed,
                         'a list-only change keeps the same live GUI owner and must destroy its GUI')
        self.assertFalse(mod.debug_request_open(), 'the changed list must settle for 1.5 seconds')
        lua.execute('for i=1,100 do update() end')
        self.assertTrue(mod.debug_request_open(), 'the same stable list becomes available after 1.5 seconds')

    def test_main_only_world_list_blocks_hotkey_and_external_open_until_overlay_resettles(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        h.worlds = lua.table_from(['WORLD_MAIN'])
        h.user32.set_key(0x4B, True)
        lua.eval('update()')
        self.assertFalse(mod.debug_panel()['open'])
        self.assertFalse(mod.debug_request_open(), 'an external request must require an Armory overlay world')
        self.assertIn('overlay_world_unavailable', mod.panel_context)
        lua.execute('for i=1,120 do update() end')
        self.assertFalse(mod.debug_panel()['open'], 'main-only state remains blocked after 1.5 seconds')
        h.worlds = lua.table_from(['WORLD_MAIN', 'WORLD_OVERLAY'])
        self.assertFalse(mod.debug_request_open(), 'overlay restoration starts a new settle interval')
        lua.execute('for i=1,100 do update() end')
        self.assertFalse(mod.debug_panel()['open'], 'held K cannot auto-open when overlay becomes ready')
        h.user32.set_key(0x4B, False)
        lua.eval('update()')
        h.user32.set_key(0x4B, True)
        lua.eval('update()')
        self.assertTrue(mod.debug_panel()['open'], 'a fresh K press opens after overlay settles')

    def test_open_panel_closes_and_destroys_gui_when_overlay_disappears(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        self.assertTrue(mod.debug_request_open())
        lua.execute('for i=1,12 do update() end')
        self.assertEqual(1, h.live_guis)
        original_message = mod.debug_cfg()['message']
        mod.debug_set_editing(True)
        mod.debug_set_edit_buffer('draft canceled by overlay loss')
        self.assertTrue(mod.debug_cursor_state()['taken'])
        lua.eval('update()')  # let the editor redraw settle before measuring teardown
        self.assertEqual(1, h.live_guis)
        destroyed_before = h.gui_destroyed
        h.worlds = lua.table_from(['WORLD_MAIN'])
        lua.execute('for i=1,12 do update() end')
        self.assertFalse(mod.debug_panel()['open'])
        self.assertEqual(destroyed_before + 1, h.gui_destroyed)
        self.assertEqual(0, h.live_guis)
        self.assertEqual(original_message, mod.debug_cfg()['message'])
        self.assertFalse(mod.debug_cursor_state()['taken'])
        self.assertEqual(0, h.call_count(), 'overlay loss must not send the unconfirmed draft')

    def test_world_list_error_with_live_main_closes_and_destroys_gui(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        self.assertTrue(mod.debug_request_open())
        lua.execute('for i=1,12 do update() end')
        self.assertGreater(h.gui_created, 0)
        self.assertEqual(1, h.live_guis)
        destroyed_before = h.gui_destroyed
        h.worlds_error = True
        lua.execute('for i=1,12 do update() end')
        self.assertFalse(mod.debug_panel()['open'])
        self.assertEqual(destroyed_before + 1, h.gui_destroyed,
                         'a list read failure must still destroy GUI while main_world remains live')
        self.assertEqual(0, h.live_guis, 'no retained GUI may remain in the live world')
        self.assertEqual(0, h.call_count(), 'closing for a list failure must not send a message')
        self.assertIn('world_list_unavailable', mod.panel_context)

    def test_native_ui_reader_mismatch_fails_closed_without_disabling_sender(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        h.bytes(h.code_base + 0x185f566, 'broken!')
        self.assertFalse(mod.debug_request_open())
        self.assertFalse(mod.debug_cursor_state()['taken'])
        self.assertEqual('match', mod.signature, 'UI-only signature mismatch cannot disable sender verification')
        self.assertIn('unknown:chat field fingerprint mismatch', mod.panel_context)
        self.assertEqual(0, h.call_count())

    def test_native_ui_read_failure_blocks_only_the_panel(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        h.deny_reads_from = h.ui_registry
        self.assertFalse(mod.debug_request_open())
        self.assertFalse(mod.debug_cursor_state()['taken'])
        self.assertIn('unknown:chat UI registry count invalid', mod.panel_context)
        self.assertEqual('match', mod.signature)
        ok, count = mod.send_text('sender unaffected by UI reader', False)
        self.assertTrue(ok)
        self.assertEqual(1, count)

    def test_unavailable_ui_clock_blocks_panel_but_keeps_sender_verified(self):
        lua, h = fresh_image()
        h.disable_qpc_frequency()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        self.assertFalse(mod.debug_request_open())
        self.assertIn('clock_unavailable', mod.panel_context)
        self.assertEqual('match', mod.signature)
        ok, count = mod.send_text('sender remains usable', False)
        self.assertTrue(ok)
        self.assertEqual(1, count)

    def test_clock_failure_during_main_switch_discards_stale_native_gui_handle(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        self.assertTrue(mod.debug_request_open())
        lua.eval('update()')
        destroyed_before = h.gui_destroyed
        h.fail_qpc_counter()
        h.main_world = 'WORLD_NEXT'
        lua.eval('update()')
        self.assertFalse(mod.debug_panel()['open'])
        self.assertIsNone(mod.debug_panel()['gui'])
        self.assertEqual(destroyed_before, h.gui_destroyed,
                         'a clock fault plus changed owner must not destroy a stale native handle')

    def test_registry_count_change_invalidates_cached_chat_view_identity(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        self.assertTrue(mod.debug_request_open())
        h.u32(h.ui_registry + 0x2be8, 2)
        lua.execute('for i=1,6 do update() end')
        self.assertFalse(mod.debug_panel()['open'])
        self.assertIn('unknown:chat view identity changed', mod.panel_context)
        self.assertFalse(mod.debug_cursor_state()['taken'])

    def test_closed_panel_does_not_read_native_chat_registry(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        before = h.ui_reads
        lua.execute('for i=1,120 do update() end')
        self.assertEqual(before, h.ui_reads,
                         'closed steady state must not poll or scan native ChatUI')

    def test_open_chat_check_is_cached_o1_and_does_not_rescan_registry(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        self.assertTrue(mod.debug_request_open())
        before = h.ui_reads
        lua.execute('for i=1,6 do update() end')
        self.assertTrue(mod.debug_panel()['open'])
        self.assertLessEqual(h.ui_reads - before, 14,
                             'an open-panel check validates the cached slot, not all registry entries')

    def test_oversized_chat_registry_fails_closed(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        h.u32(h.ui_registry + 0x2be8, 4097)
        self.assertFalse(mod.debug_request_open())
        self.assertIn('unknown:chat UI registry count invalid', mod.panel_context)
        self.assertEqual('match', mod.signature)

    def test_missing_world_recovery_restarts_settle_window_for_same_identity(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        self.assertTrue(mod.debug_request_open())
        h.main_world = None
        lua.execute('for i=1,12 do update() end')
        self.assertFalse(mod.debug_panel()['open'])
        h.main_world = 'WORLD_MAIN'
        self.assertFalse(mod.debug_request_open(), 'restoring the same handle starts a fresh settle interval')
        lua.execute('for i=1,100 do update() end')
        self.assertTrue(mod.debug_request_open())

    def test_hotkey_held_during_startup_loading_does_not_open_when_gate_lifts(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        h.user32.set_key(0x4B, True)
        lua.execute('for i=1,601 do update() end')
        self.assertFalse(mod.debug_panel()['open'], 'a K press begun during loading must be consumed')
        h.user32.set_key(0x4B, False)
        lua.eval('update()')
        lua.execute('for i=1,100 do update() end')
        h.user32.set_key(0x4B, True)
        lua.eval('update()')
        self.assertTrue(mod.debug_panel()['open'], 'a fresh K press in a ready context still opens')

    def test_world_loading_closes_panel_and_discards_uncommitted_draft(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        mod.debug_set_open(True)
        before_message = mod.debug_cfg()['message']
        mod.debug_set_editing(True)
        mod.debug_set_edit_buffer('invalid draft that must not commit')
        self.assertTrue(mod.debug_cursor_state()['taken'])
        lua.eval('update()')
        panel_input = mod.debug_panel_input()
        lua.execute('''local input = ...
            local release = input.release
            input.release = function(...)
                panel_input_release_calls = (panel_input_release_calls or 0) + 1
                return release(...)
            end''', panel_input)
        lua.eval('update()')
        destroyed_before_world_loss = h.gui_destroyed
        h.main_world = None
        lua.eval('update()')
        self.assertFalse(mod.debug_panel()['open'], 'panel closes as the world enters loading')
        self.assertFalse(mod.debug_cursor_state()['taken'])
        self.assertGreater(lua.globals().panel_input_release_calls, 0,
                           'automatic close releases the input bridge')
        self.assertFalse(mod.debug_panel_input().status()['editing'])
        self.assertEqual('none', h.user32_clip_text())
        self.assertIsNone(mod.debug_panel()['editing'])
        self.assertIsNone(mod.debug_panel()['edit_text'])
        self.assertEqual(before_message, mod.debug_cfg()['message'])
        self.assertEqual(destroyed_before_world_loss, h.gui_destroyed,
                         'a missing world must discard its stale GUI handle without native destruction')

    def test_world_replacement_closes_panel_and_consumes_held_hotkey(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        mod.debug_set_open(True)
        lua.eval('update()')
        destroyed_before_replacement = h.gui_destroyed
        h.user32.set_key(0x4B, True)
        h.main_world = 'WORLD_NEXT'
        lua.eval('update()')
        self.assertFalse(mod.debug_panel()['open'])
        self.assertFalse(mod.debug_cursor_state()['taken'])
        self.assertEqual(destroyed_before_replacement, h.gui_destroyed,
                         'world replacement must discard the stale native GUI handle')
        lua.eval('update()')
        self.assertFalse(mod.debug_panel()['open'], 'held K must not reopen after the new world is ready')
        h.user32.set_key(0x4B, False)
        lua.eval('update()')
        lua.execute('for i=1,100 do update() end')
        h.user32.set_key(0x4B, True)
        lua.eval('update()')
        self.assertTrue(mod.debug_panel()['open'], 'a fresh press still works in the replacement world')

    def test_invalid_resolution_closes_and_destroys_gui_in_the_live_world(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        mod.debug_set_open(True)
        lua.eval('update()')
        self.assertGreater(h.gui_created, 0)
        destroyed_before = h.gui_destroyed
        h.res_w = 0
        lua.eval('update()')
        self.assertFalse(mod.debug_panel()['open'])
        self.assertEqual(destroyed_before + 1, h.gui_destroyed,
                         'an unavailable resolution leaves the native world valid for normal GUI teardown')

    def test_confirmed_message_survives_close_and_reopen(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        mod.debug_set_open(True)
        original = mod.debug_cfg()['message']
        mod.debug_set_editing(True)
        mod.debug_set_edit_buffer('confirmed message')
        h.user32.set_key(0x0D, True)
        lua.eval('update()')
        h.user32.set_key(0x0D, False)
        self.assertEqual('confirmed message', mod.debug_cfg()['message'])
        self.assertIsNone(mod.debug_panel()['edit_backup'])
        mod.debug_set_open(False)
        mod.debug_set_open(True)
        self.assertEqual('confirmed message', mod.debug_cfg()['message'])
        self.assertNotEqual(original, mod.debug_cfg()['message'])

    def test_cancelled_message_then_new_edit_uses_fresh_backup(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        mod.debug_set_open(True)
        original = mod.debug_cfg()['message']
        mod.debug_set_editing(True)
        mod.debug_set_edit_buffer('cancelled draft')
        h.user32.set_key(0x1B, True)
        lua.eval('update()')
        h.user32.set_key(0x1B, False)
        self.assertEqual(original, mod.debug_cfg()['message'])
        self.assertIsNone(mod.debug_panel()['edit_backup'])
        mod.debug_set_editing(True)
        mod.debug_set_edit_buffer('second unconfirmed draft')
        mod.debug_set_open(False)
        self.assertEqual(original, mod.debug_cfg()['message'])
        self.assertIsNone(mod.debug_panel()['edit_backup'])

    def test_loading_close_discards_invalid_option_draft_without_validation(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute('for i=1,601 do update() end')
        mod.debug_set_open(True)
        original = mod.options['cooldown']
        panel = mod.debug_panel()
        panel['editing'], panel['edit_field'], panel['edit_text'] = True, 'option:cooldown', 'invalid'
        h.main_world = None
        lua.eval('update()')
        self.assertFalse(panel['open'], 'forced close must not be blocked by draft validation')
        self.assertEqual(original, mod.options['cooldown'], 'unconfirmed setting must not be applied')

    def test_panel_text_keeps_readable_pixels_when_labels_are_long(self):
        for rw,rh,minimum in ((1920,1080,14),(2560,1600,21)):
            lua,h=fresh_image(font_ids=True)
            h.res_w,h.res_h=rw,rh
            mod=h.load(SOURCE);mod.debug_set_open(True)
            lua.execute('''drawn={}
                stingray.Gui.text=function(gui,value,font,size,material,pos,colour)
                    drawn[#drawn+1]={value=value,size=size}
                end
                stingray.Gui.text_extents=function(gui,value,font,size)
                    local width=0
                    for ch in tostring(value):gmatch('[%z\\1-\\127\\194-\\244][\\128-\\191]*') do
                        width=width+(#ch>1 and size or size*.6)
                    end
                    return {x=0},{x=width}
                end''')
            lua.execute('for i=1,601 do update() end')
            for view in ('tasks','automation','pings'):
                mod.debug_panel()['settings_view']=view
                lua.execute('drawn={}; for i=1,3 do update() end')
                drawn=lua.globals().drawn
                self.assertGreater(len(drawn),0)
                self.assertGreaterEqual(min(drawn[i]['size'] for i in range(1,len(drawn)+1)),minimum,view)

    def fresh(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        mod.debug_set_open(True)
        lua.execute('for i=1,601 do update() end')
        for field, value in (('name', 'Mouse task'), ('message', 'Mouse message')):
            p = mod.debug_panel()
            p['edit_field'], p['editing'], p['edit_text'] = field, True, value
            h.user32.set_key(0x0D, True)
            lua.eval('update()')
            h.user32.set_key(0x0D, False)
            lua.eval('update()')
        return lua, h, mod

    def point(self, h, mod, key):
        boxes = mod.debug_panel()['regions']
        r = next(boxes[i] for i in range(1, len(boxes)+1) if boxes[i]['key'] == key)
        h.mouse_x = r['x'] + r['w']/2
        h.mouse_y = 1080 - r['y'] - r['h']/2

    def test_drag_moves_the_drawn_panel_and_its_hit_regions(self):
        lua, h, mod = self.fresh()
        self.point(h, mod, 'drag')
        before = mod.debug_geometry(1920, 1080)
        h.user32.set_key(1, True)
        lua.eval('update()')
        h.mouse_x += 200
        h.mouse_y += 80
        lua.eval('update()')
        h.user32.set_key(1, False)
        lua.eval('update()')
        after = mod.debug_geometry(1920, 1080)
        self.assertEqual(before['x']+200, after['x'])
        self.assertEqual(before['y']+80, after['y'])
        self.assertIsNone(mod.debug_panel()['drag'])
        self.point(h, mod, 'task:add')
        h.user32.set_key(1, True)
        lua.eval('update()')
        h.user32.set_key(1, False)
        lua.eval('update()')
        self.assertEqual(1, len(mod.tasks), 'moved controls still respond')
        written = h.written()
        self.assertTrue(any('panel-position.txt' in written[i]['path'] for i in range(1, len(written)+1)))

    def test_armory_click_activates_only_on_release_inside_same_button(self):
        lua, h, mod = self.fresh()
        self.point(h, mod, 'task:add')
        h.user32.set_key(1, True)
        lua.eval('update()')
        self.assertEqual(0, len(mod.tasks), 'press arms a button; release activates it')
        h.mouse_x, h.mouse_y = 1800, 1000
        h.user32.set_key(1, False)
        lua.eval('update()')
        self.assertEqual(0, len(mod.tasks), 'releasing elsewhere cancels the action')

    def test_saved_position_is_clamped_and_scales_with_resolution(self):
        lua, h = fresh_image()
        lua.execute('''local old=io.open
            io.open=function(path,mode)
                if tostring(path):find('panel-position.txt',1,true) and mode=='r' then
                    return {read=function() return 'x = 0.25\\ny = 0.1\\n' end,close=function() end}
                end
                return old(path,mode)
            end''')
        mod = h.load(SOURCE)
        geo = mod.debug_geometry(1920, 1080)
        self.assertEqual(480, geo['x'])
        self.assertEqual(108, geo['y'])
        geo = mod.debug_geometry(1280, 720)
        self.assertEqual(320, geo['x'])
        self.assertEqual(72, geo['y'])
        mod.debug_panel()['pos'] = lua.table_from({'fx': 2, 'fy': -3})
        geo = mod.debug_geometry(1280, 720)
        self.assertLessEqual(geo['x']+geo['w'], 1280)
        self.assertGreaterEqual(geo['y'], 0)

    def test_ctrl_zero_resets_dragged_position(self):
        lua, h, mod = self.fresh()
        mod.debug_panel()['pos'] = lua.table_from({'fx': .2, 'fy': .1})
        h.user32.set_key(0x11, True)
        h.user32.set_key(0x30, True)
        lua.eval('update()')
        self.assertIsNone(mod.debug_panel()['pos'])
        self.assertEqual(24, mod.debug_geometry(1920, 1080)['x'])

    def test_automation_settings_buttons_and_custom_fields_are_connected(self):
        lua, h, mod = self.fresh()
        def click(key):
            self.point(h, mod, key)
            h.user32.set_key(1, True)
            lua.eval('update()')
            h.user32.set_key(1, False)
            lua.eval('update()')
        click('view:automation')
        boxes = mod.debug_panel()['regions']
        keys = {boxes[i]['key'] for i in range(1, len(boxes)+1)}
        self.assertTrue({'opt:enabled', 'opt:allow_solo', 'opt:welcome',
            'output:squad', 'output:local', 'option:welcome_message',
            'option:cooldown', 'option:welcome_delay'} <= keys)
        self.assertFalse(any(key.startswith('scope:') for key in keys),
                         'host/client role selection owns the profile; no sender scope gate remains')
        self.assertTrue(mod.options['allow_solo'])
        click('opt:allow_solo')
        self.assertFalse(mod.options['allow_solo'])
        click('output:local')
        self.assertEqual('local', mod.options['output'])
        click('option:welcome_message')
        mod.debug_set_edit_buffer('你好，欢迎！')
        h.user32.set_key(0x0D, True)
        lua.eval('update()')
        h.user32.set_key(0x0D, False)
        lua.eval('update()')
        self.assertEqual('你好，欢迎！', mod.options['welcome_message'])
        self.assertTrue(any('settings.txt' in h.written()[i]['path'] for i in range(1,len(h.written())+1)))
        click('view:tasks')
        self.point(h, mod, 'task:add')

    def test_zoom_key_can_be_released_when_ctrl_is_not_held(self):
        lua, h, mod = self.fresh()
        for expected in (1.1, 1.2):
            h.user32.set_key(0x11, True)
            h.user32.set_key(0xBB, True)
            lua.eval('update()')
            self.assertAlmostEqual(expected, mod.debug_panel()['ui_scale'])
            h.user32.set_key(0x11, False)
            h.user32.set_key(0xBB, False)
            lua.eval('update()')

    def test_ping_page_has_building_stratagem_map_and_enemy_switches(self):
        lua, h, mod = self.fresh()
        def click(key):
            self.point(h, mod, key)
            h.user32.set_key(1, True); lua.eval('update()')
            h.user32.set_key(1, False); lua.eval('update()')
        click('view:pings')
        for option in ('ping_building','ping_stratagem','ping_summon','ping_map','ping_sender_prefix','ping_sender_color'):
            self.assertTrue(mod.options[option])
            click('opt:'+option)
            self.assertFalse(mod.options[option])
        self.point(h, mod, 'opt:ping')
        self.point(h, mod, 'option:ping_message')
        click('option:summon_message')
        mod.debug_set_edit_buffer('{缩写}{动作}了{目标}')
        h.user32.set_key(0x0D, True); lua.eval('update()')
        h.user32.set_key(0x0D, False); lua.eval('update()')
        self.assertEqual('{缩写}{动作}了{目标}', mod.options['summon_message'])
        click('rules:open:enemy')
        for category in ('medium_enemy','large_enemy','giant_enemy','flying_enemy'):
            self.assertTrue(mod.options['ping_'+category])
            click('rules:select:'+category);click('rules:enabled')
            self.assertFalse(mod.options['ping_'+category])
        self.assertFalse(mod.options['ping_small_enemy'])
        click('rules:back');self.point(h,mod,'rules:open:stratagem')
        self.assertTrue(any('settings.txt' in h.written()[i]['path'] for i in range(1,len(h.written())+1)))

    def test_all_settings_pages_have_visible_nonoverlapping_hit_regions(self):
        for rw, rh in ((1280,720), (1920,1080), (3840,2160)):
            lua, h = fresh_image()
            h.res_w, h.res_h = rw, rh
            mod = h.load(SOURCE)
            mod.debug_set_open(True)
            for view in ('tasks','automation','pings'):
                mod.debug_panel()['settings_view'] = view
                lua.execute('for i=1,601 do update() end')
                geo = mod.debug_geometry(rw, rh)
                regions = mod.debug_panel()['regions']
                boxes = [regions[i] for i in range(1,len(regions)+1)]
                for a in boxes:
                    self.assertGreaterEqual(a['y'], rh-geo['y']-geo['h']-1)
                    self.assertLessEqual(a['y']+a['h'], rh-geo['y']+1)
                    self.assertGreaterEqual(a['x'], geo['x']-1)
                    self.assertLessEqual(a['x']+a['w'], geo['x']+geo['w']+1)
                for i,a in enumerate(boxes):
                    for b in boxes[i+1:]:
                        dx = min(a['x']+a['w'],b['x']+b['w'])-max(a['x'],b['x'])
                        dy = min(a['y']+a['h'],b['y']+b['h'])-max(a['y'],b['y'])
                        self.assertFalse(dx>1 and dy>1, (view,a['key'],b['key']))


class ScheduledAvailabilityTest(unittest.TestCase):
    def test_short_repeat_cannot_starve_a_countdown_during_global_cooldown(self):
        _, h = fresh_image()
        mod = h.load(SOURCE)
        mod.add_task('Repeat', 'repeat', '5', 'repeat', 1000)
        once = mod.add_task('Once', 'once', '5', 'once', 1000)
        for now in (1005, 1010, 1015):
            mod.debug_run_tasks(now)
        self.assertTrue(once['done'], 'oldest overdue task must get the next slot')
        self.assertEqual(3, h.call_count())

    def test_peer_guard_uses_slots_even_when_raw_count_is_zero(self):
        _, h = fresh_image(others=2)
        mod = h.load(SOURCE)
        h.u32(h.ctx_base+mod.PEER_COUNT, 0)
        ok, count = mod.send_text('real peers', False)
        self.assertTrue(ok)
        self.assertEqual(2, count)

    def test_solo_schedule_reaches_the_native_chat_sender(self):
        _, h = fresh_image(others=0)
        mod = h.load(SOURCE)
        task = mod.add_task('Solo', 'once', '5', 'hello solo', 1000)
        mod.debug_run_tasks(1005)
        self.assertEqual(1, h.call_count(), 'solo is a valid chat session')
        self.assertEqual('\nhello solo\0', h.last_call()['arg3_text'])
        self.assertTrue(task['done'])

    def test_unavailable_chat_does_not_consume_countdown_and_retries_later(self):
        _, h = fresh_image(chat_flag=0)
        mod = h.load(SOURCE)
        task = mod.add_task('Wait', 'once', '5', 'send after ready', 1000)
        mod.debug_run_tasks(1005)
        self.assertFalse(task['done'], 'a disabled chat is not a completed send')
        self.assertTrue(task['enabled'])
        self.assertEqual(0, h.call_count())
        self.assertIn('等待', task['result'])
        h.bytes(h.ctx_base+mod.CHAT_OBJECT, chr(1))
        mod.debug_run_tasks(1006)
        self.assertEqual(0, h.call_count(), 'retry backoff is respected')
        mod.debug_run_tasks(1010)
        self.assertEqual(1, h.call_count())
        self.assertTrue(task['done'])


if __name__ == '__main__':
    unittest.main()
