# M15 / M16：从「事件·督程·消息·队列·缓存·日志」反推语言改造

> 这一轮的起点不是「再加一个布局语法」，而是**先把一套能跑的高吞吐运行时写出来**，看写的过程中编译器哪里不够用，再改语言。
> 参考的三个仓库都是本机已有的 Odin 项目，读的是实现而不是 README 口号。

## 0. 三个参考项目各自回答了什么问题

| 项目 | 定位 | 拿来的东西 | 明确不拿 |
|---|---|---|---|
| `../tina` | Odin 写的 thread-per-core / shared-nothing 框架：Isolate + Effect + Shard + 监督树 + DST | 128 B `Message_Envelope` 契约、绝对序号 SPSC ring（生产者/消费者各占一行、热路径零原子）、generational handle 位打包、静态 boot spec 一次切分、重启策略滑窗、`#assert` 锁 wire format、分域 PRNG 的单线程确定性 round | OS trap/信号级容错（SIGSEGV 恢复、guard page、绑核、watchdog）：需要运行时插桩、平台分叉，且**布局不可见**；4 份 50–67 KB 平台 IO backend；ASan shadow 挂钩进入每条热路径 |
| `../oboe` | VictoriaLogs 风格日志服务 + 桶式缓存 + beanstalkd 内存队列 | `gen<<40 | idx` 分代环形 chunk、hash→slot 索引与数据解耦、`get_into` 免中间副本、绝对 TTL 惰性判定、队列 `Reserved_Heap` 的 lazy-stale（堆里只放 `{id, deadline}`，靠主表复核） | logdb 全链持久化（LSM part/merge/列式格式/背压，7 文件 1400+ 行）、beanstalkd 协议外壳、HTTP/UI/Prometheus 胶水 |
| `../opus` | `core:nbio` 上的 HTTP/1.1 库 | 每连接 `Dynamic_Arena` + 请求边界 O(1) reset、`*_poly` 类型安全回调、显式状态机 `conn_drive`、一次 head clone 后全切片视图、合并写 | HTTP 分帧/走私防护、头语义、TLS/反代/SSE 等协议专有部分 |

一句话总结差距：**三个项目里所有「快」的部分都是数据结构的字节形状决定的**（谁写哪个 cache line、消息多少字节、记录头在哪），
而它们全都靠 `#assert` 人肉维护这个事实；**Hela 的编译器已经知道这些字节，却只把布局导出，没有把「谁写它」导出**。

## 1. 写这些库时，语言到底缺什么

按实现顺序遇到的三个缺口：

1. **清单不描述并发契约。** `#share(label)` 写进源码后，编译器拿它判伪共享，然后**把 label 丢掉了**。
   AI 读 `-emit-layout` 只能看到 offset/padding，看不到 `head` 是 producer 写的、是不是原子的、哪一行归谁。
   tina 的整张架构图（producer 行 / consumer 行 / 冷数据行）在 Hela 里只能靠注释传递。
2. **没有「无隐藏分配」的机器可检查语义。** tina 的第一条铁律是启动后不 malloc，opus 靠每请求 arena 把峰值内存压住。
   Odin 里 `make([]T, n)` 不写 allocator 时会**静默**取 `context.allocator`；
   Hela 现有的 `#+analysis` 家族只有 `escape`/`atomic`/`sharing`，没有一个能说「这个文件不许偷偷分配」。
   注意：编译器**已经有**完整的隐式 allocator 判定（`-vet-explicit-allocators` 用的那段），只是没有接到方言语义上。
3. **没有消息/记录的固定尺寸声明。** tina 用 `#assert(size_of(Message_Envelope) == 128)` +
   `offset_of(payload) == 32` 维护 wire format，这跟 Hela 的 `#explicit`/`#offset`/`#assert` 已经等价，
   **不值得再加语法**。记下来，作为「不加」的理由。

前两条是本轮真正改语言的地方；第三条明确不做。

## 2. 语言改造

### M15 `#atomic` 字段前缀 + 清单 v5 并发契约

```odin
Ring :: struct($T: typeid) {
    #align(64) #atomic #share(producer) head: u64,
    #align(64) #atomic #share(consumer) tail: u64,
    #align(64) slots: []T,
    mask: u64,
}
```

- `#atomic` 是**裸前缀**（无参数），声明「这个字段跨线程原子访问」。它不改变任何字节，因此 **`layout_hash` 不变**（ABI 门禁不刷新）。
- 编译器校验（Hela 门控）：字段类型必须是 1/2/4/8 字节的整数、指针、bool 或枚举；与 `#packed` / `#raw_union` / bit field 互斥。
  这是能做得到的真检查——`#atomic payload: [96]u8` 会立刻被拒，而 AI 不用猜「这个字段能用 `atomic_load` 吗」。
- `#+analysis sharing` 打开时，`#atomic` 字段必须带 `#share(label)`：既然声明了跨线程，就得说出谁写它，
  否则 `--contract` 给出的所有权地图是残缺的。
- 清单升到 **v5**，每个字段多两个键：`"atomic": true/false`、`"share": "producer"`（无 label 时为空串）。
  加键必须同步改 CBOR 的 `sw_map(w, N)` 手算长度——这是本仓库踩过的坑。
- `hela-layout --contract <manifest.json>`：按 cache line 分组打印「行 → writer → 原子字段」，
  并对「有 `#share` 但没 `#atomic`」的字段给出提示（不是错误：可能被外层 mutex 保护）。
  **这是 AI 侧的核心交付**：一份机器可读的「谁拥有哪一行」。

### M16 `#+analysis alloc`（无隐藏分配）

- `#+analysis alloc` 是 `#+analysis` 家族第四个成员，**默认关闭**（不像 `sharing` 标注即触发），
  因为默认打开会把所有普通 Odin 代码的 `make()` 都判错。文件写了这个标签才生效；
  `#+analysis !alloc` / `-no-alloc-analysis` 可覆盖。
- 语义精确且诚实：**凡是把 `context.allocator` / `context.temp_allocator` 当作默认参数悄悄传进来的调用，一律编译错误**，
  消息写明「想分配就显式传 allocator」。这复用编译器已有的 `ParameterValue` / `Ast_Implicit("context")` 判定，
  不需要写 AST 遍历器，也不需要假装做了完整的分配逃逸分析。
- 为什么不是「禁止一切分配」：显式 `make([]T, n, arena)` 是允许的——它是**声明的**，不是隐藏的。
  tina 的 boot spec / opus 的每请求 arena 都是这个模型。真正的「零分配」是调用方把 allocator 传成固定 arena 的结果，
  编译器管的是「看得见」。
- 实现落在 `check_expr.cpp` 默认参数判定处（约 7452 行）加一个分支 + 新 pass 头文件，
  `build_settings.cpp` 加 `AnalysisFlag_Alloc = 1u<<3`，`main.cpp` 加 `-no-alloc-analysis`，
  `parser.cpp` 的 analysis 名字表加 `alloc`。**不碰 `types.cpp`**。

## 3. 库清单（`core:hela/*`，全部 `.odin` + 文件头 `#+dialect hela`）

设计成一条可组合的链，而不是六个互不相干的 demo：

```
producer ──MPSC queue──> worker(督程 supervised) ──message/mailbox──> shard
                              │                          │
                              ├── cache (分代 slot)       ├── event (timer wheel + reactor)
                              └── log  (批量 ring)        └── bench (预热/中位数/p99/JSON)
                    mem (bump arena + generational pool) 是所有人的地基
```

| 包 | 核心结构 | 借鉴自 | Hela 语法怎么用 |
|---|---|---|---|
| `mem` | `Arena`（固定 buffer，O(1) reset）、`Pool`（intrusive LIFO + generation） | tina `allocator_arena`/`allocator_msg_pool`、opus 每连接 arena | `#explicit` 写 arena 头，`#assert size_of` |
| `queue` | Vyukov 有界 MPSC + MPMC：每槽 `sequence` + 两个绝对序号游标，2 的幂 mask | tina `spsc_ring`（绝对序号/批量提交） | `#align(64)` + `#atomic` + `#share` 三游标分三行；`#split(64)` 给 cell |
| `msg` | 128 B `Envelope`（`#offset` 钉死字段）、`Mailbox` = 信封 ring + 批量 drain | tina `Message_Envelope` / `mailbox` | `#offset(0/8/12/16/32)` + `#assert(size_of == 128)` + `declared_offset` 进清单 |
| `event` | 可注入 `Clock` + 分层 timer wheel 位图 + `Loop` 批量分派 | tina `timer.odin` / DST 最小子集 | `#soa`/`#aosoa` 存 deadline/target/tag；`#+analysis alloc` |
| `supervise` | generational handle（8/8/20/28 位打包）、`Group` 重启策略 `One_For_One/One_For_All` + 滑窗计数 | tina `handle.odin` / `supervision.odin` | `#explicit` 锁 handle 布局；纯整数，无裸指针 |
| `cache` | 分片开放寻址表 + 绝对 TTL + 分代淘汰 + `get_into` 零中间副本 | oboe `cache.odin` 的 `gen<<40|idx` 与 `cache_get_into` | 每 shard 一行（`#align(64)`）；`#aosoa` 存 key/value/expiry |
| `log` | MPSC 固定记录环（32 B header + 96 B payload）+ 批量 drain + level filter | tina `logging.odin`（`PIPE_BUF` 批量）、oboe 写入路径 | `#offset` 钉 header，`#explicit` 逐字节命名 |
| `bench` | 预热 + N 轮 + 中位数/p99 + JSON | 补上 `00-plan.md` 里排第一的欠账 | 纯库，不改编译器 |

**明确不做**：OS 信号恢复、绑核、io_uring/kqueue 平台 backend、持久化 LSM、HTTP 协议栈、async/await、
所有权/借用检查（与 Odin 隐式 `context` + 手动分配模型冲突，MEMORY.md 已记）。

## 4. 验证方式（延续本仓库的规矩）

- `build_odin.sh release` 全量重建；
- `tests/hela/run.sh` 扩到 **N 步**：新增 `#atomic` 正/负例、`#+analysis alloc` 正/负例、清单 v5 键、
  `--contract` 输出、每个库的**行为**测试（不是只看布局）、端到端流水线、MPSC/MPMC 多线程与 TSAN；
- `HELA_TSAN=1 ./tests/hela/run.sh`；
- `./odin test tests/core -all-packages`（自举解析库必须同步认识 `#atomic`）；
- 线性一致性：MPSC/MPMC 用「生产者写入唯一 `(producer,seq)`、消费者求和校验、无重复无丢失」的 litmus，
  而不是「跑完没崩」。

## 5. 取舍记录（写给以后的自己）

- **没有新增扩展名、没有改后端 codegen**：M15/M16 都是「声明 + 校验 + 导出」，字节形状不由它们决定。
- **`#atomic` 不参与 `layout_hash`**：hash 是字节的指纹，并发契约是元数据，混进去会让 ABI 门禁因为注释级改动而红。
- **`#+analysis alloc` 不假装是逃逸分析**：它只能抓「隐式 allocator」，抓不到显式分配；这是刻意的，
  因为 Hela 的主张是「看得见」，不是「编译器替你保证没有」。
- **`#view` / 跨 target golden / `#share` 跨类型** 继续排在后面；本轮优先级让给「先有一套能跑的库」。
