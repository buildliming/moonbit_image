// Copyright (c) 2025 lws
// JPEG baseline decoder — grayscale
//
// Supports JFIF grayscale baseline JPEG (SOF0) with:
//   - Huffman-coded DC and AC coefficients
//   - Zigzag deordering → dequantization → IDCT

//-----------------------------------------------------------------------------
// Zigzag
//-----------------------------------------------------------------------------

fn zz(k : Int) -> Int {
  [0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,
   12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28,
   35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,
   58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63][k]
}

//-----------------------------------------------------------------------------
// Bit reader (MSB-first)
//-----------------------------------------------------------------------------

priv struct JBR { data : Bytes; bp : Int }

fn JBR::new(data : Bytes) -> JBR { { data: data, bp: 0 } }

fn JBR::read_bit(self : JBR) -> (JBR, Int) raise Failure {
  let bi = self.bp / 8
  if bi >= self.data.length() { raise Failure::Failure("JPEG: end of entropy data") }
  let byte = self.data[bi].to_int()
  let bit = (byte >> (7 - self.bp % 8)) & 1
  let mut nbp = self.bp + 1
  if self.bp % 8 == 7 && byte == 0xFF && bi + 1 < self.data.length() && self.data[bi + 1].to_int() == 0x00 {
    nbp = nbp + 8
  }
  ({ data: self.data, bp: nbp }, bit)
}

fn JBR::read_bits(self : JBR, n : Int) -> (JBR, Int) raise Failure {
  let mut r = self
  let mut v = 0
  for _i = 0; _i < n; _i = _i + 1 {
    let (nr, b) = r.read_bit()
    r = nr
    v = (v << 1) | b
  }
  (r, v)
}

fn JBR::align(self : JBR) -> JBR {
  let r = self.bp % 8
  if r == 0 { self } else { { data: self.data, bp: self.bp + 8 - r } }
}

//-----------------------------------------------------------------------------
// Huffman table
//-----------------------------------------------------------------------------

priv struct JHT {
  minc : Array[Int]; maxc : Array[Int]; vptr : Array[Int]
  hv : Array[Int]
}

fn build_jht(bits : Array[Int], hv_in : Array[Int]) -> JHT {
  let minc = Array::make(17, 0); let maxc = Array::make(17, -1)
  let vptr = Array::make(17, -1)
  let mut code = 0; let mut ptr = 0
  for l = 1; l <= 16; l = l + 1 {
    if bits[l - 1] > 0 {
      minc[l] = code; maxc[l] = code + bits[l - 1] - 1; vptr[l] = ptr
      ptr = ptr + bits[l - 1]
      code = (code + bits[l - 1]) << 1
    } else {
      code = code << 1
    }
  }
  { minc: minc, maxc: maxc, vptr: vptr, hv: hv_in }
}

fn jht_decode(ht : JHT, r : JBR) -> (JBR, Int) raise Failure {
  let mut reader = r
  let mut code = 0
  for l = 1; l <= 16; l = l + 1 {
    let (nr, bit) = reader.read_bit()
    reader = nr
    code = (code << 1) | bit
    if ht.maxc[l] >= 0 && code <= ht.maxc[l] {
      let idx = ht.vptr[l] + (code - ht.minc[l])
      return (reader, ht.hv[idx])
    }
  }
  raise Failure::Failure("JPEG: bad Huffman code")
}

//-----------------------------------------------------------------------------
// IDCT
//-----------------------------------------------------------------------------

fn idct_1d(v : Array[Int], out : Array[Int], os : Int) -> Unit {
  let t : Array[Array[Int]] = [
    [1448,1448,1448,1448,1448,1448,1448,1448],
    [2009,1703,1138, 400,-400,-1138,-1703,-2009],
    [1892, 784,-784,-1892,-1892,-784, 784, 1892],
    [1703,-400,-2009,-1138,1138,2009, 400,-1703],
    [1448,-1448,-1448,1448,1448,-1448,-1448,1448],
    [1138,-2009, 400,1703,-1703,-400,2009,-1138],
    [ 784,-1892,1892,-784,-784,1892,-1892, 784],
    [ 400,-1138,1703,-2009,2009,-1703,1138,-400]
  ]
  for x = 0; x < 8; x = x + 1 {
    let mut sum = 0
    for u = 0; u < 8; u = u + 1 { sum = sum + v[u] * t[u][x] }
    let pixel = ((sum + 2048) >> 12) + 128
    if pixel < 0 { out[os + x] = 0 } else if pixel > 255 { out[os + x] = 255 } else { out[os + x] = pixel }
  }
}

fn idct_2d(block : Array[Int]) -> Array[Int] {
  let t = Array::make(64, 0)
  for y = 0; y < 8; y = y + 1 {
    let row = Array::make(8, 0)
    for x = 0; x < 8; x = x + 1 { row[x] = block[y * 8 + x] }
    let tmp = Array::make(8, 0)
    idct_1d(row, tmp, 0)
    for x = 0; x < 8; x = x + 1 { t[x * 8 + y] = tmp[x] }
  }
  let res = Array::make(64, 0)
  for x = 0; x < 8; x = x + 1 {
    let col = Array::make(8, 0)
    for y = 0; y < 8; y = y + 1 { col[y] = t[x * 8 + y] }
    idct_1d(col, res, x * 8)
  }
  res
}

//-----------------------------------------------------------------------------
// JPEG Decoder
//-----------------------------------------------------------------------------

/// Decode DC coefficient
fn jpg_dc(r : JBR, ht : JHT, pred : Int) -> (JBR, Int) raise Failure {
  let (r2, cat) = jht_decode(ht, r)
  let mut diff = 0
  if cat > 0 {
    let (r3, bits) = r2.read_bits(cat)
    let half = 1 << (cat - 1)
    diff = if bits < half { bits - ((1 << cat) - 1) } else { bits }
    (r3, pred + diff)
  } else {
    (r2, pred)
  }
}

/// Decode AC coefficients
fn jpg_ac(r : JBR, ht : JHT, block : Array[Int]) -> JBR raise Failure {
  let mut reader = r
  let mut k = 1
  while k < 64 {
    let (r2, sym) = jht_decode(ht, reader)
    reader = r2
    if sym == 0 { return reader }
    let rs = sym >> 4; let sz = sym & 0xF
    if sz == 0 && rs == 15 { k = k + 16; continue }
    k = k + rs
    if k >= 64 { break }
    if sz > 0 {
      let (r3, bits) = reader.read_bits(sz)
      reader = r3
      let half = 1 << (sz - 1)
      let val = if bits < half { bits - ((1 << sz) - 1) } else { bits }
      let zi = zz(k)
      if zi < 64 { block[zi] = val }
    }
    k = k + 1
  }
  reader
}

/// Decode one 8x8 block
fn jpg_block(r : JBR, dc_ht : JHT, ac_ht : JHT, qt : Array[Int], dc_pred : Int) -> (JBR, Int, Array[Int]) raise Failure {
  let block = Array::make(64, 0)
  let (r2, dc) = jpg_dc(r, dc_ht, dc_pred)
  let r3 = jpg_ac(r2, ac_ht, block)
  block[0] = dc
  for i = 0; i < 64; i = i + 1 { block[i] = block[i] * qt[i] }
  (r3, dc, idct_2d(block))
}

/// Decode JPEG image
pub fn decode_jpeg(data : Bytes) -> Image raise Failure {
  if data.length() < 2 || data[0].to_int() != 0xFF || data[1].to_int() != 0xD8 {
    raise Failure::Failure("JPEG: missing SOI marker")
  }

  let mut pos = 2
  let mut w = 0; let mut h = 0; let mut nc = 1
  let mut qt_y = Array::make(64, 1)  // default quant table
  let empty_ht = JHT::{ minc:Array::make(17, -1), maxc:Array::make(17, -1), vptr:Array::make(17, -1), hv:Array::make(0, 0) }
  let dc_ht = Array::make(4, empty_ht); let ac_ht = Array::make(4, empty_ht)

  // Parse markers
  while pos < data.length() {
    if data[pos].to_int() != 0xFF { raise Failure::Failure("JPEG: expected marker at \{pos}") }
    pos = pos + 1
    let mb = data[pos].to_int(); pos = pos + 1
    if mb == 0x00 { continue }
    if mb == 0xD8 { continue }
    if mb >= 0xD0 && mb <= 0xD7 { continue }
    if mb == 0xD9 { break }

    let len = (data[pos].to_int() << 8) | data[pos + 1].to_int()
    pos = pos + 2
    let end = pos + len - 2

    if mb == 0xDB {
      // DQT
      while pos < end {
        let info = data[pos].to_int(); pos = pos + 1
        let tid = info & 0x0F; let prec = (info >> 4) & 0x0F
        let tbl = Array::make(64, 0)
        for i = 0; i < 64; i = i + 1 {
          let k = zz(i)
          if prec == 0 {
            tbl[k] = data[pos].to_int(); pos = pos + 1
          } else {
            tbl[k] = (data[pos].to_int() << 8) | data[pos + 1].to_int(); pos = pos + 2
          }
        }
        if tid == 0 { qt_y = tbl }
      }
    } else if mb == 0xC0 {
      // SOF0 — frame header
      let _precision = data[pos].to_int(); pos = pos + 1
      let hi_h = data[pos].to_int(); let lo_h = data[pos + 1].to_int()
      let hi_w = data[pos + 2].to_int(); let lo_w = data[pos + 3].to_int()
      h = hi_h * 256 + lo_h; w = hi_w * 256 + lo_w
      pos = pos + 4
      nc = data[pos].to_int(); pos = pos + 1
      // Skip component specs
      for i = 0; i < nc; i = i + 1 { pos = pos + 3 }
    } else if mb == 0xC4 {
      // DHT
      while pos < end {
        let info = data[pos].to_int(); pos = pos + 1
        let tc = (info >> 4) & 1; let th = info & 0xF
        let bits = Array::make(16, 0)
        let mut total = 0
        for i = 0; i < 16; i = i + 1 { bits[i] = data[pos].to_int(); pos = pos + 1; total = total + bits[i] }
        let hv = Array::make(total, 0)
        for i = 0; i < total; i = i + 1 { hv[i] = data[pos].to_int(); pos = pos + 1 }
        let ht = build_jht(bits, hv)
        if tc == 0 { dc_ht[th] = ht } else { ac_ht[th] = ht }
      }
    } else if mb == 0xDA {
      // SOS — decode image
      let ns = data[pos].to_int(); pos = pos + 1
      // Skip component selectors
      for i = 0; i < ns; i = i + 1 { pos = pos + 2 }
      pos = pos + 3  // skip Ss, Se, Ah/Al

      // Collect entropy-coded bytes (until next marker)
      let ec_buf = Buffer()
      while pos < data.length() - 1 {
        let b0 = data[pos].to_int()
        if b0 == 0xFF {
          let b1 = data[pos + 1].to_int()
          if b1 != 0x00 && (b1 < 0xD0 || b1 > 0xD7) { break }
          if b1 == 0x00 { ec_buf.write_byte(b'\xFF'); pos = pos + 2; continue }
          pos = pos + 2; continue  // RST: skip
        }
        ec_buf.write_byte(data[pos]); pos = pos + 1
      }

      let ec = ec_buf.to_bytes()
      let mut reader = JBR::new(ec)
      let out = Array::make(w * h, b'\x00')
      let mpr = (w + 7) / 8; let mpc = (h + 7) / 8
      let mut dc_pred = 0

      for my = 0; my < mpc; my = my + 1 {
        for mx = 0; mx < mpr; mx = mx + 1 {
          let (r2, ndc, pixels) = jpg_block(reader, dc_ht[0], ac_ht[0], qt_y, dc_pred)
          reader = r2
          dc_pred = ndc
          for py = 0; py < 8; py = py + 1 {
            let oy = my * 8 + py
            if oy >= h { continue }
            for px = 0; px < 8; px = px + 1 {
              let ox = mx * 8 + px
              if ox >= w { continue }
              out[oy * w + ox] = pixels[py * 8 + px].to_byte()
            }
          }
        }
      }
      return Image::new(w, h, PixelFormat::Gray8, Bytes::from_array(out))
    } else {
      // Skip unknown segment
      pos = end
    }
  }

  raise Failure::Failure("JPEG: no SOS marker found")
}
