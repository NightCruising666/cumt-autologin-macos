# SPDX-License-Identifier: AGPL-3.0-only
import contextlib
import http.server
import importlib.util
import io
import json
import logging
from pathlib import Path
import plistlib
import tempfile
import threading
import unittest
from unittest.mock import MagicMock, patch
import urllib.parse

SPEC = importlib.util.spec_from_file_location("cumt_login", Path(__file__).parents[1] / "cumt_login.py")
app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app)
PAGE = "<script>var v4ip = '10.4.2.3'; var olmac = 'AA:BB:CC:DD:EE:FF';</script><script src='/drcom.js'></script>"


class LocalPortal(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_GET(self):
        type(self).calls.append((self.path, self.headers.get("Cookie")))
        if self.path == "/":
            self.send_response(200)
            self.send_header("Set-Cookie", "session=cumt-test; Path=/")
            self.end_headers()
            self.wfile.write(PAGE.encode())
        elif self.path.startswith("/login"):
            self.send_response(302)
            self.send_header("Location", "/unexpected-redirect?password=SECRET")
            self.end_headers()
        elif self.path == "/204":
            self.send_response(204)
            self.end_headers()
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"should not be visited")

    def log_message(self, *args):
        pass


class ProtocolTests(unittest.TestCase):
    def test_session_cookie_and_credential_redirect_is_not_followed(self):
        LocalPortal.calls = []
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), LocalPortal)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = "http://127.0.0.1:%d" % server.server_port
        try:
            client = app.PortalClient()
            self.assertEqual(client.get(base + "/")[0], 200)
            self.assertEqual(client.get(base + "/login?password=SECRET")[0], 302)
            self.assertEqual(LocalPortal.calls[-1][1], "session=cumt-test")
            self.assertEqual(len(LocalPortal.calls), 2)
            with patch.object(app, "CHECK_URLS", (base + "/login",)):
                self.assertFalse(client.online())
            with patch.object(app, "CHECK_URLS", (base + "/204",)):
                self.assertTrue(client.online())
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_special_password_is_encoded_and_not_confused_with_parameters(self):
        client = app.PortalClient()
        secret = 'a&+?# 中文="'
        with patch.object(client, "get", return_value=(200, b'{"result":1}')) as get:
            client.login("1234", "@cmcc", secret, "10.4.2.3", "000000000000")
        url = get.call_args.args[0]
        params = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
        self.assertEqual(params["user_password"], [secret])
        self.assertEqual(params["user_account"], ["1234@cmcc"])
        self.assertEqual(urllib.parse.urlsplit(url).netloc, "10.2.5.251:801")

    def test_request_exceptions_do_not_expose_password_url(self):
        client = app.PortalClient()
        with patch.object(client, "get", side_effect=OSError("http://server/?user_password=SECRET")):
            message, _ = client.login("1234", "", "SECRET", "10.4.2.3", "000000000000")
        self.assertNotIn("SECRET", message)

    def test_unknown_response_does_not_echo_credentials(self):
        for body in (b'callback({"result":0,"msg":"SECRET"});', b'<html>SECRET</html>', b'[]'):
            message, _ = app.response_message(200, body)
            self.assertNotIn("SECRET", message)

    def test_known_errors_and_success_are_distinguished(self):
        self.assertTrue(app.response_message(200, b'{"result":0,"msg":"userid error2"}')[1])
        self.assertFalse(app.response_message(200, b'dr123({"result":1});')[1])
        self.assertFalse(app.response_message(302, b'')[1])

    def test_portal_parsing_and_fingerprint(self):
        self.assertEqual(app.parse_portal(PAGE, "10.4.2.3", True), ("10.4.2.3", "aabbccddeeff"))
        self.assertEqual(app.parse_portal("var user_ip = \"10.4.2.3\"; eportal", "10.4.2.3", True)[1], "000000000000")
        with self.assertRaises(app.LoginError):
            app.parse_portal(PAGE, "10.5.3.2", True)
        with self.assertRaises(app.LoginError):
            app.parse_portal("ordinary router login", "10.4.2.3", True)


class LoginFlowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = Path(self.temp.name)
        app.write_config(self.state, {"username": "1234", "operator": "中国移动", "verified": False})
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.addCleanup(self.temp.cleanup)
        self.wifi = self.stack.enter_context(patch.object(app, "wifi_interface", return_value="en0"))
        self.ssid = self.stack.enter_context(patch.object(app, "current_ssid", return_value=app.SSID))
        self.route = self.stack.enter_context(patch.object(app, "route_interface", return_value="en0"))
        self.ip = self.stack.enter_context(patch.object(app, "interface_ip", return_value="10.4.2.3"))
        self.client_class = self.stack.enter_context(patch.object(app, "PortalClient"))
        self.client = self.client_class.return_value
        self.client.info.return_value = PAGE
        self.client.login.return_value = ("接口受理成功，正在验证联网状态。", False)
        self.keychain_class = self.stack.enter_context(patch.object(app, "Keychain"))
        self.keychain_class.return_value.read.return_value = "SECRET"
        self.stack.enter_context(patch.object(app.time, "sleep"))

    def test_other_wifi_does_not_read_password_or_contact_portal(self):
        self.ssid.return_value = "Home"
        self.assertEqual(app.login_once(self.state), 2)
        self.keychain_class.assert_not_called()
        self.client_class.assert_not_called()

    def test_tun_route_never_reads_password(self):
        self.route.return_value = "utun4"
        self.assertEqual(app.login_once(self.state), 2)
        self.keychain_class.assert_not_called()
        self.client_class.assert_not_called()

    def test_no_campus_address_never_reads_password(self):
        self.ip.return_value = None
        self.assertEqual(app.login_once(self.state), 2)
        self.keychain_class.assert_not_called()

    def test_already_online_is_not_account_verification(self):
        self.client.online.return_value = True
        self.assertEqual(app.login_once(self.state, True), 0)
        self.keychain_class.assert_not_called()
        self.assertFalse(app.read_config(self.state)["verified"])

    def test_hidden_ssid_without_portal_fingerprint_never_reads_password(self):
        self.ssid.return_value = None
        self.client.online.return_value = False
        self.client.info.return_value = "router admin page"
        with self.assertRaises(app.LoginError):
            app.login_once(self.state)
        self.keychain_class.assert_not_called()

    def test_hidden_ssid_and_matching_portal_can_authenticate(self):
        self.ssid.return_value = None
        self.client.online.side_effect = [False, True]
        self.assertEqual(app.login_once(self.state, True), 0)
        self.client.login.assert_called_once_with("1234", "@cmcc", "SECRET", "10.4.2.3", "aabbccddeeff")
        self.assertTrue(app.read_config(self.state)["verified"])

    def test_interface_success_without_connectivity_never_verifies(self):
        self.client.online.return_value = False
        self.assertEqual(app.login_once(self.state, True), 1)
        self.assertEqual(self.client.login.call_count, 3)
        self.assertFalse(app.read_config(self.state)["verified"])

    def test_network_switch_during_login_prevents_submission(self):
        self.ssid.side_effect = [app.SSID, "Home"]
        self.client.online.return_value = False
        self.assertEqual(app.login_once(self.state), 2)
        self.client.login.assert_not_called()

    def test_permanent_failure_does_not_repeat_submissions(self):
        self.client.online.return_value = False
        self.client.login.return_value = ("账号或密码错误，请先在浏览器中确认。", True)
        self.assertEqual(app.login_once(self.state), 1)
        self.client.login.assert_called_once()

    def test_keychain_is_noninteractive_for_background(self):
        self.client.online.side_effect = [False, True]
        self.assertEqual(app.login_once(self.state), 0)
        self.keychain_class.assert_called_once_with(interactive=False)


class MacIntegrationTests(unittest.TestCase):
    def test_native_keychain_api_symbols_are_available_without_reading_passwords(self):
        # Only bind framework functions. No real keychain item is read/written.
        keychain = app.Keychain(interactive=False)
        self.assertTrue(callable(keychain.sec.SecKeychainAddGenericPassword))

    def test_plist_uses_separate_arguments_for_paths_with_spaces(self):
        state = Path("/tmp/Test Project/校园网")
        value = plistlib.loads(plistlib.dumps(app.make_plist("/opt/homebrew/bin/python3", state)))
        self.assertEqual(value["ProgramArguments"][1], str(state / "cumt_login.py"))
        self.assertEqual(value["StartInterval"], 60)
        self.assertTrue(value["RunAtLoad"])
        self.assertEqual(value["StandardOutPath"], "/dev/null")

    def test_configuration_has_no_password_and_private_permissions(self):
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp)
            app.write_config(state, {"username": "1234", "operator": "校园网", "verified": False})
            data = json.loads((state / "config.json").read_text())
            self.assertNotIn("password", data)
            self.assertEqual((state / "config.json").stat().st_mode & 0o777, 0o600)
            self.assertEqual(state.stat().st_mode & 0o777, 0o700)
            with self.assertRaises(app.LoginError):
                app.install(state)


if __name__ == "__main__":
    unittest.main()
