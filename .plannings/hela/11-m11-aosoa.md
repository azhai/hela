# M11 — `#aosoa[W]`

> 目标：把 AoSoA（array of structures of arrays）从「手写嵌套类型 + 心算 i/W、i%W」变成一种类型写法，并让清单知道它的形状。

## 1. 现状：布局能力早就在，缺的是写法

Odin 的 `#soa` 作用在数组类型上：`#soa[W]T` 得到「字段转置的 W 个元素」，也就是一个 block。于是

```odin
[4]#soa[8]Vec3
```

**已经**是标准的 AoSoA：4 个 block，每个 block 内 `x[8] y[8] z[8]` 连续。实测 `size_of == 384`，block stride 96，block 内 `x`/`y`/`z` 分别在 0/32/64。

所以这一项**不需要改 codegen**（这条和原计划的判断相反，实测后修正）：不需要新的 lowering，不需要新指令，`p[b].x[lane]` 本来就编译成对 `#soa` 结构体的字段选择 + 数组索引。

真正的问题是写法本身：

- `[N/W]` 要求作者先做一次除法，`N` 不是 W 的倍数时静默产生一个不完整的尾部 block；
- 类型里看不出「一共有 N 个元素」，`layout` 清单里 `count` 是 block 数，工具无法区分；
- 访问要写 `a[i/W].x[i%W]`，两个 `i` 的变形散落在业务代码里。

## 2. 语法与语义

```odin
#aosoa[W][N]T   ==   [N/W]#soa[W]T
```

- `W`：block 宽度，必须是 2 的幂（这样 `i/W`、`i%W` 是移位与掩码）。`W == 1` 允许，等价于 AoS。
- `N`：**逻辑元素个数**。必须是 `W` 的倍数，否则报错并给出相邻两个合法值：
  ```
  '#aosoa[8]' needs an element count that is a multiple of the block width, got 100. Use 96 or 104, ...
  ```
  不做「最后一个 block 部分填充」：那会让元素类型依赖位置，索引进而需要分支，正好抵消这个布局带来的收益。
- `T`：必须是 struct，且不能已经是 `#soa`（已经转置过）。
- 方言门控：与其它 Hela 特性一致，需要 `#+dialect hela`。

访问写法保持显式：

```odin
ps: #aosoa[8][1024]Vec3
b := i / 8      // 或 i >> 3
lane := i & 7
ps[b].x[lane] = 1.0
```

显式是刻意的。AoSoA 的收益来自「一次扫一个字段」，把 `i` 藏进一个 `at(ps, i)` 里会掩盖这一点；真正需要的是让**布局**可写、可查、可断言，而不是让访问看起来像 AoS。

## 3. 实现

| 文件 | 改动 |
|---|---|
| `src/parser.hpp` | `Ast_ArrayType.aosoa_block`：`#aosoa[W][N]T` 里的 `W`；`count` 仍是逻辑的 `N` |
| `src/parser.cpp` | 解析 `#aosoa` 时吃掉 `[W]`，要求后面是固定长度数组类型 |
| `src/check_type.cpp` | `check_aosoa_array_type()`：方言、元素类型、`W` 的 2 的幂、`N % W == 0`，然后 `make_soa_struct_fixed(..., W, ...)` + `alloc_type_array(..., N/W)` |
| `src/types.cpp` | `TypeArray.aosoa_width`（仅元数据，不参与类型同一性） |
| `src/layout_writer.cpp` | 数组条目追加 `aosoa_width`、`elements`；数组的 `layout_hash` 纳入元素类型与 count |

一个细节：`alloc_type_array` 是 `Type_Array` 的唯一构造点，而 `alloc_type` 不清零内存（arena bump），所以 `aosoa_width` 必须在那里显式置 0，否则普通数组会读到垃圾。

## 4. 清单：两个 count

```json
{"name":"Particles","kind":"array","size":12288,"elem":"#soa[8]Vec3",
 "count":128,"stride":96,"aosoa_width":8,"elements":1024}
```

- `count` 是类型系统里的数组长度，也就是 **block 数**；
- `elements` 是程序索引用的 **逻辑元素数**（`count * aosoa_width`）；
- `stride` 是 block 字节数，所以 `count * stride == size` 仍然成立。

手写版与语法糖版 `layout_hash` 相同（`8c9c6b3d4e6a20ac`），因为元素类型 `#soa[8]Vec3` 已经携带了 W：

| 类型 | 写法 | hash |
|---|---|---|
| `Particles` | `#aosoa[8][1024]Vec3` | `8c9c6b3d4e6a20ac` |
| `Blocks` | `[128]#soa[8]Vec3` | `8c9c6b3d4e6a20ac` |

这正是 hash 的定位：**字节的指纹**，不是源码写法的指纹。`aosoa_width`/`elements` 说明意图，hash 说明字节。

## 5. 数组 hash 的修正

原来数组的 hash 只覆盖 `kind/size/align`，于是 `[8]u64` 与 `[2][4]u64`（都是 64 字节）hash 相同，而它们的索引语义不同。这一轮把元素类型与 `count` 纳入数组 hash，`tests/hela/abi/golden.hash` 里的 `abi::Chunk` 因此变化（`6e46...` → `b888...`），其余不变。这是一次有意的 fingerprint 收紧，不是 ABI 变化：`Chunk` 的字节没有动。

## 6. 验证

`tests/hela/aosoa/main.odin`：

- `size_of(Particles) == 1024 * 12 == size_of(Blocks)`；
- block 内 `x/y/z` 的地址差 0/32/64，block 之间差 96；
- block 内相邻元素（同字段）差 4 字节——这是这个布局存在的理由；
- 写入 1024 个元素再读回，逐元素校验；
- 把 `&ps[3].x[0]` 转成 `[^]f32` 后连续读 8 个，和逐个 `ps[3].x[lane]` 求和比较，证明「一个字段在一个 block 内连续」。

四个负例：`aosoa_plain`（无方言头）、`aosoa_elem`（元素不是 struct）、`aosoa_width`（W=3 非 2 的幂）、`aosoa_multiple`（100 不是 8 的倍数）。

## 7. 已知限制

- 不支持部分填充的尾 block（见上）。
- `N`、`W` 必须是编译期常量，不能是多态参数。
- 元素必须是具体 struct；多态元素类型在实例化前无法布局（报错而不是猜测）。
- 没有 `aosoa_at(a, i)` 之类的索引助手：见 §2 的理由。
- 顺序遍历一个字段仍然是「每个 block 一次跳转」，想要完全连续的扫描请直接用 `#soa[N]`（纯 SoA）。AoSoA 换的是「block 内多字段同时访问」的局部性。
