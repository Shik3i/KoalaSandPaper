class_name DeterministicHash
extends RefCounted

const MASK_31 := 0x7fffffff


static func hash_2d(seed: int, position: Vector2i, salt: int = 0) -> int:
	var value := (seed ^ salt ^ 0x45d9f3b) & MASK_31
	value = ((value ^ position.x) * 0x119de1f3) & MASK_31
	value = ((value ^ position.y) * 0x1b873593) & MASK_31
	value = (value ^ (value >> 16)) & MASK_31
	value = (value * 0x45d9f3b) & MASK_31
	return (value ^ (value >> 16)) & MASK_31


static func unit_float(seed: int, position: Vector2i, salt: int = 0) -> float:
	return float(hash_2d(seed, position, salt)) / float(MASK_31)


static func mix_int(hash_value: int, component: int) -> int:
	return ((hash_value ^ (component & MASK_31)) * 16777619) & MASK_31
