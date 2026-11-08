# M23：前向进展 —— 把「容量必须覆盖批量」这笔欠账还掉

> 关键词：`core:hela/flow`、`Gate`、`Table($N)`、pump 背压、`tests/hela/exec` 容量 8 < 批量 256、
> 零语言改动、零清单版本升级。

---

## 1. 为什么是这一轮

M19 的 `15-m19-exec.md` 5.2 节记了一个**正确性欠账**，不是展示特性：

> 第一次把负载调到每通道 256 条、容量仍是 64，程序直接挂住（SIGTERM）：所有 worker 都在
> `seed` 里对满环 `push` 自旋，没有一个人进入 drain 循环，形成 N 方互相等待。

当时的定案是「声明式工作预算」：`Config.mailbox_capacity` 必须覆盖每通道批量，`expected`
把总投递数显式交给 `start`，`send` 里的重试循环只当安全网。测试因此写死
`CAPACITY = 512`、`PER_PAIR = 256`，并在注释里承认：

> 真正的无限流需要 credits 或「push 受阻时顺便 drain 自己 inbox」的 pump，本轮明确不做。

`00-plan.md` 的「下一步」把它排在第 2 位。M22 收尾时用户要求「继续，并考虑形成可复用的
语言结构或数据结构」，M23 就顺着这条线：**把背压状态从 send 里的隐形自旋，变成一个有名字、
有字节、有策略表、能被穷举验证的可复用结构**，然后把 `exec` 的容量约束彻底解除。

这一轮要证明的不是「更快」，而是「**以前会挂死的配置现在必然跑完**」。

---

## 2. 设计：liveness 也能变成声明

M1–M22 的清单回答的是「字节在哪、谁写它、占哪几位」。死锁是**活性**问题，布局清单看不见它，
也编不出一个 `layout_hash` 来。所以 M23 没有往清单里塞新字段，而是让活性依赖的东西变成
可检查的值：

| 层 | 结构 | 可检查性 |
|---|---|---|
| 策略 | `Policy { Spin, Pump, Reject }`、`Action { Retry, Drain, Abort }` | 枚举值，可传参、可穷举 |
| 决策 | `plan(policy, depth) -> Action`（纯函数） | 24 个 `(policy, depth)` 组合的真值表，无线程 |
| 状态 | `Gate :: struct #explicit #align(64)`，64 B / padding 0 / 一个 writer | 编译期 `#assert` + 清单 + `--contract` |
| 复用 | `Table($N)` / `Table_8`，8 个 Gate 各占一行，512 B | 与 M22 的 `pattern.Table($N)` 同构：一张每线程独占的表 |
| 观测 | `blocked / drains / delivered / spins` + `Worker_Stats` 快照 | `stop` 之后仍可读，测试直接 grep |

`Gate` 全部字节都命名了：`blocked@0`、`drains@8`、`delivered@16`、`spins@24`、`depth@32`、
`policy@36`、3 B 显式空隙、`reserved@40..63`。`#align(64)` 是结构体级的，所以 `[N]Gate`
天然每个元素一行——**跨 worker 的背压状态不共享 cache line**，这一点由编译器保证，不是注释。

`Gate` 的字段标了 `#share(worker)`：`--contract` 会打印 `owner=worker`。它们是普通计数、
不是原子操作，所以工具会同时报 `6 shared field(s) without #atomic`。这是**预期的提示而非缺陷**：
`--contract` 的 hint 只是说「这些字段没声明成原子」，而 Gate 只被自己的 worker 写，
controller 在 `thread.join` 之后才读，本来就不该有原子开销。判据是
`0 line(s) with conflicting writers`。

### 2.1 三种策略，一个纯函数

```odin
plan :: proc(p: Policy, depth: u32) -> Action {
    switch p {
    case .Spin:   return .Retry                       // 要求外部保证有人 drain（M19 的假设）
    case .Reject: return .Abort                       // 立刻交还调用方
    case .Pump:
        if depth != 0 { return .Retry }               // 不能递归进用户 handler
        return .Drain
    }
    return .Retry
}
```

`exec` 固定 `.Pump`（它的契约是「一条消息都不丢」）；`.Spin` / `.Reject` 留给别的拓扑复用。
`depth` 是重入守卫：用户 handler 里若再调 `send`，此时不能 pump —— pump 会用同一个
`w.batch` 并再次调用 handler，既是递归又会覆盖正在遍历的批次。这个窗口退化为 `.Retry`，
由其他 worker 的 pump 提供进展；**这是本轮明确保留的剩余约束**，写在下面的「取舍」里。

### 2.2 `simulate`：不用线程也能证明活性

`flow.simulate` 是确定性的两阶段模型，直接对应一个真实 worker 的生命周期：

- **phase 1（seeding）**：还没完成投递承诺的 worker 一直 push，遇到满环严格按策略处理；
  **没有隐式 drainer**。
- **phase 2（running）**：seed 已返回的 worker 进入主循环，每轮无条件 drain 自己 inbox。

关键就在「`.Spin` 下没有任何 worker 能走到 phase 2」——全员卡在 phase 1，第二轮零进展，
模型立刻报告死锁，而不是把测试进程挂住。`.Pump` 让 worker 在 phase 1 卡住时先排空自己
inbox，别的生产者因此能推完、进入 phase 2，批次完成。

测试扫 160 组拓扑（`n=2..5` × `capacity=1..16` × `burst=0..64`）：

| 策略 | `burst <= capacity` | `burst > capacity` |
|---|---|---|
| `.Spin` | 完成 | **80/80 报告死锁** |
| `.Reject` | 完成 | **80/80 不完成** |
| `.Pump` | 完成 | **80/80 完成，且 `drains > 0`** |

`plan` 的 24 个真值表项与 `Gate` 的记账（`blocked=10 / drains=3 / delivered=12 / spins=2`、
`enter/leave` 不 underflow）也一起验。全部是纯函数，没有 sleep、没有超时、没有调度噪声。

---

## 3. `exec` 接线

```odin
// 主循环与 pump 共用，保证 consumed 只在 handler 之后发布（M19 的顺序 bug 不再有第二处实现）
consume_batch :: proc(w: ^Worker, n: int) {
    g := &rt.backpressure.gates[w.id]
    flow.enter(g)
    for i in 0..<n { ...; cfg.handler(w, e); atomic_add(&rt.consumed, 1, .Release) }
    flow.leave(g)
}

pump_inbox :: proc(w: ^Worker) -> int {   // 排空所有 [src][w.id]，正是别人被卡住的那些通道
    for src in 0..<w.count { n := msg.drain(...); consume_batch(w, n); total += n }
    return total
}

send :: proc(...) -> bool {
    for !msg.send(&rt.boxes[w.id][dst], e) {
        switch flow.on_full(g) {
        case .Drain: n := pump_inbox(w); flow.note_drain(g, n); if n == 0 { spin_hint() }
        case .Retry: flow.note_spin(g);  spin_hint()
        case .Abort: dropped += 1; return false
        }
    }
    sent += 1; return true
}
```

正常路径（一次 push 成功）**完全不碰 Gate**：背压状态只在慢路径上被写，热路径开销不变。
`Runtime` 尾部挂 `flow.Table(MAX_WORKERS)`，`start` 用 `flow.table_init(&rt.backpressure, .Pump)`
初始化；`stop` 在 join 之后把四个计数快照进 `Worker_Stats.blocked/pump_rounds/pumped/spins`。

`Config` **一个字段都没加**。M20 已经吃过一次亏：给 `Config` 加 `io_handler` 把它从 56 B
撑到 64 B，正好把 `Runtime.expected` 挤出 line 0，`#assert` 当场抓到。这次若把 policy 放进
`Config`，64 → 72 B 会重演同一件事。策略固定为 `.Pump` 是更诚实的选择：exec 本来就不允许丢消息。

---

## 4. 两个真坑

### 4.1 判别模型漏了「主循环本来就会 drain」

第一版 `simulate` 只有「卡住才 drain」这一相，结果 `n=2 / capacity=1 / burst=2` 下 `.Pump`
也报失败。推演发现：worker 1 完成 seed 后，真实运行时会回到主循环无条件 drain，从而清掉
`inflight[0][1]`；模型里它「没有 pending 就什么也不做」，于是 worker 0 永远卡在自己的
`inflight[0][1]` 上。加上 phase 2 之后模型才和真实行为对齐——**这一步恰好说明为什么
`.Spin` 会死锁：不是因为没人会 drain，而是因为没人能走到会 drain 的那一行代码**。

### 4.2 pump 会递归进 handler 并踩坏共享的 `w.batch`

`w.batch` 是每个 worker 唯一的一块 drain 缓冲。若 `send` 在 handler 内被满环触发 pump，
pump 会 `msg.drain` 覆盖 `w.batch`，而外层 `consume_batch` 正在遍历它。`flow.enter/leave`
把 handler 窗口记进 `Gate.depth`，`on_full` 在该窗口返回 `.Retry` 而非 `.Drain`。
对当前测试路径（`io_handler` 在 `loop_handler` 内、`depth == 0`）没有影响，
4096 条投递仍全部由真实内核 completion 驱动。

---

## 5. 验证

| 项目 | 结果 |
|---|---|
| `./odin run tests/hela/exec -o:speed` | **`CAPACITY=8` < `PER_PAIR=256`**：4096 投递全完成，litmus 唯一值求和一致，`dropped=0`；41583 次满环 push → 41583 pump 轮 → 消费 3823 条；960 us ≈ 4.27 M msg/s |
| TSAN 下同一测试 | 16.3 ms ≈ 0.25 M msg/s，79908 次满环 push / pump 轮，无 data race（内部 5 s 有界等待远未触发） |
| `./odin run tests/hela/flow -o:speed` | 24 个 plan 用例、160 组拓扑、80 个 Spin 死锁被检出、80 个 Pump 完成 |
| `tests/hela/run.sh` | **26 步全绿**（25 → 26，新增 flow 步骤；负例仍 25 个；严格 vet 包 13 → 14） |
| `HELA_TSAN=1 ./tests/hela/run.sh` | 全绿（MPMC 2P/2C、io、exec） |
| `./odin test tests/core -all-packages` | 1072 tests 全绿 |
| 清单 / ABI | 仍是 **v7**，字段键数不变，`layout_hash` 不变；`golden.hash` 与 5 份 `golden.<target>.hash` **未刷新** |
| 布局门禁 | `flow::Gate` 64 B / padding 0 / `owner=worker`、0 conflicting lines；`flow::Table_8` 512 B / padding 0；`exec::Runtime` 19264 B / 301 行 / 0 conflicts |
| 跨 target | 7 个 target `core/hela/flow` check 全过，`--stable` 报 **4 stable, 0 drifting, 0 missing**（含 `linux_i386` / `wasi_wasm32`） |
| CBOR | 未改 schema，v7 既有解码门禁不受影响 |

`run.sh` 第 21 步同时断言 `24 plan cases`、`80 Spin deadlocks`、`size 64 B` / `size 512 B` /
`padding 0 B` / `owner=worker` / `4 stable, 0 drifting`；第 25 步（exec）新增
`capacity 8 < burst 256` 与 `pump rounds` 两条 grep——**如果有人把 pump 删了、把容量调回 512，
回归会红**。

---

## 6. 取舍

- **不做 credits 协议**。SPSC 的 head/tail 本来就是配额；再加一层跨 worker 原子 credit，
  只会多一条被两边写的 cache line，把 M12 想消掉的伪共享又请回来。pump 不需要任何跨核原子，
  只消费自己本来就拥有的 inbox。
- **不改 `expected` 的语义**。`wait_idle` 仍是精确谓词（`consumed >= expected`），不是启发式
  idle 检测。变化是：**工作预算和队列容量现在是两个独立的数**，M19 把它们绑在了一起。
- **不承诺「handler 内无限 send」也无死锁**。`depth > 0` 时退化为 `.Retry`，依赖其他 worker
  的 pump。当前 handler 不 send，所以不触发；这是已知边界，写在这里而不是藏起来。
- **不加语法 token、不改 parser、不改 codegen、不升清单版本**。这是继 M19/M20/M22 之后
  又一次**零语言改动**：现有 `#explicit` / `#align` / `#share` / 编译期 `#assert` 足够把
  liveness 依赖的状态钉成声明。
- **不把 `pattern` 接进热路径**。M22 留下的理由仍然成立：没有真实尾延迟剖面之前，
  为展示特性去改已被 litmus + TSAN 验证过的分派路径不划算。

---

## 7. 关键文件

| 文件 | 作用 |
|---|---|
| `core/hela/flow/flow.odin` | **新增**。`Policy` / `Action`、`Gate`（64 B `#explicit #align(64)`）、`Table($N)` + `Table_8`、`plan` / `on_full` / `enter` / `leave` / 记账、`simulate` 两阶段确定性模型 |
| `core/hela/exec/exec.odin` | `consume_batch` 抽出、`pump_inbox` 新增、`send` 三分支、`Runtime.backpressure`、`Worker_Stats` 四个背压计数、`start` 初始化 / `stop` 快照；`Config` 不变 |
| `tests/hela/flow/main.odin` | **新增**。plan 真值表、Gate 记账与重入、160 组拓扑的 Spin/Pump/Reject 对照；编译期布局断言 |
| `tests/hela/exec/main.odin` | `CAPACITY` 512 → **8**；断言 `blocked/pumped/pump_rounds` 均非 0 且 `pumped <= TOTAL`；输出打印容量、批量与 pump 统计 |
| `tests/hela/run.sh` | **26 步**；新增第 21 步（flow 穷举 + 字节/owner + 跨 target `--stable`）；strict vet 加 `flow`；exec 步骤加 pump 断言 |
| `00-plan.md` / `README.md` | 进度表 M23、链路图包数 13 → 14、关键文件表、下一步列表（背压项移除）、步数 25 → 26 |
