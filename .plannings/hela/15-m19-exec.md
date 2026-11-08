# M19：`core:hela/exec` —— 把 8 个库串成 thread-per-core / shared-nothing

> 上一轮（M15–M18）先把 8 个 `core:hela/*` 库写出来，再从缺口反推语言改造。
> 这一轮反过来：**语言一个字都没改**，用已有的 M3–M16 语法去搭一个真正的运行时，
> 看这套「布局即契约」在完整系统里够不够用。结论是够用，而且暴露了一个编译器层面的偏移缓存坑。

## 0. 起点：为什么需要一个 exec

M17 的 8 个包各自都通过了行为测试，但它们是**互不相干的能力**，不是一个系统：

- `core:hela/queue` 是共享 MPMC：所有生产者 CAS 同一个 `enqueue_pos`。这在一台多核机上是单行争用点，
  而布局清单看不见它——争用不在类型里，在「几个核同时打这一行」这个事实里。
- 项目定位里的第一条前沿方法就是 thread-per-core / shared-nothing（MEMORY.md），
  但本 fork 到 M18 为止没有任何一层调度模型把 ring / msg / cache / event / supervise 串起来。
- `00-plan.md` 里 `core:hela/exec` 排在未做项第 2：串起每核 SPSC 队列。

参考仍是本机三个 Odin 项目里已经验证过的部分：tina 的 Isolate + 每对端点一条 SPSC 通道 + 静态 boot spec
一次切分 + 监督树；opus 的每请求 arena（在这里变成每 worker 的 arena）；oboe 的 `get_into` 零拷贝读
（在这里变成每 worker 独占的 cache）。**没有引入新外部依赖**，也没拿 Seastar 的 reactor 抽象来撑门面。

## 1. 为什么是 N×N SPSC，而不是一条共享 MPMC

```
                    shared MPMC                    per-peer SPSC matrix (exec)
producer 0..N  ──CAS──> enqueue_pos (1 line)      w0 ──[0][1]──> w1   w1 ──[1][0]──> w0
                        ↑ 所有核抢这一行           每条通道：一个生产者、一个消费者
                                                    push = 普通 store + release，零 CAS
```

`ring.Ring` 早就把契约写进类型了：`head` 归 producer、`tail` 归 consumer、冷数据第三行，
`#align(64)` + `#atomic` + `#share` 全是 M10/M15 已有的语法。`exec` 只做一件事：
给每个 `(sender, receiver)` 对分配**一条**这样的环，于是「谁写哪个 cache line」从注释变成了
编译器能检查、清单能导出的类型事实。`hela-layout --contract` 输出的就是这套东西（见第 4 节）。

代价是 O(N²) 条通道。N 上限设成 8（固定 `[8][8]` 矩阵、只初始化用到的 `workers²` 条），
对学习用的 thread-per-core 完全够；真要几百核得换成分片路由，那时再说。

## 2. 本轮语言改造：零

这是本轮最值得记的结论。**没有新增任何语法、没有改编译器、没有改 codegen、没有刷新 ABI golden。**
用到的都是已有能力：

| 语法 | 用在哪 |
|---|---|
| `#+dialect hela` | 文件头 |
| `#+analysis alloc` | `start` 里所有 `make` / `init` / `destroy` / `delete` 都显式传 allocator；一次 boot 分配，之后全从 arena 切 |
| `#+analysis sharing` | `Runtime` / `Worker` 的 `#share(workers|worker|controller)` 分线；编译器拒绝不同 writer 共线 |
| `#align(64)` + `#atomic` + `#share` | 计数器带、停止标志带、SPSC 环游标 |
| `#explicit` / `#offset` | `msg.Envelope` 的 128 B wire format（继承，不重复声明） |
| `#assert` + `intrinsics.layout_cache_lines_of` | 编译期锁 `Runtime`/`Worker` 的行边界与 envelope 行数 |
| 清单 v5 + `--contract` | 导出「哪一行归谁」 |

也就是说：M3–M16 的语法不是为 demo 准备的，它足够描述一个真实运行时的并发契约。

## 3. 结构与三条正确性细节

```
Runtime (controller + shared header)
  line 0  cfg / expected                frozen before start
  line 1  sent / consumed / dropped     #atomic #share(workers)
  line 2  stopping                     #atomic #share(controller)
  line 3  logs                         one MPMC log ring, drained after join
  line 4+ boxes[8][8]                 SPSC matrix
  workers: []Worker                   EXPLICIT make (see the pitfall below)
  stats:   [8]Worker_Stats            controller-readable snapshot

Worker (one per thread, everything else private)
  line 0  rt / id / count / thread / batch
  line 1  handled / app_sum / app_bad   #atomic #share(worker)
  line 2+ arena / event.Loop / cache
  last    stopped                      #atomic #share(controller)
```

三处不是「能跑就行」的细节：

1. **`consumed` 必须在 handler 之后自增。** `wait_idle` 的定义是 `consumed >= expected`；
   如果在 handler 之前计数，控制器会在某个 worker 还在累加 litmus sum 时就返回，
   checksum 变成随机值。改成 handler → `consumed` 后，`wait_idle` 就成了所有 handler 完成的屏障。
2. **`Worker_Stats` 快照。** `stop()` 会 `delete(rt.workers)`；若控制器之后还去读 `rt.workers[i].app_sum`，
   就是访问已释放内存。所以在 join 之后、释放之前把每个 worker 的 sum/handled/bad/ticks/posted/stopped
   拷进 `Runtime.stats`，`stop` 之后一律读 `stats`。
3. **`send` 满环重试，不丢。** 静默丢弃会把「布局正确」变成「程序错误」，而布局检查完全看不见它。
   同时 `send` 拒绝 `stopping` 之后的发送，保证控制器观察到 `consumed == expected` 时不会再有新消息。

监督策略保持 `supervise` 的语义：**纯决策，副作用归调用方**。`report_failure` 按名字查当前句柄
（组重启后 `rt.handles[]` 是故意留着做陈旧句柄测试的），所以不会拿过期 handle 去重启。

## 4. 布局契约确实可用

`./odin check core/hela/exec -emit-layout:json` + `hela-layout --contract` 的实际输出（节选）：

```
exec::Runtime  (18432 B, 288 cache line(s))
  line 1 [64..127]   owner=workers    : sent@64#atomic#share(workers) consumed@72 ... dropped@80 ...
  line 2 [128..191]  owner=controller : stopping@128#atomic#share(controller)
exec::Worker  (1792 B, 28 cache line(s))
  line 1 [64..127]   owner=worker     : handled@64#atomic#share(worker) app_sum@72 ... app_bad@80 ...
  line 27 [1728..1791] owner=controller : stopped@1728#atomic#share(controller)

2 type(s), 0 line(s) with conflicting writers, 0 shared field(s) without #atomic
```

`run.sh` 第 20 步直接 grep 这三行，把它当成**交付物**而不是注释：哪天有人把控制器标志挪到 worker 的行上，
回归会红。

## 5. 两个真坑（一个在编译器里）

### 5.1 内嵌「含惰性多态类型」的 struct 数组会拿到错误偏移 ★

最初 `Runtime` 写成 `workers: [MAX_WORKERS]Worker`（内联数组）。`check` 通过、`#assert` 通过，
但 `build` 直接崩在后端：

```
src/llvm_backend_general.cpp(3367): Assertion Failure: `offset >= prev_offset`
```

导出的清单暴露了根因：

```
Runtime size 18048
  boxes    off 448    size 16384
  workers  off 16832  size 14336
  group    off 16832  size 1096     <-- 和 workers 同偏移！
```

`Worker` 里含 `event.Loop` → `queue.Queue(Event)`（多态类型的惰性实例化）。
`Runtime` 的字段偏移在 `Worker` 的尺寸定稿**之前**就被 `type_set_offsets` 算好并缓存了，
于是 `[8]Worker` 当时按 0 字节计，`group`/`handles`/`backing`/`stats` 全部错位，
`size_of(Runtime)` 少算 14336 B。之后清单读到的 `size` 是定稿值，`offsets` 却是旧值，两者矛盾。

**修法**：`workers` 改成显式 `make([]Worker, n, allocator)` 的切片（16 B，布局不依赖 `Worker` 的尺寸），
在 `start` 里分配、`stop` 里释放。这既绕开了缓存顺序，又更贴合 Hela 的主张——
「这批 worker 占多少内存」是 `Config` 里一个显式数字，不是类型推导的副产品。

**为什么不去改编译器**：改 `type_set_offsets` 的惰性实例化顺序要碰 `src/types.cpp` 主干，
风险和「可持续合并上游 / 尽量不动主干」的约束冲突；而「大块 worker 状态显式分配」本来就是更正确的
系统设计。这条限制已写进 MEMORY.md，以后遇到同类崩溃不用再查一遍。

### 5.2 有界 SPSC 矩阵的启动死锁 ★

第一次把负载调到每通道 256 条、容量仍是 64，程序直接挂住（SIGTERM）：
所有 worker 都在 `seed` 里对满环 `push` 自旋，**没有一个人进入 drain 循环**，
形成 N 方互相等待。这不是 Odin 的问题，是 bounded SPSC + 全员先生产后消费的必然结果。

**定案**：采用「声明式工作预算」——`Config.mailbox_capacity` 必须覆盖每通道的批量，
`expected` 把总投递数显式交给 `start`。测试用 `CAPACITY = 512`、`PER_PAIR = 256`（4096 投递），
`send` 的重试循环保留作安全网。真正的无限流需要 credits 或「push 受阻时顺便 drain 自己 inbox」的
pump，那会把 handler 递归、所有权语义都拖进来，本轮明确**不做**，已列为后续项。

### 5.3 其余小坑

- `-vet-tabs` 不接受「tab 后接空格做字段对齐」，结构体字段一律单 tab 缩进。
- Odin 过程参数不可赋值：`send` 里用 `e_in` + `e := e_in`。
- 常量数组不能用变量下标：`names := WORKER_NAMES` 后再 `names[i]`。
- `-warnings-as-errors` 会抓原子序不配对：release store 没有对应 acquire load 就报
  "the release orders nothing"。`w.stopped` 在 `thread.join` 之后读，改成 `.Relaxed` 即正确。
- `stopped` 的快照必须在 `delete(rt.workers)` 之前，否则读已释放内存（运行时报 bounds check 0..<0）。

## 6. 验证

| 项 | 结果 |
|---|---|
| `./tests/hela/run.sh` | **21 步 EXIT=0**（原 20 步 + exec e2e + 契约 grep；exec 加入严格 vet 列表与第 1 步断言） |
| `HELA_TSAN=1 ./tests/hela/run.sh` | EXIT=0，`TSAN: exec 4-worker SPSC matrix clean`（另保留 ring + MPMC 2P/2C） |
| `ODIN_DONT_DOWNLOAD_TEST_ASSETS=1 ./odin test tests/core -all-packages` | 1072 tests 全绿（自举解析库不受影响，本轮零语法改动） |
| litmus | 4 workers × 4 destinations × 256 = **4096 投递**，唯一编码值求和 + 计数校验，无丢失/重复/双投 |
| 每 worker | `app_bad == 0`（cache set/get_into 逐条往返）、`loop.posted == 0`、`loop.ticks > 0`、`stopped == 1` |
| 全局 | `sent == consumed == 4096`、`dropped == 0`、`log_records == 8`、监督树 One_For_All / 滑窗升级 / 陈旧句柄 |
| 吞吐（host, 4 workers） | 4096 投递 ~517 µs ≈ **7.9 M msg/s**；TSAN 下 ~6.5 ms ≈ 0.63 M msg/s（仅作回归，不用于性能结论） |

## 7. 明确不做

- 绑核 / NUMA 感知分配 / OS trap 级容错 / watchdog：平台分叉重，且布局不可见（14 号文档已述）。
- `io_uring` / `kqueue` / IOCP backend：`event.Loop` 目前只是注入时钟 + 用户态分派，没有真实 IO 事件源。
- work stealing / 跨核任务迁移：与 shared-nothing 主张相反；`thread.Pool` 是上游已有的东西。
- credits / pump 式背压：见 5.2，本轮用声明式预算绕开。
- 跨 target golden、`#share` 跨类型、`#view`：继续留在 `00-plan.md` 的下一步。

## 8. 取舍记录

- **零语言改动是有意的结论**，不是偷懒。M15/M16 已经把「谁写它」「不许偷偷分配」补齐；
  exec 证明这两条加上 M3–M14 的布局语法，足够描述一个完整运行时的契约。再往语言里加东西就得有真实缺口。
- **清单是交付物**：run.sh 直接 grep `--contract` 的 owner 行与冲突数，
  而不是把并发契约写在 README 里等人自觉。
- **并发正确性不靠布局**：litmus（唯一值求和）+ TSAN 双保险，
  避免「对齐完美但内存序/计数顺序错」——本轮 5.3 之前的 `consumed` 顺序就是活例子。
