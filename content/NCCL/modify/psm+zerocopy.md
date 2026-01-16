背景
引入registered buffer有两个初衷。其一，实现zero-copy，优化latency以及节省资源。其二，使用zero-copy避免了send/recv环节多次的send/recv操作，有可能解决无核训练hang问题。

Register buffer的升级主要体现在底层Net Transport和P2P Transport的实现中，现将这两部分的改动详述如下。
Net Transport
原生
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250917195406670.png)
无核
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250917195427130.png)
无核 with Register buffer
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250917195444004.png)
Net Transport with PXN
原生
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250917195501739.png)
无核 with Register buff
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250917195518936.png)
P2PTransport
无核
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250917195539744.png)

无核 with register buff
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250917195556993.png)