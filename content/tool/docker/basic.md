## basic instructions

**用images直接新run一个镜像：**

```cpp
docker run -d -it --network=host --gpus all --privileged --ipc=host --ulimit memlock=-1 --ulimit stack=67108864 -v /mnt/nfs:/workspace/  --name liuda crpi-w4le1oy1gd4wy3vu.cn-hangzhou.personal.cr.aliyuncs.com/ai-stack/liuda-deepmoe:te2.8
```

```cpp
docker run -d -it --network=host --gpus all --privileged --ipc=host --ulimit memlock=-1 --ulimit stack=67108864 -v /mnt/nfs/infra:/workspace/infrawaves/ --name cuda129 nvcr.io/nvidia/pytorch:25.06-py3
```

实例变成images：

```bash
docker commit a1b2c3d4e5f6 my_custom_cuda129_image
```

保存images:

```bash
docker save -o my_custom_cuda129_image.tar my_custom_cuda129_image
```

**删除一个镜像：**

```cpp
docker rm -f testori
```

**构建自定义镜像 `deepep-dual-port:ibgda`：**

```bash
docker build -t deepep-dual-port:ibgda .
```

**加载已有的 `.tar` 镜像包：**

```bash
docker load -i liuda-cuda129.tar
```

**以 `--gpus all` + 挂载 + 特权模式运行容器并命名为 `new`：**

```bash
docker run -d -it --network=host --gpus all --privileged --ipc=host --ulimit memlock=-1 --ulimit stack=67108864 -v /mnt/nfs/:/workspace/infrawaves --name new deepep-dual-port:ibgda
```

**以相同方式运行容器，命名为 `ibgda`：**

```bash
docker run -d -it --network=host --gpus all --privileged --ipc=host --ulimit memlock=-1 --ulimit stack=67108864 -v /mnt/nfs/:/workspace/infrawaves --name ibgda deepep-dual-port:ibgda
```

**运行阿里云镜像并挂载 `/model/share`，命名为 `testori`：**

```bash
docker run -d -it --network=host --gpus all --privileged --ipc=host --ulimit memlock=-1 --ulimit stack=67108864 -v /model/share/:/workspace/infrawaves/share --name testori crpi-w4le1oy1gd4wy3vu.cn-hangzhou.personal.cr.aliyuncs.com/ai-stack/ngc:24.10-py3-ssh
```
## 免密
方法1:
```cpp
apt-get update
apt-get install openssh-server -y 
apt-get install net-tools -y 

vim /etc/ssh/sshd_config
Port 3217    

vim /etc/ssh/ssh_config
StrictHostKeyChecking no
Port 3217

vim ~/.bashrc 
/etc/init.d/ssh restart

ssh-keygen 生成秘钥 并制作免密
把自己的公钥cat ~/.ssh/id_rsa.pub 放到 
~/.ssh/authorized_keys
自己登录自己一次
```
方法2:
```bash
# 使用 NVIDIA 官方 PyTorch 镜像作为基础镜像（已包含 CUDA 和 cuDNN）
FROM nvcr.io/nvidia/pytorch:25.09-py3

# 作者信息（可选）
LABEL maintainer="liuda@infrawaves.com"

# 设置默认工作目录
WORKDIR /infrawaves

# 安装必要的工具包
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssh-server \
        net-tools \
        vim \
        git \
        wget && \
    rm -rf /var/lib/apt/lists/*

# 配置 SSH 服务：更换端口、关闭 HostKey 检查
RUN mkdir -p /var/run/sshd && \
    sed -i 's/#Port 22/Port 3218/' /etc/ssh/sshd_config && \
    echo "StrictHostKeyChecking no" >> /etc/ssh/ssh_config && \
    echo "Port 3218" >> /etc/ssh/ssh_config
# 生成 SSH 密钥对（如果不存在），并配置免密登录
RUN ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa && \
    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys && \
    chmod 600 /root/.ssh/authorized_keys

# 保证 .ssh 目录权限正确（部分镜像有必要）
RUN chmod 700 /root/.ssh
# 默认启动时自动启动 ssh 服务（可选）
RUN echo '/etc/init.d/ssh restart' >> /root/.bashrc

# 恢复工作目录
WORKDIR /infrawave
```