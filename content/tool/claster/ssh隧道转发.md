## 常用指令

| 指令                                     | 功能  |
| -------------------------------------- | --- |
| <br>mount 10.1.2.108:/mnt/nfs /mnt/nfs |     |
|                                        |     |
## vscode远程端口转发
1. 在你的本地电脑上，打开 SSH 配置文件 `~/.ssh/config`, 增加 下面的远程服务器配置：
   ```cpp
   Host my-remote-server
    HostName 192.168.x.x
    User root
    # 添加下面这一行
    # 格式: RemoteForward <远程端口> <本地地址>:<本地端口>
    RemoteForward 7897 127.0.0.1:7890
   ```
2. 在remote端 VSCode 设置里搜 http.proxy 并设置为 http://127.0.0.1:7897
3. 勾选 Use Local Proxy Configuration