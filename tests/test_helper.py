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
    def test_origin_url_from_git_config(self):
        self.assertEqual(
            helper.sanitize_github_repo_url("https://github.com/dreed47/tempest-weather.git"),
            "https://github.com/dreed47/tempest-weather",
        )
        self.assertEqual(
            helper.sanitize_github_repo_url("git@github.com:dreed47/tempest-weather.git"),
            "https://github.com/dreed47/tempest-weather",
        )
        self.assertEqual(helper.sanitize_github_repo_url("https://evil.example/x"), "")
        self.assertEqual(helper.sanitize_github_repo_url("https://github.com/dreed47/tempest-weather.git\nrm"), "")
        cfg = b'[remote "origin"]\n\turl = https://github.com/dreed47/tempest-weather.git\n'
        self.assertEqual(helper.parse_origin_url(cfg), "https://github.com/dreed47/tempest-weather")

    def test_scan_uses_git_origin_not_omarchy_prefix_guess(self):
        with tempfile.TemporaryDirectory() as home:
            os.chmod(home, 0o755)
            plugins = Path(home) / ".config" / "omarchy" / "plugins"
            plugin = plugins / "io.github.dreed47.tempest-weather"
            git = plugin / ".git"
            git.mkdir(parents=True)
            (plugin / "manifest.json").write_text(json.dumps({
                "id": "io.github.dreed47.tempest-weather",
                "name": "Tempest Weather",
                "version": "0.4.1",
            }))
            (git / "config").write_text(
                '[remote "origin"]\n\turl = https://github.com/dreed47/tempest-weather.git\n'
            )
            found = helper.scan_installed(home, str(plugins))
            self.assertEqual(
                found["io.github.dreed47.tempest-weather"]["repo"],
                "https://github.com/dreed47/tempest-weather",
            )

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
        helper.assert_allowed_url(helper.github_search_url("dreed47"))
        with self.assertRaises(helper.Fail):
            helper.assert_allowed_url("https://api.github.com/repos/omacom/omarchy-plugin-marketplace/issues/6398")
        with self.assertRaises(helper.Fail):
            helper.assert_allowed_url("https://api.github.com/search/issues?q=repo:evil/evil+is:issue+author:dreed47")

    def test_parse_and_attach_verification_issue(self):
        raw = {
            "items": [{
                "number": 6398,
                "html_url": "https://github.com/omacom/omarchy-plugin-marketplace/issues/6398",
                "state": "open",
                "title": "[Verify]: new version 2.4.0",
                "labels": [
                    {"name": "plugin-update"},
                    {"name": "validated"},
                    {"name": "security-review-required"},
                ],
                "body": "### Plugin ID\n\nio.github.dreed47.session-restore\n",
            }]
        }
        issues = helper.parse_marketplace_issues(raw)
        self.assertEqual(issues[0]["kind"], "verify")
        self.assertEqual(helper.issue_status_label(issues[0]), "in review")
        rows = helper.attach_issues(
            [{"id": "io.github.dreed47.session-restore", "repo": "https://github.com/dreed47/omarchy-session-restore"}],
            issues,
        )
        self.assertEqual(rows[0]["issueNumber"], 6398)
        self.assertEqual(rows[0]["issueStatus"], "in review")
        closed = dict(raw["items"][0], state="closed", number=5770,
                      html_url="https://github.com/omacom/omarchy-plugin-marketplace/issues/5770")
        attached = helper.attach_issues(
            [{"id": "io.github.dreed47.session-restore"}],
            helper.parse_marketplace_issues({"items": [closed]}),
        )
        self.assertEqual(attached[0]["issueNumber"], 0)

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
            os.chmod(home, 0o755)
            state = str(Path(home) / ".local" / "state" / "omarchy" / "my-plugins")
            fd = helper.open_owned_dir_under_home(home, state, create=True, private_leaf=True)
            try:
                st = os.fstat(fd)
                self.assertTrue(stat.S_ISDIR(st.st_mode))
                self.assertEqual(st.st_uid, os.getuid())
                self.assertEqual(st.st_mode & 0o777, 0o700)
                helper.write_at(fd, "internal.json", b'{"ok":true}', 1024)
                self.assertEqual(helper.read_at(fd, "internal.json", 1024), b'{"ok":true}')
                raw = os.open("internal.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    self.assertEqual(os.fstat(raw).st_mode & 0o777, 0o600)
                finally:
                    os.close(raw)
            finally:
                os.close(fd)
            local = Path(home) / ".local"
            self.assertEqual(local.stat().st_mode & 0o777, 0o700)

    def test_rejects_group_writable_home(self):
        with tempfile.TemporaryDirectory() as home:
            os.chmod(home, 0o775)
            state = str(Path(home) / ".local" / "state" / "omarchy" / "my-plugins")
            with self.assertRaises(helper.Fail):
                helper.open_owned_dir_under_home(home, state, create=True, private_leaf=True)

    def test_rejects_group_writable_ancestor(self):
        with tempfile.TemporaryDirectory() as home:
            os.chmod(home, 0o755)
            local = Path(home) / ".local"
            local.mkdir()
            os.chmod(local, 0o775)
            state = str(Path(home) / ".local" / "state" / "omarchy" / "my-plugins")
            with self.assertRaises(helper.Fail):
                helper.open_owned_dir_under_home(home, state, create=True, private_leaf=True)

    def test_tightens_existing_leaf_not_shared_ancestors(self):
        with tempfile.TemporaryDirectory() as home:
            os.chmod(home, 0o755)
            leaf = Path(home) / ".local" / "state" / "omarchy" / "my-plugins"
            leaf.mkdir(parents=True)
            os.chmod(Path(home) / ".local", 0o755)
            os.chmod(Path(home) / ".local" / "state", 0o755)
            os.chmod(Path(home) / ".local" / "state" / "omarchy", 0o755)
            os.chmod(leaf, 0o755)
            fd = helper.open_owned_dir_under_home(home, str(leaf), create=True, private_leaf=True)
            try:
                self.assertEqual(os.fstat(fd).st_mode & 0o777, 0o700)
            finally:
                os.close(fd)
            self.assertEqual((Path(home) / ".local").stat().st_mode & 0o777, 0o755)
            self.assertEqual((Path(home) / ".local" / "state").stat().st_mode & 0o777, 0o755)
            self.assertEqual((Path(home) / ".local" / "state" / "omarchy").stat().st_mode & 0o777, 0o755)

    def test_fchmod_survives_permissive_umask(self):
        with tempfile.TemporaryDirectory() as home:
            os.chmod(home, 0o755)
            old = os.umask(0)
            try:
                state = str(Path(home) / ".local" / "state" / "omarchy" / "my-plugins")
                fd = helper.open_owned_dir_under_home(home, state, create=True, private_leaf=True)
                try:
                    self.assertEqual(os.fstat(fd).st_mode & 0o777, 0o700)
                    helper.write_at(fd, "catalog.json", b"{}", 1024)
                    raw = os.open("catalog.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
                    try:
                        self.assertEqual(os.fstat(raw).st_mode & 0o777, 0o600)
                    finally:
                        os.close(raw)
                finally:
                    os.close(fd)
            finally:
                os.umask(old)

    def test_scan_skips_group_writable_plugin_dirs(self):
        with tempfile.TemporaryDirectory() as home:
            os.chmod(home, 0o755)
            plugins = Path(home) / ".config" / "omarchy" / "plugins"
            good = plugins / "io.github.dreed47.tempest-weather"
            bad = plugins / "io.github.dreed47.open-dir"
            good.mkdir(parents=True)
            bad.mkdir()
            (good / "manifest.json").write_text(json.dumps({
                "id": "io.github.dreed47.tempest-weather",
                "name": "Tempest Weather",
                "version": "0.4.1",
            }))
            (bad / "manifest.json").write_text(json.dumps({
                "id": "io.github.dreed47.open-dir",
                "name": "Open",
                "version": "1.0.0",
            }))
            os.chmod(bad, 0o775)
            found = helper.scan_installed(home, str(plugins))
            self.assertIn("io.github.dreed47.tempest-weather", found)
            self.assertNotIn("io.github.dreed47.open-dir", found)

    def test_scan_resolves_one_hop_symlink_under_home(self):
        with tempfile.TemporaryDirectory() as home:
            os.chmod(home, 0o755)
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
            os.chmod(Path(home) / "code", 0o755)
            os.chmod(target, 0o700)
            (target / "manifest.json").write_text(json.dumps({
                "id": "io.github.dreed47.my-plugins",
                "name": "My Plugins",
                "version": "0.1.5",
            }))
            (plugins / "io.github.dreed47.my-plugins").symlink_to(target)
            found = helper.scan_installed(home, str(plugins))
            self.assertIn("io.github.dreed47.tempest-weather", found)
            self.assertIn("io.github.dreed47.my-plugins", found)

    def test_scan_skips_symlink_outside_home(self):
        with tempfile.TemporaryDirectory() as home:
            os.chmod(home, 0o755)
            plugins = Path(home) / ".config" / "omarchy" / "plugins"
            plugins.mkdir(parents=True)
            with tempfile.TemporaryDirectory() as outside:
                os.chmod(outside, 0o700)
                (Path(outside) / "manifest.json").write_text(json.dumps({
                    "id": "io.github.dreed47.evil",
                    "name": "Evil",
                    "version": "1.0.0",
                }))
                (plugins / "io.github.dreed47.evil").symlink_to(outside)
                found = helper.scan_installed(home, str(plugins))
                self.assertNotIn("io.github.dreed47.evil", found)


if __name__ == "__main__":
    unittest.main()
