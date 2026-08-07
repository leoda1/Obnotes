---
title: PPU 裸机安装配置 Mihomo 代理
date: 2026-08-05
tags: [claude-code, mihomo, proxy, ppu]
---

# 背景

在 `ppu` 服务器（Alibaba Cloud Linux 3, x86_64，非容器，裸机）上安装 [Mihomo](https://github.com/MetaCubeX/mihomo)（原 Clash Meta 内核），用订阅 URL 拉取代理节点，跑一个本地 HTTP/SOCKS 混合代理端口，供需要代理的进程按需使用。

> 安全提示：本文档中的 SSH 密码、订阅 token 均已替换为占位符，实际值不写入笔记。

---

## 0. 前置：非交互 SSH 登录（本机执行）

本机（macOS）没有 `sshpass`，且 `brew install hudochenkov/sshpass/sshpass` 因 Command Line Tools 过旧一度失败，改用系统自带的 `expect` 写自动登录脚本。

**踩坑点**：远程是 root 用户，shell 提示符结尾是 `# ` 不是 `$ `，用 `expect "$ "` 死活匹配不上，只能靠超时兜底，导致命令乱序、输出错位。修正为正则匹配 `[#\$] $`，并且干脆用「远程命令写入本地文件 + expect 从文件读取」的方式，避免命令行多层引号转义(订阅 URL 里有 `?`、`=`、`token=` 这类字符)。

`/tmp/ppu_ssh_file.sh`：

```bash
#!/usr/bin/expect -f
set timeout 90
set fname [lindex $argv 0]
set fp [open $fname r]
set remote_cmd [read $fp]
close $fp
log_user 1
spawn ssh ppu
expect {
    "password:" { send "<PPU_SSH_PASSWORD>\r" }
    "yes/no" { send "yes\r"; exp_continue }
}
expect -re {[#\$] $}
send -- "$remote_cmd\r"
expect -re {__CMD_DONE__}
send "exit\r"
expect eof
```

用法：把要在远程执行的命令写到一个文件（比如 `/tmp/remote_cmd.txt`），结尾加一行 `echo __CMD_DONE__` 作为完成标记，然后：

```bash
chmod +x /tmp/ppu_ssh_file.sh
/tmp/ppu_ssh_file.sh /tmp/remote_cmd.txt
```

---

## 1. 探测远程环境

```bash
uname -a
cat /etc/os-release | head -5
whoami
which mihomo clash
```

结果：Alibaba Cloud Linux 3 (Soaring Falcon)，x86_64，root，未安装 mihomo/clash。

---

## 2. 探测网络连通性（直连 GitHub 是否可用）

```bash
curl -m 8 -o /dev/null -s -w 'github: %{http_code} time:%{time_total}\n' https://github.com
curl -m 8 -o /dev/null -s -w 'raw.githubusercontent: %{http_code} time:%{time_total}\n' https://raw.githubusercontent.com
curl -m 8 -o /dev/null -s -w 'baidu: %{http_code}\n' https://www.baidu.com
```

结论：能连上但不稳定，后面下载 release 大文件时会暴露问题。

---

## 3. 查询 mihomo 最新版本 & 下载链接

```bash
curl -m 15 -sL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest -o /tmp/mihomo_release.json
grep -o '"tag_name": *"[^"]*"' /tmp/mihomo_release.json
grep -o 'https://github.com/MetaCubeX/mihomo/releases/download/[^"]*linux-amd64[^"]*' /tmp/mihomo_release.json
```

当时最新版本：`v1.19.29`，Alibaba Cloud Linux 是 RHEL 系，选 `.rpm` 包：

```
https://github.com/MetaCubeX/mihomo/releases/download/v1.19.29/mihomo-linux-amd64-v1.19.29.rpm
```

---

## 4. 直连下载失败排查

第一次、第二次直接 `curl`/`wget` 下载这个 rpm，两次拿到的文件大小完全不一样（1.2MB / 241KB），装的时候报错：

```
package mihomo-1.19.29-1.x86_64 does not verify: Payload SHA256 digest: BAD
```

用 `wget -c` 断点续传重试也复现了：

```
HTTP request sent, awaiting response... Read error (Success.) in headers.
Retrying.
...
Connecting to github.com|20.205.243.166|:443... failed: Connection timed out.
```

**结论**：直连 `github.com` 下载大文件时连接被反复打断/超时，不是文件本身问题（正常 mihomo 二进制应该在 15~20MB，之前下到的 1.2MB/241KB 都是被截断的坏文件）。

清理残留的僵尸下载进程：

```bash
pkill -9 -f 'wget.*mihomo'
```

---

## 5. 换用 GitHub 加速镜像下载

依次尝试几个公共镜像站，命中第一个可用的：

```bash
cd /tmp && rm -f mihomo.rpm
for M in 'https://ghfast.top/' 'https://gh-proxy.com/' 'https://mirror.ghproxy.com/'; do
  echo TRY:$M
  curl -m 30 -sL -o mihomo.rpm "${M}https://github.com/MetaCubeX/mihomo/releases/download/v1.19.29/mihomo-linux-amd64-v1.19.29.rpm" \
    -w 'code:%{http_code} size:%{size_download}\n'
  SZ=$(stat -c%s mihomo.rpm 2>/dev/null || echo 0)
  if [ "$SZ" -gt 1000000 ]; then
    echo GOT_IT_VIA:$M
    break
  fi
done
```

`https://ghfast.top/` 命中，拿到完整的 17.7MB 文件。

---

## 6. 校验并安装

```bash
file /tmp/mihomo.rpm
rpm -K --nosignature /tmp/mihomo.rpm      # 输出: digests OK
rpm -ivh --replacepkgs /tmp/mihomo.rpm
```

确认安装结果：

```bash
mihomo -v
which mihomo
rpm -ql mihomo-1.19.29-1
```

```
Mihomo Meta v1.19.29 linux amd64 with go1.26.5
Use tags: with_gvisor

/usr/bin/mihomo
/etc/mihomo/config.yaml
/usr/lib/systemd/system/mihomo.service
/usr/lib/systemd/system/mihomo@.service
/usr/share/licenses/mihomo/LICENSE
```

---

## 7. 写入订阅配置

选择方案：**HTTP/SOCKS 混合端口（`mixed-port`），非 TUN 全局代理**。

理由：这台机器是共享计算节点，还要靠 SSH 连上去跑训练/推理任务；TUN 模式会接管全机流量，一旦配置有问题可能直接把当前 SSH 连接搞断、影响其他用户任务。混合端口模式只影响手动设置了 `http_proxy`/`https_proxy` 环境变量的进程，风险小很多。

`/etc/mihomo/config.yaml`：

```yaml
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
external-controller: 127.0.0.1:9090

proxy-providers:
  my_sub:
    type: http
    url: "<你的订阅URL，形如 https://xxx.com/xxx?token=xxx>"
    interval: 3600
    path: /etc/mihomo/providers/my_sub.yaml
    health-check:
      enable: true
      interval: 600
      url: http://www.gstatic.com/generate_204

proxy-groups:
  - name: PROXY
    type: select
    use:
      - my_sub

rules:
  - MATCH,PROXY
```

写入并启动：

```bash
mkdir -p /etc/mihomo/providers
cat > /etc/mihomo/config.yaml <<'MIHOMOEOF'
# ...（同上）
MIHOMOEOF
systemctl enable --now mihomo
```

---

## 8. 验证

```bash
systemctl status mihomo --no-pager -l
journalctl -u mihomo --no-pager -n 40
curl -x http://127.0.0.1:7890 -m 10 -sI https://www.google.com
```

关键日志：

```
Mixed(http+socks) proxy listening at: 127.0.0.1:7890
Start initial provider my_sub
[TCP] mihomo --> xxx.com:443 match Match using PROXY[COMPATIBLE]
```

测试请求返回：

```
HTTP/1.1 200 Connection established
```

代理跑通。

---

## 9. 日常使用

```bash
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
```

只对设置了这两个环境变量的终端/进程生效（如 `curl`/`pip`/`git`），不影响其他会话和 SSH 本身。

常用运维命令：

```bash
systemctl restart mihomo          # 改完 config.yaml 后重启生效
systemctl status mihomo           # 查看运行状态
journalctl -u mihomo -f           # 实时看日志
curl http://127.0.0.1:9090/proxies | jq   # 查看当前节点列表（RESTful API）
```

---

## 待办 / 可选优化

- [ ] 按域名分流规则（国内直连、国外走代理），而不是全部 `MATCH,PROXY`
- [ ] 接入可视化面板（yacd / metacubexd）管理节点和规则
- [ ] 多订阅节点时配置 `url-test` 自动测速选优
