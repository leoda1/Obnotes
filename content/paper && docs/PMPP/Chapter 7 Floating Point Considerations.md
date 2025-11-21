### 7.1 Floating-Point Format
浮点标准是IEEE 754于1985发布。**一个浮点数的system将数值表示位Bit Patterns（位模式）。** 由三组位表示：符号（Sign，S）、指数（Exponent，E）和尾数（Mantissa，M），每个（S，E，M）模式由以下公式唯一标识一个数值：
$$\mathrm{Value}=(-1)^\mathrm{S}\times\mathrm{M}\times\{2^\mathrm{E}\},\mathrm{~where~}1.0\leq\mathrm{M}<2.0\tag{1}$$
S是0现在就是正数，反之亦然。
#### 7.1.1 Normalized Representation of M
公式（1）内的M在十进制（D）上范围是[1, 2]，在二进制（B）上是 [1, 10）。0.5D可以表示为：$0.5_{D}=1.0_{B} × 2^{-1}$，或者$0.5_{D}=0.1_{B} × 2^{0}$ ，或者$0.5_{D}=10_{B} × 2^{-2}$。但是只有1.0B是符合M的范围的，所以就需要normalize。
在1.0B<= M <10.0B的限制下，每个浮点数就会有唯一合法的M。这样所有的M都会变成1.xxxx的形式，这样就可以省略 ‘1.’的部分。
再例如，10.75D等价于1010.11B，那么这里M就是1.01011，由于左移小数点三位，那么E就是3。
#### 7.1.2 Excess Encoding of E

![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250721234051100.png)
### 7.2 Representable Numbers

### 7.3 Special Bit patterns and Precision
### 7.4 Arithmetic Accuracy and Rounding

### 7.5 Algorithm Considerations 

### 7.6 Exercises

