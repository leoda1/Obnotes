> 管什么：PTX 怎么读写、怎么在 CUDA 里嵌 PTX、怎么看编译器最后生成了什么。

## PTX 基础

### 语法与状态空间

### 查看 PTX 和 SASS

## 内联汇编

### 格式与约束符
```cpp
asm volatile("指令" : 输出 : 输入 : clobber);
```
- `"r"`：32 位寄存器；`"l"`：64 位寄存器（指针常用）。
- 什么时候要写 asm：指令没有对应 intrinsic，或 intrinsic 生成不出想要的变体（`.sem`、`.scope`、`.noftz` 等修饰）。

### volatile 与 memory clobber
`asm volatile(... : "memory")` 每个部分管一件事，前三个都只管编译器，不管硬件。

| 写法 | 管什么 | 不加会怎样 |
|---|---|---|
| `asm` | 写出编译器不会生成的指令 | 写不出来 |
| `volatile` | 不准删、不准合并、不准提到循环外 | `red` 这种没输出的指令可能被当死代码删掉；两次相同的 `red add 1` 被合成一次 |
| `"memory"` | 前后普通读写不准挪过它，寄存器缓存值先写回、之后重读 | 先写数据再发信号，写数据可能被挪到信号后面，对端读到旧值 |
| `.release` / `fence` | 别的线程、别的卡看到的顺序 | 编译器按顺序发了，硬件仍可能乱序可见 |

为什么编译器会删：它默认把 asm 当纯函数，输出没人用就删、输入一样就合并。`red`、`cp.async.bulk` 的作用全在副作用上，编译器看不出来，所以要 `volatile`。

```cpp
buf[i] = x;                                                    // 写数据
asm volatile("red.release.gpu.add.u64 [%0], 1;" :: "l"(flag)); // 发信号，缺 "memory" 就可能被越过
```

GCC 对没输出的 asm 默认当 volatile，但 nvcc / hgcc 不一定，习惯上显式写。
