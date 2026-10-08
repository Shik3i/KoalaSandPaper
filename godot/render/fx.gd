class_name Fx
## Cosmetic particle effects (no physics, excluded from conservation): furnace
## embers and chimney smoke.


static func soft_dot(size := 64) -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	t.width = size
	t.height = size
	return t


static func embers(area_px: Rect2, ppm: float) -> GPUParticles2D:
	var p := GPUParticles2D.new()
	p.amount = 260
	p.lifetime = 2.6
	p.position = area_px.get_center()
	p.texture = soft_dot(16)
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = Vector3(area_px.size.x * 0.5, area_px.size.y * 0.5, 0)
	m.direction = Vector3(0, -1, 0)
	m.spread = 25.0
	m.initial_velocity_min = 0.15 * ppm
	m.initial_velocity_max = 0.6 * ppm
	m.gravity = Vector3(0, -0.25 * ppm, 0)
	m.turbulence_enabled = true
	m.turbulence_noise_strength = 2.0
	m.turbulence_noise_scale = 3.0
	m.scale_min = 0.12
	m.scale_max = 0.35
	var ramp := Gradient.new()
	ramp.set_color(0, Color(4.0, 1.8, 0.5, 1.0))
	ramp.add_point(0.5, Color(2.2, 0.6, 0.12, 0.8))
	ramp.set_color(ramp.get_point_count() - 1, Color(0.6, 0.1, 0.02, 0.0))
	var rt := GradientTexture1D.new()
	rt.gradient = ramp
	m.color_ramp = rt
	p.process_material = m
	return p


static func smoke(at_px: Vector2, ppm: float) -> GPUParticles2D:
	var p := GPUParticles2D.new()
	p.amount = 60
	p.lifetime = 7.0
	p.position = at_px
	p.texture = soft_dot(64)
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = Vector3(0.12 * ppm, 2, 0)
	m.direction = Vector3(-0.3, -1, 0)
	m.spread = 12.0
	m.initial_velocity_min = 0.08 * ppm
	m.initial_velocity_max = 0.18 * ppm
	m.gravity = Vector3(-0.02 * ppm, -0.01 * ppm, 0)
	m.scale_min = 0.5
	m.scale_max = 1.2
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.4))
	sc.add_point(Vector2(1, 2.5))
	var st := CurveTexture.new()
	st.curve = sc
	m.scale_curve = st
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.35, 0.33, 0.32, 0.0))
	ramp.add_point(0.15, Color(0.32, 0.3, 0.3, 0.35))
	ramp.set_color(ramp.get_point_count() - 1, Color(0.25, 0.27, 0.3, 0.0))
	var rt := GradientTexture1D.new()
	rt.gradient = ramp
	m.color_ramp = rt
	p.process_material = m
	return p
