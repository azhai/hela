# M28：让清单说出它的假设 —— cache line 是透镜，不是事实

> 一句话：`cache_line: 64` 这个数字在清单里长得像**测量值**，其实是**编译器的兜底默认**。
> 本机的线是 128。读者拿到的每一个 `spans_cache_line`、每一条 `--contract` 的 owner 判定、
> M25 的每一条数组规则，都建立在那个数字上 —— 所以必须先让它自己说明白。

## 1. 问题：清单没有区分「测到的」和「没说」

M27 测出本机（Apple M4）的 cache line 是 **128 B**，而编译器默认 64。
两件事同时成立，于是清单里出现了一个读者**无法正确解释**的字段：

```json
"cache_line": 64
```

它有三种可能的真相，字面上完全一样：

1. 构建者跑了 `-layout-cache-line:64`，因为目标机真的抓 64 字节；
2. 构建者什么也没说，这是编译器的兜底值 —— **没人做过判断**；
3. 目标机抓 128，构建者没说，于是这份清单描述的分组是错的（对这台机器而言）。

前两种的字节完全相同、`layout_hash` 也相同，但**结论相反**：第一种是决策，第二种是隐式。
一份"所见即所得"的清单不该让人去猜这个。

工具侧的第二个问题更直接：`hela-layout --contract` / `--waste` 的每一行都在按**某条线**
分组，但报告从不说按哪条线。读者只能回去翻清单，或者更糟 —— 假设"报告里的线就是机器的线"。

第三个问题是 M25 留下的：`#share` 类型的 size/align 必须是 cache line 的整数倍，这条规则
在**编译时**按 `-layout-cache-line` 校验一次。到了客户端，如果线其实更宽，这个"已验证"就失效了，
而没有任何东西会重新检查它。

## 2. 决定一：清单 v8 多一个 bool，不是多一个字符串

顶层新增：

```json
"cache_line": 64,
"cache_line_explicit": false
```

`LAYOUT_VERSION` 8，CBOR 顶层 map `6 → 7`。

为什么是 bool 而不是 `"cache_line_source": "default" | "flag" | "override"`：`cache_line`
本身已经承载了数字，能区分的只有**两个**状态 —— "有人给过值" 与 "没人给过值"。
`default` / `flag` / `override` 三个字符串里有两个在描述同一个数字的不同解释，落在清单里
就是三份需要同步维护的真相。而 `cache_line_explicit` 是**能表达这件事的最小信息**，
CBOR 里还是一个单字节头（`0xf4/0xf5`），不会把 map 长度算错。

**`layout_hash` 不进这个字段，也不进 `cache_line`。** 线宽是读者的透镜，不是字节的事实：
同一堆 offset 在 64 与 128 下的 `layout_hash` 必须相同。于是 **6 份 golden 一个字节都没刷新**
—— 这是"新字段确实属于元数据"的证明（M21 加 `target` 时用过同一个论证）。

## 3. 决定二：报告抬头先说自己按哪条线算的

`core:hela/layout` 新增 `lines.odin`：`Line{bytes, source, compiled}`、
`Line_Source{.Declared, .Default, .Overridden}`、`line_of(m)`、`line_banner(l)`、
`set_cache_line`、`straddle_summary`。横幅只有三种措辞，逐字：

| 场合 | 措辞 |
|---|---|
| 清单没声明（兜底 64） | `cache line 64 B (compiler default, not a decision: pass -layout-cache-line:N if this target fetches a different size)` |
| 清单声明了 | `cache line 64 B (from -layout-cache-line)` |
| 工具侧覆盖 | `cache line 128 B (--cache-line; the manifest was built for 64 B)` |

第一句故意长：它要同时说清"这是默认值"和"默认值不等于事实，你可以改"。
只写 `cache line 64 B` 是**误导**，因为它在读者眼里是测量结果。

配套给 `hela-layout` 加了 `--cache-line:N` / `--cache-line N`（任意位置、两种拼写都能用），
在全部六个解析点统一经 `load(path, cache_line)` 应用。于是有了一条不需要重新编译的路：

```console
$ hela-layout --contract atomic.json
hela concurrency contract (cache line 64 B (compiler default, not a decision: ...))

main::Cursors  (192 B, 3 cache line(s))
  line 0 [0..63] owner=producer : head@0#atomic#share(producer)
  line 1 [64..127] owner=consumer : tail@64#atomic#share(consumer)
  line 2 [128..191] owner=- : mask@128

1 type(s), 0 line(s) with conflicting writers, 0 shared field(s) without #atomic

$ hela-layout --contract --cache-line 128 atomic.json
hela concurrency contract (cache line 128 B (--cache-line; the manifest was built for 64 B))

main::Cursors  (192 B, 2 cache line(s))
  line 0 [0..127] owner=CONFLICT : head@0#atomic#share(producer) tail@64#atomic#share(consumer)
  ...
1 type(s), 1 line(s) with conflicting writers, 0 shared field(s) without #atomic

shared type(s) not a whole number of 128 B lines (element i would share a line with i+1): main::Cursors(192 B)
```

**同一份清单，两条线，两个答案。** offsets 是事实，线宽是透镜 —— 这句话以前是个说法，
现在是一条命令。注意第二个答案里两件事同时坏了：`head`(0..7) 与 `tail`(64..71) 落进同一行
（producer/consumer 契约破了），且 192 B 不是 128 的整数倍（M25 的数组规则也破了）。

## 4. 决定三：M25 的不变量必须能在客户端重算

`straddle_summary` 之所以敢在工具侧重新判定，是因为它要用的两条都能**纯从 offsets 推出**：

- 跨线：`(offset % line) + size > line`
- 整线：`size % line == 0`

这不需要"再实现一遍编译器"，只需要 offsets + size + 一个线宽 —— 三者都在清单里。
这是"清单必须自足"的一次压力测试：如果 M25 的规则里掺了任何只在编译器内部才有的信息
（比如"这个字段对齐是隐式抬上去的"），这里就复算不出来。

## 5. 决定四：编译器在 `-layout-cache-line:128` 下必须拒绝

工具侧的复读如果不是同一条规则，就只是"第二个意见"。所以 `run.sh` 第 17 步断言编译器自己
在同一份源码、按 128 编译时给出**同样两条**结论：

```console
$ odin check tests/hela/atomic -no-entry-point -layout-cache-line:128
main.odin(12:12) Warning: this struct carries '#share' annotations but is 192 bytes, not a
  multiple of the cache line (128): ... Pad it to a multiple of 128 (a trailing `_: [64]u8`),
  or mark it '#split(128)'.
main.odin(14:38) Error: False sharing: 'tail' (written by 'consumer', bytes 64..71) and
  'head' (written by 'producer', bytes 0..7) both live in cache line 0. Every write to one
  invalidates the line the other writer is using. Separate them with '#align(128)' on one of
  the fields, or '#split(128)' on the struct.
```

**这也是为什么默认值不能直接抬到 128。** 服务器 ARM64 与 x86-64 都抓 64；一个"一行"的类型
在那里只有半行。默认 64 + `cache_line_explicit:false` + 一条横幅，比一个"更聪明的猜测"诚实：
它把不可判定的事摊在桌面上，而不是替读者赌一把。

## 6. 决定五：CBOR 的 map 长度必须有结构检查

`sw_map(&w, 7)` 是**手写**的常量。加字段忘改它，JSON 一点问题都没有（JSON 靠 `}` 定界），
CBOR 会产出一个谁也解不开的文件 —— 而且错得很安静。所以新增 `tests/hela/cbor_lint.py`：
纯结构遍历（不解值），每一层 map 的 pair count 必须与后续实际条目一致、文档必须恰好在 root
声明处结束，且 root 必须含 `version/target/pointer_size/cache_line/cache_line_explicit`、
其中最后一个是 bool。

它自己的自测就是把 root 头改坏：

| 改动 | 输出 | 退出码 |
|---|---|---|
| `0xa7 → 0xa6`（长度少一位） | `cbor-lint: FAIL: document is 2740 bytes but the root claims 92 (a map count is too small)` | 1 |
| `0xa7 → 0xa8`（长度多一位） | `cbor-lint: FAIL: truncated header ...` | 1 |
| 正常 | `cbor-lint: ok: 16 map(s), 237 pair(s), version 8, cache_line 64 B (default)` | 0 |

`run.sh` 第 2 步在有 `python3` 时跑它，没有则打印跳过（不因为缺 python 就让整条回归变红）。

## 7. 决定六：把 M27 的曲线变成断言（并在这一轮被自己的断言打了一次）

`tests/hela/membw` 的第 7 段从"打印"变成"判定"：

| 断言 | 阈值 | 本次实测 |
|---|---|---|
| `levels are ordered (outer >= 3x inner)` | ≥ 3.0 | 16 KiB 1.51 ns → 256 MiB 100.98 ns = **66.9x** |
| `there is a middle level` | ≥ 1.3 | 4 MiB 7.45 ns 比 256 MiB 快 **13.6x** |
| `threads buy bandwidth` | ≥ 1.2 | 1 线程 44.50 → 10 线程 97.23 GB/s = **2.2x** |
| `two candidates in one pass beat two passes` | ≥ 1.3 | 61.09 vs 30.22 GB/s = **2.02x** |
| `a second candidate in the same pass is nearly free` | ≥ 0.8 | 61.09 vs 62.62 GB/s = **0.98x** |

失败则 `os.exit(1)`，`run.sh` 第 28 步 grep `memory curve assertions: all ok`。
一个悄悄长出第二趟的扫描路径会在这里红，而不是在 code review 里红。

**这一轮它抓到了我自己。** 上一版还有一条断言：

```odin
check("the inner level reads faster than DRAM", ratio(bw_inner, bw_outer) >= 1.2, ...)
```

它这次跑出来是 `46.35 GB/s vs 45.50 GB/s = 1.02x` —— **失败**。测量本身没问题，是我的
命题错了：**单线程流式读的带宽与数据在 L2 还是 DRAM 无关**。一个核的 load 通路在内存子系统
饱和之前就先饱和了，所以 cache→DRAM 的差别不体现在带宽上，只体现在**延迟**（66.9x，上面第一条）
和**多线程聚合带宽**（2.2x，第三条）上。

处理方式：把断言换成 `note`，并把实测数字印出来 —— 事实是真实的，只是它不是那条断言声称的事实。
这条 note 现在是 M27 那份曲线里最容易被误读的一行，值得留在输出里。

## 8. 这一轮的取舍与没做的事

- **没有让编译器去探测宿主的 cache line。** 编译器可以读 `hw.cachelinesize`，但那描述的是
  *构建机*，不是*目标机*。交叉编译时这两者一定不同，而"构建机的属性"混进字节的事实里是最坏的一类
  隐式。所以：默认是显式的 64，要说别的就 `-layout-cache-line`。
- **没有把 `cache_line_explicit` 做成三态枚举。** 见第 2 节：能表达的最小信息是两个状态。
- **没有让 `--cache-line` 影响 `layout_hash` 或 `--stable`。** 线宽不同不影响"字节能不能直传"，
  `--stable` 在 CSV 里把每个 manifest 的线宽打出来，但 hash 比较不看它（不一致时只打印 note）。
- **没有给 v8 之前的清单做兼容推断。** v7 及更早的 `cache_line` 一律按"未声明"处理（`Default`），
  因为那时确实没有任何办法声明 —— 这不是兼容性妥协，这是历史事实。

## 9. 交付物

| 位置 | 内容 |
|---|---|
| `src/layout_writer.cpp` | `LAYOUT_VERSION = 8`、顶层 `cache_line_explicit`、CBOR map 7 |
| `core/hela/layout/lines.odin` | `Line` / `Line_Source` / `line_banner` / `set_cache_line` / `straddle_summary` |
| `core/hela/layout/{layout,contract,waste,stable}.odin` | `Manifest.cache_line_explicit`、横幅接入、`--stable` 打印线宽 |
| `cmd/hela-layout/main.odin` | `--cache-line:N` / `--cache-line N`，六个解析点统一 `load()` |
| `tests/hela/cbor_lint.py` | CBOR 结构自检（map 长度 / root 必须字段） |
| `tests/hela/membw/main.odin` | 第 7 段 5 条断言 + 1 条 note |
| `tests/hela/run.sh` | **29 步**：第 2 步 CBOR 结构检查、第 15 步 v8 provenance、第 17 步「两条线两个答案」+ 编译器拒绝、第 28 步曲线断言 |
