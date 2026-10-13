// Independent reference assertions shared by both photographic test suites.

///|
fn photo_reference_compare(
  actual : Bytes,
  expected : Bytes,
  tolerance : Int,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i = 0; i < expected.length(); i = i + 1 {
    let difference = actual[i].to_int() - expected[i].to_int()
    if difference < -tolerance || difference > tolerance {
      fail(
        "Reference pixel mismatch at byte \{i}: actual \{actual[i]}, expected \{expected[i]}",
      )
    }
  }
}
