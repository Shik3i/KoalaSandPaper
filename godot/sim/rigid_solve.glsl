#[compute]
#version 450
// Rigid pieces, one workgroup per piece (grains of a piece are contiguous):
// 1. laser: a body crossed by the beam splits into two bodies; grains in the
//    kerf burn to free (glowing) grains;
// 2. each grain's contact correction Δ (D_OUT - D_IN) becomes a positional
//    impulse p = Δ / w_eff, w_eff = 1/M + (r×n)²/I; the body moves by the
//    averaged impulse response (exact for one contact, Jacobi-averaged for many);
// 3. crush: if the rigid motion cannot satisfy the corrections (pinched between
//    rollers, pressed) for several substeps, the body shatters into its bond net.
// Requires iterations == 1 (D_OUT = binding 1, D_IN = binding 2 in this variant).
#include "common.glsli"
// Small workgroups: 4 KB shared memory, cheap launch for idle piece slots.
#define RWG 64u
layout(local_size_x = RWG) in;

#define D_AFTER D_IN
#define D_BEFORE D_OUT
#define NSUB BODIES_PER_PIECE
#define SYNC() memoryBarrierBuffer(); memoryBarrierShared(); barrier()

shared uint s_hit[NSUB];
shared uint s_left[NSUB];
shared uint s_right[NSUB];
shared int s_newsub[NSUB];
shared uint s_nsub;
shared float s_red[RWG * 16u];
shared uint s_res;

float side_of(vec2 p) {
	vec2 ab = pc.laser_b - pc.laser_a;
	vec2 ap = p - pc.laser_a;
	return ab.x * ap.y - ab.y * ap.x;
}

// Distance from p to the beam segment and whether p is within its extent.
float beam_dist(vec2 p) {
	vec2 ab = pc.laser_b - pc.laser_a;
	float t = clamp(dot(p - pc.laser_a, ab) / dot(ab, ab), 0.0, 1.0);
	return length(p - (pc.laser_a + t * ab));
}

void main() {
	uint piece = gl_WorkGroupID.x;
	uint tid = gl_LocalInvocationID.x;
	if (piece >= pc.n_pieces || pc.laser_b.x < -1e30) return;
	uvec4 pd = PIECES[piece];
	if (pd.y == 0u) return;
	uint base = piece * NSUB;
	bool laser = any(notEqual(pc.laser_a, pc.laser_b));
	float ab_len = length(pc.laser_b - pc.laser_a);

	if (tid == 0u) {
		s_nsub = pd.z;
		for (uint k = 0u; k < NSUB; k++) {
			s_hit[k] = 0u; s_left[k] = 0u; s_right[k] = 0u; s_newsub[k] = -1;
		}
	}
	SYNC();

	// 1. Laser classification.
	if (laser) {
		for (uint i = pd.x + tid; i < pd.x + pd.y; i += RWG) {
			if (kind_of(INFO[i]) != KIND_RIGID) continue;
			uint k = BODY_OF[i] - base;
			vec2 p = X[i] + D_AFTER[i];
			if (beam_dist(p) < pc.kerf) atomicOr(s_hit[k], 1u);
			else if (side_of(p) > 0.0) atomicAdd(s_left[k], 1u);
			else atomicAdd(s_right[k], 1u);
		}
		SYNC();
		if (tid == 0u) {
			for (uint k = 0u; k < pd.z; k++) {
				if (RB[4u * (base + k)].w < 0.5 || s_hit[k] == 0u) continue;
				if (s_left[k] > 0u && s_right[k] > 0u && s_nsub < NSUB) {
					uint ns = s_nsub++;
					s_newsub[k] = int(ns);
					for (uint q = 0u; q < 4u; q++) RB[4u * (base + ns) + q] = RB[4u * (base + k) + q];
				}
			}
			PIECES[piece].z = s_nsub;
		}
		SYNC();
		for (uint i = pd.x + tid; i < pd.x + pd.y; i += RWG) {
			uint info = INFO[i];
			if (kind_of(info) != KIND_RIGID) continue;
			uint k = BODY_OF[i] - base;
			if (s_hit[k] == 0u) continue;
			vec2 p = X[i] + D_AFTER[i];
			if (beam_dist(p) < pc.kerf) {
				// Burnt in the kerf: free glowing grain, keeps fragment id for bond logic.
				INFO[i] = with_heat((info & ~0xff00u) | (KIND_GRAIN << 8u), 65535u);
			} else if (s_newsub[k] >= 0 && side_of(p) <= 0.0) {
				BODY_OF[i] = base + uint(s_newsub[k]);
			}
		}
		SYNC();
	}

	// 2. Impulse reduction per body.
	uint nsub = s_nsub;
	float m = 1.0 / inv_mass(KIND_RIGID << 8u | 1u, pc.r);  // rigid grains have radius R
	for (uint k = 0u; k < nsub; k++) {
		uint b = base + k;
		vec4 c = RB[4u * b];
		if (c.w < 0.5) continue;  // uniform across the workgroup
		vec4 ps = RB[4u * b + 2u];
		vec2 c0 = RB[4u * b + 3u].xy;
		mat2 R = rot(ps.z);
		float cnt = 0.0, nc = 0.0, rr = 0.0, tq = 0.0, nf = 0.0, rxd = 0.0, r2 = 0.0;
		vec2 sr = vec2(0.0), sp = vec2(0.0), srr = vec2(0.0), sdl = vec2(0.0);
		vec4 fr = vec4(0.0);
		for (uint i = pd.x + tid; i < pd.x + pd.y; i += RWG) {
			if (kind_of(INFO[i]) != KIND_RIGID || BODY_OF[i] != b) continue;
			vec2 r0 = REST[i] - c0;
			cnt += 1.0;
			sr += r0;
			rr += dot(r0, r0);
		}
		s_red[tid * 16u] = cnt; s_red[tid * 16u + 1u] = sr.x; s_red[tid * 16u + 2u] = sr.y; s_red[tid * 16u + 3u] = rr;
		SYNC();
		for (uint w = RWG / 2u; w > 0u; w >>= 1u) {
			if (tid < w) for (uint q = 0u; q < 4u; q++) s_red[tid * 16u + q] += s_red[(tid + w) * 16u + q];
			SYNC();
		}
		float N = s_red[0]; vec2 SR = vec2(s_red[1], s_red[2]); float RR = s_red[3];
		SYNC();
		if (N < 1.0) {
			if (tid == 0u) RB[4u * b].w = 0.0;
			continue;
		}
		vec2 c0n = SR / N;                 // rest COM offset from c0
		float M = N * m;
		float I = max(m * (RR - N * dot(c0n, c0n)), 1e-9);
		// Impulses (inertia about the current COM, lever arms about it too).
		for (uint i = pd.x + tid; i < pd.x + pd.y; i += RWG) {
			if (kind_of(INFO[i]) != KIND_RIGID || BODY_OF[i] != b) continue;
			vec4 f = FRIC[i];
			if (f.z > 0.0) {
				fr += f;
				nf += 1.0;
			}
			vec2 dl = D_AFTER[i] - D_BEFORE[i];
			float l = length(dl);
			if (l < 1e-12) continue;
			vec2 r = R * (REST[i] - c0 - c0n);
			vec2 nh = dl / l;
			float rn = r.x * nh.y - r.y * nh.x;
			vec2 p = dl / (1.0 / M + rn * rn / I);
			nc += 1.0;
			sp += p;
			tq += r.x * p.y - r.y * p.x;
			srr += r;
			sdl += dl;
			rxd += r.x * dl.y - r.y * dl.x;
			r2 += dot(r, r);
		}
		uint o = tid * 16u;
		s_red[o] = nc; s_red[o + 1u] = sp.x; s_red[o + 2u] = sp.y; s_red[o + 3u] = tq;
		s_red[o + 4u] = nf; s_red[o + 5u] = fr.x; s_red[o + 6u] = fr.y; s_red[o + 7u] = fr.z; s_red[o + 8u] = fr.w;
		s_red[o + 9u] = srr.x; s_red[o + 10u] = srr.y; s_red[o + 11u] = sdl.x; s_red[o + 12u] = sdl.y;
		s_red[o + 13u] = rxd; s_red[o + 14u] = r2;
		SYNC();
		for (uint w = RWG / 2u; w > 0u; w >>= 1u) {
			if (tid < w) for (uint q = 0u; q < 15u; q++) s_red[tid * 16u + q] += s_red[(tid + w) * 16u + q];
			SYNC();
		}
		float NC = s_red[0]; vec2 SP = vec2(s_red[1], s_red[2]); float TQ = s_red[3];
		float NF = s_red[4]; vec2 FT = vec2(s_red[5], s_red[6]); float FS = s_red[7]; float FK = s_red[8];
		vec2 RB_ = vec2(s_red[9], s_red[10]); vec2 DB = vec2(s_red[11], s_red[12]); float RXD = s_red[13]; float R2 = s_red[14];
		if (tid == 0u) s_res = 0u;
		SYNC();
		vec2 dc = NC > 0.0 ? SP / (M * NC) : vec2(0.0);
		float dth = NC > 0.0 ? TQ / (I * NC) : 0.0;
		// Extended contact sets (resting, pressed): least-squares rigid motion of the
		// contact points is exact; blend in by contact spread vs radius of gyration.
		if (NC > 1.0) {
			vec2 rb = RB_ / NC;
			vec2 db = DB / NC;
			float spread = R2 - NC * dot(rb, rb);
			float th_l = spread > 1e-12 ? (RXD - NC * (rb.x * db.y - rb.y * db.x)) / spread : 0.0;
			vec2 c_l = db - th_l * vec2(-rb.y, rb.x);
			float beta = clamp(spread / NC / (0.1 * I / M), 0.0, 1.0);
			dc = mix(dc, c_l, beta);
			dth = mix(dth, th_l, beta);
		}
		// Coulomb at piece level: mean slip vs mean cone over the surface contacts.
		vec2 dcf = vec2(0.0);
		if (NF > 0.0) {
			vec2 t = FT / NF;
			float tl = length(t);
			if (tl > 0.0) dcf = tl < FS / NF ? -t : -t * min((FK / NF) / tl, 1.0);
		}
		// 3. Crush residual: what the rigid response leaves unsatisfied.
		for (uint i = pd.x + tid; i < pd.x + pd.y; i += RWG) {
			if (kind_of(INFO[i]) != KIND_RIGID || BODY_OF[i] != b) continue;
			vec2 dl = D_AFTER[i] - D_BEFORE[i];
			if (dot(dl, dl) < 1e-24) continue;
			vec2 r = R * (REST[i] - c0 - c0n);
			vec2 res = dl - (dc + dth * vec2(-r.y, r.x));
			atomicMax(s_res, floatBitsToUint(length(res)));
		}
		SYNC();
		if (tid == 0u) {
			// Pose about the old reference c0, then re-reference to the new COM.
			vec2 cs = ps.xy + R * c0n + dc + dcf;  // solved COM
			float th = ps.z + dth;
			vec2 cs_start = c.xy + rot(c.z) * c0n;
			vec4 v = RB[4u * b + 1u];
			v.xy = (cs - cs_start) / pc.h;
			v.z = (th - c.z) / pc.h;
			v.w = M;
			RB[4u * b + 1u] = v;
			vec4 extra = RB[4u * b + 3u];
			extra.xy = c0 + c0n;
			float crush = uintBitsToFloat(s_res) > pc.crush ? extra.z + 1.0 : max(extra.z - 1.0, 0.0);
			extra.z = crush;
			RB[4u * b + 3u] = extra;
			RB[4u * b + 2u] = vec4(cs, th, I);
			RB[4u * b] = vec4(cs, th, crush >= 4.0 ? 0.0 : 1.0);
		}
		SYNC();
		if (RB[4u * b].w < 0.5) {
			// Shatter: grains continue as the piece's bond network.
			for (uint i = pd.x + tid; i < pd.x + pd.y; i += RWG) {
				uint info = INFO[i];
				if (kind_of(info) == KIND_RIGID && BODY_OF[i] == b) INFO[i] = (info & ~0xff00u) | (KIND_BONDED << 8u);
			}
			if (tid == 0u) atomicAdd(STATS[ST_BROKEN], 1u);
		}
		SYNC();
	}
}
