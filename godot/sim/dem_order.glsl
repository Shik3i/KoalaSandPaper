#[compute]
#version 450
// Spatial processing order, rebuilt once per frame (counting sort of all live
// grains by 8 x 8-cell blocks, ~9 cm): dem_step threads then visit grains block by
// block, so the threads of one SIMD group read the same neighbour bins and hit the
// cache instead of gathering from all over the world. Particle data is not moved.
// Mode (flags bits 16-17): 0 count per block, 1 exclusive scan (one workgroup;
// also zeroes the counts for the next frame), 2 scatter into ORDER, 3 carry the
// contact histories from last frame's visit slots to the new ones (and RANK).
#include "common.glsli"
layout(local_size_x = 1024) in;

shared uint s_sum[1024];

uvec2 block_dims() { return uvec2((pc.grid_w + 7u) / 8u, (pc.grid_h + 7u) / 8u); }

uint block_of(vec2 p) {
	uvec2 c = cell_coord(p) / 8u;
	return c.y * block_dims().x + c.x;
}

void main() {
	if (pc.guard < -1e30) return;
	uint mode = (pc.flags >> 16u) & 3u;
	uint t = gl_GlobalInvocationID.x;
	uvec2 bd = block_dims();
	uint nb = bd.x * bd.y;
	if (mode == 1u) {
		// One workgroup: each thread sums a contiguous run of blocks, then a
		// Hillis-Steele scan of the run totals.
		uint per = (nb + 1023u) / 1024u;
		uint lo = t * per;
		uint hi = min(lo + per, nb);
		uint run = 0u;
		for (uint b = lo; b < hi; b++) run += BLOCK_COUNT[b];
		s_sum[t] = run;
		barrier();
		for (uint off = 1u; off < 1024u; off <<= 1u) {
			uint v = t >= off ? s_sum[t - off] : 0u;
			barrier();
			s_sum[t] += v;
			barrier();
		}
		uint acc = s_sum[t] - run;
		for (uint b = lo; b < hi; b++) {
			uint c = BLOCK_COUNT[b];
			BLOCK_CURSOR[b] = acc;
			BLOCK_COUNT[b] = 0u;
			acc += c;
		}
		if (t == 1023u) BLOCK_CURSOR[nb] = s_sum[1023];
		return;
	}
	if (mode == 3u) {
		if (t >= BLOCK_CURSOR[nb]) return;
		uint i = ORDER[t];
		uint t_old = RANK[i];
		RANK[i] = t;
		bool has = t_old < pc.cap;
		for (uint k = 0u; k < HIST_K; k++) {
			uint key = has ? HKEY_IN[t_old * HIST_K + k] : 0u;
			HKEY_OUT[t * HIST_K + k] = key;
			if (key == 0u) break;
			HXI_OUT[t * HIST_K + k] = HXI_IN[t_old * HIST_K + k];
		}
		return;
	}
	if (t >= pc.n) return;
	if (kind_of(INFO[t]) == KIND_NONE) return;
	uint b = block_of(XV[t].xy);
	if (mode == 0u) {
		atomicAdd(BLOCK_COUNT[b], 1u);
	} else {
		ORDER[atomicAdd(BLOCK_CURSOR[b], 1u)] = t;
	}
}
