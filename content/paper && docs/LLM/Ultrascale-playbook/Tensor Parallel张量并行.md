## 0. 简单定义  && 按列切
X * w=Y的矩阵乘法，这里的权重w按照列拆分就可以让权重被激活的时候内存减少。w拆成两列的话，激活的内存至少就节省一半。
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250923113602726.png)
## 1. 行切
就是把w按照行来切，同时输入X也需要切。只需要控制好X的列宽等于w的行宽。
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250923114217191.png)
## 2. Transformer中的TP

