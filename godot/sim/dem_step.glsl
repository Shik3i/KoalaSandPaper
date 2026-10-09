#[compute]
#version 450
#extension GL_EXT_control_flow_attributes : require
#extension GL_EXT_shader_atomic_float : require
#extension GL_KHR_shader_subgroup_arithmetic : require
#extension GL_KHR_shader_subgroup_ballot : require
#extension GL_KHR_shader_subgroup_vote : require
// One DEM step for every grain (fused: contact forces, integration, zones, grid
// insert, render). Grains of rigid pieces take their position from their body
// (body_now in common.glsli: integrated from last step's accumulated forces) and
// add their contact force and torque to this step's accumulator with atomics.
//
// Contacts: linear spring-dashpot normal force (no attraction) and a tangential
// spring with memory, capped by Coulomb friction (Cundall & Strack 1979; Luding
// 2008). Dashpots are applied implicitly in the particle's own velocity: explicit
// dashpots become unstable when a grain has many stiff contacts at once.
#include "common.glsli"
#include "colliders.glsli"
layout(local_size_x = WG) in;

uint h_base = 0u;
uint n_new = 0u;

// Spring vector and sliding flag of contact `key` from the last step.
vec2 hist_get(uint key, out bool sliding) {
	sliding = false;
	for (uint k = 0u; k < HIST_K; k++) {
		uint h = HKEY_IN[h_base + k];
		if ((h & 0x7fffffffu) == key) {
			sliding = (h & 0x80000000u) != 0u;
			return HXI_IN[h_base + k];
		}
		if (h == 0u) break;
	}
	return vec2(0.0);
}

void hist_put(uint key, vec2 xi, bool sliding) {
	if (n_new < HIST_K) {
		HKEY_OUT[h_base + n_new] = key | (sliding ? 0x80000000u : 0u);
		HXI_OUT[h_base + n_new] = xi;
		n_new++;
	}
}

// Implicit dashpots: D = sum c P (2x2 symmetric xx, xy, yy), B = sum c P v_other,
// P = n n^T (normal) or I - n n^T (tangential).
vec3 dmp_d = vec3(0.0);
vec2 dmp_b = vec2(0.0);

void add_damper(float c, vec2 n, bool normal, vec2 v_other) {
	vec3 p = normal ? vec3(n.x * n.x, n.x * n.y, n.y * n.y) : vec3(1.0 - n.x * n.x, -n.x * n.y, 1.0 - n.y * n.y);
	dmp_d += c * p;
	dmp_b += c * vec2(p.x * v_other.x + p.y * v_other.y, p.y * v_other.x + p.z * v_other.y);
}

// Elastic + friction force on particle i from one contact (dampers go to D, B).
// n: unit normal towards i, pen: overlap, vrel: velocity of i relative to the
// other side at the contact, meff: effective mass for damping, zeta: damping ratio.
vec2 contact_force(uint key, vec2 n, float pen, vec2 vrel, vec2 v_other, float meff, float zeta, float mu_s, float mu_k) {
	float vn = dot(vrel, n);
	float gn = 2.0 * zeta * sqrt(pc.kn * meff);
	float fn = pc.kn * pen - gn * vn;
	// gt = 2 zeta sqrt(kt meff) = gn sqrt(kt / kn) = gn sqrt(2 / 7).
	if (fn <= 0.0) return vec2(0.0);  // separating fast: no tension, spring released
	add_damper(gn, n, true, v_other);
	vec2 vt = vrel - vn * n;
	// Spring from the last step, projected into the current tangent plane (the
	// contact turns by well under a degree per step).
	bool sliding;
	vec2 xi = hist_get(key, sliding);
	xi -= dot(xi, n) * n;
	xi += vt * pc.dt;
	// Coulomb on the elastic shear force (Cundall & Strack) with static/kinetic
	// hysteresis: a sticking contact starts to slide above mu_s fn and keeps
	// sliding at mu_k fn until the shear relaxes below that (then it sticks again).
	float fe = pc.kt * length(xi);
	sliding = sliding ? fe >= mu_k * fn : fe > mu_s * fn;
	if (sliding) {
		xi *= mu_k * fn / fe;
		hist_put(key, xi, true);
		return pc.kn * pen * n - pc.kt * xi;
	}
	hist_put(key, xi, false);
	add_damper(gn * 0.53452248, n, false, v_other);
	return pc.kn * pen * n - pc.kt * xi;
}

void main() {
	uint t = gl_GlobalInvocationID.x;
	if (t >= pc.n || pc.guard < -1e30) return;
	uvec2 bdim = uvec2((pc.grid_w + 7u) / 8u, (pc.grid_h + 7u) / 8u);
	if (t >= BLOCK_CURSOR[bdim.x * bdim.y]) return;  // live grains this frame
	uint i = ORDER[t];
	uint info = INFO[i];
	uint kind = kind_of(info);
	bool last = (pc.flags & FLAG_LAST) != 0u;
	ivec2 texel = ivec2(int(i % TEX_W), int(i / TEX_W));
	if (kind == KIND_NONE) {
		// Died earlier this frame (its texel was cleared then).
		HKEY_OUT[t * HIST_K] = 0u;
		return;
	}
	vec4 xvi = XV[i];
	vec2 xi = xvi.xy;
	vec2 vi = xvi.zw;
	uint body = 0u;
	vec2 arm = vec2(0.0);
	if (kind == KIND_RIGID) {
		body = BODY_OF[i];
		Body B = body_now(body);
		if (uint(B.aux.y) == i) {
			body_store(pc.stamp & 1u, body, B);
			uint z = acc_at((pc.stamp + 1u) % 3u, body);
			for (uint q = 0u; q < ACC_STRIDE; q++) ACC[z + q] = 0.0;
		}
		arm = rot(B.c.z) * (REST[i] - B.ex.xy);
		xi = B.c.xy + arm;
		vi = B.v.xy + B.v.z * vec2(-arm.y, arm.x);
	}
	float ri = rad_of(info);
	uint mat = mat_of(info);
	vec4 mi = MAT[2u * mat];
	float m_i = mass_of(info, ri);
	bool rigid = kind == KIND_RIGID;
	float md_i = rigid ? m_i * pc.rigid_damp_mass : m_i;

	h_base = t * HIST_K;

	vec2 f = vec2(0.0);
	float max_pen = 0.0;
	uint n_contacts = 0u;
	uint last_prim = 0xffffu;
	if (kind != KIND_SPARK) {
		// All 9 bin counts are loaded up front (independent loads in flight together),
		// then one flat loop over the 9 x CELL_CAP slots: a fixed trip count keeps the
		// SIMD lanes in step instead of diverging on per-cell loop lengths.
		ivec2 cc = ivec2(cell_coord(xi));
		uint rg = grid_read();
		uint rstamp = pc.stamp - 1u;
		uint gbase = rg * cells_total();
		uint cnt[9];
		uint cbase[9];
		[[unroll]] for (int k = 0; k < 9; k++) {
			ivec2 c = cc + ivec2(k % 3 - 1, k / 3 - 1);
			bool ok = c.x >= 0 && c.y >= 0 && c.x < int(pc.grid_w) && c.y < int(pc.grid_h);
			uint cell = ok ? uint(c.y) * pc.grid_w + uint(c.x) : 0u;
			uint w = BIN_COUNT[gbase + cell];
			cnt[k] = ok && (w >> 8u) == rstamp ? min(w & 0xffu, CELL_CAP) : 0u;
			cbase[k] = (gbase + cell) * CELL_CAP;
		}
		[[unroll]] for (int k = 0; k < 9; k++) {
			for (uint s = 0u; s < cnt[k]; s++) {
				uvec4 e = BINS[cbase[k] + s];
				uint j = e.w & ID_MASK;
				if (j == i) continue;
				vec2 dv = xi - uintBitsToFloat(e.xy);
				float rj = rad_code(e.w);
				float d0 = ri + rj;
				float d2 = dot(dv, dv);
				if (d2 >= d0 * d0) continue;
				uint kj = (e.w >> 25u) & 7u;
				if (kj == KIND_SPARK) continue;
				if (kind == KIND_RIGID && kj == KIND_RIGID && BODY_OF[i] == BODY_OF[j]) continue;
				float dist = sqrt(d2);
				vec2 n = dist > 1e-9 * pc.r ? dv / dist : vec2(0.0, i < j ? 1.0 : -1.0);
				float pen = d0 - dist;
				uint matj = e.w >> 28u;
				float m_j = mass_ref(matj, rj);
				float md_j = kj == KIND_RIGID ? m_j * pc.rigid_damp_mass : m_j;
				vec4 mj = MAT[2u * matj];
				vec2 vj = unpackHalf2x16(e.z);
				f += contact_force(j + 1u, n, pen, vi - vj, vj, md_i * md_j / (md_i + md_j),
						0.5 * (mi.z + mj.z), 0.5 * (mi.x + mj.x), 0.5 * (mi.y + mj.y));
				max_pen = max(max_pen, pen / min(ri, rj));
				n_contacts++;
			}
		}

		// Machine surfaces (kinematic, infinite mass) and the four world walls, in one
		// loop with a single contact_force call site (each inlined copy costs registers).
		uint pcell = pgrid_cell(xi);
		uint pcnt = PGRID[pcell];
		vec2 hi = pc.world - ri;
		for (uint gi = 1u; gi <= pcnt + 4u; gi++) {
			vec2 n, vs;
			float pen;
			uint key;
			vec2 mu = mi.xy;
			if (gi <= pcnt) {
				uint pid = PGRID[pcell + gi];
				// Out of reach, sink/heat zone or visual-only: skip without loading the prim.
				if (!in_bound(pid, xi, ri) || (prim_flags(pid) & 14u) != 0u) continue;
				Prim pr = PRIMS[pid];
				if (!prim_contact(pr, xi, pc.t_sub, ri, n, pen, vs)) continue;
				key = KEY_PRIM | pid;
				mu = 0.5 * (mi.xy + pr.surf.xy);
				last_prim = pid;
			} else {
				uint w = gi - pcnt - 1u;
				pen = w == 0u ? ri - xi.y : w == 1u ? xi.y - hi.y : w == 2u ? ri - xi.x : xi.x - hi.x;
				if (pen <= 0.0) continue;
				n = w == 0u ? vec2(0.0, 1.0) : w == 1u ? vec2(0.0, -1.0) : w == 2u ? vec2(1.0, 0.0) : vec2(-1.0, 0.0);
				vs = vec2(0.0);
				key = KEY_PRIM | (0xfff0u + w);
			}
			f += contact_force(key, n, pen, vi - vs, vs, md_i, mi.z, mu.x, mu.y);
			max_pen = max(max_pen, pen / ri);
			n_contacts++;
		}
	}

	if (n_new < HIST_K) HKEY_OUT[h_base + n_new] = 0u;
	if (last) {
		// One atomic per SIMD group instead of one per grain.
		float mp = subgroupMax(max_pen);
		float ms = subgroupMax(length(vi));
		if (subgroupElect()) {
			atomic_max_f(ST_MAX_PEN, mp);
			atomic_max_f(ST_MAX_SPEED, ms);
		}
	}

	if (rigid) {
		// Bodies integrate explicitly (their mass is large compared with the dampers).
		vec2 ft = f - vec2(dmp_d.x * vi.x + dmp_d.y * vi.y, dmp_d.y * vi.x + dmp_d.z * vi.y) + dmp_b;
		// Accumulate into the body: first summed over the lanes of this SIMD group
		// that share the body (grains are visited in spatial order, so usually all
		// of them), then one atomic per sum. Hundreds of grains adding to the same
		// 12 addresses directly would serialise on the atomics.
		vec4 pr = vec4(ft.x, ft.y, dot(ft, vec2(0.70710678, 0.70710678)), dot(ft, vec2(-0.70710678, 0.70710678)));
		vec4 sa = vec4(ft, arm.x * ft.y - arm.y * ft.x, 0.0);
		vec4 hp = max(pr, vec4(0.0));
		vec4 hn = max(-pr, vec4(0.0));
		if (subgroupAny(ft.x != 0.0 || ft.y != 0.0)) {
			for (;;) {
				uint lb = subgroupBroadcastFirst(body);
				if (body == lb) {
					vec4 s1 = subgroupAdd(sa);
					vec4 s2 = subgroupAdd(hp);
					vec4 s3 = subgroupAdd(hn);
					if (subgroupElect() && (s1.x != 0.0 || s1.y != 0.0 || s2 != vec4(0.0) || s3 != vec4(0.0))) {
						uint a = acc_at(pc.stamp % 3u, body);
						atomicAdd(ACC[a], s1.x);
						atomicAdd(ACC[a + 1u], s1.y);
						atomicAdd(ACC[a + 2u], s1.z);
						for (uint d = 0u; d < 4u; d++) {
							if (s2[d] > 0.0) atomicAdd(ACC[a + 3u + 2u * d], s2[d]);
							if (s3[d] > 0.0) atomicAdd(ACC[a + 4u + 2u * d], s3[d]);
						}
					}
					break;
				}
			}
		}
		XV[i] = vec4(xi, vi);
		bin_insert(i, info, xi, vi);
		if (last) imageStore(RENDER_IMG, texel, vec4(xi, float(COLOR[i] & 0xffffffu), float(render_w(kind, info, heat_of(info), 0u))));
		return;
	}

	// (m I + dt D) v' = m v + dt (f + m g + B)
	vec2 rhs = m_i * vi + pc.dt * (f + m_i * pc.gravity + dmp_b);
	vec3 a = vec3(m_i, 0.0, m_i) + pc.dt * dmp_d;
	float det = a.x * a.z - a.y * a.y;
	vec2 v = vec2(a.z * rhs.x - a.y * rhs.y, a.x * rhs.y - a.y * rhs.x) / det * pc.damp;
	float sp = length(v);
	if (sp > pc.v_max) {
		v *= pc.v_max / sp;
		atomicAdd(STATS[ST_CLAMP], 1u);
		STATS[ST_CLAMP_POS] = floatBitsToUint(xi.x);
		STATS[ST_CLAMP_POS + 1] = floatBitsToUint(xi.y);
		STATS[ST_CLAMP_PRIM] = last_prim;
	}
	vec2 p = xi + v * pc.dt;
	if (any(isnan(p)) || any(isinf(p)) || any(isnan(v)) || any(isinf(v))) {
		atomicAdd(STATS[ST_NAN], 1u);
		p = xi;
		v = vec2(0.0);
	}
	if (p.x < 0.0 || p.y < 0.0 || p.x > pc.world.x || p.y > pc.world.y) {
		atomicAdd(STATS[ST_OOB], 1u);
		STATS[ST_OOB_POS] = floatBitsToUint(p.x);
		STATS[ST_OOB_POS + 1] = floatBitsToUint(p.y);
		p = clamp(p, vec2(pc.r), pc.world - pc.r);
	}

	// Zones (checked every heat_every steps): sinks remove; heat zones heat grains
	// until they burn. Outside, grains cool.
	uint heat = heat_of(info);
	uint sc = step_counter();
	if (sc % pc.heat_every == 0u) {
		bool heating = false;
		uint pcell = pgrid_cell(p);
		uint pcnt = PGRID[pcell];
		for (uint gi = 1u; gi <= pcnt; gi++) {
			uint pid = PGRID[pcell + gi];
			if (!in_bound(pid, p, 0.0) || (prim_flags(pid) & 10u) == 0u) continue;
			Prim pr = PRIMS[pid];
			vec2 bpos, bvel;
			float bang, bom;
			body_pose(pr.head.y, pc.t_sub, bpos, bang, bvel, bom);
			if (prim_sdf(pr, rot(-bang) * (p - bpos)) >= 0.0) continue;
			if ((pr.head.w & 8u) != 0u && heat < 250u) {
				heating = true;
				continue;
			}
			INFO[i] = 0u;
			atomicAdd(STATS[8u + min(pr.head.w >> 8u, 3u)], 1u);
			atomicAdd(STATS[ST_SUNK], 1u);
			imageStore(RENDER_IMG, texel, vec4(0.0));
			return;
		}
		if (heating) {
			heat += 1u;
		} else if (heat > 0u && sc % (3u * pc.heat_every) == 0u) {
			heat -= 1u;
		}
		info = with_heat(info, heat);
		INFO[i] = info;
	}
	XV[i] = vec4(p, v);
	if (kind != KIND_SPARK) bin_insert(i, info, p, v);
	if (last) imageStore(RENDER_IMG, texel, vec4(p, float(COLOR[i] & 0xffffffu), float(render_w(kind, info, heat, n_contacts))));
}
