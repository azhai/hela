# M3 — `struct #explicit`：禁止隐式填充

状态：✅ 完成并验证

## 目标

让「所见即所得」落到字节级：声明 `struct #explicit` 后，**每一个字节都必须有名字**。编译器插入的任何 leading / interior / trailing padding 都是错误，并指出具体字节区间和修复写法。

## 语法

```hela
Ring_Header :: struct #explicit #align(64) {
	head: u32,
	_:    [60]u8,   // 显式占位
	tail: u32,
	_:    [60]u8,
}
```

与 `#packed` / `#align` / `#raw_union` 同一位置（`struct` 关键字后），因此不引入新的语法生产式，只是多认一个 hash 标签。

## 改了什么

| 位置 | 改动 |
|---|---|
| `src/parser.hpp` | `AstStructType` 新增 `bool is_explicit`；`AstFile_AstFile_IsHela` 已由 M2 提供 |
| `src/parser.cpp` | `ast_struct_type` 增加参数；`struct` 解析循环识别 `#explicit` |
| `src/types.cpp` | `TypeStruct` 新增 `is_explicit_layout : 1`；新增 `type_padding_size(Type*, i64 *tail)` —— padding 的**单一定义**，同时供 `-emit-layout` 与 `intrinsics.layout_*` 使用 |
| `src/check_type.cpp` | `check_struct_explicit_layout()`：在字段检查完成、`fields_wait_signal` 置位之后校验 |

## 门控

`#explicit` 是 Hela 专属特性：文件顶部必须写 `#+dialect hela`（扩展名保持 `.odin`）。否则报错：

```
Error: 'struct #explicit' is a Hela feature: add '#+dialect hela' to the top of this file
```

这是第一个真正被 `#+dialect` 门控的特性，验证了「新特性不污染 Odin 语义」的路线可行。

## 错误信息

```
Error: 'struct #explicit' requires every byte to be named: 3 byte(s) of implicit padding
before 'b' (it starts at offset 4, the previous field ends at 1).
Add a padding field such as `_: [3]u8`.
```

尾部 padding 同样报错并给出建议大小。

## 验证

| 场景 | 结果 |
|---|---|
| `#+dialect hela` + `#explicit` + 显式 padding | `size = 128 align = 64`，通过 |
| `#+dialect hela` + `#explicit` + 隐式 padding | 报错，指出 3 字节与位置 |
| 无 `#+dialect hela` + `#explicit` | 报错，提示在文件顶部加方言标签 |
| 现有 `.odin` 代码 | 完全不受影响（`core` 测试套件验证） |
