"""Unit tests for helper.py (stdlib only: `python3 -m unittest discover -s tests`)."""

from __future__ import annotations

import contextlib
import importlib
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

# The plugin is not a package: load helper.py from the plugin root (a dynamic import, so
# no type checker needs an ignore whose rule name differs between ty versions).
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
helper = importlib.import_module("helper")


def call(*argv: str, results: list[dict] | None = None) -> tuple[dict, list[list[str]]]:
    """Run helper.main with `nstream` stubbed; return its JSON and the nstream argvs."""
    calls: list[list[str]] = []
    queue = list(results or [{"ok": True}])

    def fake_run(args, timeout):
        calls.append(list(args))
        return queue.pop(0) if queue else {"ok": True}

    out = io.StringIO()
    with mock.patch.object(helper, "run", fake_run), contextlib.redirect_stdout(out):
        helper.main(list(argv))
    return json.loads(out.getvalue()), calls



class TransferTest(unittest.TestCase):
    def test_requires_explicit_retirement_confirmation(self):
        out, calls = call("transfer", "local", "a" * 32,
                          results=[{"ok": True, "source_stopped": True, "target": "local"}])
        self.assertTrue(out["ok"])
        self.assertEqual(out["target"], "local")
        self.assertEqual(calls, [["--transfer-to", "local", "--session-id", "a" * 32]])
        out, _ = call("transfer", "cast", "a" * 32, results=[{"ok": True}])
        self.assertFalse(out["ok"])

    def test_invalid_identity_never_reaches_core(self):
        out, calls = call("transfer", "local", "bad/identity")
        self.assertFalse(out["ok"])
        self.assertEqual(calls, [])


class HistoryTest(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("NSTREAM_CONTRACT_TEST"), "requires compatible installed nstream")
    def test_real_nstream_history_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            env = {}
            for kind in ("CONFIG", "STATE", "CACHE", "RUNTIME"):
                root = base / kind.lower()
                root.mkdir()
                env[f"XDG_{kind}_HOME" if kind != "RUNTIME" else "XDG_RUNTIME_DIR"] = str(root)
            config = base / "config" / "nstream"
            config.mkdir()
            (config / "config.json").write_text('{"prefer_cast": true}')
            history = base / "state" / "nstream"
            history.mkdir()
            (history / "history.json").write_text(json.dumps({"tt1": {
                "title": "Contract Movie", "type": "movie", "position": 100,
                "duration": 1000, "ts": time.time(),
            }}))
            (base / "runtime" / "nstream-active-cast.json").write_text(json.dumps({
                "title": "Contract Movie", "device": "Contract TV", "follow": True,
                "pid": os.getpid(), "ts": time.time(),
            }))
            out = io.StringIO()
            with mock.patch.dict(os.environ, env), contextlib.redirect_stdout(out):
                helper.main(["history"])
            response = json.loads(out.getvalue())
            self.assertTrue(response["ok"], response)
            self.assertEqual(response["session"], {"title": "Contract Movie", "device": "Contract TV"})
            self.assertEqual(response["entries"][0]["title"], "Contract Movie")
            self.assertTrue(response["preferCast"])

    def test_missing_history_interface_is_reported_as_incompatible(self):
        out, _ = call("history", results=[{"ok": False, "error": "usage"}])
        self.assertFalse(out["ok"])
        self.assertIn("--json --history", out["error"])
        self.assertNotIn("vecchio", out["error"])

    def test_rejects_malformed_collection(self):
        for entries in ({"title": "Show"}, "Show", None):
            out, _ = call("history", results=[{"ok": True, "entries": entries}])
            self.assertFalse(out["ok"])

    def test_bounds_and_sanitizes_entries(self):
        raw = {
            "ok": True,
            "entries": [
                {
                    "title": "Show\x1b[31m\n",
                    "type": "series",
                    "season": 1,
                    "episode": 2,
                    "position": 10,
                    "duration": 20,
                    "next": True,
                },
                {"title": "", "type": "movie"},
                {"title": "x" * 500, "type": "weird", "season": "1", "position": "nan"},
            ],
            "cast_session": {"title": "Show", "device": "TV"},
        }
        with mock.patch.object(helper, "prefer_cast", return_value=True):
            out, calls = call("history", results=[raw])
        self.assertEqual(calls, [["--history"]])
        self.assertTrue(out["ok"] and out["preferCast"])
        show, film = out["entries"]
        self.assertEqual(show["title"], "Show[31m")
        self.assertEqual((show["season"], show["episode"], show["next"]), (1, 2, True))
        self.assertEqual(len(film["title"]), helper.MAX_TITLE)
        self.assertEqual((film["type"], film["season"], film["position"]), ("movie", 0, 0.0))
        self.assertEqual(out["session"], {"title": "Show", "device": "TV"})

    def test_failure_is_reported(self):
        out, _ = call("history", results=[{"ok": False, "error": "x", "message": "rotto"}])
        self.assertEqual(out, {"kind": "history", "ok": False, "error": "rotto"})


class ControlTest(unittest.TestCase):
    def test_extreme_numeric_status_fields_are_bounded(self):
        out, _ = call(
            "status",
            results=[
                {
                    "ok": True,
                    "position": 10**400,
                    "duration": "inf",
                    "volume_percent": "nan",
                }
            ],
        )
        self.assertTrue(out["ok"])
        self.assertEqual((out["position"], out["duration"], out["volume"]), (0, 0, 0))

    def test_receiver_error_is_visible_without_forwarding_payload(self):
        out, _ = call(
            "status",
            results=[
                {
                    "ok": True,
                    "player_state": "IDLE",
                    "receiver_error": {"code": "LOAD_FAILED", "url": "secret"},
                }
            ],
        )
        self.assertFalse(out["ok"])
        self.assertNotIn("secret", json.dumps(out))

    def test_status_fields(self):
        st = {
            "ok": True,
            "device": "TV",
            "title": "Dune",
            "player_state": "playing",
            "position": 12.5,
            "duration": 100,
            "volume_percent": 140,
        }
        out, _ = call("status", results=[st])
        self.assertEqual((out["state"], out["volume"], out["position"]), ("PLAYING", 100, 12.5))
        out, _ = call("status", results=[{"ok": True, "player_state": "IDLE"}])
        self.assertEqual(out["volume"], -1)

    def test_relative_seek_clamps_to_duration(self):
        _, calls = call("seek", "30", results=[{"ok": True, "position": 90, "duration": 100}])
        self.assertEqual(calls, [["--status"], ["--seek", "95"]])
        _, calls = call("seek", "-30", results=[{"ok": True, "position": 10, "duration": 100}])
        self.assertEqual(calls[-1], ["--seek", "0"])

    def test_rejects_out_of_range_values(self):
        for argv in (
            ("volume", "101"),
            ("volume", "x"),
            ("subshift", "31"),
            ("seekto", "-1"),
            ("seek", "1e9"),
            ("pause", "extra"),
            ("rm", "-rf"),
        ):
            out, calls = call(*argv)
            self.assertFalse(out["ok"], argv)
            self.assertEqual(calls, [], argv)

    def test_simple_actions_map_to_flags(self):
        for cmd in ("pause", "resume", "stop"):
            _, calls = call(cmd)
            self.assertEqual(calls, [["--" + cmd]])
        _, calls = call("volume", "40")
        self.assertEqual(calls, [["--volume", "40"]])
        _, calls = call("subshift", "-0.5")
        self.assertEqual(calls, [["--sub-shift", "-0.5"]])


class ContinueTest(unittest.TestCase):
    def test_cast_passes_title_after_separator(self):
        out, calls = call("continue", "cast", "--stop", results=[{"ok": True, "title": "T"}])
        self.assertEqual(calls, [["-c", "--cast", "--", "--stop"]])
        self.assertTrue(out["ok"])

    def test_local_waits_for_result_and_reports_playback_failure(self):
        for result in (
            {"ok": True, "title": "Dune"},
            {
                "ok": False,
                "error": "no_streams",
                "message": "no streams",
            },
        ):
            with mock.patch.object(helper, "run", return_value=result) as run:
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    helper.main(["continue", "local", "Dune"])
            self.assertEqual(run.call_args.args, (["-c", "--local", "--", "Dune"], None))
            response = json.loads(out.getvalue())
            self.assertEqual(response["kind"], "local")
            self.assertEqual(response["ok"], result["ok"])

    def test_rejects_bad_target_or_empty_title(self):
        for argv in (("continue", "tv", "Dune"), ("continue", "cast", "\x00\n")):
            out, calls = call(*argv)
            self.assertFalse(out["ok"])
            self.assertEqual(calls, [])


class RunTest(unittest.TestCase):
    def test_parses_last_json_line_and_handles_missing_binary(self):
        def fake_run(argv, **kwargs):
            return mock.Mock(returncode=0, stdout=b'noise\n{"ok": true, "action": "x"}\n')

        with (
            mock.patch.object(helper, "nstream_bin", return_value="/bin/nstream"),
            mock.patch.object(helper.subprocess, "run", side_effect=fake_run) as run,
        ):
            self.assertEqual(helper.run(["--status"], 5), {"ok": True, "action": "x"})
        self.assertEqual(run.call_args.args[0], ["/bin/nstream", "--json", "--status"])
        self.assertTrue(run.call_args.kwargs["start_new_session"])
        self.assertIn(os.path.expanduser("~/.local/bin"), run.call_args.kwargs["env"]["PATH"])
        with mock.patch.object(helper, "nstream_bin", return_value=None):
            self.assertEqual(helper.run(["--status"], 5)["error"], "missing")

    def test_process_errors_return_json(self):
        for error in (OSError("secret"), subprocess.TimeoutExpired("nstream", 1)):
            with (
                mock.patch.object(helper, "nstream_bin", return_value="/bin/nstream"),
                mock.patch.object(helper.subprocess, "run", side_effect=error),
            ):
                response = helper.run(["--status"], 1)
            self.assertFalse(response["ok"])
            self.assertNotIn("secret", json.dumps(response))

    def test_real_child_inherits_path_and_local_failure_is_observed(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = pathlib.Path(directory) / "nstream"
            executable.write_text(
                f"#!{sys.executable}\nimport json, os, sys\n"
                "print(json.dumps({'ok':False, 'error':'no_streams',"
                "'message':os.environ['PATH']}))\nsys.exit(1)\n"
            )
            executable.chmod(0o755)
            with mock.patch.dict(os.environ, {"PATH": directory}):
                response = helper.run(["-c", "--local", "--", "Dune"], None)
            self.assertFalse(response["ok"])
            self.assertIn(os.path.expanduser("~/.local/bin"), response["message"])

    def test_rejects_oversized_or_invalid_output_and_false_success(self):
        for raw, code in (
            (b"x" * (helper.MAX_OUTPUT + 1), 0),
            (b"\xffnot json", 0),
            (b'{"ok": true}', 1),
        ):

            def fake_run(argv, raw=raw, code=code, **kwargs):
                return mock.Mock(returncode=code, stdout=raw)

            with (
                mock.patch.object(helper, "nstream_bin", return_value="/bin/nstream"),
                mock.patch.object(helper.subprocess, "run", side_effect=fake_run),
            ):
                self.assertFalse(helper.run(["--status"], 1)["ok"])


class OpenTest(unittest.TestCase):
    def test_launcher_missing_is_reported(self):
        with mock.patch.object(helper.shutil, "which", return_value=None):
            response, _ = call("open")
        self.assertFalse(response["ok"])

    def test_open_waits_for_confirmed_activation(self):
        for result in ("opened", "focused", "already_open"):
            body = {"api_version": 1, "action": "launch", "ok": True, "result": result}
            with mock.patch.object(helper.shutil, "which", return_value="/bin/launcher"), \
                 mock.patch.object(helper.subprocess, "run", return_value=subprocess.CompletedProcess(
                     [], 0, json.dumps(body).encode())) as run:
                response, _ = call("open")
            self.assertTrue(response["ok"])
            self.assertEqual(response["result"], result)
            self.assertEqual(run.call_args.args[0], ["/bin/launcher", "--json"])
            self.assertIn(os.path.expanduser("~/.local/bin"), run.call_args.kwargs["env"]["PATH"])

    def test_open_failure_is_not_a_successful_spawn(self):
        for code in ("terminal_missing", "focus_failed", "launch_failed", "launch_timeout"):
            body = {"api_version": 1, "action": "launch", "ok": False, "error": code}
            with mock.patch.object(helper.shutil, "which", return_value="/bin/launcher"), \
                 mock.patch.object(helper.subprocess, "run", return_value=subprocess.CompletedProcess(
                     [], 1, json.dumps(body).encode())):
                response, _ = call("open")
            self.assertFalse(response["ok"])

    def test_open_rejects_timeout_and_unconfirmed_or_malformed_reply(self):
        outputs = [b'{}', b'not json', b'{"ok":true}', b'x' * (helper.MAX_OUTPUT + 1)]
        for output in outputs:
            with mock.patch.object(helper.shutil, "which", return_value="/bin/launcher"), \
                 mock.patch.object(helper.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output)):
                response, _ = call("open")
            self.assertFalse(response["ok"])
        with mock.patch.object(helper.shutil, "which", return_value="/bin/launcher"), \
             mock.patch.object(helper.subprocess, "run", side_effect=subprocess.TimeoutExpired([], 15)):
            response, _ = call("open")
        self.assertFalse(response["ok"])


class DesktopProtocolTest(unittest.TestCase):
    def test_watch_replaces_adapter_without_a_shell(self):
        with mock.patch.object(helper, "nstream_bin", return_value="/usr/bin/nstream"), \
             mock.patch.object(helper.os, "execvpe") as execute:
            helper.main(["watch"])
        self.assertEqual(execute.call_args.args[:2],
                         ("/usr/bin/nstream", ["/usr/bin/nstream", "--json", "--watch"]))

    def test_context_is_bounded_and_only_allowed_for_lifecycle(self):
        out, _ = call("pause", "--session-id", "bad\nidentity", "--device", "TV")
        self.assertFalse(out["ok"])
        out, _ = call("continue", "cast", "Movie", "--session-id", "abc", "--device", "TV")
        self.assertFalse(out["ok"])

    def test_guard_reaches_backend_argv(self):
        result = subprocess.CompletedProcess([], 0, b'{"ok":true}', b'')
        output = io.StringIO()
        with mock.patch.object(helper, "nstream_bin", return_value="/usr/bin/nstream"), \
             mock.patch.object(helper.subprocess, "run", return_value=result) as execute, \
             contextlib.redirect_stdout(output):
            helper.main(["pause", "--session-id", "generation", "--device", "192.0.2.1"])
        self.assertTrue(json.loads(output.getvalue())["ok"])
        self.assertEqual(execute.call_args.args[0], ["/usr/bin/nstream", "--json", "--pause",
                         "--session-id", "generation", "--device", "192.0.2.1"])

    @unittest.skipUnless(os.environ.get("NSTREAM_CONTRACT_TEST"), "requires watch-capable nstream")
    def test_real_watch_contract_and_clean_observer_exit(self):
        import select

        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            env = helper.child_env()
            for kind in ("CONFIG", "STATE", "CACHE", "RUNTIME"):
                root = base / kind.lower()
                root.mkdir()
                env[f"XDG_{kind}_HOME" if kind != "RUNTIME" else "XDG_RUNTIME_DIR"] = str(root)
            config = base / "config" / "nstream"
            config.mkdir()
            (config / "config.json").write_text('{}')
            proc = subprocess.Popen([sys.executable, "-I", "-B", str(pathlib.Path(helper.__file__)), "watch"],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True, env=env)
            try:
                self.assertTrue(select.select([proc.stdout], [], [], 10)[0])
                snapshot = json.loads(proc.stdout.readline())
                self.assertEqual(snapshot["api_version"], 1)
                self.assertIn("session_guard", snapshot["capabilities"])
                self.assertIsNone(snapshot["cast_session"])
                self.assertEqual(snapshot["telemetry"]["connection"], "idle")
                proc.stdin.close()
                self.assertEqual(proc.wait(timeout=5), 0)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=5)
                proc.stdout.close()
                proc.stderr.close()


if __name__ == "__main__":
    unittest.main()
