# -*- coding: utf-8 -*-
"""
中国矿业大学 CUMT_Stu 校园网自动登录（纯 HTTP 版，无需浏览器、无需安装任何第三方库）
协议已在真实网关上闭环实测验证（注销→离线→纯HTTP登录→204联网）：
  1) 访问认证页 http://10.2.5.251/ ，页面里写有服务器视角的本机 IP(v4ip) 与 MAC(olmac)，
     同时建立会话 Cookie（关键：后续登录接口靠它识别身份）；
  2) 带 Cookie 调用 Dr.COM eportal 登录接口(801端口)，提交 学号@运营商后缀 + 密码 + IP + MAC；
     MAC 不是必须的——页面自身 JS 的兜底就是 000000000000，无 MAC 时用全零即可；
  3) 用 generate_204 探测确认真正联网（返回 204 = 成功）。
"""
import os
import re
import json
import time
import socket
import urllib.parse
import urllib.request
import http.cookiejar

# ===================== 配置区（换账号/运营商只改这里） =====================
USER_ID  = "00000000"      # 纯学号，运营商后缀由下面 ISP 追加
PASSWORD = "000000"        # 融合门户密码
ISP      = ""              # 中国移动=@cmcc 中国电信=@telecom 中国联通=@unicom 校园网=""
PORTAL   = "http://10.2.5.251"
CHECK_URLS = [             # 在线探测：返回 HTTP 204 即视为已联网
    "http://connect.rom.miui.com/generate_204",
    "http://204.ustclug.org/",
]
INTERVAL = 30              # 在线巡检间隔（秒）
RETRY    = 3               # 登录重试次数
# ========================================================================

_opener = None


def log(msg):
    print(time.strftime("[%H:%M:%S] ") + msg, flush=True)


def get_opener():
    """带 Cookie 会话、强制绕过系统代理的 opener（全局复用）。"""
    global _opener
    if _opener is None:
        cj = http.cookiejar.CookieJar()
        _opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),          # 屏蔽 Clash 等系统代理
            urllib.request.HTTPCookieProcessor(cj),
        )
    return _opener


def http_get(url, timeout=6, referer=None):
    req = urllib.request.Request(url)
    if referer:
        req.add_header("Referer", referer)
    with get_opener().open(req, timeout=timeout) as r:
        return r.status, r.read()


def is_online():
    """任一探测地址返回 204 即已联网；未认证时会被网关劫持/超时。"""
    for url in CHECK_URLS:
        try:
            status, _ = http_get(url, timeout=5)
            if status == 204:
                return True
        except Exception:
            pass
    return False


def local_ip():
    """兜底取本机出口 IP：UDP connect 只查路由表，不真正发包。"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.2.5.251", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return None


def get_portal_info():
    """从认证页 HTML 解析服务器看到的本机 IP 与 MAC。返回 (ip, mac, err)。
    注意：刚掉线/刚注销的瞬间页面可能短暂缺失 olmac，因此重试几次；
    并把成功拿到的 MAC 缓存到脚本旁的 cumt_mac.txt，之后取不到时兜底。"""
    cache = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cumt_mac.txt")
    ip, mac, html = None, None, ""
    for attempt in range(4):
        try:
            _, body = http_get(PORTAL + "/", timeout=8)
            html = body.decode("gb2312", "ignore")
        except Exception as e:
            return None, None, "访问认证页失败：%s" % e

        m = re.search(r"v4ip\s*=\s*'([\d.]+)'", html)
        if m:
            ip = m.group(1)
        m = re.search(r"olmac\s*=\s*'([0-9A-Fa-f]{12})'", html)
        if m:
            mac = m.group(1).lower()
            try:  # 缓存 MAC，供以后页面缺失时兜底
                with open(cache, "w") as f:
                    f.write(mac)
            except Exception:
                pass
            break
        if attempt < 3:
            time.sleep(1)

    if not mac:  # 页面始终没给 MAC：用上次缓存的
        try:
            with open(cache) as f:
                t = f.read().strip()
                if re.fullmatch(r"[0-9a-f]{12}", t):
                    mac = t
        except Exception:
            pass
    if not ip:
        ip = local_ip()
    return ip, mac, None


def do_login(ip, mac):
    """调用 eportal 登录接口。返回服务器消息（仅供参考展示）。"""
    ts = int(time.time() * 1000)
    params = {
        "c": "Portal",
        "a": "login",
        "callback": "dr%d" % ts,
        "login_method": "1",
        "wlan_user_ip": ip or "",
        "wlan_user_ipv6": "",
        "wlan_user_mac": mac or "000000000000",  # 页面自带JS的兜底也是全零，靠会话Cookie识别
        "wlan_ac_ip": "",
        "wlan_ac_name": "",
        "portal_type": "1",
        "jsVersion": "3.0",
        "user_account": USER_ID + ISP,     # 如 00000000@cmcc
        "user_password": PASSWORD,
        "_": ts,
    }
    url = PORTAL + ":801/eportal/?" + urllib.parse.urlencode(params)
    try:
        _, body = http_get(url, timeout=8, referer=PORTAL + "/")
        txt = body.decode("utf-8", "ignore")
    except Exception as e:
        return "请求失败：%s" % e

    # 实测：服务器可能返回 JSONP，也可能 302 跳转到网页（此时认证仍会在服务端生效），
    # 因此这里只解析消息用于展示，成败一律以随后的 204 连通性探测为准。
    try:
        data = json.loads(txt[txt.find("(") + 1: txt.rfind(")")])
        return str(data.get("msg") or "") or ("result=" + str(data.get("result")))
    except Exception:
        if re.search(r'"result"\s*:\s*"?1"?', txt):
            return "认证成功"
        if txt.lstrip().lower().startswith("<!doctype") or "<html" in txt[:200].lower():
            return "服务器返回网页(302跳转)，以连通性探测为准"
        return txt.strip()[:80]


def try_login():
    log("检测到离线，开始自动登录...")
    ip, mac, err = get_portal_info()
    if err:
        print("  " + err, flush=True)
        return False
    if not ip:
        print("  获取本机IP失败：请确认已连接 CUMT_Stu", flush=True)
        return False
    print("  本机 IP=%s  MAC=%s  账号=%s" % (ip, mac or "(空)", USER_ID + ISP), flush=True)

    for i in range(1, RETRY + 1):
        msg = do_login(ip, mac)
        # 成败以“真正能上外网”为准（响应格式不可靠）
        for _ in range(10):
            if is_online():
                log("认证成功，已联网")
                return True
            time.sleep(1)
        print("  第%d次未成功：%s" % (i, msg or "未联网"), flush=True)
        time.sleep(2)
    log("登录失败：请核对密码/运营商，或设备数是否超限")
    return False


def main():
    print("CUMT 校园网自动登录（纯HTTP版，无需浏览器）账号 %s%s" % (USER_ID, ISP), flush=True)
    try:
        while True:
            try:
                if not is_online():
                    try_login()
            except KeyboardInterrupt:
                raise
            except Exception as e:
                print("异常：%r" % e, flush=True)
            time.sleep(INTERVAL)
    except KeyboardInterrupt:
        print("\n已退出", flush=True)


if __name__ == "__main__":
    main()
