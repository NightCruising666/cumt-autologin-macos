#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Adapted 2026-10-06 from Carl-K-Atlantic/CUMT-Network-Auto-Connect.
# See NOTICE.md and upstream/cumt_login_windows.py for provenance.
"""CUMT 南湖校园网：标准库 HTTP 认证、macOS 钥匙串、用户级 launchd。"""
import argparse
import ctypes
import fcntl
import getpass
import http.cookiejar
import ipaddress
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PORTAL = "http://10.2.5.251"
SSID = "CUMT_Stu"
LABEL = "local.cumt.autologin"
SERVICE = "CUMT-AutoLogin-Nanhu"
STATE = Path.home() / "Library/Application Support/CUMT-AutoLogin"
PLIST = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
OPERATORS = {"校园网": "", "中国移动": "@cmcc", "中国联通": "@unicom", "中国电信": "@telecom"}
CHECK_URLS = ("http://connect.rom.miui.com/generate_204", "http://204.ustclug.org/")
LOG = logging.getLogger(LABEL)


class LoginError(Exception):
    """Only user-safe, credential-free messages may be included here."""


def command(args, timeout=10):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


class Keychain:
    """Use native Security.framework; never pass passwords to shell/argv."""
    def __init__(self, interactive=True):
        self.sec = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
        self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        p, n, i = ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int32
        self.sec.SecKeychainFindGenericPassword.argtypes = [p, n, p, n, p, ctypes.POINTER(n), ctypes.POINTER(p), ctypes.POINTER(p)]
        self.sec.SecKeychainFindGenericPassword.restype = i
        self.sec.SecKeychainAddGenericPassword.argtypes = [p, n, p, n, p, n, p, ctypes.POINTER(p)]
        self.sec.SecKeychainAddGenericPassword.restype = i
        self.sec.SecKeychainItemModifyAttributesAndData.argtypes = [p, p, n, p]
        self.sec.SecKeychainItemModifyAttributesAndData.restype = i
        self.sec.SecKeychainItemFreeContent.argtypes = [p, p]
        self.sec.SecKeychainItemFreeContent.restype = i
        self.sec.SecKeychainItemDelete.argtypes = [p]
        self.sec.SecKeychainItemDelete.restype = i
        self.sec.SecKeychainSetUserInteractionAllowed.argtypes = [ctypes.c_bool]
        self.sec.SecKeychainSetUserInteractionAllowed.restype = i
        self.cf.CFRelease.argtypes = [p]
        self.cf.CFRelease.restype = None
        self.sec.SecKeychainSetUserInteractionAllowed(interactive)

    def find(self, account):
        service, account = SERVICE.encode(), account.encode()
        length, data, item = ctypes.c_uint32(), ctypes.c_void_p(), ctypes.c_void_p()
        status = self.sec.SecKeychainFindGenericPassword(None, len(service), service, len(account), account, ctypes.byref(length), ctypes.byref(data), ctypes.byref(item))
        if status == -25300:  # errSecItemNotFound
            return None, None
        if status:
            raise LoginError("无法读取钥匙串（状态 %d）；请解锁登录钥匙串，并运行“立即测试”授权当前 Python。" % status)
        try:
            password = ctypes.string_at(data, length.value).decode("utf-8")
        finally:
            self.sec.SecKeychainItemFreeContent(None, data)
        return password, item

    def read(self, account):
        password, item = self.find(account)
        if item:
            self.cf.CFRelease(item)
        if password is None:
            raise LoginError("钥匙串中没有校园网密码，请先运行“设置账号”。")
        return password

    def save(self, account, password):
        _, item = self.find(account)
        secret, account_bytes, service = password.encode(), account.encode(), SERVICE.encode()
        if item:
            try:
                status = self.sec.SecKeychainItemModifyAttributesAndData(item, None, len(secret), secret)
            finally:
                self.cf.CFRelease(item)
        else:
            status = self.sec.SecKeychainAddGenericPassword(None, len(service), service, len(account_bytes), account_bytes, len(secret), secret, None)
        if status:
            raise LoginError("密码保存到钥匙串失败（状态 %d）。" % status)

    def delete(self, account):
        _, item = self.find(account)
        if item:
            try:
                status = self.sec.SecKeychainItemDelete(item)
            finally:
                self.cf.CFRelease(item)
            if status:
                raise LoginError("钥匙串密码删除失败（状态 %d）。" % status)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # No credential-bearing redirects or false-positive 204s.


class PortalPageRedirect(urllib.request.HTTPRedirectHandler):
    max_redirections = 3

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        destination = urllib.parse.urlsplit(newurl)
        expected = urllib.parse.urlsplit(PORTAL)
        if (destination.scheme != expected.scheme or destination.netloc != expected.netloc
                or "user_password" in req.full_url or "user_password" in newurl):
            return None
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class PortalClient:
    def __init__(self):
        cookies = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(cookies),
            NoRedirect(),
        )
        self.page_opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(cookies),
            PortalPageRedirect(),
        )

    def get(self, url, timeout=5, referer=None, allow_portal_redirects=False):
        req = urllib.request.Request(url, headers={"User-Agent": "CUMT-AutoLogin-macOS/1.0"})
        if referer:
            req.add_header("Referer", referer)
        try:
            opener = self.page_opener if allow_portal_redirects else self.opener
            with opener.open(req, timeout=timeout) as response:
                return response.status, response.read(1024 * 1024)
        except urllib.error.HTTPError as exc:
            # A redirect after authentication may still mean server-side success.
            # Do not follow it; verify connectivity independently.
            try:
                return exc.code, exc.read(1024 * 1024)
            finally:
                exc.close()

    def online(self):
        for url in CHECK_URLS:
            try:
                status, body = self.get(url, timeout=3)
                if status == 204 and not body:
                    return True
            except (OSError, urllib.error.URLError):
                pass
        return False

    def info(self):
        try:
            status, body = self.get(PORTAL + "/", allow_portal_redirects=True)
        except (OSError, urllib.error.URLError):
            raise LoginError("校园网认证页不可达；请确认已连接 CUMT_Stu，稍后重试。") from None
        if status != 200:
            raise LoginError("认证页返回 HTTP %d，本次不提交账号密码。" % status)
        return body.decode("utf-8", "ignore")

    def login(self, username, suffix, password, ip, mac):
        ts = int(time.time() * 1000)
        params = {
            "c": "Portal", "a": "login", "callback": "dr%d" % ts,
            "login_method": "1", "user_account": username + suffix,
            "user_password": password, "wlan_user_ip": ip,
            "wlan_user_ipv6": "", "wlan_user_mac": mac,
            "wlan_ac_ip": "", "wlan_ac_name": "", "portal_type": "1",
            "jsVersion": "3.0", "_": ts,
        }
        try:
            status, body = self.get(PORTAL + ":801/eportal/?" + urllib.parse.urlencode(params), referer=PORTAL + "/")
        except (OSError, urllib.error.URLError):
            # str(exception) can contain the password-bearing request URL.
            return "认证请求未完成，请检查网络或代理。", False
        return response_message(status, body)


def response_message(status, body):
    if 300 <= status < 400:
        return "接口返回跳转，继续验证是否真正联网。", False
    if status != 200:
        return "认证接口返回 HTTP %d。" % status, False
    text = body.decode("utf-8", "ignore").strip()
    try:
        if not text.startswith("{"):
            text = text[text.index("(") + 1:text.rindex(")")]
        data = json.loads(text)
        if not isinstance(data, dict):
            raise ValueError()
    except (ValueError, TypeError):
        return "接口响应格式未知，继续验证联网状态。", False
    if str(data.get("result")) == "1":
        return "接口受理成功，正在验证联网状态。", False
    # Do not log unknown portal text: it may echo submitted credentials.
    import base64
    message = str(data.get("msg", ""))
    try:
        message += base64.b64decode(message, validate=True).decode("utf-8", "ignore")
    except (ValueError, TypeError):
        pass
    if "userid error1" in message or "用户不存在" in message:
        return "账号不存在或运营商选择错误，请重新设置账号。", True
    if "userid error2" in message or "密码" in message:
        return "账号或密码错误，请先在浏览器中确认。", True
    if "Limit Users" in message or "在线" in message and "限制" in message:
        return "在线设备数量已达上限，请在自助服务中下线旧设备。", True
    return "认证尚未成功，请检查账号、运营商或设备数限制。", False


def wifi_interface():
    _, text = command(["/usr/sbin/networksetup", "-listallhardwareports"])
    match = re.search(r"Hardware Port: (?:Wi-Fi|AirPort)\nDevice: (\S+)", text)
    return match.group(1) if match else None


def route_interface():
    _, text = command(["/sbin/route", "-n", "get", "10.2.5.251"])
    match = re.search(r"interface:\s*(\S+)", text)
    return match.group(1) if match else None


def current_ssid(interface):
    _, text = command(["/usr/sbin/networksetup", "-getairportnetwork", interface])
    match = re.search(r"Current (?:AirPort|Wi-Fi) Network:\s*(.+)", text)
    if match:
        value = match.group(1).strip()
        if value not in ("<redacted>", "<hidden>"):
            return value
    # New macOS can hide SSID even when Wi-Fi is connected. Do not treat
    # “not associated” as proof of disconnection; gate on route + portal.
    return None


def interface_ip(interface):
    code, text = command(["/usr/sbin/ipconfig", "getifaddr", interface])
    value = text.strip()
    try:
        if code == 0 and ipaddress.IPv4Address(value).is_private and value.startswith("10."):
            return value
    except ipaddress.AddressValueError:
        pass
    return None


def parse_portal(html, local_ip, require_fingerprint=False):
    match = re.search(r"\b(?:v4ip|wlan_user_ip|user_ip)\s*=\s*['\"]([\d.]+)['\"]", html)
    ip = match.group(1) if match else local_ip
    try:
        ipaddress.IPv4Address(ip)
    except (ipaddress.AddressValueError, TypeError):
        raise LoginError("无法识别认证页中的终端地址，本次不登录。") from None
    if ip != local_ip:
        raise LoginError("认证页终端地址与 Wi-Fi 地址不一致，本次不登录；请检查 TUN 或虚拟网卡。")
    if require_fingerprint:
        # SSID unavailable: only accept the expected school address plus
        # Dr.COM's terminal-IP assignment. Never accept an arbitrary web page.
        fingerprint = match and re.search(r"(?:drcom|eportal|哆点)", html, re.I)
        if not fingerprint:
            raise LoginError("SSID 被系统隐藏，且页面不符合校园网认证特征，本次不提交密码。")
    mac_match = re.search(r"\b(?:olmac|wlan_user_mac|user_mac)\s*=\s*['\"]([0-9a-fA-F:.-]+)['\"]", html)
    mac = re.sub(r"[:.-]", "", mac_match.group(1)).lower() if mac_match else ""
    if not re.fullmatch(r"[0-9a-f]{12}", mac):
        mac = "000000000000"
    return ip, mac


def read_config(state):
    try:
        config = json.loads((state / "config.json").read_text())
    except (OSError, ValueError):
        raise LoginError("未配置账号，请先运行“设置账号”。") from None
    if not isinstance(config, dict) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", str(config.get("username", ""))):
        raise LoginError("账号配置无效，请重新设置。")
    if config.get("operator") not in OPERATORS:
        raise LoginError("运营商配置无效，请重新设置。")
    return config


def write_config(state, config):
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(state, 0o700)
    temp = state / "config.json.tmp"
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as file:
        json.dump(config, file, ensure_ascii=False, indent=2)
        file.write("\n")
    os.chmod(temp, 0o600)
    temp.replace(state / "config.json")


def setup(state):
    print("中国矿业大学南湖校区 · CUMT_Stu 自动登录设置")
    print("账号密码只在本机录入；密码保存到 macOS 钥匙串。")
    username = input("学号/工号（不含运营商后缀）：").strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", username):
        raise LoginError("账号格式不正确。")
    operators = list(OPERATORS)
    for index, name in enumerate(operators, 1):
        print("%d. %s" % (index, name))
    choice = input("选择运营商（1–4）：").strip()
    if choice not in ("1", "2", "3", "4"):
        raise LoginError("请输入 1–4。")
    password = getpass.getpass("校园网密码（输入不显示）：")
    if not password:
        raise LoginError("密码不能为空。")
    previous = None
    if (state / "config.json").exists():
        previous = read_config(state)["username"]
    keychain = Keychain()
    keychain.save(username, password)
    write_config(state, {"username": username, "operator": operators[int(choice) - 1], "verified": False})
    if previous and previous != username:
        keychain.delete(previous)
    print("设置完成。请先在浏览器注销校园网，再运行“立即测试”。")


def login_once(state, interactive=False):
    config = read_config(state)
    interface = wifi_interface()
    if not interface:
        LOG.info("未找到 Wi-Fi 网卡，本次跳过。")
        return 2
    ssid = current_ssid(interface)
    if ssid is not None and ssid != SSID:
        LOG.info("当前 Wi-Fi 不是 CUMT_Stu，本次跳过。")
        return 2
    route = route_interface()
    if route != interface:
        LOG.info("校园网路由未经过 Wi-Fi 网卡；若使用代理，请关闭 TUN 或将 10.2.5.251 设为直连。本次跳过。")
        return 2
    ip = interface_ip(interface)
    if not ip:
        LOG.info("Wi-Fi 尚未取得校园网 IPv4 地址，本次跳过。")
        return 2
    client = PortalClient()
    if client.online():
        LOG.info("已联网，无需重复认证。")
        if interactive and not config.get("verified"):
            LOG.info("尚未验证本工具的账号；请在浏览器注销后再运行“立即测试”。")
        return 0
    html = client.info()  # Session cookie is reused by login().
    ip, mac = parse_portal(html, ip, require_fingerprint=ssid is None)
    if ssid is None:
        LOG.info("系统未提供 SSID，已通过 Wi-Fi 路由、终端 IP 和校园门户特征确认环境。")
    password = Keychain(interactive=interactive).read(config["username"])
    for attempt in range(1, 4):
        # Recheck before every password submission: user may change network
        # while a previous attempt is waiting for the gateway.
        now_ssid = current_ssid(interface)
        if route_interface() != interface or interface_ip(interface) != ip or (now_ssid is not None and now_ssid != SSID):
            LOG.info("网络环境发生变化，停止认证。")
            return 2
        LOG.info("开始第 %d/3 次认证。", attempt)
        message, permanent_failure = client.login(config["username"], OPERATORS[config["operator"]], password, ip, mac)
        LOG.info(message)
        for probe in range(3):
            if client.online():
                LOG.info("认证成功，外网检查通过。")
                if interactive:
                    config["verified"] = True
                    write_config(state, config)
                return 0
            if permanent_failure:
                break
            if probe < 2:
                time.sleep(2)
        if permanent_failure:
            break
        if attempt < 3:
            time.sleep(3)
    LOG.error("未能确认联网；请检查密码、运营商和设备数限制。没有自动注销其他设备。")
    return 1


def make_plist(python, state):
    return {
        "Label": LABEL,
        "ProgramArguments": [str(python), str(state / "cumt_login.py"), "--state-dir", str(state), "run"],
        "RunAtLoad": True, "StartInterval": 60,
        "ProcessType": "Background", "WorkingDirectory": str(state),
        # Application logs already rotate; avoid unbounded launchd duplicates.
        "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
    }


def install(state):
    config = read_config(state)
    if not config.get("verified"):
        raise LoginError("请先在浏览器注销校园网，再运行“立即测试”；认证成功后才能安装后台任务。")
    source = Path(__file__).resolve()
    target = state / "cumt_login.py"
    if source != target.resolve():
        shutil.copy2(source, target)
    os.chmod(target, 0o700)
    for name in ("README.md", "LICENSE", "NOTICE.md"):
        origin = source.parent / name
        if origin.exists() and origin.resolve() != (state / name).resolve():
            shutil.copy2(origin, state / name)
    python = Path(sys.executable).absolute()
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    PLIST.write_bytes(plistlib.dumps(make_plist(python, state)))
    os.chmod(PLIST, 0o600)
    domain = "gui/%d" % os.getuid()
    command(["/bin/launchctl", "bootout", domain, str(PLIST)])
    code, _ = command(["/bin/launchctl", "bootstrap", domain, str(PLIST)])
    if code:
        raise LoginError("文件已安装，但后台任务加载失败；请在当前 Mac 桌面登录会话中重新安装。")
    print("后台任务已安装：登录 Mac 后运行，每 60 秒检查一次；唤醒后也会继续检查。")
    print("程序已复制到：%s；现在可以移动或删除下载包。" % state)


def uninstall(state, delete_data=False):
    domain = "gui/%d" % os.getuid()
    command(["/bin/launchctl", "bootout", domain, str(PLIST)])
    PLIST.unlink(missing_ok=True)
    print("后台任务已移除。")
    if delete_data:
        if (state / "config.json").exists():
            Keychain().delete(read_config(state)["username"])
        # Delete only files belonging to this app, never an arbitrary directory.
        for name in ("cumt_login.py", "config.json", "config.json.tmp", "autologin.log", "autologin.log.1", "launchd.out.log", "launchd.err.log", "run.lock", "README.md", "LICENSE", "NOTICE.md"):
            (state / name).unlink(missing_ok=True)
        try:
            state.rmdir()
        except OSError:
            pass
        print("已删除本工具的账号配置、钥匙串密码和日志。")
    else:
        print("账号配置和钥匙串密码保留；彻底删除可执行 uninstall --delete-data。")


def status(state):
    print("账号配置：%s" % ("存在" if (state / "config.json").exists() else "未设置"))
    print("后台任务文件：%s" % ("存在" if PLIST.exists() else "未安装"))
    code, _ = command(["/bin/launchctl", "print", "gui/%d/%s" % (os.getuid(), LABEL)])
    print("后台任务：%s" % ("已加载" if code == 0 else "未加载"))
    interface = wifi_interface()
    print("Wi-Fi：%s" % ("识别到 " + interface if interface else "未识别"))
    print("SSID：%s" % ((current_ssid(interface) or "系统未提供（可能被隐藏）") if interface else "未知"))
    print("认证页路由网卡：%s" % (route_interface() or "未知"))
    print("日志：%s" % (state / "autologin.log"))
    log = state / "autologin.log"
    if log.exists():
        print("\n最近日志：\n" + "\n".join(log.read_text().splitlines()[-12:]))


def init_logging(state):
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(state, 0o700)
    handler = RotatingFileHandler(state / "autologin.log", maxBytes=512 * 1024, backupCount=1, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    LOG.addHandler(handler)
    LOG.addHandler(logging.StreamHandler(sys.stdout))
    LOG.setLevel(logging.INFO)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=STATE)
    sub = parser.add_subparsers(dest="action", required=True)
    for action in ("setup", "check", "run", "install", "status"):
        sub.add_parser(action)
    remove = sub.add_parser("uninstall")
    remove.add_argument("--delete-data", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("本版本仅支持 macOS。")
    if sys.version_info < (3, 10):
        parser.error("需要 Python 3.10 或更高版本。")
    os.umask(0o077)
    try:
        if args.action == "setup":
            setup(args.state_dir)
        elif args.action in ("run", "check"):
            init_logging(args.state_dir)
            with (args.state_dir / "run.lock").open("a") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    LOG.info("已有认证检查正在运行，本次跳过。")
                    return 0
                return login_once(args.state_dir, interactive=args.action == "check")
        elif args.action == "install":
            install(args.state_dir)
        elif args.action == "status":
            status(args.state_dir)
        else:
            uninstall(args.state_dir, args.delete_data)
        return 0
    except LoginError as exc:
        if LOG.handlers:
            LOG.error(str(exc))
        else:
            print("错误：%s" % exc, file=sys.stderr)
        return 1
    except (OSError, ValueError):
        # Never dump request URLs or native-keychain data in a traceback.
        print("操作失败；请检查文件权限、网络状态和 Python 环境。", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
