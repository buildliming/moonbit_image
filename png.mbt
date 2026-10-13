// Copyright (c) 2025 lws
// PNG decoder with DEFLATE, transparency and Adam7 support

//-----------------------------------------------------------------------------
// Huffman Tree for DEFLATE (RFC 1951)
//-----------------------------------------------------------------------------

///|
/// Huffman table entry: symbol value and code length
priv struct HEntry {
  symbol : Int
  length : Int
}

///|
/// Fast lookup Huffman decoder using a prefix table
priv struct HDecoder {
  table : Array[HEntry]
  tbl_bits : Int
}

///|
/// Build a canonical Huffman tree from an array of code lengths
/// Uses a fast lookup table of size 2^tbl_bits for O(1) symbol decoding
fn build_huffman(cl : Array[Int], ns : Int) -> HDecoder {
  // Determine maximum code length
  let mut ml = 0
  for i = 0; i < ns; i = i + 1 {
    if cl[i] > ml && cl[i] <= 15 {
      ml = cl[i]
    }
  }
  if ml == 0 {
    return { table: Array::make(1, { symbol: -1, length: 0, }), tbl_bits: 0, }
  }

  // Count codes per length (RFC 1951 §3.2.2)
  let bc = Array::make(16, 0)
  let nc = Array::make(16, 0)
  for i = 0; i < ns; i = i + 1 {
    let l = cl[i]
    if l > 0 && l <= 15 {
      bc[l] = bc[l] + 1
    }
  }

  // Compute the starting code for each length
  let mut code = 0
  for b = 1; b <= 15; b = b + 1 {
    code = (code + bc[b - 1]) << 1
    nc[b] = code
  }

  // Build fast lookup table: tbl_bits = ml gives optimal size (2^ml entries)
  // Kraft inequality guarantees all 2^ml entries are filled for complete Huffman trees
  let tb = ml
  let ts = 1 << tb
  let tbl = Array::make(ts, { symbol: -1, length: 0, })

  for i = 0; i < ns; i = i + 1 {
    let l = cl[i]
    if l > 0 && l <= 15 {
      let a = nc[l]
      nc[l] = a + 1
      let base = a << (tb - l)
      let step = 1 << (tb - l)
      for j = 0; j < step && base + j < ts; j = j + 1 {
        tbl[base + j] = { symbol: i, length: l, }
      }
    }
  }

  { table: tbl, tbl_bits: tb, }
}

///|
/// Validate dynamic trees before constructing the lookup table.
/// A single one-bit code is allowed for literal/distance alphabets, and
/// an empty distance alphabet is allowed for blocks containing only literals.
fn checked_huffman(
  cl : Array[Int],
  ns : Int,
  allow_single : Bool,
  allow_empty : Bool,
) -> HDecoder raise Failure {
  let counts = Array::make(16, 0)
  let mut max_length = 0
  for i = 0; i < ns; i = i + 1 {
    let length = cl[i]
    if length < 0 || length > 15 {
      raise Failure::Failure("DEFLATE: invalid code length")
    }
    counts[length] = counts[length] + 1
    if length > max_length {
      max_length = length
    }
  }
  if max_length == 0 {
    if !allow_empty {
      raise Failure::Failure("DEFLATE: empty Huffman tree")
    }
    return build_huffman(cl, ns)
  }
  let mut remaining = 1
  for length = 1; length <= 15; length = length + 1 {
    remaining = (remaining << 1) - counts[length]
    if remaining < 0 {
      raise Failure::Failure("DEFLATE: oversubscribed Huffman tree")
    }
  }
  if remaining > 0 && !(allow_single && max_length == 1) {
    raise Failure::Failure("DEFLATE: incomplete Huffman tree")
  }
  build_huffman(cl, ns)
}

///|
/// Reverse the bottom `n` bits of `v` (bit 0 becomes bit n-1, etc.)
fn reverse_bits(v : Int, n : Int) -> Int {
  let mut result = 0
  let mut x = v
  for i = 0; i < n; i = i + 1 {
    result = (result << 1) | (x & 1)
    x = x >> 1
  }
  result
}

///|
/// Decode a single symbol using the fast lookup table
/// `bits` contains the next `tbl_bits` bits LSB-first; we reverse them because
/// Huffman codes are transmitted MSB-first but packed LSB-first in DEFLATE
fn huff_decode(d : HDecoder, bits : Int) -> (Int, Int) {
  let idx = reverse_bits(bits, d.tbl_bits)
  let e = d.table[idx]
  (e.symbol, e.length)
}

///|
/// Query the number of lookup bits for this decoder
fn huff_bits(d : HDecoder) -> Int {
  d.tbl_bits
}

//-----------------------------------------------------------------------------
// Fixed Huffman trees (RFC 1951 §3.2.6)
//-----------------------------------------------------------------------------

///|
/// Pre-built fixed literal/length Huffman tree (288 symbols)
let fxl : HDecoder = {
  let ls = Array::make(288, 0)
  for i = 0; i <= 143; i = i + 1 {
    ls[i] = 8
  }
  for i = 144; i <= 255; i = i + 1 {
    ls[i] = 9
  }
  for i = 256; i <= 279; i = i + 1 {
    ls[i] = 7
  }
  for i = 280; i <= 287; i = i + 1 {
    ls[i] = 8
  }
  build_huffman(ls, 288)
}

///|
/// Pre-built fixed distance Huffman tree (32 symbols)
let fxd : HDecoder = {
  let ls = Array::make(32, 0)
  for i = 0; i < 32; i = i + 1 {
    ls[i] = 5
  }
  build_huffman(ls, 32)
}

//-----------------------------------------------------------------------------
// Length and distance tables (RFC 1951 §3.2.5)
//-----------------------------------------------------------------------------

///|
/// Base length values for length codes 257-285
let lbase : Array[Int] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
/// Extra bits for length codes 257-285
let lextra : Array[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
/// Base distance values for distance codes 0-29
let dbase : Array[Int] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
/// Extra bits for distance codes 0-29
let dextra : Array[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
/// Code length alphabet reorder (RFC 1951 §3.2.7)
let clord : Array[Int] = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]

//-----------------------------------------------------------------------------
// Bit buffer helpers
//-----------------------------------------------------------------------------

///|
/// Ensure at least `need` bits are available in the buffer
/// Bits are accumulated LSB-first: first bit read is at position 0
/// When the bit stream is exhausted (e.g., end-of-block padding), returns
/// whatever bits are available instead of raising. Callers must check `cnt`
/// to verify sufficient bits were obtained.
fn ensure_bits(
  r : BitReader,
  buf : Int,
  cnt : Int,
  need : Int,
) -> (BitReader, Int, Int) raise Failure {
  let mut xr = r
  let mut xb = buf
  let mut xc = cnt
  while xc < need {
    if xr.byte_pos >= xr.data.length() {
      break
    }
    // Never request more bits than remain: read_bits is atomic on failure,
    // so a failed wide lookahead must not discard a valid short final code.
    let mut to_read = if need - xc > 16 { 16 } else { need - xc }
    let remaining_bytes = xr.data.length() - xr.byte_pos
    if remaining_bytes <= 2 {
      let available = remaining_bytes * 8 - xr.bit_pos
      if to_read > available {
        to_read = available
      }
    }
    let (nr, val) = xr.read_bits(to_read)
    xr = nr
    xb = xb | (val << xc)
    xc = xc + to_read
  }
  (xr, xb, xc)
}

///|
/// Consume `n` bits from the LSB side of the buffer, returning the value and updated state
fn consume(b : Int, c : Int, n : Int) -> (Int, Int, Int) {
  let v = b & ((1 << n) - 1)
  let nb = b >> n
  let nc = c - n
  (nb, nc, v)
}

///|
/// Put lookup bits back before reading the next block or the zlib trailer.
fn rewind_bits(r : BitReader, count : Int) -> BitReader {
  let back = count - r.bit_pos
  if back <= 0 {
    { data: r.data, byte_pos: r.byte_pos, bit_pos: -back, }
  } else {
    let bytes = (back + 7) / 8
    { data: r.data, byte_pos: r.byte_pos - bytes, bit_pos: bytes * 8 - back, }
  }
}

//-----------------------------------------------------------------------------
// DEFLATE Decompressor (RFC 1951)
//-----------------------------------------------------------------------------

///|
/// Return the byte offset after the final block's padding for zlib framing.
fn deflate_decompress_stream(
  data : Bytes,
  max_output : Int,
  window_size : Int,
) -> (Bytes, Int) raise Failure {
  let mut r = BitReader::new(data)
  let out = Buffer()
  let mut fb = false

  while !fb {
    let (r_bf, bf) = r.read_bits(1)
    r = r_bf
    let (r_bt, bt) = r.read_bits(2)
    r = r_bt
    fb = bf == 1

    if bt == 0 {
      // BTYPE=0: No compression
      r = r.align_to_byte()
      let (r_lb, lb) = r.read_bytes(2)
      r = r_lb
      let (r_nb, nb) = r.read_bytes(2)
      r = r_nb
      let len = lb[0].to_int() | (lb[1].to_int() << 8)
      let nlen = nb[0].to_int() | (nb[1].to_int() << 8)
      if (len ^ nlen) != 0xFFFF {
        raise Failure::Failure("DEFLATE: bad uncomp len")
      }
      if len > max_output - out.length() {
        raise Failure::Failure("DEFLATE: output exceeds image data size")
      }
      let (r_ld, ld) = r.read_bytes(len)
      r = r_ld
      out.write_bytes(ld)
    } else if bt == 1 {
      // BTYPE=1: Fixed Huffman codes
      let (r2, _, count) = decode_block(
        r, out, fxl, fxd, 0, 0, max_output, window_size,
      )
      r = rewind_bits(r2, count)
    } else if bt == 2 {
      // BTYPE=2: Dynamic Huffman codes
      let (r_dyn, bb_dyn, bc_dyn, lt, dt) = read_dyn_header(r)
      r = r_dyn
      let (r2, _, count) = decode_block(
        r, out, lt, dt, bb_dyn, bc_dyn, max_output, window_size,
      )
      r = rewind_bits(r2, count)
    } else {
      raise Failure::Failure("DEFLATE: bad btype")
    }
  }

  (out.to_bytes(), r.align_to_byte().byte_pos)
}

///|
/// Decode a single DEFLATE block (BTYPE 1 or 2)
/// Reads literal/length and distance Huffman codes with LZ77 back-references
fn decode_block(
  r : BitReader,
  out : Buffer,
  lt : HDecoder,
  dt : HDecoder,
  bb0 : Int,
  bc0 : Int,
  max_output : Int,
  window_size : Int,
) -> (BitReader, Int, Int) raise Failure {
  let mut xr = r
  let mut bb = bb0
  let mut bc = bc0
  let lb = huff_bits(lt)
  let db = huff_bits(dt)
  let mut done = false

  while !done {
    // Short codes may end before the table's full lookahead width.
    let (nr, eb, ec) = ensure_bits(xr, bb, bc, lb)
    xr = nr
    bb = eb
    bc = ec

    let (sym, clen) = huff_decode(lt, bb & ((1 << lb) - 1))
    if clen == 0 || clen > bc {
      raise Failure::Failure("DEFLATE: bad lit code")
    }
    let (nb, nc, _) = consume(bb, bc, clen)
    bb = nb
    bc = nc

    if sym < 256 {
      // Literal byte
      if out.length() >= max_output {
        raise Failure::Failure("DEFLATE: output exceeds image data size")
      }
      out.write_byte(sym.to_byte())
    } else if sym == 256 {
      // End of block
      done = true
    } else {
      // Length code (257-285)
      let li = sym - 257
      if li >= 29 {
        raise Failure::Failure("DEFLATE: bad length")
      }
      let mut length = lbase[li]
      let ex = lextra[li]
      if ex > 0 {
        let (nr2, eb2, ec2) = ensure_bits(xr, bb, bc, ex)
        xr = nr2
        bb = eb2
        bc = ec2
        if bc < ex {
          raise Failure::Failure("DEFLATE: truncated length")
        }
        let (nb2, nc2, ev) = consume(bb, bc, ex)
        bb = nb2
        bc = nc2
        length = length + ev
      }

      // Distance code
      let (nr3, eb3, ec3) = ensure_bits(xr, bb, bc, db)
      xr = nr3
      bb = eb3
      bc = ec3
      let (dc, dcl) = huff_decode(dt, bb & ((1 << db) - 1))
      if dcl == 0 || dcl > bc {
        raise Failure::Failure("DEFLATE: bad dist code")
      }
      let (nb3, nc3, _) = consume(bb, bc, dcl)
      bb = nb3
      bc = nc3

      if dc >= 30 {
        raise Failure::Failure("DEFLATE: bad distance")
      }
      let mut dist = dbase[dc]
      let dex = dextra[dc]
      if dex > 0 {
        let (nr4, eb4, ec4) = ensure_bits(xr, bb, bc, dex)
        xr = nr4
        bb = eb4
        bc = ec4
        if bc < dex {
          raise Failure::Failure("DEFLATE: truncated distance")
        }
        let (nb4, nc4, ev) = consume(bb, bc, dex)
        bb = nb4
        bc = nc4
        dist = dist + ev
      }

      // LZ77 back-reference copy
      let ol = out.length()
      if dist > ol || dist > window_size {
        raise Failure::Failure("DEFLATE: dist>len")
      }
      if length > max_output - ol {
        raise Failure::Failure("DEFLATE: output exceeds image data size")
      }
      let cs = ol - dist
      if dist >= length {
        // Non-overlapping: simple bulk copy
        for i = 0; i < length; i = i + 1 {
          out.write_byte(out.view()[cs + i])
        }
      } else {
        // Overlapping: copy in dist-sized chunks, advancing source each iteration
        // so that newly written bytes become the source for subsequent chunks
        let mut remaining = length
        let mut src_pos = cs
        while remaining > 0 {
          let chunk = if dist < remaining { dist } else { remaining }
          for i = 0; i < chunk; i = i + 1 {
            out.write_byte(out.view()[src_pos + i])
          }
          src_pos = src_pos + chunk
          remaining = remaining - chunk
        }
      }
    }
  }

  (xr, bb, bc)
}

///|
/// Read dynamic Huffman header for BTYPE=2 blocks
/// Returns the literal/length and distance Huffman decoders
fn read_dyn_header(
  r : BitReader,
) -> (BitReader, Int, Int, HDecoder, HDecoder) raise Failure {
  let mut xr = r
  let mut bb = 0
  let mut bc = 0

  // Read HLIT (5 bits), HDIST (5 bits), HCLEN (4 bits)
  let (nr, nb, nc) = ensure_bits(xr, bb, bc, 14)
  xr = nr
  bb = nb
  bc = nc
  if bc < 14 {
    raise Failure::Failure("DEFLATE: truncated dynamic header")
  }
  let (b1, c1, hl) = consume(bb, bc, 5)
  let (b2, c2, hd) = consume(b1, c1, 5)
  let (b3, c3, hc) = consume(b2, c2, 4)
  bb = b3
  bc = c3

  let nl = hl + 257
  let nd = hd + 1
  let ncl = hc + 4

  if nl > 286 {
    raise Failure::Failure("DEFLATE: too many codes")
  }

  // Read code length code lengths in clord order
  let cll = Array::make(19, 0)
  for i = 0; i < ncl; i = i + 1 {
    let (nr2, eb2, ec2) = ensure_bits(xr, bb, bc, 3)
    xr = nr2
    bb = eb2
    bc = ec2
    if bc < 3 {
      raise Failure::Failure("DEFLATE: truncated code lengths")
    }
    let (nb2, nc2, len) = consume(bb, bc, 3)
    bb = nb2
    bc = nc2
    cll[clord[i]] = len
  }

  // Build code length Huffman tree and decode literal/distance code lengths
  let clt = checked_huffman(cll, 19, false, false)
  let cls = Array::make(nl + nd, 0)
  let mut i = 0

  while i < nl + nd {
    let (nr3, eb3, ec3) = ensure_bits(xr, bb, bc, huff_bits(clt))
    xr = nr3
    bb = eb3
    bc = ec3
    let (sym, cl) = huff_decode(clt, bb & ((1 << huff_bits(clt)) - 1))
    if cl == 0 || cl > bc {
      raise Failure::Failure("DEFLATE: bad cl code")
    }
    let (nb3, nc3, _) = consume(bb, bc, cl)
    bb = nb3
    bc = nc3

    if sym < 16 {
      cls[i] = sym
      i = i + 1
    } else if sym == 16 {
      // Repeat previous code length (3-6 times)
      if i == 0 {
        raise Failure::Failure("DEFLATE: rep with no prev")
      }
      let (nr4, eb4, ec4) = ensure_bits(xr, bb, bc, 2)
      xr = nr4
      bb = eb4
      bc = ec4
      if bc < 2 {
        raise Failure::Failure("DEFLATE: truncated repeat")
      }
      let (nb4, nc4, ex) = consume(bb, bc, 2)
      bb = nb4
      bc = nc4
      let rp = ex + 3
      let pv = cls[i - 1]
      if rp > nl + nd - i {
        raise Failure::Failure("DEFLATE: repeat exceeds code lengths")
      }
      for j = 0; j < rp; j = j + 1 {
        cls[i] = pv
        i = i + 1
      }
    } else if sym == 17 {
      // Repeat zero (3-10 times)
      let (nr5, eb5, ec5) = ensure_bits(xr, bb, bc, 3)
      xr = nr5
      bb = eb5
      bc = ec5
      if bc < 3 {
        raise Failure::Failure("DEFLATE: truncated repeat")
      }
      let (nb5, nc5, ex) = consume(bb, bc, 3)
      bb = nb5
      bc = nc5
      let rp = ex + 3
      if rp > nl + nd - i {
        raise Failure::Failure("DEFLATE: repeat exceeds code lengths")
      }
      for j = 0; j < rp; j = j + 1 {
        cls[i] = 0
        i = i + 1
      }
    } else {
      // Repeat zero (11-138 times)
      let (nr6, eb6, ec6) = ensure_bits(xr, bb, bc, 7)
      xr = nr6
      bb = eb6
      bc = ec6
      if bc < 7 {
        raise Failure::Failure("DEFLATE: truncated repeat")
      }
      let (nb6, nc6, ex) = consume(bb, bc, 7)
      bb = nb6
      bc = nc6
      let rp = ex + 11
      if rp > nl + nd - i {
        raise Failure::Failure("DEFLATE: repeat exceeds code lengths")
      }
      for j = 0; j < rp; j = j + 1 {
        cls[i] = 0
        i = i + 1
      }
    }
  }

  // Split into literal/length and distance trees
  let lla = Array::make(nl, 0)
  for j = 0; j < nl; j = j + 1 {
    lla[j] = cls[j]
  }
  let dla = Array::make(nd, 0)
  for j = 0; j < nd; j = j + 1 {
    dla[j] = cls[nl + j]
  }

  if lla[256] == 0 {
    raise Failure::Failure("DEFLATE: missing end-of-block code")
  }
  (
    xr,
    bb,
    bc,
    checked_huffman(lla, nl, true, false),
    checked_huffman(dla, nd, true, true),
  )
}

//-----------------------------------------------------------------------------
// zlib decompression wrapper (RFC 1950)
//-----------------------------------------------------------------------------

///|
/// Decompress zlib-wrapped DEFLATE data
/// zlib format: 2-byte header (CMF+FLG) + DEFLATE stream + 4-byte Adler32
fn zlib_decompress(
  data : Bytes,
  max_output? : Int = 0x7FFFFFFF,
) -> Bytes raise Failure {
  if data.length() < 6 {
    raise Failure::Failure("zlib: data too short")
  }

  // CMF (Compression Method and Flags)
  let cmf = data[0].to_int()
  let cm = cmf & 0x0F // Compression method
  let cinfo = cmf >> 4 // Compression info (window size)

  // FLG (Flags)
  let flg = data[1].to_int()
  let fcheck = (cmf * 256 + flg) % 31

  // Verify header checksum
  if fcheck != 0 {
    raise Failure::Failure("zlib: header checksum mismatch")
  }

  // Only DEFLATE (CM=8) is supported
  if cm != 8 {
    raise Failure::Failure("zlib: unsupported compression method: \{cm}")
  }
  if cinfo > 7 {
    raise Failure::Failure("zlib: invalid window size")
  }
  if max_output < 0 {
    raise Failure::Failure("zlib: invalid output limit")
  }

  // Check for preset dictionary (FDICT flag)
  let fdict = (flg >> 5) & 1
  if fdict == 1 {
    raise Failure::Failure("zlib: preset dictionary not supported")
  }

  // Locate the trailer from the final block rather than the input's end.
  // PNG permits unused bytes after the zlib stream in the final IDAT chunk.
  let (result, consumed) = deflate_decompress_stream(
    data[2:].to_owned(),
    max_output,
    1 << (cinfo + 8),
  )
  let trailer = 2 + consumed
  if trailer > data.length() - 4 {
    raise Failure::Failure("zlib: truncated Adler32 checksum")
  }
  let expected_adler = (data[trailer].to_int() << 24) |
    (data[trailer + 1].to_int() << 16) |
    (data[trailer + 2].to_int() << 8) |
    data[trailer + 3].to_int()
  let actual_adler = adler32(result)
  if actual_adler != expected_adler {
    raise Failure::Failure("zlib: Adler32 checksum mismatch")
  }

  result
}

//-----------------------------------------------------------------------------
// PNG filter reversal
//-----------------------------------------------------------------------------

// PNG filter types

///|
const F_NONE : Int = 0

///|
const F_SUB : Int = 1

///|
const F_UP : Int = 2

///|
const F_AVG : Int = 3

///|
const F_PAETH : Int = 4

///|
/// Absolute value
fn abs_i(x : Int) -> Int {
  if x < 0 {
    -x
  } else {
    x
  }
}

///|
/// Paeth predictor: selects the neighbor (a=left, b=up, c=upper-left)
/// closest to a+b-c, used by PNG filter type 4
fn paeth(a : Int, b : Int, c : Int) -> Int {
  let p = a + b - c
  let pa = abs_i(p - a)
  let pb = abs_i(p - b)
  let pc = abs_i(p - c)
  if pa <= pb && pa <= pc {
    a
  } else if pb <= pc {
    b
  } else {
    c
  }
}

///|
/// Apply PNG filter reversal to a single row of pixel data
/// `ft` = filter type, `rd` = filtered row data, `prev` = previous unfiltered row
/// `row` = current row index, `bpp` = bytes per pixel, `arr` = output buffer
fn apply_filter(
  ft : Int,
  rd : Bytes,
  prev : Array[Byte],
  row : Int,
  bpp : Int,
  arr : Array[Byte],
  pitch : Int,
) -> Unit raise Failure {
  let ro = row * pitch
  let sl = rd.length()

  // Filter None: data is already unfiltered
  if ft == F_NONE {
    for i = 0; i < sl; i = i + 1 {
      arr[ro + i] = rd[i]
    }
    return ()
  }

  // Filter Sub: add left neighbor (already decoded in current row)
  if ft == F_SUB {
    let cf = if bpp < sl { bpp } else { sl }
    for i = 0; i < cf; i = i + 1 {
      arr[ro + i] = rd[i]
    }
    for i = bpp; i < sl; i = i + 1 {
      arr[ro + i] = ((rd[i].to_int() + arr[ro + i - bpp].to_int()) & 0xFF).to_byte()
    }
    return ()
  }

  // Filter Up: add pixel from previous row (no left neighbor needed)
  if ft == F_UP {
    for i = 0; i < sl; i = i + 1 {
      let raw = rd[i].to_int()
      let upv = if row > 0 && i < prev.length() { prev[i].to_int() } else { 0 }
      arr[ro + i] = ((raw + upv) & 0xFF).to_byte()
    }
    return ()
  }

  // Filter Average: average of left and up neighbors (no upper-left needed)
  if ft == F_AVG {
    for i = 0; i < sl; i = i + 1 {
      let raw = rd[i].to_int()
      let left = if i >= bpp { arr[ro + i - bpp].to_int() } else { 0 }
      let upv = if row > 0 && i < prev.length() { prev[i].to_int() } else { 0 }
      arr[ro + i] = ((raw + (left + upv) / 2) & 0xFF).to_byte()
    }
    return ()
  }

  // Filter Paeth: Paeth predictor (needs left, up, and upper-left)
  if ft == F_PAETH {
    for i = 0; i < sl; i = i + 1 {
      let raw = rd[i].to_int()
      let left = if i >= bpp { arr[ro + i - bpp].to_int() } else { 0 }
      let upv = if row > 0 && i < prev.length() { prev[i].to_int() } else { 0 }
      let ul = if row > 0 && i >= bpp && i < prev.length() {
        prev[i - bpp].to_int()
      } else {
        0
      }
      arr[ro + i] = ((raw + paeth(left, upv, ul)) & 0xFF).to_byte()
    }
    return ()
  }

  raise Failure::Failure("PNG: bad filter")
}

//-----------------------------------------------------------------------------
// PNG Decoder (all standard color types and depths, including Adam7)
//-----------------------------------------------------------------------------

///|
/// PNG 8-byte file signature
let png_sig : Array[Byte] = [
  b'\x89', b'P', b'N', b'G', b'\r', b'\n', b'\x1A', b'\n',
]

///|
/// PNG color types
const PC_GRAY : Int = 0

///|
const PC_RGB : Int = 2

///|
const PC_IDX : Int = 3

///|
const PC_GA : Int = 4

///|
const PC_RGBA : Int = 6

///|
/// Check if a chunk type matches a 4-character code
fn chunk_is(b : Bytes, c0 : Byte, c1 : Byte, c2 : Byte, c3 : Byte) -> Bool {
  b.length() >= 4 && b[0] == c0 && b[1] == c1 && b[2] == c2 && b[3] == c3
}

///|
/// Samples per pixel for a given color type
fn png_spp(ct : Int) -> Int {
  match ct {
    0 => 1
    2 => 3
    4 => 2
    6 => 4
    _ => 1
  }
}

///|
/// Output PixelFormat for a given color type
/// Indexed color outputs RGBA8 after palette expansion
fn out_fmt(ct : Int, transparent : Bool) -> PixelFormat {
  match ct {
    PC_GRAY =>
      if transparent {
        PixelFormat::GrayA8
      } else {
        PixelFormat::Gray8
      }
    PC_IDX => PixelFormat::RGBA8
    PC_GA => PixelFormat::GrayA8
    PC_RGB => if transparent { PixelFormat::RGBA8 } else { PixelFormat::RGB8 }
    PC_RGBA => PixelFormat::RGBA8
    _ => PixelFormat::RGBA8
  }
}

///|
/// Adam7 interlacing parameters: (x_start, y_start, x_step, y_step)
let a7_params : Array[(Int, Int, Int, Int)] = [
  (0, 0, 8, 8),
  (4, 0, 8, 8),
  (0, 4, 4, 8),
  (2, 0, 4, 4),
  (0, 2, 2, 4),
  (1, 0, 2, 2),
  (0, 1, 1, 2),
]

///|
/// Compute sub-image dimensions for an Adam7 pass
fn a7dims(w : Int, h : Int, pass : Int) -> (Int, Int) {
  let (xs, ys, xst, yst) = a7_params[pass]
  (
    if w > xs {
      (w - 1 - xs) / xst + 1
    } else {
      0
    },
    if h > ys {
      (h - 1 - ys) / yst + 1
    } else {
      0
    },
  )
}

///|
/// Decode a PNG image from raw bytes
/// Samples are returned in an 8-bit PixelFormat; 16-bit samples use their high byte.
/// tRNS adds alpha to grayscale/RGB output and supplies indexed palette alpha.
pub fn decode_png(data : Bytes) -> Image raise Failure {
  // Verify PNG signature
  if data.length() < 8 {
    raise Failure::Failure("PNG: too small")
  }
  for i = 0; i < 8; i = i + 1 {
    if data[i] != png_sig[i] {
      raise Failure::Failure("PNG: bad sig")
    }
  }

  let mut pos = 8
  let mut w = 0
  let mut h = 0
  let mut bd : Int = 0
  let mut ct : Int = 0
  let mut il : Int = 0
  let cd = Buffer()
  let mut hi = false // IHDR seen flag
  let mut has_idat = false
  let mut idat_ended = false
  let mut has_iend = false
  let mut has_palette = false
  let mut has_trns = false
  let mut trns : Bytes = b""
  let mut pal = Array::make(0, Color::default())

  // Chunk parsing loop
  while pos < data.length() {
    if data.length() - pos < 12 {
      raise Failure::Failure("PNG: trunc chunk")
    }

    // Read chunk length (4 bytes, big-endian)
    let cl = read_u32_be(data, pos)
    pos = pos + 4

    // Read chunk type (4 bytes)
    let cbt = data[pos:pos + 4].to_owned()
    pos = pos + 4

    if cl < 0 || cl > data.length() - pos - 4 {
      raise Failure::Failure("PNG: trunc chunk data")
    }
    for i = 0; i < 4; i = i + 1 {
      let c = cbt[i].to_int()
      if !((c >= 65 && c <= 90) || (c >= 97 && c <= 122)) {
        raise Failure::Failure("PNG: bad chunk type")
      }
    }

    // Read chunk data
    let cdat = data[pos:pos + cl].to_owned()
    pos = pos + cl

    // Read stored CRC
    let sc = read_u32_be(data, pos)
    pos = pos + 4

    // Verify critical chunks and transparency data used to produce pixels.
    let is_critical = (cbt[0].to_int() & 32) == 0
    let it = chunk_is(cbt, b't', b'R', b'N', b'S')
    if is_critical || it {
      let ccrc = crc32_chunk(cbt, cdat)
      if ccrc != sc {
        raise Failure::Failure("PNG: CRC mismatch")
      }
    }

    let ih = chunk_is(cbt, b'I', b'H', b'D', b'R')
    let id = chunk_is(cbt, b'I', b'D', b'A', b'T')
    let ie = chunk_is(cbt, b'I', b'E', b'N', b'D')
    let ip = chunk_is(cbt, b'P', b'L', b'T', b'E')
    if !hi && !ih {
      raise Failure::Failure("PNG: IHDR must be first")
    }
    if has_idat && !id {
      idat_ended = true
    }

    if ih {
      // IHDR: image header
      if cl != 13 {
        raise Failure::Failure("PNG: IHDR len")
      }
      if hi {
        raise Failure::Failure("PNG: dup IHDR")
      }
      w = read_u32_be(cdat, 0)
      h = read_u32_be(cdat, 4)
      bd = cdat[8].to_int()
      ct = cdat[9].to_int()
      il = cdat[12].to_int()
      if w <= 0 || h <= 0 {
        raise Failure::Failure("PNG: bad dims")
      }
      let valid = match ct {
        PC_GRAY => bd == 1 || bd == 2 || bd == 4 || bd == 8 || bd == 16
        PC_RGB | PC_GA | PC_RGBA => bd == 8 || bd == 16
        PC_IDX => bd == 1 || bd == 2 || bd == 4 || bd == 8
        _ => false
      }
      if !valid {
        raise Failure::Failure("PNG: bad color/depth")
      }
      // Validate compression and filter method
      if cdat[10].to_int() != 0 {
        raise Failure::Failure("PNG: bad comp")
      }
      if cdat[11].to_int() != 0 {
        raise Failure::Failure("PNG: bad filt")
      }
      if il != 0 && il != 1 {
        raise Failure::Failure("PNG: bad interlace")
      }
      hi = true
    } else if id {
      // IDAT: image data
      if idat_ended {
        raise Failure::Failure("PNG: nonconsecutive IDAT")
      }
      if ct == PC_IDX && !has_palette {
        raise Failure::Failure("PNG: missing PLTE")
      }
      has_idat = true
      cd.write_bytes(cdat)
    } else if ie {
      // IEND: image end
      if cl != 0 || !has_idat {
        raise Failure::Failure("PNG: bad IEND")
      }
      has_iend = true
      break
    } else if ip {
      // PLTE: palette
      if has_palette || has_idat || has_trns || ct == PC_GRAY || ct == PC_GA {
        raise Failure::Failure("PNG: invalid PLTE placement")
      }
      if cl == 0 || cl > 768 || cl % 3 != 0 {
        raise Failure::Failure("PNG: PLTE len")
      }
      let n = cl / 3
      if ct == PC_IDX && n > 1 << bd {
        raise Failure::Failure("PNG: palette exceeds bit depth")
      }
      has_palette = true
      pal = Array::make(n, Color::default())
      for i = 0; i < n; i = i + 1 {
        let o = i * 3
        pal[i] = Color::new(
          cdat[o].to_int(),
          cdat[o + 1].to_int(),
          cdat[o + 2].to_int(),
          255,
        )
      }
    } else if it {
      if has_trns || has_idat {
        raise Failure::Failure("PNG: invalid tRNS placement")
      }
      match ct {
        PC_GRAY => if cl != 2 { raise Failure::Failure("PNG: tRNS len") }
        PC_RGB => if cl != 6 { raise Failure::Failure("PNG: tRNS len") }
        PC_IDX => {
          if !has_palette || cl > pal.length() {
            raise Failure::Failure("PNG: tRNS palette len")
          }
          for i = 0; i < cl; i = i + 1 {
            pal[i] = pal[i].with_alpha(cdat[i].to_int())
          }
        }
        _ => raise Failure::Failure("PNG: tRNS with alpha channel")
      }
      has_trns = true
      trns = cdat
    } else if is_critical {
      raise Failure::Failure("PNG: unknown critical chunk")
    }
  }

  if !hi {
    raise Failure::Failure("PNG: no IHDR")
  }
  if !has_idat || !has_iend {
    raise Failure::Failure("PNG: missing IDAT or IEND")
  }
  let output_bpp = if ct == PC_IDX {
    4
  } else {
    png_spp(ct) + (if has_trns { 1 } else { 0 })
  }
  let _ = checked_image_size(w, h, output_bpp)
  let expected = png_filtered_size(w, h, bd, ct, il)
  let dec = zlib_decompress(cd.to_bytes(), max_output=expected)
  if dec.length() != expected {
    raise Failure::Failure("PNG: incorrect scanline data length")
  }

  // Decode (interlaced or non-interlaced)
  if il == 1 {
    decode_a7(w, h, bd, ct, pal, trns, dec)
  } else {
    decode_plain(w, h, bd, ct, pal, trns, dec)
  }
}

///|
/// Number of packed bytes in one scanline, without the filter byte.
fn png_pitch(w : Int, bd : Int, ct : Int) -> Int raise Failure {
  let pitch = (w.to_int64() * bd.to_int64() * png_spp(ct).to_int64() + 7L) / 8L
  if pitch >= 0x7FFFFFFFL {
    raise Failure::Failure("PNG: row too large")
  }
  pitch.to_int()
}

///|
/// Validate the filtered size before inflating or allocating pixel buffers.
fn png_filtered_size(
  w : Int,
  h : Int,
  bd : Int,
  ct : Int,
  il : Int,
) -> Int raise Failure {
  let mut size = 0L
  if il == 0 {
    size = (png_pitch(w, bd, ct).to_int64() + 1L) * h.to_int64()
  } else {
    for pass = 0; pass < 7; pass = pass + 1 {
      let (pw, ph) = a7dims(w, h, pass)
      if pw > 0 && ph > 0 {
        size = size + (png_pitch(pw, bd, ct).to_int64() + 1L) * ph.to_int64()
      }
    }
  }
  if size > MAX_DECODE_BYTES.to_int64() {
    raise Failure::Failure("PNG: image too large")
  }
  size.to_int()
}

///|
/// Reverse filters on packed scanlines; each row starts on a byte boundary.
fn png_unfilter(
  w : Int,
  h : Int,
  bd : Int,
  ct : Int,
  dec : Bytes,
) -> Bytes raise Failure {
  let pitch = png_pitch(w, bd, ct)
  let bpp = (png_spp(ct) * bd + 7) / 8
  let ssl = pitch + 1
  let arr = Array::make(pitch * h, b'\x00')
  let prev = Array::make(pitch, b'\x00')
  for y = 0; y < h; y = y + 1 {
    let rs = y * ssl
    apply_filter(
      dec[rs].to_int(),
      dec[rs + 1:rs + ssl].to_owned(),
      prev,
      y,
      bpp,
      arr,
      pitch,
    )
    for x = 0; x < pitch; x = x + 1 {
      prev[x] = arr[y * pitch + x]
    }
  }
  Bytes::from_array(arr)
}

///|
/// Read a sample at its original precision, before transparency comparison.
fn png_sample(
  data : Bytes,
  row : Int,
  x : Int,
  channel : Int,
  bd : Int,
  sp : Int,
) -> Int {
  if bd < 8 {
    let per_byte = 8 / bd
    (data[row + x / per_byte].to_int() >> (8 - bd - x % per_byte * bd)) &
    ((1 << bd) - 1)
  } else {
    let offset = row + (x * sp + channel) * (bd / 8)
    if bd == 16 {
      (data[offset].to_int() << 8) | data[offset + 1].to_int()
    } else {
      data[offset].to_int()
    }
  }
}

///|
/// Expand packed samples/palette entries and normalize samples to 8-bit output.
fn png_expand(
  data : Bytes,
  w : Int,
  h : Int,
  bd : Int,
  ct : Int,
  pal : Array[Color],
  trns : Bytes,
) -> Bytes raise Failure {
  if bd == 8 && ct != PC_IDX && trns.length() == 0 {
    return data
  }
  let sp = png_spp(ct)
  let transparent = trns.length() > 0 && ct != PC_IDX
  let bpp = if ct == PC_IDX {
    4
  } else {
    sp + (if transparent { 1 } else { 0 })
  }
  let pitch = png_pitch(w, bd, ct)
  let arr = Array::make(w * h * bpp, b'\x00')
  let mask = (1 << bd) - 1
  let transparent_samples = Array::make(sp, 0)
  if transparent {
    for c = 0; c < sp; c = c + 1 {
      transparent_samples[c] = (
          (trns[c * 2].to_int() << 8) | trns[c * 2 + 1].to_int()
        ) &
        mask
    }
  }
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      let dst = (y * w + x) * bpp
      if ct == PC_IDX {
        let index = png_sample(data, y * pitch, x, 0, bd, sp)
        if index >= pal.length() {
          raise Failure::Failure("PNG: palette index out of range")
        }
        let color = pal[index]
        arr[dst] = color.r.to_byte()
        arr[dst + 1] = color.g.to_byte()
        arr[dst + 2] = color.b.to_byte()
        arr[dst + 3] = color.a.to_byte()
      } else {
        let mut matches = transparent
        for c = 0; c < sp; c = c + 1 {
          let sample = png_sample(data, y * pitch, x, c, bd, sp)
          if transparent && sample != transparent_samples[c] {
            matches = false
          }
          let value = if bd == 16 {
            sample >> 8
          } else if bd < 8 {
            sample * 255 / mask
          } else {
            sample
          }
          arr[dst + c] = value.to_byte()
        }
        if transparent {
          arr[dst + sp] = if matches { b'\x00' } else { b'\xFF' }
        }
      }
    }
  }
  Bytes::from_array(arr)
}

///|
/// Decode a non-interlaced PNG image from decompressed filtered data
fn decode_plain(
  w : Int,
  h : Int,
  bd : Int,
  ct : Int,
  pal : Array[Color],
  trns : Bytes,
  dec : Bytes,
) -> Image raise Failure {
  let raw = png_unfilter(w, h, bd, ct, dec)
  let pixels = png_expand(raw, w, h, bd, ct, pal, trns)
  Image::new(w, h, out_fmt(ct, trns.length() > 0), pixels)
}

///|
/// Decode an Adam7 interlaced PNG image
fn decode_a7(
  w : Int,
  h : Int,
  bd : Int,
  ct : Int,
  pal : Array[Color],
  trns : Bytes,
  dec : Bytes,
) -> Image raise Failure {
  let bpp = if ct == PC_IDX {
    4
  } else {
    png_spp(ct) + (if trns.length() > 0 { 1 } else { 0 })
  }
  let oarr = Array::make(w * h * bpp, b'\x00')
  let mut sp_off = 0

  for pass = 0; pass < 7; pass = pass + 1 {
    let (pw, ph) = a7dims(w, h, pass)
    if pw == 0 || ph == 0 {
      continue
    }

    let (xs, ys, xst, yst) = a7_params[pass]
    let pass_size = (png_pitch(pw, bd, ct) + 1) * ph
    let raw = png_unfilter(
      pw,
      ph,
      bd,
      ct,
      dec[sp_off:sp_off + pass_size].to_owned(),
    )
    sp_off = sp_off + pass_size
    let pixels = png_expand(raw, pw, ph, bd, ct, pal, trns)

    // Scatter pass pixels to output image
    for py = 0; py < ph; py = py + 1 {
      let oy = ys + py * yst
      for px = 0; px < pw; px = px + 1 {
        let ox = xs + px * xst
        for b = 0; b < bpp; b = b + 1 {
          let si = (py * pw + px) * bpp + b
          let di = oy * (w * bpp) + ox * bpp + b
          oarr[di] = pixels[si]
        }
      }
    }
  }

  Image::new(w, h, out_fmt(ct, trns.length() > 0), Bytes::from_array(oarr))
}
