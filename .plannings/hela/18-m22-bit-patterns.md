# M22：位级布局真源与可复用的按位匹配结构

> 本轮的命题：**Hela 之前的语法都是「一次性布局声明」，缺一个可以命名、组合、跨库复用的结构。**
> 选的落点是「按位匹配」：协议头、消息 tag、寄存器映射都是位级的，而清单此前只导出字节 offset。
> 结论是把「位」也纳入编译器真源，并做一个泛型决策表，让规则从类型声明派生、一次编译、只读复用。

---

## 1. 为什么是「位」

M0–M21 把字节布局做成了唯一真源：`type_set_offsets_of` → 清单 → `#assert` → AI 读清单。
但 `bit_field u16 { kind: u8 | 3, flags: u8 | 5, tag: u16 | 8 }` 的**位**信息一直只在编译器内部：

| 已有 | 缺的 |
|---|---|
| 上游 `type_field_bit_offset/bit_size` 编译期查询 | 清单字段虽有 `bit_offset`/`bit_size`，但没有可直接使用的**掩码** |
| 清单导出 `bit_offset`/`bit_size` | 路由表仍要手写 `0x0007`、`0x00f8` 这类魔数 |
| `#assert(size_of(T))` 能锁字节 | 没有编译期手段锁「这个字段值编码后落在哪几位」 |

手写的掩码可以悄悄和声明不一致：`kind` 从 3 位改成 4 位，源码改了、清单改了、`#assert` 过了，
而散落在 `if header & 0x7 == 1` 里的 `0x7` 一个都不会报错。这正是 Hela 最该消灭的漂移。

另外，用户要的是**可复用**的东西，而不是又一个「写一次就完」的标签。所以本轮同时交付：

- 语言结构：位段掩码/编码成为编译期常量（可从类型派生、可进 `#assert`、可导出清单）；
- 数据结构：一个泛型、零分配、只读的位模式决策表，规则可组合、可校验、可跨类型复用。

---

## 2. 语言改造

### 2.1 单一真源：`src/bit_layout.cpp`（新增）

`Type_BitField.bit_offsets` / `bit_sizes` 是位布局的唯一真源。新增的独立文件只做两件事：

```cpp
gb_internal bool bit_field_lookup(Type *t, InternedString name, i64 *bit_offset_, i64 *bit_size_);
gb_internal u64  bit_field_mask(i64 bit_offset, i64 bit_size);
```

`checker.cpp` 在 `types.cpp` 之后 include 它，于是 `check_builtin.cpp`（intrinsic）与
`layout_writer.cpp`（清单）**读同一份计算**。掩码不是「又写了一遍」，而是同一函数的两个消费者。
仍是 unity build 里一个独立文件，不碰 `types.cpp` / `check_type.cpp` 主干。

### 2.2 两个 intrinsic

上游已有 `type_field_bit_offset(T, name)` / `type_field_bit_size(T, name)`，本轮补的是按位匹配真正需要的两件：

```odin
layout_bit_mask_of   :: proc($T: typeid, $name: string) -> u64 ---
layout_bit_encode_of :: proc($T: typeid, $name: string, $value: u64) -> u64 ---
```

- `layout_bit_mask_of(Header, "kind")` → `0x7`，**已移位**到 backing word 中字段的位置；
- `layout_bit_encode_of(Header, "flags", 21)` → `0xa8`，把值放进那几位；
- 值超宽是**编译错误**：`layout_bit_encode_of(Header, "kind", 8)` →
  `Value 8 does not fit in the 3-bit field 'kind'`。普通 `<<` 会静默溢到 `flags` 里；
- 非 `bit_field` 类型、不存在的字段名都各自报错（3 个负例进 `run.sh`）。

两者都是编译期常量，因此能进 `#assert`、能当数组长度、能在常量表里组合。返回 `u64` 是刻意的选择：
协议字最长就是一个机器字，超过 64 位的位段由 helper 返回 0 并由编译器报错，不假装支持。

### 2.3 清单 v7 + `hela-layout --bits`

`src/layout_writer.cpp`：字段 map 从 14 键升到 **15 键**，新增 `bit_mask`（hex 字符串，避开 JSON
读端的 64 位整数精度问题）。顶层 version 6 → 7。

**`layout_hash` 不变**：掩码是从已有的 `bit_offset`/`bit_size` 派生的元数据，不改一个字节。
所以 `tests/hela/abi/golden.hash` 与 5 份 `golden.<target>.hash` 都不需要刷新——实测 `run.sh` 直接过。

`core/hela/layout/bits.odin` + `--bits` 把清单渲染成位地图，并且**独立重算**每个掩码：

```
main::Bits  backing=u16  width=16 bit(s)  hash=514dd1b2d2491165
  bits 00..02  x  width=3  mask=0x7  ok
  bits 03..07  y  width=5  mask=0xf8  ok
  unused bits                  mask=0xff00
  segments=2  covered=8 bit(s)  unused=8 bit(s)

bit_field types: 1  mask mismatches: 0
```

`ok` 是「清单里的 `bit_mask` 与从 `bit_offset`/`bit_size` 独立重算的结果一致」。`MISMATCH` 表示清单
被手改过或来自旧工具——和 `--stable` 一样，这是让 AI 能信任输入的检查，不是装饰。
`--bits` 拒绝 v6 清单（没有 `bit_mask` 契约），与 `--stable` 拒绝 v5 的做法一致。

---

## 3. 可复用的数据结构：`core:hela/pattern`

### 3.1 规则代数

```odin
Rule :: struct #explicit #align(8) { mask: u64, value: u64, id: u32, flags: u32 }  // 24 B

term     :: proc($T: typeid, $name: string, $value: u64, id: u32) -> Rule
and_rule :: proc(a, b: Rule, id: u32) -> (rule: Rule, ok: bool)
decode   :: proc($T: typeid, $name: string, word: u64) -> u64
```

- `term(Header, "kind", 1, ID_DATA)` 的 mask/value **全部来自 intrinsic**，源码里没有 hex；
- `and_rule` 把两个不同位段的约束并成一条规则，若共享位上要求矛盾则失败；
- `decode` 是配套的反向操作，掩码同样来自真源。

于是「规则」成了可命名、可组合、可传值的一等结构，而不是散落的 `if` 条件。
改 `Header` 的位宽，所有派生规则自动跟着变，编译期 `#assert` 立刻指出不合法的值。

### 3.2 决策表

```odin
Table :: struct($N: int) #explicit {
    rules:      [N]Rule,          // 24 B each
    nodes:      [8 * N + 8]Node,  // 16 B each, fixed pool
    node_count: u32, root: u32, flags: u32,
    _:          [4]u8,            // tail alignment, explicitly named
}
```

- `build(&table, rules)`：先 `validate`（规则必须互斥、value 不得越出 mask、mask 不得为 0），
  再按「区分度最高的位」递归二分，don't-care 规则复制到两侧，生成扁平只读节点数组；
- `match(&table, word)`：逐位走树，O(depth)、零分配、零哈希、与规则条数无关；
- `linear_match` 保留为刻意朴素的参考实现，测试拿它逐字对照；
- 整个表是 `#explicit`，所以 `-emit-layout` 能直接看到 `Rule=24 B / Node=16 B / Table_4=752 B`、
  padding 都是 0，worker 之间可以只读共享。

`Table($N)` 是泛型：同一个结构同时用于 16 位 `Header` 和 32 位 `Frame`，两套完全不同的规则集。

### 3.3 一个真坑：叶子必须做最终匹配验证

第一版决策树在叶子直接返回规则 id，穷举测试在 `word=0` 就红了。原因值得记下来：

> 判别树只能**排除**候选，不能**确认**候选。规则 `ERR = (kind==0) && (tag==0xab)` 的
> `tag` 位如果没被用来分裂任何分支，那么 `word=0` 会一路排除掉其它规则、到达 `ERR` 的叶子，
> 却根本不满足 `tag==0xab`。两条规则互斥，只保证「最多一条能匹配」，不保证「剩下的那条匹配了」。

修法：叶子存**规则索引**而不是结果，`match` 到达叶子后再做一次 `(word & mask) == value` 校验。
这只多一次 and/compare，却把「shadowed rule / 误报命中」这类最难查的路由 bug 从根上挡住。
现在 16 位空间 65536 个字全部穷举，与独立 oracle 和 `linear_match` 三方一致（8736 命中）。

### 3.4 第二个真坑：32 位 target 会改写 u64 对齐

跨 7 个 target 检查时 `linux_i386` 报 `#assert(align_of(Rule) == 8)` 失败——和 M21 的
`Unpinned_Wire` 是同一个现象：`u64` 在 i386 上只按 4 对齐，`#explicit` 钉得住字节、钉不住对齐。

修法是结构体级 `#align(8)`（就是 `Fixed_Wire` 的手法），而不是放宽断言。修完后 7 个 target 的
三个类型 hash 完全一致，`--stable` 报 `3 stable, 0 drifting, 0 missing`。
这条断言被写进 `run.sh` 步骤 20，以后再有人动 `Rule` 的形状会立刻红。

---

## 4. 验证

| 项目 | 结果 |
|---|---|
| `build_odin.sh release` | 通过 |
| `tests/hela/run.sh` | **25 步全绿**（23 → 25：新增位掩码/位地图、按位匹配穷举两步；负例 22 → 25 个） |
| `HELA_TSAN=1 ./tests/hela/run.sh` | 通过，MPMC 2P/2C / io / exec 均无 data race |
| `odin test tests/core -all-packages` | 1072 tests 全绿 |
| CBOR v7 | 1534/1534 B 完整消费；顶层 6 键；所有字段 map 15 键；`bit_mask` 全在场 |
| 穷举 | 16 位 Header 65536 字、32 位 Frame 65536 字，tree / linear / 独立 oracle 三方一致 |
| ABI 门禁 | `golden.hash` 与 5 份 `golden.<target>.hash` **未刷新**（`layout_hash` 不变） |
| 跨 target | 7 个 target `core/hela/pattern` check 全过；`--stable` 3 stable / 0 drifting |
| 负例 | 非 bit_field、字段不存在、值超宽，各报出可 grep 的明确消息 |

---

## 5. 怎么复用 / 取舍

`core:hela/pattern` 没有接进 `exec` 或 `io`，是刻意的：那两个包已经有经过 litmus + TSAN 验证的
分派不变量，为一个「展示用」特性去改热路径不划算。接入方式是把规则表放在 worker 初始化阶段
（`build` 一次，之后只读），例如按 `io.Completion` 的 kind/flags 组合选 handler id；
handler 仍然只在 `event.loop_tick` 内调用，M20 的确定性分派不变量不受影响。

明确**不做**：

- 不新增语法关键字。`#align`/`#offset` 那一轮已经证明：加新 token 要同步 `core/odin/parser`
  与 `core/odin/ast`（自举解析库），成本高。本轮用「intrinsic + 编译期 `$` 参数 + 泛型 struct」
  达到同样的可复用性，且零 parser / 零 codegen 改动。
- 不做有序优先级的规则集（"第一条匹配优先"）。协议路由里被遮蔽的规则是 bug，不是特性，
  所以 `build` 直接拒绝重叠。`linear_match` 只是测试用的参考语义。
- 不把决策树改成完美哈希或 SIMD 批量匹配。当前深度是 O(位数)，节点全在连续内存里；
  要更快得先有真实的尾延迟剖面，而不是先猜。
- 不支持超过 64 位的位段。Odin 的 `bit_field` backing 最长就是机器字，`bit_field_mask` 遇到
  越界返回 0，由编译器转成错误。

---

## 6. 关键文件

| 文件 | 作用 |
|---|---|
| `src/bit_layout.cpp` | **新增**。`bit_field_lookup` / `bit_field_mask`：位段查询的单一真源，由 `checker.cpp` 在 `types.cpp` 后 include |
| `src/check_builtin.cpp` / `checker_builtin_procs.hpp` | 两个新 builtin 的注册与求值；复用 `type_field_bit_offset` 的常量字符串参数解析 |
| `base/intrinsics/intrinsics.odin` | `layout_bit_mask_of` / `layout_bit_encode_of` 声明 |
| `src/layout_writer.cpp` | 清单 **v7**：字段加 `bit_mask`（hex 字符串），`sw_map(14 → 15)`；`layout_hash` 不变 |
| `core/hela/layout/bits.odin` / `layout.odin` | `bits_report` 位地图 + 独立重算校验；`Field_Layout.bit_mask` |
| `cmd/hela-layout/main.odin` | `--bits`，拒绝 v6 清单 |
| `core/hela/pattern/pattern.odin` | **新增**。规则代数、互斥校验、泛型决策表、叶子终验、`linear_match` 参考实现 |
| `tests/hela/pattern/main.odin` | **新增**。编译期位断言 + 两种字宽 × 65536 穷举 + 重叠负例 |
| `tests/hela/bit_{not_field,no_field,overflow}/` | **新增**。3 个 intrinsic 负例 |
| `tests/hela/run.sh` | 25 步；版本断言 6 → 7；库 strict vet 加 `pattern` 包；pattern 库跨 target `--stable` 门禁 |
