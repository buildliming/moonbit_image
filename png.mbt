// Copyright (c) 2025 lws
// PNG decoder - Stage 1: Huffman tree for DEFLATE

//-----------------------------------------------------------------------------
// Huffman Tree for DEFLATE (RFC 1951)
//-----------------------------------------------------------------------------

/// Huffman table entry: symbol value and code length
struct HEntry { symbol : Int; length : Int }

/// Fast lookup Huffman decoder using a prefix table
struct HDecoder { table : Array[HEntry]; tbl_bits : Int }

/// Build a canonical Huffman tree from an array of code lengths
/// Uses a fast lookup table of size 2^tbl_bits for O(1) symbol decoding
fn build_huffman(cl : Array[Int], ns : Int) -> HDecoder {
  // Determine maximum code length
  let mut ml = 0
  for i = 0; i < ns; i = i + 1 { if cl[i] > ml && cl[i] <= 15 { ml = cl[i] } }
  if ml == 0 { return { table: Array::make(1, { symbol: -1, length: 0 }), tbl_bits: 0 } }

  // Count codes per length (RFC 1951 §3.2.2)
  let bc = Array::make(16, 0); let nc = Array::make(16, 0)
  for i = 0; i < ns; i = i + 1 { let l = cl[i]; if l > 0 && l <= 15 { bc[l] = bc[l] + 1 } }

  // Compute the starting code for each length
  let mut code = 0
  for b = 1; b <= 15; b = b + 1 { code = (code + bc[b - 1]) << 1; nc[b] = code }

  // Build fast lookup table: tbl_bits bits of prefix -> symbol + code length
  let tb = if ml >= 10 { 15 } else { ml }
  let ts = 1 << tb
  let tbl = Array::make(ts, { symbol: -1, length: 0 })

  for i = 0; i < ns; i = i + 1 {
    let l = cl[i]
    if l > 0 && l <= 15 {
      let a = nc[l]; nc[l] = a + 1
      let base = a << (tb - l)
      let step = 1 << (tb - l)
      for j = 0; j < step && base + j < ts; j = j + 1 {
        tbl[base + j] = { symbol: i, length: l }
      }
    }
  }

  { table: tbl, tbl_bits: tb }
}

/// Decode a single symbol using the fast lookup table
fn huff_decode(d : HDecoder, bits : Int) -> (Int, Int) {
  let e = d.table[bits & ((1 << d.tbl_bits) - 1)]
  (e.symbol, e.length)
}

/// Query the number of lookup bits for this decoder
fn huff_bits(d : HDecoder) -> Int { d.tbl_bits }

//-----------------------------------------------------------------------------
// Fixed Huffman trees (RFC 1951 §3.2.6)
//-----------------------------------------------------------------------------

/// Pre-built fixed literal/length Huffman tree (288 symbols)
let fxl : HDecoder = {
  let ls = Array::make(288, 0)
  for i = 0; i <= 143; i = i + 1 { ls[i] = 8 }
  for i = 144; i <= 255; i = i + 1 { ls[i] = 9 }
  for i = 256; i <= 279; i = i + 1 { ls[i] = 7 }
  for i = 280; i <= 287; i = i + 1 { ls[i] = 8 }
  build_huffman(ls, 288)
}

/// Pre-built fixed distance Huffman tree (32 symbols)
let fxd : HDecoder = {
  let ls = Array::make(32, 0)
  for i = 0; i < 32; i = i + 1 { ls[i] = 5 }
  build_huffman(ls, 32)
}

//-----------------------------------------------------------------------------
// Length and distance tables (RFC 1951 §3.2.5)
//-----------------------------------------------------------------------------

/// Base length values for length codes 257-285
let lbase : Array[Int] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27,
  31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
]

/// Extra bits for length codes 257-285
let lextra : Array[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
  2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
]

/// Base distance values for distance codes 0-29
let dbase : Array[Int] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129,
  193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
]

/// Extra bits for distance codes 0-29
let dextra : Array[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6,
  6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
]

/// Code length alphabet reorder (RFC 1951 §3.2.7)
let clord : Array[Int] = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
]

//-----------------------------------------------------------------------------
// Bit buffer helpers
//-----------------------------------------------------------------------------

/// Ensure at least `need` bits are available in the buffer
fn ensure_bits(r : BitReader, buf : Int, cnt : Int, need : Int) -> Result[(BitReader, Int, Int), String] {
  let mut xr = r; let mut xb = buf; let mut xc = cnt
  while xc < need {
    match xr.read_bit() {
      Ok((r2, bit)) => { xr = r2; xb = (xb << 1) | bit; xc = xc + 1 }
      Err(e) => return Err(e)
    }
  }
  Ok((xr, xb, xc))
}

/// Consume `n` bits from the buffer, returning the value and updated state
fn consume(b : Int, c : Int, n : Int) -> (Int, Int, Int) {
  let v = b >> (c - n)
  let nc = c - n
  (b & ((1 << nc) - 1), nc, v)
}

//-----------------------------------------------------------------------------
// DEFLATE Decompressor (RFC 1951)
//-----------------------------------------------------------------------------

/// Decompress DEFLATE-formatted data (pure DEFLATE, no zlib wrapper)
fn deflate_decompress(data : Bytes) -> Result[Bytes, String] {
  let mut r = BitReader::new(data)
  let out = Buffer()
  let mut fb = false

  while !fb {
    let bf = match r.read_bits(1) { Ok((r2, v)) => { r = r2; v }; Err(e) => return Err(e) }
    let bt = match r.read_bits(2) { Ok((r2, v)) => { r = r2; v }; Err(e) => return Err(e) }
    fb = bf == 1

    if bt == 0 {
      // BTYPE=0: No compression
      r = r.align_to_byte()
      let lb = match r.read_bytes(2) { Ok((r2, v)) => { r = r2; v }; Err(e) => return Err(e) }
      let nb = match r.read_bytes(2) { Ok((r2, v)) => { r = r2; v }; Err(e) => return Err(e) }
      let len = lb[0].to_int() | (lb[1].to_int() << 8)
      let nlen = nb[0].to_int() | (nb[1].to_int() << 8)
      if len ^ nlen != 0xFFFF { return Err("DEFLATE: bad uncomp len") }
      let ld = match r.read_bytes(len) { Ok((r2, v)) => { r = r2; v }; Err(e) => return Err(e) }
      out.write_bytes(ld)
    } else if bt == 1 {
      // BTYPE=1: Fixed Huffman codes
      match decode_block(r, out, fxl, fxd) {
        Ok(r2) => { r = r2 }
        Err(e) => return Err(e)
      }
    } else if bt == 2 {
      // BTYPE=2: Dynamic Huffman codes
      match read_dyn_header(r) {
        Ok((r2, lt, dt)) => {
          r = r2
          match decode_block(r, out, lt, dt) {
            Ok(r3) => { r = r3 }
            Err(e) => return Err(e)
          }
        }
        Err(e) => return Err(e)
      }
    } else {
      return Err("DEFLATE: bad btype")
    }
  }

  Ok(out.to_bytes())
}

/// Decode a single DEFLATE block (BTYPE 1 or 2)
/// Reads literal/length and distance Huffman codes with LZ77 back-references
fn decode_block(r : BitReader, out : Buffer, lt : HDecoder, dt : HDecoder) -> Result[BitReader, String] {
  let mut xr = r; let mut bb = 0; let mut bc = 0
  let lb = huff_bits(lt); let db = huff_bits(dt)
  let ml = if lb > db { lb } else { db }
  let mut done = false

  while !done {
    // Ensure enough bits for a literal/length symbol
    match ensure_bits(xr, bb, bc, ml) {
      Ok((r2, b2, c2)) => { xr = r2; bb = b2; bc = c2 }
      Err(e) => return Err(e)
    }

    let (sym, clen) = huff_decode(lt, bb >> (bc - lb))
    if clen == 0 || clen > bc { return Err("DEFLATE: bad lit code") }
    let (nb, nc) = consume(bb, bc, clen); bb = nb; bc = nc

    if sym < 256 {
      // Literal byte
      out.write_byte(sym.to_byte())
    } else if sym == 256 {
      // End of block
      done = true
    } else {
      // Length code (257-285)
      let li = sym - 257
      if li >= 29 { return Err("DEFLATE: bad length") }
      let mut length = lbase[li]
      let ex = lextra[li]
      if ex > 0 {
        match ensure_bits(xr, bb, bc, ex) {
          Ok((r2, b2, c2)) => { xr = r2; bb = b2; bc = c2 }
          Err(e) => return Err(e)
        }
        let (nb2, nc2, ev) = consume(bb, bc, ex); bb = nb2; bc = nc2
        length = length + ev
      }

      // Distance code
      match ensure_bits(xr, bb, bc, db) {
        Ok((r2, b2, c2)) => { xr = r2; bb = b2; bc = c2 }
        Err(e) => return Err(e)
      }
      let (dc, dcl) = huff_decode(dt, bb >> (bc - db))
      if dcl == 0 || dcl > bc { return Err("DEFLATE: bad dist code") }
      let (nb3, nc3) = consume(bb, bc, dcl); bb = nb3; bc = nc3

      if dc >= 30 { return Err("DEFLATE: bad distance") }
      let mut dist = dbase[dc]
      let dex = dextra[dc]
      if dex > 0 {
        match ensure_bits(xr, bb, bc, dex) {
          Ok((r2, b2, c2)) => { xr = r2; bb = b2; bc = c2 }
          Err(e) => return Err(e)
        }
        let (nb4, nc4, ev) = consume(bb, bc, dex); bb = nb4; bc = nc4
        dist = dist + ev
      }

      // LZ77 back-reference copy
      let ol = out.length()
      if dist > ol { return Err("DEFLATE: dist>len") }
      let cs = ol - dist
      if dist >= length {
        for i = 0; i < length; i = i + 1 { out.write_byte(out.view()[cs + i]) }
      } else {
        let mut cp = 0
        while cp < length {
          let ch = if dist < length - cp { dist } else { length - cp }
          for i = 0; i < ch; i = i + 1 { out.write_byte(out.view()[cs + i]) }
          cp = cp + ch
        }
      }
    }
  }

  Ok(xr)
}

/// Read dynamic Huffman header for BTYPE=2 blocks
/// Returns the literal/length and distance Huffman decoders
fn read_dyn_header(r : BitReader) -> Result[(BitReader, HDecoder, HDecoder), String] {
  let mut xr = r; let mut bb = 0; let mut bc = 0

  // Read HLIT (5 bits), HDIST (5 bits), HCLEN (4 bits)
  match ensure_bits(xr, bb, bc, 14) {
    Ok((r2, b2, c2)) => { xr = r2; bb = b2; bc = c2 }
    Err(e) => return Err(e)
  }
  let (b1, c1, hl) = consume(bb, bc, 5)
  let (b2, c2, hd) = consume(b1, c1, 5)
  let (b3, c3, hc) = consume(b2, c2, 4)
  bb = b3; bc = c3

  let nl = hl + 257
  let nd = hd + 1
  let ncl = hc + 4

  if nl > 286 || nd > 30 { return Err("DEFLATE: too many codes") }

  // Read code length code lengths in clord order
  let cll = Array::make(19, 0)
  for i = 0; i < ncl; i = i + 1 {
    match ensure_bits(xr, bb, bc, 3) {
      Ok((r2, b2, c2)) => { xr = r2; bb = b2; bc = c2 }
      Err(e) => return Err(e)
    }
    let (nb, nc, len) = consume(bb, bc, 3); bb = nb; bc = nc
    cll[clord[i]] = len
  }

  // Build code length Huffman tree and decode literal/distance code lengths
  let clt = build_huffman(cll, 19)
  let cls = Array::make(nl + nd, 0)
  let mut i = 0

  while i < nl + nd {
    match ensure_bits(xr, bb, bc, huff_bits(clt)) {
      Ok((r2, b2, c2)) => { xr = r2; bb = b2; bc = c2 }
      Err(e) => return Err(e)
    }
    let (sym, cl) = huff_decode(clt, bb >> (bc - huff_bits(clt)))
    if cl == 0 { return Err("DEFLATE: bad cl code") }
    let (nb, nc) = consume(bb, bc, cl); bb = nb; bc = nc

    if sym < 16 {
      cls[i] = sym; i = i + 1
    } else if sym == 16 {
      // Repeat previous code length (3-6 times)
      if i == 0 { return Err("DEFLATE: rep with no prev") }
      match ensure_bits(xr, bb, bc, 2) {
        Ok((r2, b2, c2)) => { xr = r2; bb = b2; bc = c2 }
        Err(e) => return Err(e)
      }
      let (nb2, nc2, ex) = consume(bb, bc, 2); bb = nb2; bc = nc2
      let rp = ex + 3; let pv = cls[i - 1]
      for j = 0; j < rp && i < nl + nd; j = j + 1 { cls[i] = pv; i = i + 1 }
    } else if sym == 17 {
      // Repeat zero (3-10 times)
      match ensure_bits(xr, bb, bc, 3) {
        Ok((r2, b2, c2)) => { xr = r2; bb = b2; bc = c2 }
        Err(e) => return Err(e)
      }
      let (nb2, nc2, ex) = consume(bb, bc, 3); bb = nb2; bc = nc2
      let rp = ex + 3
      for j = 0; j < rp && i < nl + nd; j = j + 1 { cls[i] = 0; i = i + 1 }
    } else {
      // Repeat zero (11-138 times)
      match ensure_bits(xr, bb, bc, 7) {
        Ok((r2, b2, c2)) => { xr = r2; bb = b2; bc = c2 }
        Err(e) => return Err(e)
      }
      let (nb2, nc2, ex) = consume(bb, bc, 7); bb = nb2; bc = nc2
      let rp = ex + 11
      for j = 0; j < rp && i < nl + nd; j = j + 1 { cls[i] = 0; i = i + 1 }
    }
  }

  // Split into literal/length and distance trees
  let lla = Array::make(nl, 0)
  for j = 0; j < nl; j = j + 1 { lla[j] = cls[j] }
  let dla = Array::make(nd, 0)
  for j = 0; j < nd; j = j + 1 { dla[j] = cls[nl + j] }

  Ok((xr, build_huffman(lla, nl), build_huffman(dla, nd)))
}

//-----------------------------------------------------------------------------
// zlib decompression wrapper (RFC 1950)
//-----------------------------------------------------------------------------

/// Decompress zlib-wrapped DEFLATE data
/// zlib format: 2-byte header (CMF+FLG) + DEFLATE stream + 4-byte Adler32
fn zlib_decompress(data : Bytes) -> Result[Bytes, String] {
  if data.length() < 6 {
    return Err("zlib: data too short")
  }

  // CMF (Compression Method and Flags)
  let cmf = data[0].to_int()
  let cm = cmf & 0x0F       // Compression method
  let cinfo = cmf >> 4        // Compression info (window size)

  // FLG (Flags)
  let flg = data[1].to_int()
  let fcheck = ((cmf * 256) + flg) % 31

  // Verify header checksum
  if fcheck != 0 {
    return Err("zlib: header checksum mismatch")
  }

  // Only DEFLATE (CM=8) is supported
  if cm != 8 {
    return Err("zlib: unsupported compression method: \(cm)")
  }

  // Check for preset dictionary (FDICT flag)
  let fdict = (flg >> 5) & 1
  if fdict == 1 {
    return Err("zlib: preset dictionary not supported")
  }

  // Extract DEFLATE stream (skip 2-byte header, skip 4-byte Adler32 trailer)
  let deflate_data = data[2:data.length() - 4]

  // Decompress
  let result = deflate_decompress(deflate_data)?

  // Verify Adler32 (last 4 bytes of zlib stream, big-endian)
  let expected_adler = (data[data.length() - 4].to_int() << 24) |
                       (data[data.length() - 3].to_int() << 16) |
                       (data[data.length() - 2].to_int() << 8) |
                       data[data.length() - 1].to_int()
  let actual_adler = adler32(result)
  if actual_adler != expected_adler {
    return Err("zlib: Adler32 checksum mismatch")
  }

  Ok(result)
}

//-----------------------------------------------------------------------------
// PNG filter reversal
//-----------------------------------------------------------------------------

// PNG filter types
let F_NONE  : Int = 0
let F_SUB   : Int = 1
let F_UP    : Int = 2
let F_AVG   : Int = 3
let F_PAETH : Int = 4

/// Absolute value
fn abs_i(x : Int) -> Int { if x < 0 { -x } else { x } }

/// Paeth predictor: selects the neighbor (a=left, b=up, c=upper-left)
/// closest to a+b-c, used by PNG filter type 4
fn paeth(a : Int, b : Int, c : Int) -> Int {
  let p = a + b - c
  let pa = abs_i(p - a)
  let pb = abs_i(p - b)
  let pc = abs_i(p - c)
  if pa <= pb && pa <= pc { a } else if pb <= pc { b } else { c }
}

/// Apply PNG filter reversal to a single row of pixel data
/// `ft` = filter type, `rd` = filtered row data, `prev` = previous unfiltered row
/// `row` = current row index, `bpp` = bytes per pixel, `arr` = output buffer
fn apply_filter(
  ft : Int, rd : Bytes, prev : Array[Byte],
  row : Int, bpp : Int, arr : Array[Byte], pitch : Int
) -> Result[Unit, String] {
  let ro = row * pitch
  let sl = rd.length()

  // Filter None: data is already unfiltered
  if ft == F_NONE {
    for i = 0; i < sl; i = i + 1 { arr[ro + i] = rd[i] }
    return Ok(())
  }

  // Filter Sub: add left neighbor (already decoded in current row)
  if ft == F_SUB {
    let cf = if bpp < sl { bpp } else { sl }
    for i = 0; i < cf; i = i + 1 { arr[ro + i] = rd[i] }
    for i = bpp; i < sl; i = i + 1 {
      arr[ro + i] = ((rd[i].to_int() + arr[ro + i - bpp].to_int()) & 0xFF).to_byte()
    }
    return Ok(())
  }

  // Per-pixel filters (Up, Average, Paeth)
  for i = 0; i < sl; i = i + 1 {
    let raw = rd[i].to_int()
    let left = if i >= bpp { arr[ro + i - bpp].to_int() } else { 0 }
    let upv = if row > 0 && i < prev.length() { prev[i].to_int() } else { 0 }
    let flt = match ft {
      F_UP => (raw + upv) & 0xFF
      F_AVG => (raw + ((left + upv) / 2)) & 0xFF
      F_PAETH => {
        let ul = if row > 0 && i >= bpp && i < prev.length() { prev[i - bpp].to_int() } else { 0 }
        (raw + paeth(left, upv, ul)) & 0xFF
      }
      _ => return Err("PNG: bad filter")
    }
    arr[ro + i] = flt.to_byte()
  }
  Ok(())
}

//-----------------------------------------------------------------------------
// PNG Decoder (non-interlaced, 8-bit grayscale/RGB/RGBA)
//-----------------------------------------------------------------------------

/// PNG 8-byte file signature
let png_sig : Array[Byte] = [b'\x89', b'P', b'N', b'G', b'\r', b'\n', b'\x1A', b'\n']

/// PNG color types
let PC_GRAY  : Int = 0
let PC_RGB   : Int = 2
let PC_GA    : Int = 4
let PC_RGBA  : Int = 6

/// Check if a chunk type matches a 4-character code
fn chunk_is(b : Bytes, c0 : Byte, c1 : Byte, c2 : Byte, c3 : Byte) -> Bool {
  b.length() >= 4 && b[0] == c0 && b[1] == c1 && b[2] == c2 && b[3] == c3
}

/// Bytes per pixel for a given color type (at 8-bit depth)
fn png_spp(ct : Int) -> Int {
  match ct { 0 => 1; 2 => 3; 4 => 2; 6 => 4; _ => 1 }
}

/// Output PixelFormat for a given color type
fn out_fmt(ct : Int) -> PixelFormat {
  match ct {
    PC_GRAY => PixelFormat::Gray8
    PC_GA => PixelFormat::GrayA8
    PC_RGB => PixelFormat::RGB8
    PC_RGBA => PixelFormat::RGBA8
    _ => PixelFormat::RGBA8
  }
}

/// Compute CRC32 of chunk type + chunk data
fn crc32_chunk(chunk_type : Bytes, chunk_data : Bytes) -> Int {
  crc32_concat(crc32(chunk_type), chunk_data)
}

/// Decode a PNG image from raw bytes
pub fn decode_png(data : Bytes) -> Result[Image, String] {
  // Verify PNG signature
  if data.length() < 8 { return Err("PNG: too small") }
  for i = 0; i < 8; i = i + 1 {
    if data[i] != png_sig[i] { return Err("PNG: bad sig") }
  }

  let mut pos = 8
  let mut w = 0; let mut h = 0; let mut bd : Int = 0; let mut ct : Int = 0; let mut il : Int = 0
  let mut cd = Buffer()
  let mut hi = false  // IHDR seen flag

  // Chunk parsing loop
  while pos < data.length() {
    if pos + 8 > data.length() { return Err("PNG: trunc chunk") }

    // Read chunk length (4 bytes, big-endian)
    let cl = match read_u32_be(data, pos) { Ok(v) => v; Err(e) => return Err(e) }
    pos = pos + 4

    // Read chunk type (4 bytes)
    let cbt = data[pos:pos + 4]
    pos = pos + 4

    if pos + cl + 4 > data.length() { return Err("PNG: trunc chunk data") }

    // Read chunk data
    let cdat = data[pos:pos + cl]
    pos = pos + cl

    // Read stored CRC
    let sc = match read_u32_be(data, pos) { Ok(v) => v; Err(e) => return Err(e) }
    pos = pos + 4

    // Verify CRC for critical chunks (uppercase first letter)
    let is_critical = (cbt[0].to_int() & 32) == 0
    if is_critical {
      let ccrc = crc32_chunk(cbt, cdat)
      if ccrc != sc { return Err("PNG: CRC mismatch") }
    }

    let ih = chunk_is(cbt, b'I', b'H', b'D', b'R')
    let id = chunk_is(cbt, b'I', b'D', b'A', b'T')
    let ie = chunk_is(cbt, b'I', b'E', b'N', b'D')

    if ih {
      // IHDR: image header
      if cl != 13 { return Err("PNG: IHDR len") }
      if hi { return Err("PNG: dup IHDR") }
      w = match read_u32_be(cdat, 0) { Ok(v) => v; Err(e) => return Err(e) }
      h = match read_u32_be(cdat, 4) { Ok(v) => v; Err(e) => return Err(e) }
      bd = cdat[8].to_int()
      ct = cdat[9].to_int()
      il = cdat[12].to_int()
      // Validate compression and filter method
      if cdat[10].to_int() != 0 { return Err("PNG: bad comp") }
      if cdat[11].to_int() != 0 { return Err("PNG: bad filt") }
      if il != 0 { return Err("PNG: interlace not yet supported") }
      hi = true
    } else if id {
      // IDAT: image data
      if !hi { return Err("PNG: IDAT before IHDR") }
      cd.write_bytes(cdat)
    } else if ie {
      // IEND: image end
      break
    }
  }

  if !hi { return Err("PNG: no IHDR") }
  if w <= 0 || h <= 0 { return Err("PNG: bad dims") }

  // Validate color type + bit depth combination
  let vok = match ct {
    PC_GRAY => bd == 8
    PC_RGB => bd == 8
    PC_GA => bd == 8
    PC_RGBA => bd == 8
    _ => false
  }
  if !vok { return Err("PNG: bad color/depth") }

  // zlib decompress all IDAT data
  let dec = match zlib_decompress(cd.to_bytes()) { Ok(v) => v; Err(e) => return Err(e) }

  // Decode non-interlaced image
  decode_plain(w, h, bd, ct, dec)
}

/// Decode a non-interlaced (il=0) PNG image from decompressed filtered data
fn decode_plain(
  w : Int, h : Int, bd : Int, ct : Int, dec : Bytes
) -> Result[Image, String] {
  let sp = png_spp(ct)
  let bpp = sp * bd / 8    // bytes per pixel
  let pitch = w * bpp       // bytes per output row
  let ssl = w * bpp + 1     // source row stride (filter byte + row data)

  let arr = Array::make(w * h * bpp, b'\x00')
  let prev = Array::make(pitch, b'\x00')

  for y = 0; y < h; y = y + 1 {
    let rs = y * ssl
    if rs + ssl > dec.length() { return Err("PNG: short row") }
    let ft = dec[rs].to_int()
    let rd = dec[rs + 1:rs + ssl]

    match apply_filter(ft, rd, prev, y, bpp, arr, pitch) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }

    // Save current row as previous for next iteration
    let ro = y * pitch
    for x = 0; x < pitch && ro + x < arr.length(); x = x + 1 {
      prev[x] = arr[ro + x]
    }
  }

  Ok(Image::new(w, h, out_fmt(ct), Bytes::from_array(arr)))
}
