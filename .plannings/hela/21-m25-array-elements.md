# M25 — 数组元素伪共享（writer-bearing 类型必须是整 cache line）

> 目标：补上 M24 之后剩下的最后一条相邻性盲区——**数组边界**。`[N]T` 与 `make([]T, n)` 重复 T，元素 i 的尾字段与元素 i+1 的首字段可能同线；任何「以类型为单位」的分析都看不到这一点，因为它不是类型内部的关系，而是重复实例之间的关系。

## 问题

```odin
List :: struct { list: [dynamic]u64 }   // 40 字节
lists := make([]List, 4)                // 元素 0 占 0..39，元素 1 占 40..79
```

元素 0 与元素 1 同时落在字节 0..63 这条线里。四个 worker 各自 append 到自己的 `lists[i].list`（写 len 字段）——**没有任何字段被共享**，但每次写都在 invalidate 别人正在写的行。M12（同 struct 字段）、M24（嵌套 struct 的跨边界）都看不见，因为它们是类型内部关系；这里是「同一类型的两个实例」。

## 规则

含 `#share` 标注的类型（其自身或嵌套）必须满足：

- `size % cache_line == 0`：否则元素 i 尾部与元素 i+1 头部同线；
- `align % cache_line == 0`：否则数组可能整体错位，元素内每个字段都偏离分析假定的行。

不满足时 **warning**（不是 error：单实例使用完全合法，只有放进数组才出问题），挂在类型定义处、每类型一次。消息给出两条机械修法：尾部 padding 字段（`_: [N]u8`）或 `#split(cache_line)`；错位则 `#align(cache_line)`。

与 M24 同一层、同一开关（`#+analysis sharing`），**零语法/清单改动**。

## 代价与数据

`tests/hela/array_share`（新增，run.sh 第 26 步）：4 线程各 append 200 万次，只写 `[dynamic]` 头（backing 预分配，无分配器噪音）：

| 元素布局 | 时间（best of 3） | 说明 |
|---|---|---|
| 40 B（元素 i 与 i+1 共线） | 6.8 ms | `[dynamic]` 头的自然大小 |
| 64 B（`#align(64)` + 尾 padding） | 3.8 ms | 一元素一条线 |

**1.79x**（不同机器/负载 1.4–1.8x）。比例只打印、不断言——机器决定数字，断言只覆盖正确性（append 数、布局常量）。

正例 `tests/hela/sharing` 也随规则改写为「数组安全」形态：`Grouped` 补齐到 64 B、`Left_Side`/`Right_Side`/`Separated_Nested`/`Grouped` 加 `struct #align(64)`；新增运行时断言：`make([]Grouped, 4)` 中相邻元素不共线。

## 在 xrep 里应用（真实场景，诚实结论）

`app/scan.odin` 的 `match_lists` 原本就是 `make([][dynamic][]lib.Match_Result, thread_count)`——40 字节元素，正是本规则描述的形态。改为：

```odin
lib.Match_List :: struct #align(64) {
    #share(worker) list: [dynamic][]Match_Result,
    _: [64 - size_of([dynamic][]Match_Result)]u8,
}
```

`#assert(size_of(Match_List) == 64)`、`#assert(align_of(Match_List) == 64)` 把契约钉在类型上；`worker_data.out_list` 改为 `^lib.Match_List`，append 目标变为 `&w.out_list.list`。

**实测（64 MiB、4.19M/8.4M 命中、1/2/4/8 线程）：无可测差异**（0.35–0.41s 两侧相同）。原因不是伪共享不存在，而是被**串行归并**完全掩盖：

- 纯扫描 64 MiB 只需 0.01 s（≥6 GB/s）；
- 高命中路径 0.35 s 里几乎全部是单线程的 `merge_ordered_matches`（K 路归并 8.4M 条）与区间过滤；
- append 阶段（伪共享所在）是并行的一小段，被串行段淹没。

结论：**xrep 的命中路径瓶颈在单线程归并，不在伪共享**。改动保留（消除真实成本、让类型契约显式、为将来并行归并后兑现），但不在 dense 场景声称收益。这条负面结论本身是下一轮的输入。

## 验证

- `tests/hela/run.sh` **27 步**全绿（新增第 26 步），`HELA_TSAN=1` 全绿；27 个负例不变（新规则是 warning，不新增负例目录）；
- `tests/hela/sharing` 正例在 `-warnings-as-errors` 下干净通过；
- xrep：`test.sh`（140 单测 + 内建自检）与 `verify.sh`（78 golden + run2 34 + run3 56 + 护栏）全过，行为逐字节不变；
- 未改动清单（v7）与 `layout_hash`。

## 后续：并行归并已落地（xrep ADR 0011）

M25 的负面结论（dense 下伪共享无可测收益，瓶颈在单线程归并）在下一轮被兑现：
xrep 把 K 路归并从"线性扫最小游标 + 单线程"换成"最小堆 + 按全局 rank 精确切分的并行归并"。

- dense 端到端 0.35 s → 0.06 s（4 线程，**5.7x**）；merge 段 281 ms → 18 ms（15.6x）；
  filter 段 21 ms → 0（有序输出上 `--after/--before` 是一个连续区间，二分即可）；
- 1 线程 0.38 → 0.13 s 是**纯算法**收益（2.9x），说明算法与并行度是正交的两件事；
- 输出与旧实现逐字节相同且与 `--threads` 无关（切分只依赖数据），145 单测 +
  78 golden + run2/run3 全过。

至此 `Match_List` 的整 cache line 改动才在端到端兑现：扫描与归并现在都是带宽受限，
append 阶段不再被串行段淹没。详见 xrep 的 `.ai-memory/adr/0011-parallel-merge.md`。

## 已知限制

- 规则是类型级、保守的：从不进入数组的类型也会收到 warning（`#+analysis !sharing` 可关整个分析）；
- 不覆盖 `[dynamic]T` 的**扩容**重分配（那是分配器行为，不是布局），也不覆盖 `#soa`/`#aosoa`（字段级转置，语义不同）；
- 不在数组使用点逐个报（那需要去重与类型完成状态判断，收益不抵噪音）。
