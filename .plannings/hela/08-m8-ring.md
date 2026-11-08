# M8：`core:hela/ring` —— 把布局能力落到一个真实并发库上

> 前七个里程碑都是在**造工具**：导出清单、断言、校验、diff、门禁。
> 这一轮开始用它们：写一个真的能用、真的会被测量、真的会因布局而快慢的并发库。
> 目标不是「再加一个 ring buffer」，而是让「布局即语义」这件事在一个完整程序里成立。

## 1. 为什么从这里接

用户的原始目标是「学习如何写高并发、高性能、高吞吐量的库和项目」。
编译器侧的能力（`#explicit`、`layout_*`、清单、`golden.hash`）都只是**使能器**；
如果不用它们写出一个能测出差异的库，这条链路就只是文档。

所以 M8 的验收标准是三条：

1. 库本身正确（单线程、环绕、双线程、TSAN 干净）；
2. 库的布局在编译期被钉死（`#assert` 到字节）；
3. 布局改变能让测出来的数字改变（不是断言，是实测）。

## 2. `core:hela/ring`：SPSC 环形队列

算法是教科书式的 Lamport/Vyukov 有界队列，没有新东西。新型的是**把布局写在类型里**：

```odin
Ring :: struct($T: typeid) #explicit #align(Cache_Line) {
	head: u64,  _: [Cache_Line-8]u8,          // cache line 0：只有生产者写
	tail: u64,  _: [Cache_Line-8]u8,          // cache line 1：只有消费者写
	slots: []T, mask: u64, _: [Cache_Line-16-8]u8, // cache line 2：init 之后只读
}
```

三个设计决定，每一个都有理由：

| 决定 | 理由 |
|---|---|
| `#explicit` | 编译器不允许插入任何它自己算出来的 padding。任何「我以为没有空隙」的误解都会在编译期炸掉，而不是在 perf 上炸掉。 |
| `#align(Cache_Line)` | 保证整个结构按行对齐，`head` 才会真的落在行首；否则 `head` 和 `tail` 可能跨行，一行变两行。 |
| `head`/`tail` 分居两行 | 这是全部意义所在：写 `head` 不使消费者的行失效，反之亦然。 |

参数化 struct（`Ring($T)`）与 `#explicit` 可以共存——这是 M3 实现时没有验证过的组合，本轮补上了。
副作用：`#explicit` 的空隙检查发生在**实例化之后**，错误信息会同时指出声明处和实例化处，这反而是想要的。

### API 与内存序

```odin
push :: proc(r: ^Ring($T), value: T) -> bool
pop  :: proc(r: ^Ring($T)) -> (T, bool)
```

内存序的选择不是抄来的，是推出来的：

| 操作 | 序 | 理由 |
|---|---|---|
| 读自己的游标 | `Relaxed` | 只有本线程写它，不需要和任何人同步 |
| 读对方的游标 | `Acquire` | 需要看见对方 `Release` 之前的**槽位写入** |
| 写自己的游标 | `Release` | 把「槽位已写好」这件事发布出去 |

`head - tail` 用的是 u64 环绕减法，从不和容量比较，所以不需要 `%`，只需要 `& mask`
——这也是容量必须是 2 的幂的原因，`init` 会直接拒绝其它值。

## 3. 编译期的布局断言

`tests/hela/ring/main.odin` 开头是一串 `#assert`，它们才是这个测试的主体：

```odin
#assert(size_of(Counters) == 3 * Cache_Line)
#assert(offset_of_by_string(Counters, "head") == 0)
#assert(offset_of_by_string(Counters, "tail") == Cache_Line)
#assert(offset_of_by_string(Counters, "slots") == 2 * Cache_Line)
#assert(intrinsics.layout_padding_of(Counters) == 0)
#assert(intrinsics.layout_cache_lines_of(Counters) == 3)
#assert(offset_of_by_string(Counters, "tail") - offset_of_by_string(Counters, "head") >= Cache_Line)
```

最后一条是重点：**它不描述布局，它描述意图**——「两个游标不在同一行」。
前面几条只是这个意图在今天的实现方式；将来若改用 128 字节行的 padding，只有这一条不需要改。

## 4. 伪共享：实测而不是断言

`tests/hela/ring/false_sharing.odin` 里有两个计数器、两个线程，各写各的：

```
Counters_Shared  a@0,  b@8    // 同一行
Counters_Split   a@0,  b@64   // 各自一行
```

没有任何一个字节被两个线程同时写，所以这不是 data race，不加任何同步也是正确的；
它只是**布局错误**。实测（Apple Silicon，`-o:speed`，多次运行取范围）：

| 布局 | 吞吐 | 相对 |
|---|---|---|
| 两个计数器同一 cache line | 122 – 150 M inc/s | 1.00x |
| 各占一个 cache line | 492 – 565 M inc/s | **3.5 – 4.1x** |

同样的代码、同样的循环次数，仅靠 padding 就有 3–4 倍差距。这就是「布局是一等公民」的最短证明。

### 两个踩过的坑，都记在这里

**坑一：`j.cell^ += 1` 测不出任何东西。** 第一次跑出来是 1.02x，因为优化器把循环里的普通 store
合并成了循环外的单次 store（非原子写没有可观察的中间状态）。改用 `sync.atomic_add`（RMW 无法被
合并）之后才测到真实的 3.8x。教训：**度量伪共享必须用不会被优化掉的写**。

**坑二：ring 的对比数据不可信，所以删掉了。** 最初也给 `Bad_Ring` 和 `ring.Ring` 做了同样的
吞吐对比，结果是 0.95x – 3.31x 之间乱跳。原因是游标是**读多写少**的，两边各缓存对方的游标，
真实伪共享本来就弱；剩下的差异被线程调度和栈上分配位置淹没了。
所以最终只保留编译期对比（`Bad_Ring` 全部挤在一行 vs `Ring` 三行），把噪声源去掉。
**能测出差异的才打印数字，测不出的就诚实地说测不出。**

## 5. TSAN

```sh
HELA_TSAN=1 ./tests/hela/run.sh
```

跑 `odin build tests/hela/ring -sanitize:thread`，`otool -L` 确认链接了
`libclang_rt.tsan_osx_dynamic.dylib`，运行无 data race 报告。
这验证的是 acquire/release 配对是对的，不是布局对——两者必须分别验证，因为
「对齐完美但内存序错误」是这类代码最常见的翻车方式。

TSAN 下数字会掉到 1.5x 左右（插桩本身会串行化一部分访存），这是正常的，不作为结论。

## 6. 顺带发现的上游问题

给 `core/hela/ring` 单独跑 `-vet-unused` 会误报 `'sync' declared but not used`。
最小复现（`.odin` 同样复现，所以不是 Hela 引入的）：

```odin
package vt
import "core:sync"
R :: struct($T: typeid) { x: u64 }
f :: proc(r: ^R($T)) { sync.atomic_store(&r.x, 0) }   // 报 sync 未使用
```

去掉 `$T` 参数化就正常。原因是**多态过程体在被实例化之前不做检查**，因此体内对 `sync` 的引用
从未被记录。这不是我们要修的 bug（修它会动 checker 主干，且属于上游行为），记录在此以免以后再踩。
实践中不构成问题：`tests/hela/ring` 实例化了每一种用法，`-vet` 全绿。

## 7. 改动的文件

| 文件 | 内容 |
|---|---|
| `core/hela/ring/spsc.odin` | **新增**。`Ring($T)` + `init/destroy/push/pop/len/capacity/is_empty/is_full` + 阻塞变体 |
| `tests/hela/ring/main.odin` | **新增**。13 条布局 `#assert` + 单线程 / 环绕 / 双线程正确性 + 吞吐打印 |
| `tests/hela/ring/false_sharing.odin` | **新增**。伪共享实测 + `Bad_Ring` 编译期对照 |
| `tests/hela/run.sh` | 增第 8 步（ring）与可选的 TSAN 步骤 |

## 8. 下一步

1. `core:hela/queue`：Vyukov MPSC，游标同样是 cache-line 显式；需要一个「序列号 per slot」的布局。
2. `core:hela/exec`：thread-per-core 运行时（每核一个 SPSC 队列 + 核间投递），把 `Ring` 用起来。
3. 基准框架：现在的手写计时有线程启动开销，需要预热 + 多轮取中位数 + 循环展开的固定工作负载。
4. 编译器侧遗留：`#aosoa[W]`、`@(share)` + `#+analysis sharing`、`#view`、跨 target 的 `golden.<os>_<arch>.hash`。
