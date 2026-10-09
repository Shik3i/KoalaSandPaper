#[compute]
#version 450
#extension GL_KHR_shader_subgroup_arithmetic : require
// Rigid-piece breakage, one workgroup per piece, every few steps after dem_step
// (bodies are integrated inline in dem_step, which also chips single grains off
// where a machine edge bites). Per live body:
// 1. Bookkeeping: grains that chipped off leave the body: mass, centre of mass,
//    inertia and leader grain are recomputed (pose and velocity kept continuous);
//    a body left with fewer than MIN_CHUNK grains crumbles to sand.
// 2. Local fracture once its crush counter (body_now) is full: only the loaded
//    region fails. Around the most loaded grain (the press edge or tooth tip)
//    the material is crushed to dust (CRUSH_R); within ZONE_R a shear crack
//    (20-35° off the load direction, through the contact) breaks one or two
//    wedges off; the rest of the body stays whole. A body too small to keep a
//    remainder splits into the two wedges; below 3 MIN_CHUNK it crumbles.
//    Pieces are created at the parent's pose and point velocities, with a
//    fracture time that protects them from breaking again at once (COOLDOWN).
#include "common.glsli"
#define RWG 64u
#define MIN_CHUNK 12.0
#define CRUSH_R 1.6
#define SEPARATE 0.05
layout(local_size_x = RWG) in;

shared vec4 s_part[RWG];
shared uint s_lead[4];
shared uint s_cnt[4];
shared uint s_slot[4];
shared uint s_nsub;
shared uint s_mode;
shared uint s_maxbits;
shared uint s_arg;
shared vec2 s_p0;
shared vec2 s_dc;
shared float s_zone;

// Workgroup sum via SIMD-group reductions.
vec4 reduce_sum(vec4 a) {
	vec4 r = subgroupAdd(a);
	if (subgroupElect()) s_part[gl_SubgroupID] = r;
	barrier();
	vec4 t = vec4(0.0);
	for (uint g = 0u; g < gl_NumSubgroups; g++) t += s_part[g];
	barrier();
	return t;
}

uint hash(uint x) {
	x ^= x >> 16u; x *= 0x7feb352du; x ^= x >> 15u; x *= 0x846ca68bu; x ^= x >> 16u;
	return x;
}

float rnd(uint h) { return float(hash(h) & 0xffffu) / 65535.0; }

void free_grain(uint i, Body B) {
	vec2 r = rot(B.c.z) * (REST[i] - B.ex.xy);
	XV[i] = vec4(B.c.xy + r, B.v.xy + B.v.z * vec2(-r.y, r.x));
	// Crumbled pieces become ordinary sand (material 0).
	INFO[i] = (INFO[i] & ~0xffffu) | (KIND_GRAIN << 8u);
}

void zero_acc(uint b) {
	for (uint s = 0u; s < 3u; s++) {
		uint a = acc_at(s, b);
		for (uint q = 0u; q < ACC_STRIDE; q++) ACC[a + q] = 0.0;
	}
}

// Mass, first and second rest-frame moments and count of body b's grains; the
// lowest grain index goes to s_lead[slot].
vec4 moments(uvec4 pd, uint b, uint tid, uint slot, out float count) {
	if (tid == 0u) s_lead[slot] = 0xffffffffu;
	barrier();
	vec4 m4 = vec4(0.0);
	float cnt = 0.0;
	for (uint g = tid; g < pd.y; g += RWG) {
		uint i = PLIST[pd.x + g];
		uint info = INFO[i];
		if (kind_of(info) != KIND_RIGID || BODY_OF[i] != b) continue;
		float mi = mass_of(info, rad_of(info));
		vec2 q = REST[i];
		m4 += vec4(mi, mi * q, mi * dot(q, q));
		cnt += 1.0;
		atomicMin(s_lead[slot], i);
	}
	vec4 tot = reduce_sum(m4);
	count = reduce_sum(vec4(cnt, 0.0, 0.0, 0.0)).x;
	return tot;
}

// Body from moments, placed rigidly where the parent P has those grains.
Body make_body(Body P, vec4 tot, float count, float gen, uint lead, vec2 push) {
	float M = max(tot.x, 1e-12);
	vec2 cs0 = tot.yz / M;
	vec2 r = rot(P.c.z) * (cs0 - P.ex.xy);
	Body C;
	C.c = vec4(P.c.xy + r, P.c.z, 1.0);
	C.v = vec4(P.v.xy + P.v.z * vec2(-r.y, r.x) + push, P.v.z, M);
	C.aux = vec4(gen, float(lead), P.aux.z, max(tot.w - M * dot(cs0, cs0), 1e-12));
	C.ex = vec4(cs0, 0.0, count);
	return C;
}

void kill_body(uint b, Body B) {
	B.c.w = 0.0;
	body_store(0u, b, B);
	body_store(1u, b, B);
}

void main() {
	uint piece = gl_WorkGroupID.x;
	uint tid = gl_LocalInvocationID.x;
	if (piece >= pc.n_pieces || pc.guard < -1e30) return;
	uvec4 pd = PIECES[piece];
	if (pd.y == 0u) return;
	uint cur = pc.stamp & 1u;
	if (tid == 0u) s_nsub = pd.z;
	barrier();
	uint nsub0 = s_nsub;
	for (uint k = 0u; k < nsub0; k++) {
		uint b = piece * NSUB + k;
		Body B = body_load(cur, b);
		if (B.c.w < 0.5) continue;  // uniform across the workgroup

		// 1. Bookkeeping after chipping.
		float count;
		vec4 tot = moments(pd, b, tid, 0u, count);
		if (count < MIN_CHUNK) {
			for (uint g = tid; g < pd.y; g += RWG) {
				uint i = PLIST[pd.x + g];
				if (kind_of(INFO[i]) == KIND_RIGID && BODY_OF[i] == b) free_grain(i, B);
			}
			barrier();
			if (tid == 0u) kill_body(b, B);
			barrier();
			continue;
		}
		if (count != B.ex.w) {
			Body C = make_body(B, tot, count, B.aux.x, s_lead[0], vec2(0.0));
			C.ex.z = B.ex.z;
			barrier();
			if (tid == 0u) body_store(cur, b, C);
			B = C;
		}
		if (B.ex.z < CRUSH_STEPS) {
			barrier();
			continue;
		}

		// 2. Local fracture: find the contact (most loaded grain this step).
		if (tid == 0u) { s_maxbits = 0u; s_arg = 0xffffffffu; }
		barrier();
		for (uint g = tid; g < pd.y; g += RWG) {
			uint i = PLIST[pd.x + g];
			if (kind_of(INFO[i]) == KIND_RIGID && BODY_OF[i] == b) atomicMax(s_maxbits, floatBitsToUint(max(VN[i].y, 0.0)));
		}
		barrier();
		for (uint g = tid; g < pd.y; g += RWG) {
			uint i = PLIST[pd.x + g];
			if (kind_of(INFO[i]) == KIND_RIGID && BODY_OF[i] == b && floatBitsToUint(max(VN[i].y, 0.0)) == s_maxbits) atomicMin(s_arg, i);
		}
		barrier();
		if (tid == 0u) {
			atomicAdd(STATS[ST_BROKEN], 1u);
			STATS[ST_CRUSH_POS] = floatBitsToUint(B.c.x);
			STATS[ST_CRUSH_POS + 1] = floatBitsToUint(B.c.y);
			// Load direction: the one with the strongest two-sided push this step.
			uint a = acc_at(pc.stamp % 3u, b);
			vec2 dirs[4] = vec2[4](vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(0.70710678, 0.70710678), vec2(-0.70710678, 0.70710678));
			uint best = 1u;
			float bs = -1.0;
			for (uint d = 0u; d < 4u; d++) {
				float sq = min(ACC[a + 3u + 2u * d], ACC[a + 4u + 2u * d]);
				if (sq > bs) { bs = sq; best = d; }
			}
			vec2 dir = rot(-B.c.z) * dirs[best];  // into the rest frame
			uint h = hash(piece * 7919u + pc.stamp * 104729u + k);
			// Shear crack: 20-35° either side of the load axis, through the contact.
			float ang = (0.35 + 0.26 * rnd(h)) * (rnd(h + 3u) < 0.5 ? -1.0 : 1.0);
			s_dc = rot(ang) * dir;
			s_p0 = s_arg != 0xffffffffu ? REST[s_arg] : B.ex.xy;
			float ext = sqrt(B.aux.w / B.v.w);  // radius of gyration
			s_zone = clamp(1.1 * ext, 0.06, 0.13);
			s_mode = B.ex.w < 3.0 * MIN_CHUNK ? 0u : 1u;
			for (uint q = 0u; q < 4u; q++) s_cnt[q] = 0u;
		}
		barrier();
		uint mode = s_mode;
		// Regions: 0 stays with the body, 1/2 = the wedges either side of the crack,
		// crushed core and grains on the crack: dust.
		for (uint g = tid; g < pd.y; g += RWG) {
			uint i = PLIST[pd.x + g];
			if (kind_of(INFO[i]) != KIND_RIGID || BODY_OF[i] != b) continue;
			if (mode == 0u) {
				free_grain(i, B);
				continue;
			}
			vec2 e = REST[i] - s_p0;
			float dist = length(e);
			float side = e.x * s_dc.y - e.y * s_dc.x;
			uint reg = 0u;
			if (dist < CRUSH_R * pc.r || (dist < s_zone && abs(side) < 0.8 * pc.r)) {
				free_grain(i, B);
				continue;
			}
			if (dist < s_zone) reg = side > 0.0 ? 1u : 2u;
			atomicAdd(s_cnt[reg], 1u);
			VN[i] = vec2(float(reg), 0.0);  // region, read back below
		}
		memoryBarrierBuffer();
		barrier();
		if (mode == 0u) {
			if (tid == 0u) kill_body(b, B);
			barrier();
			continue;
		}
		// Slots: the remainder keeps b (or the bigger wedge when there is no
		// remainder); wedges take dead or new slots; too small: crumble (0xffff).
		if (tid == 0u) {
			uint keep = 0u;
			if (float(s_cnt[0]) < MIN_CHUNK) keep = s_cnt[1] >= s_cnt[2] ? 1u : 2u;
			uint next_dead = 0u;
			for (uint q = 0u; q < 3u; q++) {
				s_slot[q] = 0xffffu;
				if (float(s_cnt[q]) < MIN_CHUNK) continue;
				if (q == keep) { s_slot[q] = b; continue; }
				uint slot = 0xffffu;
				while (next_dead < s_nsub && slot == 0xffffu) {
					uint cand = piece * NSUB + next_dead;
					if (cand != b && RB[rb_at(cur, cand, 0u)].w < 0.5) slot = cand;
					next_dead++;
				}
				if (slot == 0xffffu && s_nsub < NSUB) slot = piece * NSUB + s_nsub++;
				s_slot[q] = slot;
			}
			s_slot[3] = 0xffffu;
			PIECES[piece].z = s_nsub;
		}
		barrier();
		for (uint g = tid; g < pd.y; g += RWG) {
			uint i = PLIST[pd.x + g];
			if (kind_of(INFO[i]) != KIND_RIGID || BODY_OF[i] != b) continue;
			uint slot = s_slot[uint(VN[i].x)];
			VN[i] = vec2(0.0);
			if (slot == 0xffffu) free_grain(i, B);
			else BODY_OF[i] = slot;
		}
		memoryBarrierBuffer();
		barrier();
		bool parent_kept = false;
		vec2 split_n = rot(B.c.z) * vec2(-s_dc.y, s_dc.x);
		for (uint q = 0u; q < 3u; q++) {
			uint nb = s_slot[q];
			if (nb == 0xffffu) continue;  // uniform
			parent_kept = parent_kept || nb == b;
			float cnt;
			vec4 t4 = moments(pd, nb, tid, 1u, cnt);
			if (tid == 0u) {
				// Wedges separate across the crack, away from the remainder.
				vec2 rel = rot(B.c.z) * (t4.yz / max(t4.x, 1e-12) - B.ex.xy);
				vec2 push = q == 0u ? vec2(0.0) : split_n * sign(dot(rel, split_n)) * SEPARATE;
				Body C = make_body(B, t4, cnt, B.aux.x + 1.0, s_lead[1], push);
				C.aux.z = float(pc.stamp);  // fracture time (cool-down in body_now)
				body_store(0u, nb, C);
				body_store(1u, nb, C);
				zero_acc(nb);
			}
			barrier();
		}
		// Nothing big enough left: the parent is gone.
		if (!parent_kept && tid == 0u) kill_body(b, B);
		barrier();
	}
	// A piece with no live body left (crumbled to sand) is released.
	barrier();
	if (tid == 0u) {
		bool any_alive = false;
		for (uint k = 0u; k < s_nsub; k++) any_alive = any_alive || RB[rb_at(cur, piece * NSUB + k, 0u)].w > 0.5;
		if (!any_alive) PIECES[piece] = uvec4(0u);
	}
}
