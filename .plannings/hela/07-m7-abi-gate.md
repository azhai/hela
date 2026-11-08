# M7：清单可用性与 ABI 门禁

> 目标：把 `-emit-layout` 从「能导出」推进到「能进 CI」。
> 三件事：清单要小（按需过滤）、cache line 要可配（Apple Silicon 是 128 B）、路径要可复现（跨机器 diff 不能因绝对路径而失败）。
> 最后用一份提交进仓库的 `golden.hash` 做 ABI 门禁，让布局漂移在 review 时暴露，而不是在线上暴露。

## 1. `-emit-layout-for:<file-or-package>`

```sh
# 重复出现与逗号分隔都支持
odin check cmd/hela-layout -emit-layout:json -emit-layout-file:/tmp/y.json \
    -emit-layout-for:core/hela/layout -emit-layout-for:tests/hela/abi

odin check cmd/hela-layout -emit-layout:json -emit-layout-file:/tmp/y.json \
    -emit-layout-for:core/hela/layout,tests/hela/abi
```

语义与 `-export-semantics-for` 保持一致（同一套 `overlay_path_eq`），另加目录前缀匹配：

| 写法 | 匹配 |
|---|---|
| `tests/hela/layout/main.odin` | 该文件 |
| `tests/hela/layout` | 该目录下所有文件 |
| `/abs/path/to/pkg` | 绝对路径同样可用 |

同时修掉了 M1 的已知限制 4：默认规则仍是「命令行列出的包（`Package_Init` / `is_extra`）」，而 `-emit-layout-for` 可以把 `core` / `vendor` 里的类型捞进清单。

实测（`cmd/hela-layout` 依赖 `core:hela/layout`）：

```
无过滤        -> 0 个类型        （默认只导出命令行的包）
-emit-layout-for:core/hela/layout -> 3 个类型（Manifest / Type_Layout / Field_Layout）
```

## 2. `-layout-cache-line:<bytes>`

```sh
odin check pkg -emit-layout:json -layout-cache-line:128
```

- 必须是 2 的幂，范围 `[8, 65536]`，否则 `bad_flags` 直接报错退出。
- **单一来源**：`build_context.layout_cache_line` → `get_layout_cache_line()`（`build_settings.cpp`）。
  清单的 `cache_line` / `cache_lines` / `spans_cache_line` / 字段的 `cache_line`，以及
  `intrinsics.layout_cache_lines_of` 全部读这一个函数。

这一点是可验证的：`tests/hela/layout/main.odin` 里写着

```odin
#assert(intrinsics.layout_cache_lines_of(Ring_Header) == 2)
```

在 `-layout-cache-line:128` 下编译，这条断言必然失败——而不是「清单说 1 行、断言说 2 行」这种悄悄不一致。
`tests/hela/run.sh` 第 6 步就是在跑这个反例。

## 3. 清单里的路径改为相对路径

`file` 字段原来是绝对路径，于是两个 clone 生成的清单必然不同，整份 `diff` 无法作为基线。

现在：文件在工作目录之下时写成相对路径，否则退回绝对路径（`layout_relative_path`）。
判断边界时检查分隔符，所以 `/a/b` 不会误匹配 `/a/bc`。

```
"file":"tests/hela/layout/main.odin"
```

> 注意：这依赖调用时的 working directory。跨目录调用时 `file` 会不同，
> 但 `layout_hash` 与 `--diff` 都不看 `file`，所以 ABI 门禁不受影响。

## 4. golden ABI 门禁

设计取舍：**基线文件只存 `pkg::name<TAB>layout_hash`**，不存整份 manifest。

| 方案 | 问题 |
|---|---|
| 提交整份 `layout.json` 做 diff | 含 `file` / `line`，一个空行就会造成噪声；schema 一升级全部重写 |
| 提交 `golden.hash` 做 diff | 只比布局语义，稳定、可读、review 时一眼看清哪个类型动了 |

生成方式（`hela-layout` 新增 `--hashes`）：

```sh
hela-layout --hashes layout.json
```
```
abi::Chunk	e70be8befa7d3a5b
abi::Flags	8f1720ae4d674b21
abi::Kind	01b013a1826a2b3a
abi::Mat4	745652df798d3416
abi::Mixed	8e22df1edd97e2e2
abi::Msg	45069f47c1622974
abi::Particle_View	3246952cc88a3d38
abi::Particles	fadc618e5e8854e5
abi::Ring_Header	9521ea22b62f580d
abi::Slot	60d7ad47465aa31f
abi::Vec3	abb4c3ac1730d304
abi::Vec4	4f88b7f5952c1542
abi::Wire	33cb17d121d0f918
```

`tests/hela/abi/main.odin` 是 ABI 基线包，覆盖 13 个类型：

| 类型 | 覆盖点 |
|---|---|
| `Ring_Header` | `#explicit` + `#align(64)`，128 B 两行，零 padding |
| `Slot` | 恰好 64 B，缓存行整数倍 |
| `Mixed` | 隐式 padding：内部 7 B + 尾部 6 B |
| `Wire` | `#packed`，7 B，零 padding |
| `Flags` | `bit_field u16` 三个位段 |
| `Vec3` / `Particles` / `Particle_View` | `#soa[64]`（fixed）/ `#soa[]`（slice） |
| `Vec4` / `Mat4` / `Chunk` | `#simd` / `matrix` / 定长数组 |
| `Msg` / `Kind` | `union` / `enum u8` |

门禁跑法：

```sh
./tests/hela/run.sh            # 第 7 步：生成 + diff golden.hash
HELA_UPDATE_GOLDEN=1 ./tests/hela/run.sh   # 有意改动布局后刷新基线
```

## 5. 三层防御

| 层 | 手段 | 捕获什么 | 何时失败 |
|---|---|---|---|
| 1 | `#assert(intrinsics.layout_*)` | 编译器自己的布局算法被改动 | 编译期 |
| 2 | `#explicit` | 有人新增字段却没说清字节 | 编译期 |
| 3 | `golden.hash` diff | 换序、改名、类型变化等 ABI 破坏 | CI |

第 1、2 层只能保护「已经写下来的断言」，第 3 层保护整个导出面——包括没人写过断言的类型。

## 6. 门禁有效性实测

两个刻意制造的漂移：

**(a) `Mixed` 字段换序**（`tag` 与 `value` 互换）

```
Error: Compile time assertion: intrinsics.layout_padding_of(Mixed) == 13
Error: Compile time assertion: intrinsics.layout_tail_padding_of(Mixed) == 6
Error: Compile time assertion: offset_of_by_string(Mixed, "value") == 8
```

第 1 层就拦住了——这正是它该做的。

**(b) `Slot.seq` 改名为 `Slot.stamp`**（大小、对齐、padding 全不变，断言全过）

```
--- tests/hela/abi/golden.hash
+++ /tmp/.../abi.hash
@@ -7,7 +7,7 @@
 abi::Particle_View	3246952cc88a3d38
 abi::Particles		fadc618e5e8854e5
 abi::Ring_Header	9521ea22b62f580d
-abi::Slot	60d7ad47465aa31f
+abi::Slot	0b1663ac66b6f3cf
```

退出码 1。这正是第 3 层的价值：**纯改名不改变任何字节，却破坏了 ABI**（C 侧按名字绑定、序列化按名字取字段），只有 hash 基线能发现。

## 7. 改动的文件

| 文件 | 改动 |
|---|---|
| `src/build_settings.cpp` | `emit_layout_for` / `layout_cache_line` 字段；`LAYOUT_DEFAULT_CACHE_LINE`；`get_layout_cache_line()` |
| `src/main.cpp` | `-emit-layout-for`、`-layout-cache-line` 两个 flag；交叉校验；help |
| `src/layout_writer.cpp` | `layout_cache_line()` 取代编译期常量；`layout_path_matches` / `layout_relative_path`；过滤逻辑 |
| `src/check_builtin.cpp` | `layout_cache_lines_of` 改用 `get_layout_cache_line()` |
| `cmd/hela-layout/main.odin` | `--hashes` 子模式 |
| `tests/hela/abi/main.odin` | **新增** ABI 基线包（13 个类型 + 断言） |
| `tests/hela/abi/golden.hash` | **新增** 基线 hash 表 |
| `tests/hela/run.sh` | 4 步扩到 7 步 |

## 8. 仍然没做

- `#aosoa[W]`：唯一需要动 codegen 的布局语法。
- `@(share)` / `@(cache_line)` + `#+analysis sharing`：静态伪共享检查。
- `#view`：声明式零拷贝视图。
- `golden.hash` 的 per-target 变体：`align_of` 依赖 target（如 `f32` 在 wasm 与 arm64 上不同），
  目前只对 host target 建立基线；跨 target 门禁需要 `golden.<os>_<arch>.hash` 命名方案。
