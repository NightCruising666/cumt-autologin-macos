#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""JSON-only bridge for the menu-bar app; passwords arrive through stdin."""
import json
import re
import sys
import time
import urllib.parse

import cumt_login as core


def result(state, message, **extra):
    return {"state": state, "message": message, **extra}


def environment():
    interface = core.wifi_interface()
    if not interface:
        return None, result("outside", "未找到 Wi-Fi 网卡")
    ssid = core.current_ssid(interface)
    if ssid is not None and ssid != core.SSID:
        return None, result("outside", "当前未连接 CUMT_Stu")
    if core.route_interface() != interface:
        return None, result("blocked", "校园网路由未走 Wi-Fi，请检查 TUN/VPN")
    ip = core.interface_ip(interface)
    if not ip:
        return None, result("outside", "尚未获得校园网地址")
    return (interface, ssid, ip), None


def dispatch(action, payload):
    env, error = environment()
    if error:
        return error
    interface, ssid, ip = env
    client = core.PortalClient()
    online = client.online()
    # For hidden SSIDs, validate the portal even when internet is reachable:
    # an internet connection through an unrelated 10.x Wi-Fi is not campus evidence.
    html = client.info()
    ip, mac = core.parse_portal(html, ip, require_fingerprint=ssid is None)
    if action == "status":
        return result("online" if online else "offline", "校园网已联网" if online else "已连接校园 Wi-Fi，尚未联网")
    if action == "login":
        if online:
            return result("online", "已联网，无需重复认证", authenticated=False)
        username = str(payload.get("username", ""))
        operator = payload.get("operator", "")
        password = payload.get("password", "")
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", username) or operator not in core.OPERATORS or not isinstance(password, str) or not password:
            return result("error", "请先在详细设置中填写账号、密码和运营商")
        message = "登录未成功"
        permanent = False
        for attempt in range(3):
            now, error = environment()
            if error or now[0] != interface or now[2] != ip:
                return error or result("outside", "网络发生变化，已停止认证")
            message, permanent = client.login(username, core.OPERATORS[operator], password, ip, mac)
            for probe in range(3):
                if client.online():
                    return result("online", "认证成功，外网检查通过", authenticated=True)
                if permanent:
                    break
                time.sleep(1)
            if permanent:
                break
            if attempt < 2:
                time.sleep(2)
        return result("offline", message, retry_delay=900 if permanent else 300)
    if action == "logout":
        # Only terminate this terminal's session; don't supply another user's identity.
        now, error = environment()
        if error or now[2] != ip:
            return error or result("outside", "网络发生变化，已停止注销")
        ts = int(time.time() * 1000)
        params = {
            "c": "Portal", "a": "logout", "callback": "dr%d" % ts,
            "login_method": "1", "user_account": "drcom", "user_password": "123",
            "ac_logout": "0", "wlan_user_ip": ip, "wlan_user_ipv6": "",
            "wlan_vlan_id": "1", "wlan_user_mac": mac, "wlan_ac_ip": "",
            "wlan_ac_name": "", "jsVersion": "3.0", "_": ts,
        }
        status, body = client.get(core.PORTAL + ":801/eportal/?" + urllib.parse.urlencode(params), referer=core.PORTAL + "/")
        text = body.decode("utf-8", "ignore").strip()
        try:
            if not text.startswith("{"):
                text = text[text.index("(") + 1:text.rindex(")")]
            data = json.loads(text)
            accepted = status == 200 and isinstance(data, dict) and str(data.get("result")) == "1"
        except (ValueError, TypeError):
            accepted = False
        time.sleep(1)
        still_online = client.online()
        if accepted and not still_online:
            return result("offline", "已注销当前设备，自动登录已暂停", logged_out=True)
        return result("online" if still_online else "unknown", "暂未确认注销成功；自动登录已暂停，可打开登录页检查", logged_out=False)
    return result("error", "未知操作")


def main():
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise ValueError()
        output = dispatch(sys.argv[1], payload)
    except core.LoginError as exc:
        output = result("error", str(exc))
    except Exception:
        # Never serialize raw exceptions; they can include a credential URL.
        output = result("error", "检测请求未完成，请检查网络后重试")
    print(json.dumps(output, ensure_ascii=False))


if __name__ == "__main__":
    main()
