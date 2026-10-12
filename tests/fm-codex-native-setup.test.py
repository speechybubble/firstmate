#!/usr/bin/env python3
"""Behavioral replay of native Codex trust dialogs (no live credentials)."""
import unittest

from codex_native_setup import NativeSetup


class SetupTests(unittest.TestCase):
    def replay(self, folder, review, pending, trusted):
        driver = NativeSetup()
        keys = []
        ready = False

        def step(text, reviewed=True):
            return driver.step(text, keys.append, lambda: reviewed, lambda: ready)

        self.assertFalse(step(folder))
        self.assertEqual(keys, ["Enter"])
        step(folder)
        self.assertEqual(keys, ["Enter"])
        if review:
            step(review)
            self.assertEqual(keys, ["Enter", "Enter"])
        self.assertFalse(step(pending))
        self.assertEqual(keys[-1], "t")
        self.assertFalse(step(trusted))
        self.assertEqual(keys[-1], "Escape")
        count = len(keys)
        # Retained scrollback neither sends repeated keys nor proves completion.
        self.assertFalse(step(folder + pending + trusted))
        self.assertEqual(len(keys), count)
        ready = {"watcher": 123, "completed_at": "native completion"}
        self.assertEqual(step(""), ready)

    def test_current_dialogs(self):
        self.replay("Trust this folder?\nTrust and continue\nenter continue", None,
                    "5 hooks need review before they can run.\nt trust all · enter review · esc close",
                    "5 hooks trusted\nenter review · esc close")

    def test_older_dialogs(self):
        self.replay("Do you trust the contents of this directory?",
                    "Hooks need review\nReview hooks", "Press t to trust all",
                    "Press enter to view hooks; esc to close")

    def test_unreviewed_hooks_are_not_accepted(self):
        for text in ["Press t to trust all",
                     "5 hooks need review before they can run.\nt trust all · enter review · esc close"]:
            keys = []
            with self.assertRaisesRegex(RuntimeError, "Review fixture"):
                NativeSetup().step(text, keys.append, lambda: False, lambda: True)
            self.assertEqual(keys, [])

    def test_footer_alone_does_not_complete_setup(self):
        keys = []
        self.assertFalse(NativeSetup().step("Press enter to view hooks; esc to close",
                                          keys.append, lambda: False, lambda: False))
        self.assertEqual(keys, [])

    def test_already_trusted_runtime_needs_no_keys(self):
        keys = []
        self.assertTrue(NativeSetup().step("", keys.append, lambda: False, lambda: True))
        self.assertEqual(keys, [])


if __name__ == "__main__":
    unittest.main()
