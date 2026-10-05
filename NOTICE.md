# 来源与改动

本项目基于 [Carl-K-Atlantic/CUMT-Network-Auto-Connect](https://github.com/Carl-K-Atlantic/CUMT-Network-Auto-Connect) 的 `Win/cumt_login.py` 适配。

- 上游作者：Carl-K-Atlantic（原仓库维护者）。
- 上游版本：`157294594f00eaf4309097fdb07545870dc21895`。
- 适配日期：2026-10-06。
- 原始脚本留存在 `upstream/cumt_login_windows.py`，仅供比对，不是 Mac 运行入口。
- 许可证：沿用 GNU AGPL v3，完整文本见 `LICENSE`。

保留上游的 Dr.COM/eportal 参数、会话 Cookie、运营商后缀和 204 联网验证思路。
Mac 适配增加：用户级 LaunchAgent、校园网环境检查、macOS 原生钥匙串、配置引导、任务互斥、日志轮转、凭据脱敏以及安装/卸载入口。
菜单栏版增加原生 AppKit 菜单和设置窗口、单次密码输入与显隐、独立开关、状态检测与当前终端注销；Python 通过本机管道接收凭据。
不沿用上游硬编码密码、无限前台循环和 MAC 缓存文件。

Apple 的 Security.framework 钥匙串接口用于本机凭据保存，不需要 Python 第三方库。

0.3.0 独立应用：认证逻辑已迁移到 Swift/Foundation URLSession，保留上游认证参数、Cookie 会话、运营商后缀和外网验证思路。应用不再启动 Python 进程；项目中的 Python 文件仅用于来源比对和开发测试。
