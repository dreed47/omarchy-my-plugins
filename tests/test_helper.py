import importlib.machinery
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parents[1] / "scripts" / "my-plugins"
loader = importlib.machinery.SourceFileLoader("my_plugins_helper", str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
helper = importlib.util.module_from_spec(spec)
sys.modules["my_plugins_helper"] = helper
loader.exec_module(helper)


class HelperTests(unittest.TestCase):
    def test_normalize_github_user(self):
        self.assertEqual(helper.normalize_github_user("@dreed47"), "dreed47")
        self.assertEqual(helper.normalize_github_user("https://github.com/dreed47/omarchy-my-plugins"), "dreed47")
        self.assertEqual(helper.normalize_github_user("foo_bar"), "")

    def test_matches_owner_by_id_prefix(self):
        row = {
            "id": "io.github.dreed47.my-plugins",
            "repo": "https://github.com/dreed47/omarchy-my-plugins",
            "author": "David Reed",
        }
        self.assertTrue(helper.matches_owner(row, {"githubUser": "dreed47"}))
        self.assertFalse(helper.matches_owner(row, {"githubUser": "someone"}))

    def test_allowlist_rejects_literals_and_redirects(self):
        with self.assertRaises(helper.Fail):
            helper.assert_allowed_url("https://127.0.0.1/catalog.json")
        with self.assertRaises(helper.Fail):
            helper.assert_allowed_url("https://plugins.omarchy.org/../etc/passwd")
        with self.assertRaises(helper.Fail):
            helper.assert_allowed_url("http://plugins.omarchy.org/catalog.json")
        helper.assert_allowed_url("https://plugins.omarchy.org/catalog.json")
        helper.assert_allowed_url("https://api.omarchyplugins.com/v1/stats")

    def test_state_dir_refuses_symlink(self):
        with tempfile.TemporaryDirectory() as home:
            os.chmod(home, 0o700)
            evil = Path(home) / "evil"
            evil.mkdir()
            link = Path(home) / ".local"
            link.symlink_to(evil)
            state = str(Path(home) / ".local" / "state" / "omarchy" / "my-plugins")
            with self.assertRaises(helper.Fail):
                helper.open_owned_dir_under_home(home, state, create=True)

    def test_state_dir_creates_owned_tree(self):
        with tempfile.TemporaryDirectory() as home:
            os.chmod(home, 0o700)
            state = str(Path(home) / ".local" / "state" / "omarchy" / "my-plugins")
            fd = helper.open_owned_dir_under_home(home, state, create=True)
            try:
                st = os.fstat(fd)
                self.assertTrue(stat.S_ISDIR(st.st_mode))
                self.assertEqual(st.st_uid, os.getuid())
                helper.write_at(fd, "internal.json", b'{"ok":true}', 1024)
                self.assertEqual(helper.read_at(fd, "internal.json", 1024), b'{"ok":true}')
            finally:
                os.close(fd)

    def test_scan_skips_symlink_plugin_dirs(self):
        with tempfile.TemporaryDirectory() as home:
            os.chmod(home, 0o700)
            plugins = Path(home) / ".config" / "omarchy" / "plugins"
            real = plugins / "io.github.dreed47.tempest-weather"
            real.mkdir(parents=True)
            (real / "manifest.json").write_text(json.dumps({
                "id": "io.github.dreed47.tempest-weather",
                "name": "Tempest Weather",
                "version": "0.4.1",
                "author": "David Reed",
            }))
            target = Path(home) / "code" / "omarchy-my-plugins"
            target.mkdir(parents=True)
            (target / "manifest.json").write_text(json.dumps({
                "id": "io.github.dreed47.my-plugins",
                "name": "My Plugins",
                "version": "0.1.4",
            }))
            (plugins / "io.github.dreed47.my-plugins").symlink_to(target)
            found = helper.scan_installed(home, str(plugins))
            self.assertIn("io.github.dreed47.tempest-weather", found)
            self.assertNotIn("io.github.dreed47.my-plugins", found)


if __name__ == "__main__":
    unittest.main()
