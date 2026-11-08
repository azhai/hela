# M24 — 跨类型 sharing 分析（nested 展开）

> 目标：补上 `#+analysis sharing` 的结构性盲区——两个 writer 各自住在**不同类型**里时，任何类型自己的分析都看不见对方的字节。该盲区在 xrep 实战重构（ADR 0010 的 `worker_data`）中得到实证，是本轮的直接动机。

## 问题

`#share(label)` 的分析在 `check_struct_sharing` 里比较**同一个 struct 的直接字段**。考虑：

```odin
Tail_Writer :: struct { #share(left) tail_hot: u64, _: [24]u8 }
Head_Writer :: struct { #share(right) head_hot: u64, _: [24]u8 }
Cross_Bad   :: struct { a: Tail_Writer, b: Head_Writer }
```

`a.tail_hot` 落在字节 0..8、`b.head_hot` 落在字节 32..40——同一条 cache line，两个不同 writer，真伪共享。但：

- `Tail_Writer` 的分析只知道自己内部，不知道 `a` 会被放在外层哪里；
- `Head_Writer` 同理；
- 外层 `Cross_Bad` 自己没有任何标注字段，旧版分析直接早退。

**没有任何一层能看到这对。** 这正是「清单/分析以类型为单位，而伪共享以放置位置为单位」的缝隙。

## 设计：谁看得见，谁报告

新增第二阶段：外层 struct 把**嵌套 by-value struct 的标注字段**拍平成绝对字节区间，与直接标注字段、与其他嵌套字段两两比较。报告归属遵循一条原则——**pair 由最先能同时看见两者的那一层报告**：

| pair | 报告者 |
|---|---|
| 直接字段 × 直接字段 | 原有第一段（不变） |
| 直接标注字段 × 任意嵌套范围（含自身内部） | 本层（嵌套类型看不见外层给它整体标的 label） |
| 两个嵌套字段（top_field 不同）的范围 | 本层 |
| 同一嵌套字段内部的两条范围 | 嵌套类型自己的分析（本层跳过） |

同一 pair 在两个视角（「类型内相对位置」与「实例放置」）都构成真冲突时会各报一次，消息不同（一个建议改类型布局，一个建议改字段放置）——是重复但不是误报。

新增**错位警告**：嵌套类型含标注字段、但外层把它放在非 cache line 倍数的字节上（如 `lead: u8` 之后），它自己的分析以 offset 0 为基准、已经失真。报 warning 而非 error——错位本身不是伪共享对，修法（`#align(64)`）是机械的；每字段只报一次。

消息里的字段用点路径（`b.head_hot`），错误建议只给 `#align`（跨字段 pair 无法用 `#split` 修）。

## 实现（`src/check_type.cpp`，其余零改动）

- `Shared_Field_Range`：label / 点路径 / 绝对 offset / size / top_field 索引 / token。
- `collect_shared_field_ranges`：递归拍平（深度上限 16；指针与数组是边界——指针指向的字节不在这里，数组不提供元素类型自身分析之外的信息）。
- `sharing_resolved_base_type`：`base_type` 的安全版。字段类型可能是**检查中**的 named 类型，`alloc_type` 不清零，`Named.base` 可能是垃圾——走它是 segfault（实测）。借 `Named.type_name` 实体的 `Entity_State` 判断是否已 Resolved。
- `sharing_struct_flattenable`：排除 SOA / raw union / 多态模板 / 特化实例。
- `sharing_type_has_labels`：**无副作用**预检。这是本次最关键的一课，见下。
- 清单不动：v7、`layout_hash` 均不变，ABI 基线无需刷新。

## 两个真坑（都复现了 memory 里的旧伤）

1. **过早读 offsets**：flatten 循环先于 `type_set_offsets(t)` 读 `t->Struct.offsets[i]`（裸指针，未算时为 null/垃圾）→ SIGSEGV。教训同 M21：offsets 必须先算后读。
2. **过早算 offsets**：第一版对无标注 struct 也做 flatten + `type_set_offsets`，而未标注 `#+analysis` 的文件**默认全开**（`ast_file_analysis_flags` 返回 `AnalysisFlag_All`）。core 库的海量 struct 因此在字段声明点提前触发布局计算，多态特化类型的 offsets 缓存被毒化 → `llvm_backend_general.cpp(3367): offset >= prev_offset`（正是 M15 记过的「编译器偏移缓存」坑，这次从分析侧再次踩中）。
   修复：进入任何布局操作前，先做**只读类型树**的标注预检（`sharing_type_has_labels`，不碰 offsets）；无标注树直接早退，行为与旧版完全一致。`-no-sharing-analysis` 曾是定位此坑的关键开关（加了它 core 立刻变绿，把嫌疑锁死在 sharing 路径）。

## 验证

- `tests/hela/sharing`：新增跨类型正例 `Separated_Nested`（两个不同类型错开一条线）+ `#assert`；
- `tests/hela/sharing_fail`：新增跨类型负例 `Cross_Bad`（32 字节错位、同线不同 writer）→ 报 `False sharing: 'b.head_hot' ... and 'a.tail_hot'`；
- `tests/hela/sharing_misplaced`（新目录）：错位嵌套 → warning 不 error，消息含 `not a multiple of the cache line`；
- `tests/hela/run.sh` 26 步全绿（步骤数不变，[13] 内扩展），`HELA_TSAN=1` 全绿；
- `./odin test tests/core -all-packages` **1072 tests 全绿**（含多态密集的 `core:odin` / `core:nbio`——正是踩坑并修复的输入）;
- xrep（Hela 分支）：`build.sh` + `test.sh`（140 单测 + 自检）+ `verify.sh`（run2 34 断言 + run3 56 断言 + 护栏）全部通过，行为逐字节不变。

## 已知限制（有意为之）

- 嵌套类型自身文件未开启 sharing 时，其**内部** pair 不由外层代报（报告归属原则的自然结果）；
- 数组字段不展开（`[N]T` 的相邻元素关系由 `T` 自身分析 + 元素大小给出）；
- 多态模板/特化不展开（布局在实例化点才算得准）。
