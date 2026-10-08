#[compute]
#version 450
// One Jacobi pass of particle-particle and particle-wall contacts with Coulomb
// friction. Reads P_IN, writes P_OUT (averaged corrections, Macklin 2014).
#include "common.glsli"
layout(local_size_x = WG) in;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= pc.n) return;
	uint info = INFO[i];
	if (kind_of(info) == KIND_NONE) return;
	vec2 pi = P_IN[i];
	vec2 dxi = pi - X[i];
	vec4 mi = MAT[mat_of(info)];
	float wi = mi.w;
	float d0 = 2.0 * pc.r;
	vec2 acc = vec2(0.0);
	float cnt = 0.0;
	float max_pen = 0.0;

	uint c = CELL_OF[i];
	int cx = int(c % pc.grid_w);
	int cy = int(c / pc.grid_w);
	for (int oy = -1; oy <= 1; oy++) {
		int y = cy + oy;
		if (y < 0 || y >= int(pc.grid_h)) continue;
		for (int ox = -1; ox <= 1; ox++) {
			int x = cx + ox;
			if (x < 0 || x >= int(pc.grid_w)) continue;
			uint cell = uint(y) * pc.grid_w + uint(x);
			uint m = min(CELL_COUNT[cell], CELL_CAP);
			for (uint s = 0u; s < m; s++) {
				uint j = CELL_ITEMS[cell * CELL_CAP + s];
				if (j == i) continue;
				vec2 pj = P_IN[j];
				vec2 dv = pi - pj;
				float d2 = dot(dv, dv);
				if (d2 >= d0 * d0) continue;
				float dist = sqrt(d2);
				vec2 n = dist > 1e-9 * pc.r ? dv / dist : vec2(0.0, i < j ? 1.0 : -1.0);
				float pen = d0 - dist;
				uint infoj = INFO[j];
				vec4 mj = MAT[mat_of(infoj)];
				// Shock propagation: the lower particle acts heavier.
				float b = exp(pc.stack_k * (pi.y - pj.y) / pc.r);
				float wsum = wi * b + mj.w;
				if (wsum <= 0.0) continue;
				float s_i = wi * b / wsum;
				vec2 rel = dxi - (pj - X[j]);
				vec2 t = rel - dot(rel, n) * n;
				float tl = length(t);
				float mu_s = 0.5 * (mi.x + mj.x);
				float mu_k = 0.5 * (mi.y + mj.y);
				vec2 corr = n * pen;
				if (tl > 0.0) {
					corr -= (tl < mu_s * pen) ? t : t * min(mu_k * pen / tl, 1.0);
				}
				acc += corr * s_i;
				cnt += 1.0;
				max_pen = max(max_pen, pen);
			}
		}
	}

	// World box walls (static).
	float r = pc.r;
	if (pi.y < r) surface_contact(vec2(0.0, 1.0), r - pi.y, dxi, mi.x, mi.y, acc, cnt);
	if (pi.y > pc.world.y - r) surface_contact(vec2(0.0, -1.0), pi.y - (pc.world.y - r), dxi, mi.x, mi.y, acc, cnt);
	if (pi.x < r) surface_contact(vec2(1.0, 0.0), r - pi.x, dxi, mi.x, mi.y, acc, cnt);
	if (pi.x > pc.world.x - r) surface_contact(vec2(-1.0, 0.0), pi.x - (pc.world.x - r), dxi, mi.x, mi.y, acc, cnt);

	if ((pc.flags & FLAG_LAST) != 0u) atomic_max_f(ST_MAX_PEN, max_pen / r);
	P_OUT[i] = cnt > 0.0 ? pi + acc * (pc.omega / cnt) : pi;
}
