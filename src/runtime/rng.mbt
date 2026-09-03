///|
/// Deterministic PRNG (mulberry32) so simulations are reproducible by seed.
pub struct Rng {
  mut state : UInt
}

///|
pub fn Rng::new(seed : Int) -> Rng {
  { state: seed.reinterpret_as_uint() }
}

///|
pub fn Rng::next_uint(self : Rng) -> UInt {
  self.state = self.state + 0x6D2B79F5
  let mut t = self.state
  t = (t ^ (t >> 15)) * (t | 1)
  t = t ^ (t + (t ^ (t >> 7)) * (t | 61))
  t ^ (t >> 14)
}

///|
/// Uniform in `[0, 1)`.
pub fn Rng::next_double(self : Rng) -> Double {
  self.next_uint().to_uint64().to_double() / 4294967296.0
}

///|
pub fn Rng::int(self : Rng, max_exclusive : Int) -> Int {
  if max_exclusive <= 0 {
    abort("max_exclusive must be positive")
  }
  (self.next_uint() % max_exclusive.reinterpret_as_uint()).reinterpret_as_int()
}

///|
pub fn[T] Rng::pick(self : Rng, items : Array[T]) -> T {
  items[self.int(items.length())]
}

///|
pub fn Rng::chance(self : Rng, probability : Double) -> Bool {
  self.next_double() < probability
}

///|
pub fn[T] Rng::shuffle(self : Rng, items : Array[T]) -> Array[T] {
  let out = items.copy()
  let mut index = out.length() - 1
  while index > 0 {
    let other = self.int(index + 1)
    let tmp = out[index]
    out[index] = out[other]
    out[other] = tmp
    index -= 1
  }
  out
}

///|
/// A random subset preserving order.
pub fn[T] Rng::subset(self : Rng, items : Array[T]) -> Array[T] {
  items.filter(fn(_item) { self.chance(0.5) })
}
