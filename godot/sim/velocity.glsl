#[compute]
#version 450
// Velocity pass (XPBD, Müller et al. 2020 §3.6): for every contact still closed
// after the position solve, set the relative normal velocity to -e * (relative
// normal velocity before the substep), e = 0 for slow contacts. Overlap removed
// by the position solve therefore cannot turn into separation speed (no
// compression waves / popping). Also clears the other-parity grid cells.
#include "common.glsli"
#include "colliders.glsli"
layout(local_size_x = WG) in;

float restitution_target(float vn_pre, float e) {
	// Resting/slow contacts are perfectly inelastic (threshold 2 g h).
	return vn_pre < -2.0 * length(pc.gravity) * pc.h ? -e * vn_pre : 0.0;
}

vec2 wall_velocity(vec2 n, vec2 v, vec2 v0, float e) {
	return v + n * (restitution_target(dot(v0, n), e) - dot(v, n));
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= pc.n || pc.laser_b.x < -1e30) return;
	uint other = 1u - par();
	uint prev = CELL_OF[other * pc.n + i];
	if (prev != CELL_NONE) CELL_COUNT[other * cells_total() + prev] = 0u;

	uint info = INFO[i];
	uint kind = kind_of(info);
	if (kind == KIND_NONE) return;
	vec2 vi = VN[i];
	if (kind == KIND_SPARK) {
		V[i] = vi;
		return;
	}
	vec2 xi = X[i];
	vec2 vi0 = VOLD[i];
	float ri = RAD[i];
	vec4 mi = MAT[2u * mat_of(info)];
	float wi = inv_mass(info, ri);
	float tol = 0.02 * pc.r;
	Acc a = Acc(vec2(0.0), 0.0, 0.0);

	uint c = cell_of(i);
	if (c != CELL_NONE) {
		int cx = int(c % pc.grid_w);
		int cy = int(c / pc.grid_w);
		for (int oy = -1; oy <= 1; oy++) {
			int y = cy + oy;
			if (y < 0 || y >= int(pc.grid_h)) continue;
			for (int ox = -1; ox <= 1; ox++) {
				int x = cx + ox;
				if (x < 0 || x >= int(pc.grid_w)) continue;
				uint cell = uint(y) * pc.grid_w + uint(x);
				uint m = count_at(cell);
				for (uint s = 0u; s < m; s++) {
					uint j = CELL_ITEMS[cell * CELL_CAP + s];
					if (j == i) continue;
					uint infoj = INFO[j];
					uint kj = kind_of(infoj);
					if (kj == KIND_NONE || kj == KIND_SPARK) continue;
					vec2 dv = xi - X[j];
					float rj = RAD[j];
					float d0 = ri + rj + tol;
					float d2 = dot(dv, dv);
					if (d2 >= d0 * d0 || d2 < 1e-20) continue;
					if (kind == KIND_BONDED && kj == KIND_BONDED) {
						bool bonded = false;
						for (uint k = 0u; k < MAX_BONDS; k++) bonded = bonded || BONDS[i * MAX_BONDS + k].x == j + 1u;
						if (bonded) continue;
					}
					vec2 n = dv * inversesqrt(d2);
					float vn = dot(vi - VN[j], n);
					float vn0 = dot(vi0 - VOLD[j], n);
					float e = 0.5 * (mi.z + MAT[2u * mat_of(infoj)].z);
					float wj = inv_mass(infoj, rj);
					acc_add(a, n * ((restitution_target(vn0, e) - vn) * wi / (wi + wj)));
				}
			}
		}
	}
	vi += acc_total(a);

	// Machine surfaces (kinematic, infinite mass), sequential.
	for (uint k = 0u; k < pc.n_prims; k++) {
		Prim pr = PRIMS[k];
		if ((pr.head.w & 6u) != 0u) continue;
		vec2 bpos, bvel;
		float bang, bom;
		body_pose(pr.head.y, pc.t_sub, bpos, bang, bvel, bom);
		vec2 rp = xi - bpos;
		if ((pr.head.w & 1u) == 0u && dot(rp, rp) > (pr.surf.z + ri + tol) * (pr.surf.z + ri + tol)) continue;
		vec2 q = rot(-bang) * rp;
		float d = prim_sdf(pr, q);
		if (d >= ri + tol) continue;
		float e = 0.05 * ri;
		vec2 g = vec2(prim_sdf(pr, q + vec2(e, 0.0)) - prim_sdf(pr, q - vec2(e, 0.0)),
				prim_sdf(pr, q + vec2(0.0, e)) - prim_sdf(pr, q - vec2(0.0, e)));
		float gl = length(g);
		if (gl < 1e-12) continue;
		vec2 n = rot(bang) * (g / gl);
		vec2 vs = bvel + bom * vec2(-rp.y, rp.x) + pr.surf.w * vec2(n.y, -n.x);
		float vn = dot(vi - vs, n);
		float vn0 = dot(vi0 - vs, n);
		vi += n * (restitution_target(vn0, 0.5 * (mi.z + 0.15)) - vn);
	}
	vec2 hi = pc.world - ri - tol;
	if (xi.y < ri + tol) vi = wall_velocity(vec2(0.0, 1.0), vi, vi0, mi.z);
	if (xi.y > hi.y) vi = wall_velocity(vec2(0.0, -1.0), vi, vi0, mi.z);
	if (xi.x < ri + tol) vi = wall_velocity(vec2(1.0, 0.0), vi, vi0, mi.z);
	if (xi.x > hi.x) vi = wall_velocity(vec2(-1.0, 0.0), vi, vi0, mi.z);

	V[i] = vi;
	if ((pc.flags & FLAG_LAST) != 0u) atomic_max_f(ST_MAX_SPEED, length(vi));
}
