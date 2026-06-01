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
