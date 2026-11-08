# M4 — `intrinsics.layout_*` 编译期常量

状态：✅ 完成并验证

## 为什么需要

`-emit-layout` 给的是「事后清单」；要让 AI 的布局判断在**编译期**就被验证，需要能在 `#assert` 里直接使用的常量。

## 新增 intrinsic

```odin
layout_padding_of      :: proc($T: typeid) -> int where type_is_struct(T) ---
layout_tail_padding_of :: proc($T: typeid) -> int where type_is_struct(T) ---
layout_cache_lines_of  :: proc($T: typeid) -> int ---
```

- `layout_padding_of`：没有任何具名字段覆盖的字节数（leading + interior + trailing）
- `layout_tail_padding_of`：其中最后一个字段之后的部分
- `layout_cache_lines_of`：`ceil(size_of(T)/64)`

三者都返回 `untyped integer` 常量，因此可用于 `#assert`、`where` 子句、数组长度。

## 用法

```hela
Ring_Header :: struct #explicit #align(64) { head: u32, _: [60]u8, tail: u32, _: [60]u8 }

#assert(size_of(Ring_Header) == 128)
#assert(intrinsics.layout_padding_of(Ring_Header) == 0)
#assert(intrinsics.layout_cache_lines_of(Ring_Header) == 2)
#assert(offset_of_by_string(Ring_Header, "tail") == 64)
```

## 改了什么

| 位置 | 改动 |
|---|---|
| `src/checker_builtin_procs.hpp` | `BuiltinProcId` 末尾追加 3 项；`builtin_procs[]` 表同序追加（枚举与表必须严格同序，这是该文件的硬约束） |
| `src/check_builtin.cpp` | ① 在「首参可以是类型」白名单里加入 3 项（否则会走 `check_multi_expr` 报 "'T' is not an expression but a type"）；② 新增 case，常量折叠为 `exact_value_i64` |
| `base/intrinsics/intrinsics.odin` | 补声明（文档 + 编辑器补全） |
| `src/types.cpp` | `type_padding_size` 为唯一实现，`-emit-layout` 与 intrinsic 共用，保证清单与断言永不打架 |

## 验证

`tests/hela/layout/main.odin` 里 12 条 `#assert` 全部通过（`odin check` 即测试），包括 `#packed`、`bit_field`、`#simd` 的情况。

## 已知取舍

- `layout_cache_lines_of` 固定按 64 字节算（与清单的 `cache_line` 字段一致）。Apple Silicon 上部分核心是 128 字节 cache line，若需要应按目标切换——留作后续 `-layout-cache-line` flag。
- 没有提供 `layout_hash_of`：哈希目前只在清单里以十六进制字符串出现，用于 CI diff；把它做成常量需要再定义一个 u64 字面量语法，收益不高。
