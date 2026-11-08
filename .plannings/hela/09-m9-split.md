# M9 — `struct #split(N)`：一个标签替掉手算 padding

状态：✅ 完成并验证

## 起因：`#explicit` 的算术税

`core:hela/ring` 的 `Ring` 用 `#explicit` 写成这样：

```odin
Ring :: struct($T: typeid) #explicit #align(Cache_Line) {
	head:  u64,  _: [Cache_Line-8]u8,
	tail:  u64,  _: [Cache_Line-8]u8,
	slots: []T,  mask: u64, _: [Cache_Line-16-8]u8,
}
```

布局一目了然，代价是每次改字段都要重算三处减法：`[Cache_Line-16-8]u8` 里的 `16-8` 来自「slots 是 16 字节的 slice header，mask 是 8 字节」。加一个 `u32` 字段，前面那几个数字全要改；算错不会报错——它只是变成一个**能编译、但共享了 cache line** 的结构体。这正是 Hela 想消灭的失败模式，却在自己的第一个库里复发了。

## 先确认上游已有的能力

`type_set_offsets_of`（`src/types.cpp`）里，每个字段的对齐是：

```cpp
i64 align = gb_max(type_align_of_internal(t, &path), min_field_align);
curr_offset = align_formula(curr_offset, align);
```

所以 `#min_field_align(N)` 的含义就是「每个字段至少 N 对齐」，也就是**每个字段都从 N 的倍数开始**。实测 `struct #min_field_align(64) #align(64) {a: u64, b: u64, c: u8}`：

| 观察项 | 结果 |
|---|---|
| `size_of` / `align_of` | 192 / 64 |
| 字段 offset | a=0, b=64, c=128 |
| `[3]S` 的 stride | 192（不是 16） |
| 逐字段读写 | 全部正确，无错位 |

也就是说布局层和 codegen 层都已经支持「每字段一行」，不需要新算法。缺的只是**说法**：`#min_field_align` 是 ABI 术语，不是布局意图；而且它和 `#explicit` 互斥（`#explicit` 会把这段 padding 判为「未命名」而报错），用了它就必须放弃字节地图保证。

## 决定：`#split(N)` = 声明式的 `#align(N) + #min_field_align(N)`

```odin
Split :: struct #split(64) {
	head: u64,
	tail: u64,
	flag: u8,
}
```

语义（三条，全部可验证）：

1. 每个字段的起始 offset = 上一个字段结束位置向上取整到 N 的倍数。
2. 结构体大小向上取整到 N 的倍数，对齐为 N。
3. padding 是**声明的**：它由上面两条完全决定，所以清单里的 `padding_before` 就是手工版 `_: [N]u8` 的数字，不需要再猜。

第 3 条是它区别于 `#min_field_align` 的地方，也是它能替代 `#explicit` 的地方：`#explicit` 的承诺是「每个字节都有名字」，`#split` 的承诺是「每个字节都有公式」。两者都是「所见即所得」，只是后者用一个数代替了一堆减法。

## 实现（约 90 行）

| 位置 | 改动 |
|---|---|
| `src/parser.hpp` | `AstStructType` 增加 `Ast *split`、`bool is_split` |
| `src/parser.cpp` | 解析 `#split(N)`（要求括号，重复报错）；`ast_struct_type` 增参；`clone_ast` 带上 |
| `src/types.cpp` | `TypeStruct.split_align`：**声明**的 stride，与 `custom_min_field_align`（**生效**的对齐）分开存 |
| `src/check_type.cpp` | `check_struct_split_stride()` 早于任何 offset 计算，装好对齐；`check_struct_split_fields()` 在字段检查后核对每个 offset |
| `src/layout_writer.cpp` | 清单新增 `split`（stride）与 `explicit`（bool）两个元数据字段 |
| `src/checker_global.cpp` | 把 `split` 表达式加进全局图遍历 |

两处设计选择值得记一笔：

**① `split_align` 不直接复用 `custom_min_field_align`。** 后者是「对齐下限」，很多来源（`#min_field_align`、未来的 ABI 修补）都会写它；`split_align` 只在 `#split` 时非零，是纯粹的意图标记。清单要报「这个结构体是怎么声明的」，不能报「它的对齐最后是多少」。

**② 校验是冗余的，而冗余正是目的。** `check_struct_split_fields()` 重新算一遍 `round_up(previous_end, stride)` 并与编译器给出的 offset 对比。按构造它必然相等——除非 `type_set_offsets_of` 被改坏，或者 `#split` 与别的 tag 组合出了意外。这就是 Hela 的全部方法论：让编译器把自己的承诺写下来，然后逐条核对。

## 与其他 tag 的关系

| 组合 | 结果 | 原因 |
|---|---|---|
| `#split(N)` + `#explicit` | ❌ 报错 | 两者的承诺重叠；`#split` 已经固定了每个 offset，`#explicit` 无事可做 |
| `#split(N)` + `#align` | ❌ 报错 | `#split(N)` 已经设定对齐为 N，冗余 |
| `#split(N)` + `#min_field_align` | ❌ 报错 | 同一个东西的两种拼写 |
| `#split(N)` + `#max_field_align` | ❌ 报错 | 把字段对齐压到 stride 以下会破坏 stride |
| `#split(N)` + `#packed` | ❌ 报错 | packed 没有 padding，无处安放 stride |
| `#split(N)` + `#soa` / `#raw_union` | ❌ 报错 | 字段不按顺序排，没有「上一个字段结束位置」 |
| `#split(N)` + 多态参数 | ✅ | stride 是常量表达式，逐实例化解析 |

字段自身对齐超过 stride 时（例如 `#split(64)` 里放一个 128 字节对齐的 SIMD 向量）同样报错——否则「字段 i 从 i×N 开始」这句话就不成立了。

## 它做不到什么

`#split` 是**整个结构体**一刀切。`Ring` 真正想要的是「head 一行、tail 一行、slots+mask 共用一行」：

| 写法 | 大小 | 线数 |
|---|---|---|
| `#explicit` 手工 padding（现状） | 192 | 3 |
| `#split(64)` | 256 | 4 |

`slots` 与 `mask` 是 init 之后只读的，共享一行反而更好（少一次 cache 查询）。所以 `Ring` 保留 `#explicit`，`#split` 留给「每个字段都是独立热状态」的结构体（计数器、per-CPU 统计、光标组）。

要做到字段级，需要 `@(align(N))` 能写在**字段**上。现在 Odin 只支持变量级 `@(align)`，字段列表不接受 `@`（语法错误），上游的 `field_align` 也已被 `#min_field_align` 取代。实现它需要三处改动：字段解析器接受 `@(...)`、`Entity` 上存字段对齐、`type_set_offsets_of` 读取它。这是下一步的候选，不是这一版的范围。

## 验证

**等价性**（`tests/hela/split`，编译期）：手工版与 `#split` 版并排声明，断言 `size_of`、`align_of`、每个字段的 offset 全部相等：

```odin
Manual :: struct #explicit #align(64) { head: u64, _: [56]u8, tail: u64, _: [56]u8, flag: u8, _: [63]u8 }
Split  :: struct #split(64)           { head: u64, tail: u64, flag: u8 }

#assert(size_of(Split) == size_of(Manual))            // 192 == 192
#assert(offset_of_by_string(Split, "tail") == 64)
#assert(intrinsics.layout_padding_of(Split) == 175)   // 192 - 17，padding 真实存在且被报出
```

**规则不是 `i*N`**：`Wide :: struct #split(64) {tag: u8, body: [100]u8, end: u8}` → `end` 在 192 而不是 128，因为 64+100=164 要向上取整到 192。断言写死这个值，防止有人把它「优化」成 `i*N`。

**多态**：`Box($T)` 用 `[80]u8` 实例化 → size 192、`stamp` 在 128。

**运行时**（同一个文件，`-o:speed`）：`[3]Split` 的 stride 是 192、6 个字段全部 round-trip、`&tail - &head >= 64`。编译期断言管不到 codegen，这一层才管得到。

**负例**（`run.sh` 第 4 步表驱动）：

| 目录 | 期望错误 |
|---|---|
| `explicit_fail` | `requires every byte to be named` |
| `split_plain` | `is a Hela feature`（无 `#+dialect hela`） |
| `split_conflict` | `keep only '#split'`（与 `#explicit` 冲突） |

**清单**：`tests/hela/split` 导出 `Split` 的 `split: 64`，`padding_before` 分别为 0/56/56——手工版那两行 `_: [56]u8` 的数字，现在由编译器算给你。

**ABI 基线**：`tests/hela/abi` 增加 `Cursor`（两个游标各占一行），`golden.hash` 重新生成。

## 顺带修好的一件事：`layout_hash` 现在真的只描述字节

`layout_hash` 原先会哈希每个字段的名字，包括 `_` 这种 padding 占位符。结果是「手工 padding」与「`#split`」写出来的**同一批字节**得到不同 hash——ABI 门禁会因为换了个写法而报错，把「表述变化」误判成「ABI 变化」。

改法：哈希时跳过名为 `_` 的字段。于是 `tests/hela/split` 里两个版本：

```
split::Manual	062e77f196d3cf1e
split::Split	062e77f196d3cf1e
```

`run.sh` 第 9 步直接断言这两个值相等。检测能力没有损失：padding 覆盖的字节仍然通过相邻字段的 offset 与整个 `size` 进入哈希。

这次改动的直接后果：`abi::Ring_Header` 的 hash 从 `9521ea22b62f580d` 变成 `90d7a5295de285a9`（它有 `_` 字段），`golden.hash` 中其余 13 行不变。

## 顺带修好的第二件事：字节地图不再把有公式的 padding 叫「padding」

`hela-layout` 以前把 `#split` 生成的空隙一律标 `<padding>`，和「没人要的对齐填充」看起来一样。清单里加了 `split` 之后，渲染器区分开：

```
Split	(struct, split)
  size 192 B	align 64 B	cache lines 3	padding 175 B (tail 63)	hash 062e77f196d3cf1e
  declared	#split(64)
  line 1	[64..127]
    tail	@64	8 B	u64
    <stride>	@72	56 B
```

`<stride>` 是「按 56 = 64-8 算出来的」，`<padding>` 是「编译器插的」。这个区别对读清单的模型很重要：前者可以预测，后者只能记录。
