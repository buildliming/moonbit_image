# 项目申报书

## 1. 项目名称

**MoonBit 图像解码库（lws/image）**

---

## 2. 项目简介

本项目是一个**纯 MoonBit 语言实现的图像解码库**，支持 BMP、QOI、TGA、PNG 四种主流图像格式的完整解码，包含从零实现的完整 DEFLATE 解压器（RFC 1951）、zlib 包装层（RFC 1950）、PNG 块解析器、Adam7 交错解码器，以及 Huffman 树构建器和 LZ77 回引解码等核心压缩算法。

项目代码量约 1,600 行 MoonBit 源码，配套 1,200 余行测试与文档代码，采用零外部依赖的架构设计，仅使用 MoonBit 核心标准库。库提供统一的 API 入口，支持自动格式检测、按格式分发解码、仅读取图像尺寸（不解码像素）等特性。

在 MoonBit 生态中，本项目是目前**首个完整的图像解码库**，填补了该领域的功能空白，为 MoonBit 语言在图像处理、游戏开发、Web 前端（Wasm 编译目标）等领域的应用提供了基础能力支撑。

---

## 3. 项目方向与适用场景

### 项目方向

- **MoonBit 生态基础设施建设**：为 MoonBit 语言补齐图像处理领域的关键功能模块
- **纯 MoonBit 算法实现**：展示 MoonBit 语言在系统编程和压缩算法领域的表达能力
- **Wasm 前端图像处理**：MoonBit 编译到 WebAssembly 后，可在浏览器端直接解码图像

### 适用场景

| 场景 | 描述 |
|------|------|
| **游戏引擎资源加载** | 加载 BMP/TGA 等游戏常用纹理格式 |
| **Web 前端图像处理** | 编译为 Wasm 后，在浏览器中解码 PNG/QOI 图像 |
| **图像工具与转换器** | 作为图像格式批量转换工具的核心解码模块 |
| **嵌入式/IoT 设备** | QOI 和 BMP 解码器代码量小、无依赖，适合资源受限环境 |
| **图像元数据提取** | 通过 `image_dimensions()` 快速获取宽高，无需完整解码 |
| **MoonBit 教学与学习** | 展示 Huffman 编码、LZ77、CRC32 等算法的 MoonBit 实现 |

---

## 4. 拟实现的核心功能

### 已实现功能（15 个增量提交）

**格式支持：**

| 格式 | 支持特性 |
|------|---------|
| **BMP** | 32-bit BGRA、24-bit BGR、8-bit 索引色（含 RLE8 压缩）、4-bit 索引色（含 RLE4 压缩）、1-bit 单色；自底向上/自顶向下扫描；4 字节行对齐 |
| **QOI** | RGB 和 RGBA 双通道；全部 6 种块类型（INDEX/DIFF/LUMA/RUN/RGB/RGBA）；64 色哈希缓存；sRGB/线性色彩空间 |
| **TGA** | Type 2/3（无压缩）、Type 10/11（RLE 压缩）；8/16/24/32-bit 像素深度；A1R5G5B5 解包；自顶向下/自底向上原点 |
| **PNG** | 灰度/RGB/RGBA/灰度+Alpha/索引色（含 PLTE 调色板）；Adam7 交错解码；5 种过滤器（None/Sub/Up/Average/Paeth）；CRC32 块完整性校验 |

**底层压缩算法：**

- **Huffman 树构建器**：15-bit 快速前缀查表（O(1) 解码），动态表大小适应实际码长
- **DEFLATE 块解码器**：支持 BTYPE=0（无压缩）、BTYPE=1（固定 Huffman）、BTYPE=2（动态 Huffman），含 LZ77 回引解码（重叠/非重叠块拷贝）
- **zlib 包装层**：CMF/FLG 头验证、Adler32 校验
- **CRC32**：256 项查找表，支持增量计算

**API 设计：**

- `decode(data)` — 自动检测格式并解码
- `decode_by_format(data, format)` — 按指定格式分发
- `detect_format(data)` — 魔数/页脚格式检测
- `image_dimensions(data)` — 仅读头部获取尺寸（高性能元数据查询）
- `Image.get_pixel(x, y)` / `Image.to_rgba8()` — 像素访问与格式转换

**测试与质量保障：**

- 8 个 MoonBit 单元测试模块（内嵌 2×2 测试图片）
- Python 算法验证套件（559 行），与 PIL/Pillow 参考实现交叉验证
- CRC32/Adler32 标准测试向量、DEFLATE 固定 Huffman 码验证

---

## 5. 是否为原创项目、移植项目或参考已有开源项目

### 原创性声明

本项目为**原创项目**，所有 MoonBit 代码均由作者独立编写，未直接移植或复制任何现有开源项目的代码。

### 参考标准与规范

项目严格遵循以下**国际标准与技术规范**实现算法：

| 规范 | 描述 |
|------|------|
| **RFC 1951** | DEFLATE Compressed Data Format Specification v1.3 |
| **RFC 1950** | ZLIB Compressed Data Format Specification v3.3 |
| **ISO/IEC 15948 / W3C PNG Specification** | Portable Network Graphics (PNG) Specification |
| **BMP File Format (Microsoft)** | BITMAPFILEHEADER + BITMAPINFOHEADER 规范 |
| **QOI Specification** | Quite OK Image Format（qoiformat.org） |
| **TGA File Format (Truevision)** | Truevision Targa 格式规范 v2.0 |
| **ITU-R BT.601** | 色彩空间亮度转换系数 |

### 算法学习参考

在实现过程中，作者参考了以下公开的算法描述和标准文档来理解规范细节：

- RFC 1951 中关于 Huffman 编码和 LZ77 的算法描述
- PNG 规范中关于过滤器（Sub/Up/Average/Paeth）的定义
- zlib 技术文档中关于 Adler32 校验和的说明

以上参考文献仅用于理解算法规范，**所有代码实现均为基于规范文档的独立原创编写**，未直接使用任何第三方图像解码库的源代码。

### 与现有开源项目的关系

| 项目 | 语言 | 关系 |
|------|------|------|
| stb_image | C | 设计理念参考（单头文件、零依赖、多格式），未使用其代码 |
| qoi (phoboslab) | C | 参考 QOI 规范原文，未使用其代码 |
| zlib (Jean-loup Gailly) | C | 参考 RFC 1950/1951 标准，未使用其代码 |
| libpng | C | 参考 PNG 规范，未使用其代码 |

本项目是这些图像格式在 **MoonBit 语言生态中的首次完整实现**，具有独立的代码编写和架构设计。

---

## 附录：项目信息摘要

| 项目 | 信息 |
|------|------|
| 项目名称 | MoonBit 图像解码库 |
| 包名 | `lws/image` |
| 编程语言 | MoonBit（100%） |
| 代码规模 | ~1,600 行 MoonBit + ~1,200 行测试/文档 |
| 许可证 | MIT |
| 外部依赖 | 无（仅 MoonBit 核心标准库） |
| 仓库地址 | https://github.com/buildliming/moonbit_image |
| 开发方式 | 15 次渐进式 commit，涵盖从 BMP 到完整 PNG/DEFLATE 的开发过程 |
