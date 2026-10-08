// Port of KoalaSand's GranularSimulator + DeterministicHash, pinned in vendor/.
// Fixed, finite grid. Colors are grain identities; geometry is a separate plane.
export function hash2d(seed, x, y, salt = 0) {
  let v = (seed ^ salt ^ 0x45d9f3b) & 0x7fffffff;
  v = Math.imul(v ^ x, 0x119de1f3) & 0x7fffffff;
  v = Math.imul(v ^ y, 0x1b873593) & 0x7fffffff;
  v = (v ^ (v >>> 16)) & 0x7fffffff;
  v = Math.imul(v, 0x45d9f3b) & 0x7fffffff;
  return (v ^ (v >>> 16)) & 0x7fffffff;
}

export class SandWorld {
  constructor(width = 768, height = 432, seed = 2718) {
    if (!Number.isInteger(width) || !Number.isInteger(height) || width < 4 || height < 4 || width * height > 1048576) throw new RangeError('Invalid grid size');
    this.width = width; this.height = height; this.seed = seed | 0; this.tick = 0;
    this.cells = new Uint8Array(width * height);
    this.solid = new Uint8Array(width * height);
    this.moved = new Uint32Array(width * height);
    this.chunkSize = 32;
    this.cols = Math.ceil(width / 32); this.rows = Math.ceil(height / 32);
    this.active = new Uint8Array(this.cols * this.rows).fill(1);
    this.stable = new Uint8Array(this.active.length);
    this.snapshot = new Uint8Array(this.active.length);
    this.changed = new Uint8Array(this.active.length);
    this.count = 0; this.visited = 0;
    this.lastSolidContacts = 0; this.solidContacts = 0;
  }
  index(x, y) { return y * this.width + x; }
  inside(x, y) { return x >= 0 && y >= 0 && x < this.width && y < this.height; }
  empty(x, y) { return this.inside(x, y) && !this.cells[this.index(x, y)] && !this.solid[this.index(x, y)]; }
  wake(x, y) {
    // A removed support may release any of the three source cells above it.
    for (let cy = Math.max(0, (y - 1) >> 5); cy <= Math.min(this.rows - 1, y >> 5); cy++) {
      for (let cx = Math.max(0, (x - 1) >> 5); cx <= Math.min(this.cols - 1, (x + 1) >> 5); cx++) {
        const c = cy * this.cols + cx;
        this.active[c] = 1; this.stable[c] = 0; this.changed[c] = 1;
      }
    }
  }
  add(x, y, color, stamp = false) {
    if (!Number.isInteger(x) || !Number.isInteger(y) || !Number.isInteger(color) || color < 1 || color > 24 || !this.empty(x, y)) return false;
    const i = this.index(x, y); this.cells[i] = color;
    if (stamp) this.moved[i] = this.tick + 1;
    this.count++; this.wake(x, y); return true;
  }
  remove(x, y) {
    if (!this.inside(x, y)) return 0;
    const i = this.index(x, y), color = this.cells[i];
    if (color) { this.cells[i] = 0; this.count--; this.wake(x, y); }
    return color;
  }
  wall(x, y, value = 1) {
    if (!this.inside(x, y) || (value && this.cells[this.index(x, y)])) return false;
    this.solid[this.index(x, y)] = value; this.wake(x, y); return true;
  }
  move(x, y, dx, dy) {
    const from = this.index(x, y);
    if (!this.inside(x, y) || !this.cells[from] || this.moved[from] === this.tick + 1) return false;
    if (!this.inside(dx, dy) || this.cells[this.index(dx, dy)] || this.solid[this.index(dx, dy)]) {
      if (this.inside(dx, dy) && this.solid[this.index(dx, dy)]) {
        this.lastSolidContacts++; this.solidContacts++;
      }
      return false;
    }
    const to = this.index(dx, dy);
    this.cells[to] = this.cells[from]; this.cells[from] = 0;
    this.moved[to] = this.tick + 1;
    this.wake(x, y); this.wake(dx, dy); return true;
  }
  gravity() {
    this.snapshot.set(this.active); this.changed.fill(0); this.visited = 0;
    this.lastSolidContacts = 0;
    const forward = (this.tick & 1) === 0, w = this.width;
    // Global rows, bottom to top: no second fall across a chunk boundary.
    for (let y = this.height - 2; y >= 0; y--) {
      const cy = (y >> 5) * this.cols;
      for (let c = 0; c < this.cols; c++) {
        const cx = forward ? c : this.cols - 1 - c;
        if (!this.snapshot[cy + cx]) continue;
        const lo = cx * 32, hi = Math.min(w, lo + 32);
        for (let k = 0; k < hi - lo; k++) {
          const x = forward ? lo + k : hi - 1 - k, i = y * w + x;
          this.visited++;
          if (!this.cells[i] || this.moved[i] === this.tick + 1) continue;
          if (this.move(x, y, x, y + 1)) continue;
          const d = (hash2d(this.seed, x, y, this.tick) & 1) === 0 ? -1 : 1;
          if (!this.move(x, y, x + d, y + 1)) this.move(x, y, x - d, y + 1);
        }
      }
    }
    for (let c = 0; c < this.active.length; c++) {
      if (this.snapshot[c] && !this.changed[c] && ++this.stable[c] >= 8) this.active[c] = 0;
    }
  }
  finishTick() {
    this.tick++;
    if (this.tick === 0xfffffffe) { this.tick = 0; this.moved.fill(0); }
  }
  step() { this.gravity(); this.finishTick(); }
  stateHash() {
    let h = 2166136261;
    for (let i = 0; i < this.cells.length; i++) h = Math.imul(h ^ this.cells[i] ^ (this.solid[i] << 8), 16777619);
    return (h >>> 0).toString(16).padStart(8, '0');
  }
}
