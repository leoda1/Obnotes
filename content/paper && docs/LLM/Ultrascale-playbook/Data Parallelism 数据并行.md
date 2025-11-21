## 0. define
DP 就是在多个GPU上复制模型，对每个GPU上的不同Micro Batch Size 数据并行执行前向和反向传播，所以叫DP。
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250916201611414.png)
不同的mb在每个GPU上的gradients不同，为了保持不同GPU上的model instance同步，会在backward的时候optimizer之前调nccl AR(Allreduce)，对model instances的gradients求一个average。
# 1. 优化
在训练开SP的时候，机内TP通信会用RS+AG完成一次AllReduce的操作，如果不开SP就是直接一次AR。nsys的日志如下，看到真实训练的dense model的Allreduce操作都在第三条stream上进行。第一条的default上全是计算的kernel，可以看到AR得操作是和kernel的计算overlap的(but会有sm的竞争)。
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250916203405917.png)
huggingface的文章里面提到三种优化
## 1.1 hook的方式
torch内比较经典的操作hook(钩子)，模型的参数会附带一个AR操作的钩子。钩子的作用就是钓鱼，鱼咬了就上钩。这里就是gradient准备好的时候就会调用AR操作。
## 1.2 Bucketing Gradients
意思是少次大size数据比多次小数据操作更高效。装满了一个桶才会启动一次AR。
## 1.3 DP 与梯度累计的相互作用
**在gradient accumulation和DP组合使用时，同步gradient需要格外小心。** 另外1.1的方案不是最优解，因为一个accumulation周期内最后一次backward结束之后只用调用一次AR操作，也可以得到累加的结果。在torch内会用 `no_sync()` 来让gpu不同步。

经过第二第三步骤之后，会发生的变化如下。
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250916210321314.png)
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250916210300076.png)

# 2. Global Batch Size
在megatron内会看到micro_batch，也会看到global_batch。此外还有gradient accumulation的参数，那么batchsize的公式就变为：
$$ 
bs = gbs = mbs × gas × dp
$$
*  mbs: micro batch size  
*  gas: 是 gradient accumulation step 数量
*  dp: 是并行实例数量

**在实践中,人们倾向于尽可能最大化数据并行节点(DP)的数量,超过梯度累积,因为它是固 有的并行,与梯度累积的顺序性质不同。然后在数据并行扩展不足以在用完 GPU 之前达到目标  全局批次大小时,将梯度累积添加到数据并行之上。**
如果有全局的batch size gbs，那么就可以用DP过程来交换gradient accumulation step，加快训练。
使用DP开始训练的4个步骤：
* 确定GBST（global batch size tokens，训练过程全局batch，这是跨all gpus的，所有accumulations的）总大小。
* 确定2-8K用多长的Sequence
* 确定mbs（maximum local batch size），这是单个gpu上最大的local batch。在megatron内也叫micro-batch size。
* 确定DP可用的GPU数量。上面的公式可以化简一下就会知道gas的分子gbs是死的，那么现在就得去调整dp和mbs数来控制gas。
gas如果低于1，就说明你现在十分富裕，有过多GPU。化简一下后会发现：
$$
gas=\frac{GB}{\text{{mbs} $\times$ {dp}}}, dp = \frac{GPUs}{PP*TP}
$$
随着GPU的数量增加，dp变大，gas变小，训练速度变得更快。网络（机间走IB、Roce）的带宽大约50Gb/s，即使8张网卡，bw来到400GB/s。继续增加GPU的数量之后，网络需求变大会降低训练的Throughput。
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250917210303150.png)
达到一定规模后通信开销的限制出现了很多其他优化方案；
* 并行：TP， CP，PP。这三种是侧重于加速计算，把计算分给多个gpu，减少training or inference的时间
* 共享：Zero1，Zero2，Zero3(FSDP)。侧重于优化内存，tile存储模型的status，减少单个gpu的内存压力
## ZeRO
DP会将❶Optimizer、❷gradients和❸params在DP rank上简单复制。ZeRO通过在数据并行纬度上划分这三项来消除内存的冗余，但是仍然使用完整的参数做计算。
* ZeRO-1就是❶
* ZeRO-2就是❶+❷
* ZeRO-3（FSDP）就是❶+❷+❸