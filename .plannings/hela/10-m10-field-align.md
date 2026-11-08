# M10 — 字段级 `#align(N)`

> 目标：把「哪些字节共享一条 cache line」从整结构体的一刀切，变成逐字段可写、可断言、可导出。

## 1. 为什么需要它

在此之前 Hela 有三个布局工具，缺的正好是第四个：

| 写法 | 表达力 | 问题 |
|---|---|---|
| `struct #explicit` | 逐字节 | 每个字段后面都要手算 `_: [N]u8`，加一个字段要重算整段 |
| `struct #split(N)` | 每个字段一行 | 一刀切：无法表达「两个游标各占一行，slots+mask 共用第三行」 |
| `#align(N)` / `#min_field_align(N)` | 整个结构体 | 同上，粒度是结构体 |
| **`#align(N)` 加在字段上** | **逐字段** | — |

`core:hela/ring` 就是那个反例：`head`、`tail` 各占一行，`slots`+`mask` 故意共占第三行。`#split(64)` 会把它变成 4 行（每个字段一行），`#explicit` 要手写三个 padding 数组。字段级 `#align` 是唯一能直接写出原始意图的形式。

## 2. 语义

```odin
Ring :: struct {
    #align(64) head: u64,   // 偏移 0
    #align(64) tail: u64,   // 偏移 64
    #align(64) slots: []T,  // 偏移 128
    mask: u64,              // 偏移 144，与 slots 同行
}
```

三条规则：

1. **对齐当前字段的偏移**：`offset = round_up(上一个字段末尾, N)`，效果等价于 `#min_field_align(N)` 只作用在这一个字段上。
2. **抬升结构体对齐**：`align_of(struct) = max(各字段自然对齐, 各字段声明的 N)`。这条不是可有可无的：没有它，`[2]Ring` 的第二个 `head` 就未必落在行边界上，而「数组里每个元素都对齐」才是真正的承诺。副作用是 `size_of` 也向上取整到 `N`，于是数组 stride 与对齐一致。
3. **只升不降**：`N < align_of(字段类型)` 报错。把 `u64` 放到 4 字节边界上，等于要求后端发出类型本身不允许的 load，是错的优化方向；要紧凑就该用 `#packed`。

### 互斥表

| 与 `#align` 同用 | 结果 |
|---|---|
| 结构体级 `#align(N)` | 允许（结构体对齐要 ≥ 字段对齐） |
| `#packed` | 拒绝：packed 没有 padding 可对 |
| `#raw_union` | 拒绝：所有 variant 都在偏移 0 |
| `#split(N)` | 拒绝：stride 已经规定了每个字段的位置，字段对齐会破坏它 |
| `#max_field_align` | 拒绝：一个抬升、一个封顶，语义冲突 |
| `#soa` | 拒绝：字段被转置，没有单一偏移 |
| `struct #explicit` | 拒绝：`#align` 插入的正是 `#explicit` 禁止的无名 padding |

最后一条是刻意的：`#explicit` 的承诺是「每个字节都有名字」，而 `#align` 的承诺是「这个字段落在边界上」。两者都能描述同一批字节，但不能同时作为描述；同时写上只会得到一条“你的 padding 没命名”的错误，掩盖真正的原因。所以 `#explicit` 的检查在发现字段带 `#align` 时直接给出冲突信息并停止。

## 3. 实现位置

| 文件 | 改动 |
|---|---|
| `src/parser.hpp` | `Ast_Field` 增加 `Ast *align`；`FieldFlag_align` |
| `src/parser.cpp` | `parse_argument_field_prefix()`：`#align(N)` / `#share(label)` 这两个带参数的前缀在这里消费；`parse_field_list` 把参数挂到字段上（`x, y: u64` 共享一个对齐，和共享一个类型一致） |
| `src/entity.cpp` | 复用 `Entity.Variable.custom_align`（变量级 `@(align=N)` 的同一个槽位），字段即「偏移的对齐」 |
| `src/check_type.cpp` | `check_field_align()`：方言门控 + 互斥 + 只升不降 |
| `src/types.cpp` | `type_set_offsets_of` 读字段对齐（单一真源仍在这里）；`type_align_of_internal` 把字段对齐算进结构体对齐 |
| `src/layout_writer.cpp` | 字段级 `declared_align`，清单 v3 |
| `core/odin/{ast,parser}` | 自举解析库同步支持，`odin doc` 才能解析 Hela 文件 |

一个看起来麻烦但其实不用做的事：**back-end 不需要改**。`lb_type_internal` 早就按 `type_set_offsets_of` 给出的偏移插入显式 padding（`lb_type_padding_filler`），并在必要时降级为 packed struct，所以「偏移 8 到 64 之间空着 56 字节」这条对 LLVM 就是 56 字节的填充类型。`#split` 走的也是这条路。

## 4. 验证

`tests/hela/field_align/main.odin`：

- 与手写 padding 的 `Manual` 逐字段 `offset_of` 相等，`size_of` 相等；
- `align_of(Counter) == 64`、`layout_cache_lines_of(Counter) == 2`、`padding == 96`、`tail_padding == 40`；
- `Mixed`（`u8` + `#align(32) u8` + `u8`）证明只抬升、不连锁：32、33 连续；
- 多态 `Aligned_Ring($T)` 在每个实例化点重算，`u32`/`u128` 的 `slots` 都在 64，size 分别是 128/192；
- 运行时：`[4]Counter` 里每个元素的 `pushes`/`pops` 地址都对 64 取模为 0，且 `&cs[1].pushes - &cs[0].pushes == 128`。

四个负例各自锁一条拒绝理由：`align_below`、`align_plain`、`align_explicit`、`align_split`。

`core:hela/ring` 改用字段级对齐后，布局与 `#explicit` 版逐字节一致（192 字节、3 条 cache line），但源码里不再有 `_: [56]u8`。`tests/hela/ring` 的 padding 断言随之从 0 变成 152/40——这不是回归，而是把「padding 本来就是 152 字节」这句话写在了它该在的地方。

## 5. 清单变化（schema v3）

字段条目多一个 `declared_align`：

```json
{"name":"pushes","type":"u64","offset":0,"size":8,"align":64,"declared_align":64,
 "cache_line":0,"spans_cache_line":false,"padding_before":0,"bit_offset":-1,"bit_size":0}
```

`align` 是「算偏移时实际用的对齐」，`declared_align` 是「源码里写的要求」。两者分开是有意义的：`hits` 的 `align` 是 8、`declared_align` 是 0，而 `pushes` 两者都是 64。工具想知道「这个字段是被要求的，还是碰巧的」，只能看后者。

`hela-layout` 的字节地图把声明了 `#align` 的行标出来：

```
  line 0	[0..63]
    pushes	@0	8 B	u64	#align(64)
    <padding>	@8	56 B
```

## 6. 已知限制

- 不能降低对齐（见规则 3）。
- 字段对齐的 `N` 必须是 2 的幂（与 `#align` 结构体级一致）。
- `#explicit` 结构体里的字段不能用 `#align`：要么手写 padding，要么用 `#align`。
- 结构体注释里的行边界假设仍然要靠 `tests/` 的 `#assert` 锁住：编译器不知道「64 是这台机器的 cache line」，它只知道你写了 64。`-layout-cache-line` 只影响清单与分析，不影响布局本身。
