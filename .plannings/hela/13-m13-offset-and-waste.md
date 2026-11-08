# 从原始提案到 Hela 现状：差距、判断与后续

> 输入：最初的「改造 Odin 出方言 Hela」提案（布局显式化 / 并发语法 / 标准库六层 / C 库移植 / AI 工具链 / 路线图）。
> 现状：M0–M14 已落地（见 `00-plan.md`）。
> 本文只做一件事：把提案逐条对照现实，给出**采纳 / 修正 / 拒绝**，并说明理由。理由都绑在两条硬约束上——
> **可持续合并上游**、**编译器是布局唯一真源**。

## 一、语法层（提案 A/B/C 三组）

| 提案 | 状态 | 判断 | 理由 |
|---|---|---|---|
| `struct #align(64)` | 已有（Odin 原生） | 保留 | 结构体级对齐本来就有，不需要新语法 |
| `#offset(60) tag: u32` | **已实现（M13）** | 采纳 | 绝对字节位置是 `#split`（网格）与 `#explicit`（逐字节命名）之间缺的一档；寄存器映射、wire header 真的需要它。落地形态是字段前缀 `#offset(N)` |
| `soa[N] Particle` 语言级 | 已实现为 `#aosoa[W][N]T`（M11） | 修正 | 实测 `[N/W]#soa[W]T` 本来就是 AoSoA，`#aosoa` 只是「从逻辑侧书写」的语法糖，**不需要改 codegen**。原提案以为这是唯一必须动后端的语法，判断有误 |
| `#soa` 升级为一等 | 已有 | 保留 | Odin 的 `#soa` 已在类型系统里（`StructSoa_Fixed/Slice/Dynamic`），无需改造 |
| `arena scratch: NMB { ... }` 作用域语法 | **不做** | 拒绝（对编译器而言） | 这是库能力，不是语法：`context.allocator` + `defer free_all` 已经能做到 O(1) 回收，且不需要动 parser/checker。写成库（`core:hela/mem`）比写成语法更可持续合并上游。真正需要语法化的只有「隐式分配禁令」，那属于分析 pass，见下 |
| `own` / `borrow` 所有权标注 | **不做** | 拒绝 | 与 Odin 隐式 `context` + 手动分配模型冲突；Rust 式生命周期检查的成本远大于「布局可见」的收益，且会把 fork 与上游永久拉开 |
| `@nocopy` / `@noalias` / `@pure` | **部分采纳（本轮未做）** | 修正为**分析**而非语义 | Odin 已有 `#no_alias`（参数）、`@(rodata)`、`#force_inline`。剩下的 `@nocopy` 更适合做成 `#+analysis` 家族的**静态检查**（发现 `memcpy` 一个含 mutex 的 struct 就报错），而不是改变类型语义——语义一改，上游 rebase 就断了 |
| `par group g { task ... }` 结构化并发 | **不做（本轮）** | 拒绝语法，采纳库 | 子任务必等齐是**调度器**能力，用 `core:hela/exec` 表达即可；写成块语法要改 parser + 控制流 + 逃逸分析，是 fork 税最重的一类改动 |
| 有界 channel 为默认 | **不做** | 拒绝 | 与 Odin 的 `chan T` 冲突，且「默认有界」是库的默认参数，不是语言的默认语义。`core:hela/chan` 提供 `Bounded(T, N)` 即可 |
| `@shared` 才能被多任务写 | **部分已有** | 采纳为分析 | `#share(label)` + `#+analysis sharing`（M12）已经覆盖了「谁写哪个字段、会不会撞同一 cache line」。提案要的「全局变量必须标 `@shared`」是另一个检查（写者集合），可以做，但前提是有 `#+analysis` 的入口，已有 |
| `#simd` / `prefetch` / `@unroll` | 已有 / 已有 / 不做 | 保留 | `#simd`、`intrinsics.prefetch_read/write`、`#force_inline` 都在；`@unroll` 交给 LLVM 的 `llvm.loop.unroll` 元数据，不值得新语法 |
| `#layout_of` / `#offsetof` 常量 | **已实现（M4）** | 采纳并超出 | `intrinsics.layout_padding_of / layout_tail_padding_of / layout_cache_lines_of`，可进 `#assert`；`size_of/align_of/offset_of` 本来就有 |
| 不要 GC / async / 运算符重载 / 异常 / 类 | 同意 | 保留 | 与 Odin 一致，Hela 也不引入 |

## 二、AI 工具链（提案第五节）

| 提案 | 状态 | 判断 |
|---|---|---|
| `hela layout <Type>` 字节地图 | **已实现** | `hela-layout <manifest> <Type>`：逐 cache line 的字节地图（含 `#align`/`#offset`/`#split` 声明标注） |
| 布局清单 JSON | **已实现** | `-emit-layout:json\|cbor`，v4，确定性、带 `layout_hash` |
| ABI 门禁 | **已实现** | `golden.hash` + `--hashes` |
| `hela ast --json` / `mir --json` | 已有替代 | Odin 自带 `-export-semantics`（JSON/CBOR，含类型、过程、字段偏移）。不重复造 |
| `hela explain <fn>`：分配点 / 锁 / syscall | **不做（本轮）** | 需要 MIR 级分析。Odin 的 MIR 是内部结构，导出它等于把 fork 钉死在后端实现上。可行的替代：`#+analysis alloc`（检查指定 proc 体内的 `make`/`new`），范围小、够用 |
| `hela bench --json` + 火焰图 | **待做** | 见下节 |
| LSP 自定义 `textDocument/layout` | **待做** | 清单已经够 LSP 用了；这是一个小前端工程，不是编译器工作 |
| **提案里没有的一条（新增）** | **已实现（M14）** | `hela-layout --waste`：按 padding 排序，并区分「`#split`/`#explicit` 声明的 padding」与「重排字段就能省下的 padding」。这是「哪个 struct 最浪费」的机器可读答案，也是 AI 最需要的那一问 |

## 三、标准库（提案第三节六层）

实际已落地的是 `core:hela/layout`（清单解析/渲染/diff/waste）、`core:hela/ring`（SPSC，布局即文档）、`cmd/hela-layout`。
提案的第 1–3 层（mem/task/sync/atomic/ring/chan；lockfree/epoch/io；lsm/cache/serialize）值得做，但**顺序要改**：

1. `core:hela/bench`（**下一步第一件**）：现在 `ring` 的 3.5–4.1x 是单轮数字。没有预热 + 多轮中位数 + p99，就没有可信的「改好了」。
2. `core:hela/queue`（Vyukov MPSC）：`ring` 的 SPSC 用的是 `#align` 直接写出来的布局，MPSC 用同一套语法就能写，正好验证 M10–M12 在真实无锁结构上够不够用。
3. `core:hela/exec`（thread-per-core）：每核一个 SPSC 队列 + 固定核绑核。这是提案 B 组「结构化并发」的库形态。
4. `core:hela/epoch`（EBR / hazard pointer）：无锁编程的真正门槛是回收，不是队列。
5. `core:hela/io`：Odin 已有 `core:nbio`（io_uring/kqueue/IOCP），包一层而不是重写。

C 库移植按提案的优先级（mimalloc → liburing → llhttp）不变，但**都在库侧**，不碰编译器。

## 四、本轮已做（M13 / M14）

- **M13 字段级 `#offset(N)`**：绝对字节位置。`offset = N`，前面的空隙由这个前缀自己声明；`N` 必须是字段类型自然对齐的倍数（否则后端会发出类型不允许的非对齐访问）；与前一个字段重叠时报「previous field already ends at byte N」；`#explicit` **接受** `#offset` 声明的空隙。清单 v4 增 `declared_offset`（无则 -1）。
- **M14 `hela-layout --waste`**：按 padding 降序排行，`declared` 列标出 `#split(N)`/`#explicit`，汇总行给出「可重排回收多少字节」。顺手修了 `render` 对无字段类型（array/enum/bit_field）把整个 payload 当 tail padding 打印的 bug。

## 五、下一步（按价值/成本排序）

1. `core:hela/bench`：预热 + 多轮 + 中位数/p99，把 `ring` 的伪共享数字改成可断言的形式。
2. `core:hela/queue`（Vyukov MPSC）+ 布局断言 + TSAN。
3. `#+analysis alloc`：`#+analysis` 家族的第三个成员，检查 proc 内的隐式分配点（提案 `@nocopy` 的真正落点）。
4. 跨 target 的 `golden.<os>_<arch>.hash`。
5. `core:hela/exec`（thread-per-core）。

## 六、判断原则（写给未来的自己）

- **语法只在「编译器是唯一真源」的地方新增**：布局、对齐、偏移、可见性边界。凡是库能表达的（arena、channel、任务组），一律进库。
- **每个新语法配一个负例**：能拒绝的东西必须拒绝，且给出「为什么」和「怎么改」。本轮 5 个 `offset_*` 负例即此。
- **能复用上游 pass 的绝不自己写**：`#offset` 落在 `type_set_offsets_of` 里，而不是另起一个偏移计算器——两套算法迟早会分歧。
