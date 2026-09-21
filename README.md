# GUI GitLab Runner 启动脚本

该仓库维护 Windows 与 Linux 的 GUI/Shell Executor GitLab Runner 和 NBot 自启动脚本：

- `win/`：Windows Interactive 计划任务。
- `linux/`：Linux `systemd --user` 服务。

仓库只保存脚本、文档和无凭据样例，不保存以下本机内容：

- GitLab Runner 与 NBot 二进制。
- `config.toml`、`setup-nbot.conf` 和 `.runner_system_id`。
- 日志、build/cache 目录以及 Linux setup 生成的启动器。

部署时把对应平台目录复制到目标机器，放入平台二进制，将 `.example` 复制为正式配置并填写该机器独立签发的凭据，然后按平台 README 执行 `-WhatIf` 或 setup。

Windows 与 Linux 必须使用不同的 Runner 注册、token、ID、名称和平台 tags。
