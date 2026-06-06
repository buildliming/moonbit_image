# 手写 DEFLATE：在 MoonBit 中从零实现 PNG 解压

> 作者：lws | MoonBit 生态开源大赛参赛项目

## 为什么要手写 DEFLATE？

MoonBit 是一门新兴的国产编程语言，生态还处于早期阶段。想做图像解码库，JPEG/PNG 都绕不开一个问题：**解压缩**。PNG 使用 DEFLATE 压缩（RFC 1951），但 MoonBit 标准库没有现成的 DEFLATE 解压器。

有两个选择：
1. 绑定 C/zlib 库 —— MoonBit 支持 FFI
2. 在 MoonBit 中手写一个

我选了后者。原因很简单：**纯 MoonBit 实现意味着跨平台零依赖**——编译到 Wasm 可以直接在浏览器里跑，不需要带任何 native 库。这恰好是 MoonBit 的核心优势。

## DEFLATE 是什么？

DEFLATE 是 LZ77 + Huffman 编码的组合。简单说：

1. **LZ77**：找重复的字节序列，用"往回看 N 个字节，复制 M 个字节"的引用替代
2. **Huffman**：统计字节出现频率，给高频字节短码字，低频字节长码字

PNG 的 DEFLATE 数据包在一个 zlib 头里（2 字节头 + 压缩数据 + 4 字节 Adler32 校验）。

## 最棘手的部分

DEFLATE 有三种块类型：
- **BTYPE=0**：不压缩，直接存原始数据
- **BTYPE=1**：固定 Huffman 码表
- **BTYPE=2**：动态 Huffman 码表——码表本身也用 Huffman 编码

**动态 Huffman 头是整个解压器最复杂的部分**。它用三层 Huffman 编码：
1. 第一层：19 个"码长码"的码长（固定排列顺序，3bit 每个）
2. 第二层：286 个 literal/length 码的码长 + 30 个 distance 码的码长（用第一层的 Huffman 表解码）
3. 第三层：实际的像素数据

## 一个隐秘的 Bug

测试到第 21 次 commit，我加了一批中等尺寸（128×128）的复杂图案测试。棋盘格和径向渐变这两个 PNG 全部挂了：

```
DEFLATE: dist>len
```

`dist>len` 意思是 LZ77 的"回看距离"超过了已输出数据的长度——试图从一个不存在的位置复制数据。这只有在 Huffman 解码出错、读到了错误的符号时才会发生。

### 追踪过程

我用 Python 写了一个完全镜像 MoonBit 实现的 DEFLATE 解压器来复现问题。结果是：**bit buffer 状态在 `read_dyn_header` 和 `decode_block` 之间丢失了**。

MoonBit 代码的大致结构：

```moonbit
fn read_dyn_header(r : BitReader) -> (BitReader, HDecoder, HDecoder) {
  let mut bb = 0; let mut bc = 0  // bit buffer
  let mut xr = r
  // ... 解码动态 Huffman 头，用 ensure_bits/consume 管理 buffer
  (xr, lit_tree, dist_tree)  // 注意：bb, bc 被丢弃了！
}

fn decode_block(r : BitReader, out : Buffer, lt : HDecoder, dt : HDecoder) -> BitReader {
  let mut bb = 0; let mut bc = 0  // 重新开始一个空 buffer！
  // ... 解码数据
}
```

问题在于：`read_dyn_header` 解码完最后一个码长后，bit buffer 里还剩 1~4 个已读出但未消费的 bit。这些 bit 恰好是**压缩数据流的开头**。`decode_block` 从空 buffer 开始重新读——直接跳过了这些 bit！

### 修复

让 `read_dyn_header` 把 buffer 状态传回来，`decode_block` 接着用：

```moonbit
fn read_dyn_header(r : BitReader) -> (BitReader, Int, Int, HDecoder, HDecoder)
fn decode_block(r : BitReader, out : Buffer, lt : HDecoder, dt : HDecoder, bb0 : Int, bc0 : Int) -> (BitReader, Int, Int)
```

就改了 3 行代码，但找了半天。

## 经验总结

1. **写测试要狠**：小图能过不代表大图能过。棋盘格这种高压缩比的图案才暴露了这个 bug（PNG 压缩到 918 字节，压缩比 175:1）
2. **Python 镜像法调试**：在 Python 里写一个和 MoonBit 行为完全一致的解压器，逐 bit 对比，是定位这种边界 bug 的最快方法
3. **不要信任调用约定**：函数传参时，仔细思考哪些状态需要在调用之间保持

## 代码仓库

https://github.com/buildliming/moonbit_image

支持 BMP/QOI/TGA/PNG/GIF/JPEG 六种格式的纯 MoonBit 图像解码库。
