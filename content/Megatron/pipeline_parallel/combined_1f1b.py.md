目的：提升EP A2A的本身效率，把forward和backward的部分层拆到不同stream上去。DeepSeek用Dualpipe来创造overlap机会，然后megatron core内是用1F1B之间的调度来做batch之间forward和backward之间的EP A2A通信与计算overlap。

# 0 理论





# 3 代码
## 3.1 combined_forward_backward_step
会把相邻的两个micro-batch的前向和另一个反向对齐在同一时间窗口执行，然后用combined schedule plan把MoE的A2A放到通信stream上去（而不是之前的default stream）。
```python
def combined_forward_backward_step(
	...	
	forward()
	backward()
	forward post process()
	backward post process()
):
```
主要是backward内的run会走到`TransformerModelChunkSchedulePlan.run(...)`，在层级维度交错执行。
```python
type(f_schedule_plan or b_schedule_plan).run(
            f_schedule_plan,
            b_schedule_plan,
            b_grad=b_grad,
            pre_forward=pre_forward,
            pre_backward=pre_backward,
            post_forward=post_forward,
            post_backward=post_backward,
        )
```
