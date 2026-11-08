# M2（改版）— 只保留文件头方言标识，扩展名不动

状态：✅ 完成并验证（第二版；第一版用 `.hel` 扩展名，已废弃）

## 为什么改

第一版让编译器同时接受 `.odin` 与 `.hel`，靠扩展名区分方言。实际用下来这个决定的代价大于收益：

| 问题 | 说明 |
|---|---|
| 每个工具都要认识新后缀 | 编辑器语法高亮、`grep --include`、CI 的 `**/*.odin` 模式、`find` 脚本，全都要加一条 |
| 平台后缀规则要重写一遍 | `foo_linux_amd64.odin` 的筛选逻辑基于「去掉 `.odin` 再看尾巴」，多一个后缀就多一条分支 |
| 自举链上的硬编码 | `core/odin/parser/parse_files.odin` 里写死 `*.odin`，改不动上游 |
| 两种来源同一个标志 | `.hel` 直接置 `AstFile_IsHela`，`#+dialect hela` 也置，真源有两个 |

结论：**方言应该是文件内容的一部分，不是文件名的一部分。** 现在只有一条规则——文件顶部写 `#+dialect hela`，这个文件就是 Hela。

## 现在的规则

```odin
#+dialect hela

package ring
```

- 文件必须仍然是 `.odin`。`.hel` 已被移除：`init_ast_file` 只接受 `.odin`。
- `#+dialect hela` 必须出现在 `package` 之前（和 `#+build` 等文件标签同一个位置）。
- `#+dialect odin` 显式声明默认方言，用于给读者/审查者示意，行为上等价于不写。
- 未知方言名报错：`Unknown dialect 'xxx'. The dialects are 'odin' and 'hela'`。

## 关键细节：按**定义处**的文件判定，而不是按当前检查上下文

`AstFile_IsHela` 只在 `parse_file_tag` 里置位（`src/parser.cpp`）。而校验 Hela 特性时，第一版用的是 `ctx->file`——「正在被检查的文件」。这在多态类型上直接出错：

```odin
// core/hela/ring/spsc.odin   （Hela）
Ring :: struct($T: typeid) #explicit { ... }

// 任意普通 .odin 文件
r: ring.Ring(u64)   // 实例化在这里发生，ctx->file 是普通文件 → 误报「不是 Hela 特性」
```

多态 struct 会在**每个实例化点**重新走一遍 `check_struct_type`。所以判定必须看**定义这个 struct 的那个文件**：

```cpp
gb_internal bool hela_file_of(Ast *node) {
	if (node == nullptr) return false;
	AstFile *f = node->thread_safe_file();
	return f != nullptr && (f->flags & AstFile_IsHela) != 0;
}
```

实测（`/tmp/plainuse/main.odin`，无方言头）：`import "core:hela/ring"` + `Ring(u64)` 编译通过，`size_of` 为 192，push/pop 正常。这是「布局由定义方声明，使用方不需要方言」的正确语义，也是修复前做不到的。

## 改了什么

| 位置 | 改动 |
|---|---|
| `src/parser.hpp` | `AstFile_IsHela` 注释改为「文件头 `#+dialect hela`」 |
| `src/parser.cpp` `init_ast_file` | 只接受 `.odin`；删除 `.hel` 分支 |
| `src/parser.cpp` `try_add_import_path` | 删除 `FILE_EXT_HEL`，目录扫描只收 `.odin`；三条错误文案同步收窄 |
| `src/parser.cpp` `parse_packages` | `-file` 单文件与 `-extra-packages` 只接受 `.odin` |
| `src/parser.cpp` `parse_file_tag` | 保留 `#+dialect odin\|hela`（唯一入口） |
| `src/check_type.cpp` | 新增 `hela_file_of()`，`#explicit` / `#split` 都用它，替换 `ctx->file` 判定 |
| `src/build_settings.cpp` | 单文件输出名推导恢复为只认 `.odin` |
| `src/main.cpp` | `-file` 扩展名检查恢复为只认 `.odin` |

## 代价：自举解析库要认识方言语法（已处理）

改成 `.odin` 之后，Hela 文件会进入所有「遍历 `.odin`」的工具。第一个撞上的是自举解析库的测试：

```
test_core_odin_parser.test_parse_base_core_vendor
  core/hela/ring/spsc.odin(40:29): invalid struct tag '#explicit
```

`core:odin/parser` 是 `core` 里的 Odin 解析器（`odin doc`、工具链都用它），它有一张结构体标签白名单。
换成 `.hel` 时这个测试根本看不到 Hela 文件，所以以前是绿的；现在藏不住了。

修法是在库里补上两个标签，而不是让测试跳过这些文件：

| 文件 | 改动 |
|---|---|
| `core/odin/ast/ast.odin` | `Struct_Type` 增加 `split: ^Expr`、`is_explicit: bool` |
| `core/odin/parser/parser.odin` | 标签白名单增加 `explicit` / `split`（含重复检测），解析结果写入 AST |

这个「麻烦」其实是收益：**方言从「生态之外」搬进了「生态之内」**。用 `.hel` 时，任何走 `.odin` 的工具都会静默忽略 Hela 文件；现在它至少会看到，并且只要补一个 `case` 就能理解。

## 验证

1. 10 个原 `.hel` 文件全部改名为 `.odin` + 顶部加 `#+dialect hela`（`core/hela/layout/*`、`core/hela/ring/*`、`cmd/hela-layout`、`tests/hela/*`）。
2. `find . -name "*.hel"` → 0。
3. `./odin check core/hela/ring -no-entry-point` / `core/hela/layout` / `tests/hela/layout` 全部通过。
4. 无方言头的 `.odin` 使用 `#split` / `#explicit` → 报错并提示 `add '#+dialect hela' to the top of this file`（`tests/hela/split_plain`、`tests/hela/explicit_fail`）。
5. 普通 `.odin` 文件引用 Hela 库的多态类型 → 通过（见上）。
6. 自举解析库测试：`test_parse_base_core_vendor` 曾因 `#explicit` 报错，补上标签后 **913 tests all successful**。

## 有意未处理

- `core/odin/parser/parse_files.odin` 里硬编码 `*.odin`——现在与实现一致，不再需要改。
- 编辑器语法高亮无法识别方言内容（扩展名相同）。这是这个方案唯一的实质代价，接受它换取「零工具改动」。
- 文件级开关意味着每个 Hela 文件多一行。可以接受：它同时是给读者和 AI 的标记。
