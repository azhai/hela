# M5 — `core:hela/layout` 库与 `hela-layout` 工具

状态：✅ 完成并验证

## 组成

| 文件 | 内容 |
|---|---|
| `core/hela/layout/layout.odin` | `Manifest` / `Type_Layout` / `Field_Layout`；`parse_file`、`find`、`find_in`、`members` |
| `core/hela/layout/render.odin` | `render_type` / `render_entry`：按 64 字节 cache line 分块打印字节地图，自动插入 `<padding>` 与 `<tail padding>` 行 |
| `core/hela/layout/diff.odin` | `diff_report`：按 pkg+name 归并比较，报告 `+` / `-` / `~`，以 `layout_hash` 判定「变了」 |
| `cmd/hela-layout/main.odin` | CLI：查看单类型 / 全部类型，或 `--diff old new`（有差异退出码 1） |
| `tests/hela/layout/main.odin` | 12 条编译期 `#assert` |
| `tests/hela/explicit_fail/main.odin` | 负例：隐式 padding 必须报错 |
| `tests/hela/run.sh` | 四步回归 |

库本身用 Hela 编写（`.odin` + `#+dialect hela` 头），是方言第一个「吃自己狗粮」的组件。

## 为什么用 `layout_hash` 判定变化

只看 `size` / `align` 会漏掉「字段换序但总大小不变」「字段改名」这类 ABI 破坏。`layout_hash` 覆盖 kind/size/align/packed/soa 与每个字段的 name+offset+size+bit 范围，因此更适合作为 CI 的 ABI 门禁。

## 典型输出

```
Ring_Header	(struct, main)
  size 128 B	align 64 B	cache lines 2	padding 0 B (tail 0)	hash db26ac0deabb822c
  line 0	[0..63]
    head	@0	4 B	u32
    _	@4	60 B	[60]u8
  line 1	[64..127]
    tail	@64	4 B	u32
    _	@68	60 B	[60]u8

Padded	(struct, main)
  size 8 B	align 4 B	cache lines 1	padding 3 B (tail 0)	hash 3c24e765309d3190
  line 0	[0..63]
    a	@0	1 B	u8
    <padding>	@1	3 B
    b	@4	4 B	u32
```

## 回归脚本

```sh
tests/hela/run.sh
# [1/4] compile-time layout assertions
# [2/4] manifest is deterministic
# [3/4] hela-layout renders bytes and cache lines
# [4/4] struct #explicit rejects implicit padding
# hela layout tests: ok
```

## 已知限制

1. `#soa` 的字段 offset 是「分量数组」语义，字节地图会如实显示为若干个数组字段，而非「元素在内存中交错」的直觉图。后续需要专门的 SOA 视图模式。
2. 清单里的 `file` 是绝对路径，跨机器比较整份 JSON 会因路径不同而失败；做 golden 测试时应只比较 `layout_hash`（或后续加 `-emit-layout-relative`）。
3. `render_all` 返回的字符串由调用方拥有；`render_type` 追加到调用方提供的 builder。
