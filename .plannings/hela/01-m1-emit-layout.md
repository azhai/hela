# M1 — `-emit-layout` 布局清单

状态：✅ 完成并验证（编译器 `./odin version dev-2026-11:63aac30` + 本地改动）

## 改了什么

| 文件 | 改动 |
|---|---|
| `src/layout_writer.cpp` | **新增**。遍历 `CheckerInfo.entities` 中已导出的 `Entity_TypeName`，读取 `type_size_of` / `type_align_of` / `TypeStruct.offsets` / `TypeBitField.bit_offsets`，输出确定性清单 |
| `src/main.cpp` | `#include "layout_writer.cpp"`；新增 `-emit-layout:<json\|cbor>`、`-emit-layout-file:<path>`；在 `check_parsed_files` 之后触发（紧邻 `-export-semantics`） |
| `src/build_settings.cpp` | `BuildContext` 新增 `emit_layout_format` / `emit_layout_file` |

复用 `semantics_writer.cpp` 的 `sw_map/sw_key/sw_string/sw_int/sw_array` 写入原语（unity build，同 TU 可见），因此 JSON 与 CBOR 同时可用。`sw_bool` 由新文件补充（CBOR simple 20/21）。

## 清单结构

顶层：`version`（当前 2）、`generator`（`"hela"`）、`cache_line`（64）、`types[]`。

每个类型固定 15 个键：`name pkg file line kind size align packed soa cache_lines padding tail_padding explicit split layout_hash`，按 kind 追加：

- `struct` → `fields[]`
- `union` → `variants[]`
- `bit_field` → `backing` + `fields[]`（带 `bit_offset`/`bit_size`）
- `array` → `elem` `count` `stride`
- `matrix` → `rows` `columns` `stride` `row_major`
- `enum` / `bit_set` → `underlying`
- `simd` → 仅 size/align

每个字段固定 10 个键：`name type offset size align cache_line spans_cache_line padding_before bit_offset bit_size`。非位域字段 `bit_offset = -1`、`bit_size = 0`，schema 统一，便于 AI 与工具解析。

## 两个关键设计决定

1. **只读不重算**：不在导出时重新实现对齐规则，一律调用 `types.cpp` 的 `type_set_offsets` / `type_size_of` / `type_align_of`。编译器仍是唯一真源，上游合并时不会出现两套 layout 算法。
2. **`layout_hash` 不含路径**：FNV-1a 64，输入为 kind/size/align/packed/soa/每个字段的 name+offset+size+bit 范围。跨机器稳定，可用于 CI 检测 ABI 漂移。

## 验证

测试输入（`/tmp/layout_test/main.odin`）：普通结构体、`#packed`、`bit_field`、`union`、定长数组、`#simd`、`matrix`、嵌套结构体。

```
S        struct  size= 8 align= 4 pad=3 tail=0
    a  @0 size=1    b @4 size=4
P        struct  size= 5 align= 1 pad=0 tail=0      #packed
B        bit_field size=2 align=2  x@bit0+3 y@bit3+5
U        union   size=16 align=8  variants: u32, u64
Mat      matrix  size=24 align=8 rows=2 cols=3 stride=8
Vec      simd    size=16 align=16
Nested   struct  size=12 align=4 pad=1 tail=1
```

- 连续两次生成 `diff` 完全一致 → 输出确定性成立。
- 已知限制：`#soa` 的字段 offset 是「分量数组」语义而非元素语义，清单按 SOA 生成结构如实输出，可视化时需单独解释（见 `hel:layout`）。
- 已知限制：默认只导出 `Package_Init` / `is_extra` 包（与 `-export-semantics` 同规则），`core`/`vendor` 不进入清单；后续可加 `-emit-layout-for`。

## 版本 2（M9 加入）

新增两个键，都描述「布局是怎么声明的」，不描述字节：

| 键 | 类型 | 含义 |
|---|---|---|
| `explicit` | bool | 该 struct 用了 `#explicit`（每个字节都有名字） |
| `split` | int | 该 struct 用了 `#split(N)` 时的 stride，未用为 0 |

两者**不参与 `layout_hash`**。为了让「同一批字节、两种写法」得到同一个 hash，hash 同时**跳过名为 `_` 的字段**——它们是 padding 的占位符，不构成接口：

| 写法 | 字段列表 | `layout_hash` |
|---|---|---|
| `#explicit` + `_: [56]u8` | `head _ tail _ flag _` | `062e77f196d3cf1e` |
| `#split(64)` | `head tail flag` | `062e77f196d3cf1e` |

这不损失检测能力：padding 覆盖的字节仍然通过后续字段的 offset 和整个 `size` 进入 hash。改宽度 → size 或 offset 变 → hash 变。

`core:hela/layout` 的 `Type_Layout` 同步加了这两个字段；`hela-layout` 渲染时据此把
`#split` 产生的 padding 标成 `<stride>`，而不是 `<padding>`——前者有公式可算，后者没有。
