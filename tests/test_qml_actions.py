"""Execute the real panel button handler and action functions in a Qt QML engine.

The harness replaces desktop services with small QML objects; it does not require Omarchy
or Quickshell, and takes the button binding/functions directly from Panel.qml.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

PANEL = Path(__file__).resolve().parents[1] / "Panel.qml"


def function_source(source, name):
    match = re.search(r"\bfunction\s+" + re.escape(name) + r"\s*\([^)]*\)\s*\{", source)
    if not match:
        raise AssertionError(f"Missing QML action: {name}")
    start, depth, quote, escaped = match.start(), 1, None, False
    for index in range(match.end(), len(source)):
        char = source[index]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif char in ('"', "'", '`'):
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if not depth:
                return source[start:index + 1]
    raise AssertionError(f"Unclosed QML action: {name}")


class QmlActionsTest(unittest.TestCase):
    def test_actual_open_button_without_cast_and_with_concurrent_controls(self):
        runner = os.environ.get("QMLTESTRUNNER") or shutil.which("qmltestrunner")
        if not runner and Path('/usr/lib/qt6/bin/qmltestrunner').exists():
            runner = '/usr/lib/qt6/bin/qmltestrunner'
        if not runner:
            if os.environ.get('NSTREAM_REQUIRE_QML_TESTS'):
                self.fail('Qt QML test runner is required in CI')
            self.skipTest('Qt QML test runner is not installed')
        panel = PANEL.read_text()
        button = panel.split('text: tr.t("open")', 1)[1].split('\n            }', 1)[0]
        enabled = re.search(r'enabled:\s*([^\n]+)', button).group(1)
        clicked = re.search(r'onClicked:\s*([^\n]+)', button).group(1)
        functions = '\n'.join(function_source(panel, name) for name in
                              ('openNstream', 'control', 'helperCommand', 'receive', 'close'))
        qml = '''import QtQuick 2.15
import QtTest 1.2
TestCase {
  name: "PanelOpenAction"
  QtObject {
    id: root
    property bool watchCompatible: false
    property var session: null
    property bool opened: true
    property string message: ""
    property bool messageIsError: false
    property string helper: "/test/helper.py"
    FUNCTIONS
  }
  QtObject { id: tr; function t(key) { return key } }
  QtObject { id: openProc; property bool running: false; property var command: [] }
  QtObject { id: controlProc; property bool running: false; property var command: [];
    property string kind: ""; property string sessionId: "" }
  QtObject {
    id: button
    property bool enabled: ENABLED
    function click() { CLICKED }
  }
  function init() {
    openProc.running = false
    openProc.command = []
    controlProc.running = false
    root.watchCompatible = false
    root.session = null
    root.opened = true
    root.message = ""
    root.messageIsError = false
  }
  function test_open_without_session_or_observer() {
    verify(button.enabled)
    button.click()
    verify(openProc.running)
    compare(openProc.command[openProc.command.length - 1], "open")
    verify(!controlProc.running)
    verify(root.opened) // A request is not yet an acknowledged activation.
  }
  function test_open_independent_of_busy_cast_control() {
    controlProc.running = true
    verify(button.enabled)
    button.click()
    verify(openProc.running)
  }
  function test_repeated_click_while_opening() {
    button.click()
    verify(!button.enabled)
    root.message = "pending"
    button.click()
    compare(root.message, "pending")
  }
  function test_failed_activation_remains_visible() {
    root.receive(JSON.stringify({kind:"open",ok:false,error:"focus failed"}), "open")
    verify(root.opened)
    verify(root.messageIsError)
    compare(root.message, "focus failed")
  }
  function test_existing_instance_without_focus_shows_hint() {
    root.receive(JSON.stringify({kind:"open",ok:true,result:"already_open"}), "open")
    verify(root.opened)
    verify(!root.messageIsError)
    compare(root.message, "open.already")
  }
  function test_confirmed_activation_closes_panel() {
    root.receive(JSON.stringify({kind:"open",ok:true,result:"focused"}), "open")
    verify(!root.opened)
  }
}
'''.replace('FUNCTIONS', functions).replace('ENABLED', enabled).replace('CLICKED', clicked)
        with tempfile.TemporaryDirectory(prefix='nstream-qml-test-') as directory:
            path = Path(directory) / 'tst_actions.qml'
            path.write_text(qml)
            env = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software')
            result = subprocess.run([runner, '-input', str(path), '-o', '-,txt'],
                                    capture_output=True, text=True, env=env, timeout=20)
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr)[-6000:])


if __name__ == '__main__':
    unittest.main()
