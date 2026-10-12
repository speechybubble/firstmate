"""Bounded dialog driver; readiness comes from native runtime state, not UI text."""


class NativeSetup:
    def __init__(self):
        self.sent = set()

    def step(self, text, send, hooks_reviewed, ready):
        # Do not resend keys when pane output retains an old dialog in scrollback.
        if ("Do you trust the contents of this directory?" in text
                or ("Trust this folder?" in text and "Trust and continue" in text)):
            self._once("folder", send, "Enter")
        if "Hooks need review" in text and "Review hooks" in text:
            self._once("review", send, "Enter")
        if ("Press t to trust all" in text
                or ("hooks need review before they can run" in text and "t trust all" in text)):
            if "trust" not in self.sent:
                if not hooks_reviewed():
                    raise RuntimeError("Review fixture .codex/hooks.json and set "
                                       "FM_CODEX_TEST_REVIEWED_HOOKS_SHA256 to its SHA-256")
                self._once("trust", send, "t")
                return False
        if "trust" in self.sent and ("esc to close" in text or "esc close" in text):
            self._once("close", send, "Escape")
        if "Update now" in text and "Skip" in text and "update" not in self.sent:
            self._once("update", send, "2")
            send("Enter")
        return ready()

    def _once(self, stage, send, key):
        if stage not in self.sent:
            send(key)
            self.sent.add(stage)
