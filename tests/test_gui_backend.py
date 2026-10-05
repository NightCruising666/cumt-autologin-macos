# SPDX-License-Identifier: AGPL-3.0-only
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import urllib.parse
import urllib.request

sys.path.insert(0, str(Path(__file__).parents[1]))
import gui_backend as gui

PAGE = "var v4ip='10.4.2.3';var olmac='aabbccddeeff'; // drcom"


class MenuBackendTests(unittest.TestCase):
    def setUp(self):
        for name, value in (("wifi_interface", "en0"), ("current_ssid", "CUMT_Stu"), ("route_interface", "en0"), ("interface_ip", "10.4.2.3")):
            mock = patch.object(gui.core, name, return_value=value)
            setattr(self, name, mock.start()); self.addCleanup(mock.stop)
        client = patch.object(gui.core, "PortalClient")
        self.client = client.start().return_value; self.addCleanup(client.stop)
        self.client.info.return_value = PAGE
        self.client.online.return_value = False
        self.client.login.return_value = ("接口成功，等待验证", False)
        sleep = patch.object(gui.time, "sleep"); sleep.start(); self.addCleanup(sleep.stop)

    def test_status_does_not_need_password(self):
        self.assertEqual(gui.dispatch("status", {})["state"], "offline")
        self.client.login.assert_not_called()

    def test_other_network_never_submits_credentials(self):
        self.current_ssid.return_value = "Home"
        self.assertEqual(gui.dispatch("login", {"password": "SECRET"})["state"], "outside")
        self.client.login.assert_not_called()
        self.client.get.assert_not_called()

    def test_tun_route_is_not_misreported_as_campus(self):
        self.route_interface.return_value = "utun4"
        self.assertEqual(gui.dispatch("status", {})["state"], "blocked")
        self.client.online.assert_not_called()

    def test_hidden_ssid_requires_portal_evidence_even_when_online(self):
        self.current_ssid.return_value = None
        self.client.online.return_value = True
        self.client.info.return_value = "an unrelated router page"
        with self.assertRaises(gui.core.LoginError):
            gui.dispatch("status", {})

    def test_login_requires_account_and_password(self):
        self.assertEqual(gui.dispatch("login", {})["state"], "error")
        self.client.login.assert_not_called()

    def test_manual_login_uses_selected_operator_and_checks_connectivity(self):
        self.client.online.side_effect = [False, True]
        response = gui.dispatch("login", {"username": "1234", "operator": "中国电信", "password": "SECRET"})
        self.assertTrue(response["authenticated"])
        self.client.login.assert_called_once_with("1234", "@telecom", "SECRET", "10.4.2.3", "aabbccddeeff")

    def test_permanent_login_failure_gets_cooldown(self):
        self.client.login.return_value = ("账号或密码错误", True)
        response = gui.dispatch("login", {"username": "1234", "operator": "校园网", "password": "SECRET"})
        self.assertEqual(response["retry_delay"], 900)
        self.client.login.assert_called_once()

    def test_logout_only_targets_current_terminal(self):
        self.client.get.return_value = (200, b'dr123({"result":1});')
        response = gui.dispatch("logout", {})
        self.assertTrue(response["logged_out"])
        url = self.client.get.call_args.args[0]
        parameters = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
        self.assertEqual(parameters["a"], ["logout"])
        self.assertEqual(parameters["wlan_user_ip"], ["10.4.2.3"])
        self.assertEqual(parameters["wlan_user_mac"], ["aabbccddeeff"])

    def test_logout_does_not_claim_success_if_online_probe_failed_only(self):
        self.client.get.return_value = (200, b'unknown response SECRET')
        response = gui.dispatch("logout", {})
        self.assertFalse(response["logged_out"])
        self.assertNotIn("SECRET", response["message"])

    def test_logout_success_response_is_not_enough_if_still_online(self):
        self.client.online.return_value = True
        self.client.get.return_value = (200, b'{"result":1}')
        self.assertFalse(gui.dispatch("logout", {})["logged_out"])

    def test_homepage_redirect_is_limited_to_school_host(self):
        handler = gui.core.PortalPageRedirect()
        request = urllib.request.Request("http://10.2.5.251/")
        self.assertIsNotNone(handler.redirect_request(request, None, 302, "", {}, "http://10.2.5.251/a70.htm"))
        self.assertIsNone(handler.redirect_request(request, None, 302, "", {}, "http://example.com/"))
        request = urllib.request.Request("http://10.2.5.251/?user_password=SECRET")
        self.assertIsNone(handler.redirect_request(request, None, 302, "", {}, "http://10.2.5.251/"))


if __name__ == "__main__":
    unittest.main()
