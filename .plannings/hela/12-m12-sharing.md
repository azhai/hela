# M12 — `#share(label)` 与 `#+analysis sharing`

> 目标：把「这两个字段由不同的线程写，所以不能同一条 cache line」从注释、从 code review 的直觉，变成编译器会检查的声明。

## 1. 为什么 `#assert` 不够

`#split`、`#explicit`、`#align` 都能用 `#assert` 锁住布局，因为它们说的是**一个类型自己的字节**：

```odin
#assert(offset_of_by_string(Ring, "tail") - offset_of_by_string(Ring, "head") >= 64)
```

但伪共享不是单个类型的性质，而是**两个字段之间的关系**外加**谁知道谁会写它**。`#assert` 能检查前者（如果你把每一对都手写一遍），检查不了后者：编译器看到的只是 `u64`，它不知道 `head` 归 producer、`tail` 归 consumer。

`#share(label)` 补的就是这一点信息：

```odin
Ring :: struct {
    #align(64) #share(producer) head: u64,
    #align(64) #share(consumer) tail: u64,
    #align(64) slots: []T,          // 只读，无需标注
    mask: u64,
}
```

然后编译器做硬件的算术：`head` 在 line 0，`tail` 在 line 1，两个不同 writer 不共线，通过。如果哪天有人删掉一个 `#align(64)`，构建就失败：

```
Error: False sharing: 'tail' (written by 'consumer', bytes 8..15) and 'head' (written by
'producer', bytes 0..7) both live in cache line 0. Every write to one invalidates the line the
other writer is using. Separate them with '#align(64)' on one of the fields, or '#split(64)' on
the struct.
```

这条错误信息本身就是修复方案，这正是 Hela 想要的那种错误。

## 2. 检查规则

只比较**带标注**的字段，并且只在**标签不同**时报告：

| 情况 | 结果 | 理由 |
|---|---|---|
| `a` 与 `b` 标签不同，同一行 | **错误** | 两次写、一条线，正是伪共享 |
| `a` 与 `b` 标签相同，同一行 | 静默 | 同一个 writer 写两个字段，共线是对的（常见的「这一组归这个线程」） |
| 未标注的字段 | 静默 | 可能只读，也可能被所有人写，猜错就是噪声 |
| 单个带标注字段跨两条线 | 警告 | 一次 store 脏两条线，且永远不能原子读 |
| `#soa` / `#raw_union` | 跳过 | 没有单一的字段偏移表 |

判定的行号区间就是 `[offset, offset+size)` 与 `[line*CL, (line+1)*CL)` 的交叠，没有别的近似。

### cache line 大小从哪来

同一个来源：`get_layout_cache_line()`，即 `-layout-cache-line:N`（默认 64）。所以

```sh
odin check pkg -layout-cache-line:128     # Apple Silicon 的 128 字节取指
```

会同时改变清单里的 `cache_line`/`cache_lines`、`intrinsics.layout_cache_lines_of` 的返回值，以及伪共享判定的边界——三者不可能互相矛盾。`tests/hela/run.sh` 第 12 步就锁这一点：`tests/hela/sharing` 在 64 下通过、在 128 下必须失败（两个游标相隔 64 字节，在 128 字节的线上就是同一条）。

原来的计划里写的是 `@(cache_line=...)` 逐结构体覆盖。没有采用：Odin 的 `@(...)` 属性只挂在变量/导入声明上，字段上没有属性通道；而 cache line 是机器属性，不是类型属性，逐类型声明一个数字只会让同一台机器上出现互相矛盾的假设。**一个进程一个数字**更诚实。

## 3. 开关

`sharing` 是 `AnalysisFlag` 的第三位，与 `escape`、`atomic` 同级：

| 写法 | 效果 |
|---|---|
| 默认（无标签） | **开**。但只有出现 `#share` 才有可比较的对象，所以实际是「标注即启用」 |
| `#+analysis sharing` | 显式声明本文件要求这项分析（推荐写在文件头，读代码的人能看到） |
| `#+analysis !sharing` | 关掉本文件的分析，给「故意共线」的代码一个出口 |
| `-no-sharing-analysis` | 全局关掉；带 `#+analysis sharing` 的文件仍然开着（与 escape/atomic 的语义一致） |

为什么默认是开：如果要求必须写 `#+analysis sharing` 才生效，那么忘记写的人会得到一个**静默无效**的注解——比报错更糟。默认开 + 标注触发，最坏情况是多报一次，且错误信息里就有补丁。

## 4. 实现

| 文件 | 改动 |
|---|---|
| `src/parser.hpp` | `Ast_Field.share`（标签 Token）、`FieldFlag_share` |
| `src/parser.cpp` | `#share(label)` 与 `#align(N)` 共用 `parse_argument_field_prefix`；标签可以是标识符或字符串 |
| `src/entity.cpp` | `Entity.Variable.share_label` |
| `src/check_type.cpp` | `check_field_share()`：方言门控 + 去引号；`check_struct_sharing()`：成对比较、跨线警告 |
| `src/build_settings.cpp` | `AnalysisFlag_Sharing`、`-no-sharing-analysis` 的名字解析 |
| `src/main.cpp` | `-no-sharing-analysis` 注册与帮助 |
| `core/hela/ring/spsc.odin` | `#+analysis sharing` + `#share(producer/consumer)`：真实类型上的示范 |

`check_struct_sharing` 放在 `check_struct_type` 的 `if (!is_polymorphic)` 块里，因此对具体结构体和多态实例化后的具体类型都会跑，只跳过未实例化的模板（那时还没有偏移）。代价是多态类型按每个 `$T` 各检查一次，同一个错误可能出现多次；换来的是 `Ring(u64)` 这种「别名 + 实例化」也能被检查到。

## 5. 验证

- `tests/hela/sharing`：`Separated`（两个 writer，两行）通过；`Grouped`（同一 writer 两个字段，一行）通过；`Unannotated`（无标注）不产生任何报告。运行时再断言一次地址分属不同的行。
- `tests/hela/sharing_fail`：两个 writer 一行 → 必须编译失败，且消息包含 `False sharing`。
- `tests/hela/sharing_off`：同一对字段 + `#+analysis !sharing` → 必须编译通过。
- 同一个文件在 `-layout-cache-line:128` 下必须失败，证明判定用的是 `-layout-cache-line` 而不是硬编码 64。
- `core:hela/ring` 在标注之后仍然通过（布局本来就是对的），并且 `#align` 一旦被删就会被这条检查接住。

## 6. 已知限制

- 标签是**纯符号**，不与线程、actor、goroutine 绑定，也不做跨字段的写入推导。它表达的是「这些字段的 writer 集合不同」，仅此而已。真正的写入可见性仍然要靠 `core:sync`/TSAN（`HELA_TSAN=1 ./tests/hela/run.sh`）。
- 只检查结构体内部的字段对。两个不同结构体的字段、数组元素之间、堆上相邻分配的对象之间的伪共享，不在范围内——那需要分配器信息，属于运行时/工具链的事。
- 未标注字段一律不参与，所以「一半标注一半不标」可能漏掉真问题；`#share` 应该成组使用。
- 一个字段只能有一个标签；需要表达「被两个 writer 写」时，说明布局本来就需要改（加锁或分片）。
