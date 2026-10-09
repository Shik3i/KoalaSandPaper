#[compute]
#version 450
#extension GL_KHR_shader_subgroup_arithmetic : require
// Rigid-piece breakage, one workgroup per piece, run every few steps after
// dem_step (bodies themselves are integrated inline in dem_step). A body whose
// crush counter (body_now) reached CRUSH_STEPS breaks: a whole piece
// (generation 0) into up to SPLIT rigid chunks (nearest-seed partition of its
// grains), a chunk (generation 1, or a piece too small to split) crumbles into
// free sand grains. Chunks start at the parent's pose and point velocities, so
// nothing jumps. Pieces without a live body are released.
#include "common.glsli"
#define RWG 64u
#define SPLIT 5u
#define MIN_CHUNK 12.0
layout(local_size_x = RWG) in;

shared vec4 s_part[RWG];
shared uint s_mode;
shared uint s_nsub;
shared uint s_k;
shared vec2 s_seed[SPLIT];
shared uint s_newb[SPLIT];
shared uint s_lead[SPLIT];

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

void free_grain(uint i, Body B) {
	vec2 r = rot(B.c.z) * (REST[i] - B.ex.xy);
	vec2 p = B.c.xy + r;
	vec2 v = B.v.xy + B.v.z * vec2(-r.y, r.x);
	XV[i] = vec4(p, v);
	// Crumbled pieces become ordinary sand (material 0).
	INFO[i] = (INFO[i] & ~0xffffu) | (KIND_GRAIN << 8u);
}

void body_both(uint b, Body B) {
	body_store(0u, b, B);
	body_store(1u, b, B);
	for (uint s = 0u; s < 3u; s++) {
		uint a = acc_at(s, b);
		for (uint q = 0u; q < ACC_STRIDE; q++) ACC[a + q] = 0.0;
	}
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
		if (B.c.w < 0.5 || B.ex.z < CRUSH_STEPS) continue;  // uniform across the workgroup
		if (tid == 0u) {
			uint room = NSUB - s_nsub + 1u;
			s_mode = (B.aux.x < 0.5 && B.ex.w >= 2.0 * MIN_CHUNK && room >= 2u) ? 1u : 2u;
			atomicAdd(STATS[ST_BROKEN], 1u);
			STATS[ST_CRUSH_POS] = floatBitsToUint(B.c.x);
			STATS[ST_CRUSH_POS + 1] = floatBitsToUint(B.c.y);
		}
		barrier();
		if (s_mode == 2u) {
			for (uint g = tid; g < pd.y; g += RWG) {
				uint i = PLIST[pd.x + g];
				if (kind_of(INFO[i]) == KIND_RIGID && BODY_OF[i] == b) free_grain(i, B);
			}
			barrier();
			if (tid == 0u) {
				Body D = B;
				D.c.w = 0.0;
				body_both(b, D);
			}
			barrier();
			continue;
		}
		// Split: seeds = rest positions of pseudo-random grains of this body.
		if (tid == 0u) {
			uint kk = min(SPLIT, NSUB - s_nsub + 1u);
			s_k = kk;
			uint h = hash(piece * 7919u + pc.stamp * 104729u + k);
			for (uint s = 0u; s < kk; s++) {
				s_seed[s] = REST[PLIST[pd.x + hash(h + s * 2654435761u) % pd.y]];
				s_newb[s] = s == 0u ? b : piece * NSUB + s_nsub + s - 1u;
				s_lead[s] = 0xffffffffu;
			}
			s_nsub += kk - 1u;
			PIECES[piece].z = s_nsub;
		}
		barrier();
		uint kk = s_k;
		for (uint g = tid; g < pd.y; g += RWG) {
			uint i = PLIST[pd.x + g];
			if (kind_of(INFO[i]) != KIND_RIGID || BODY_OF[i] != b) continue;
			vec2 q = REST[i];
			uint best = 0u;
			float bd = 1e30;
			for (uint s = 0u; s < kk; s++) {
				vec2 e = q - s_seed[s];
				float d2 = dot(e, e);
				if (d2 < bd) { bd = d2; best = s; }
			}
			BODY_OF[i] = s_newb[best];
			atomicMin(s_lead[best], i);
		}
		memoryBarrierBuffer();
		barrier();
		for (uint s = 0u; s < kk; s++) {
			uint nb = s_newb[s];
			// Mass, first and second moments of the chunk in the rest frame; count.
			vec4 m4 = vec4(0.0);
			float cnt = 0.0;
			for (uint g = tid; g < pd.y; g += RWG) {
				uint i = PLIST[pd.x + g];
				uint info = INFO[i];
				if (kind_of(info) != KIND_RIGID || BODY_OF[i] != nb) continue;
				float mi = mass_of(info, rad_of(info));
				vec2 q = REST[i];
				m4 += vec4(mi, mi * q, mi * dot(q, q));
				cnt += 1.0;
			}
			vec4 tot = reduce_sum(m4);
			float count = reduce_sum(vec4(cnt, 0.0, 0.0, 0.0)).x;
			bool keep = count >= MIN_CHUNK;
			if (tid == 0u) {
				float M = max(tot.x, 1e-12);
				vec2 cs0 = tot.yz / M;
				vec2 r = rot(B.c.z) * (cs0 - B.ex.xy);
				Body C;
				C.c = vec4(B.c.xy + r, B.c.z, keep ? 1.0 : 0.0);
				C.v = vec4(B.v.xy + B.v.z * vec2(-r.y, r.x), B.v.z, M);
				C.aux = vec4(1.0, float(s_lead[s]), 0.0, max(tot.w - M * dot(cs0, cs0), 1e-12));
				C.ex = vec4(cs0, 0.0, count);
				body_both(nb, C);
			}
			if (!keep) {
				for (uint g = tid; g < pd.y; g += RWG) {
					uint i = PLIST[pd.x + g];
					if (kind_of(INFO[i]) == KIND_RIGID && BODY_OF[i] == nb) free_grain(i, B);
				}
			}
			memoryBarrierBuffer();
			barrier();
		}
	}
	// A piece with no live body left (crumbled to sand) is released.
	barrier();
	if (tid == 0u) {
		bool any_alive = false;
		for (uint k = 0u; k < s_nsub; k++) any_alive = any_alive || RB[rb_at(cur, piece * NSUB + k, 0u)].w > 0.5;
		if (!any_alive) PIECES[piece] = uvec4(0u);
	}
}
