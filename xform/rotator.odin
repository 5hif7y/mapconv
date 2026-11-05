// Rotation conversion between Source `angles` and Unreal `FRotator`.
//
// The mapping is derived, not guessed. Both engines build their rotation from
// the same three axes (forward, right, up):
//
//	Source SDK  AngleVectors:
//	  X = ( cp*cy,  cp*sy, -sp )
//	  Y = ( -sr*sp*cy + cr*sy,  -sr*sp*sy - cr*cy,  -sr*cp )
//	  Z = ( cr*sp*cy + sr*sy,   cr*sp*sy - sr*cy,    cr*cp )
//
//	Unreal 3  FRotationTranslationMatrix (UnMath.h):
//	  X = ( CP*CY,  CP*SY,  SP )
//	  Y = ( SR*SP*CY - CR*SY,  SR*SP*SY + CR*CY,  -SR*CP )
//	  Z = ( -(CR*SP*CY + SR*SY),  CY*SR - CR*SP*SY,  CR*CP )
//
// The coordinate change between the frames is the Y mirror M = diag(1, -1, 1)
// (see docs/coordinates.md). Applying M to the Source axes and solving for the
// Unreal angles gives exactly:
//
//	pitch_unreal = -pitch_source
//	yaw_unreal   = -yaw_source
//	roll_unreal  = +roll_source
//
// Unreal rotators use 65536 units per full turn; Source uses degrees.
package xform

import "core:math"

UNREAL_ROTATOR_PER_DEGREE :: 65536.0 / 360.0
DEGREES_PER_UNREAL_ROTATOR :: 360.0 / 65536.0

// wrap_rotator folds a rotator component into [-32768, 32767], the range Unreal
// prints and compares.
wrap_rotator :: proc(v: i32) -> i32 {
	w := v % 65536
	if w < 0 {
		w += 65536
	}
	if w >= 32768 {
		w -= 65536
	}
	return w
}

// source_angles_to_unreal_rotator converts Source "pitch yaw roll" degrees into
// Unreal rotator units. The derivation is in the package comment.
source_angles_to_unreal_rotator :: proc(pitch_deg, yaw_deg, roll_deg: f64) -> (pitch, yaw, roll: i32) {
	pitch = wrap_rotator(i32(math.round(-pitch_deg * UNREAL_ROTATOR_PER_DEGREE)))
	yaw = wrap_rotator(i32(math.round(-yaw_deg * UNREAL_ROTATOR_PER_DEGREE)))
	roll = wrap_rotator(i32(math.round(roll_deg * UNREAL_ROTATOR_PER_DEGREE)))
	return
}

// unreal_rotator_to_source_angles is the inverse conversion, in degrees.
unreal_rotator_to_source_angles :: proc(pitch, yaw, roll: i32) -> (pitch_deg, yaw_deg, roll_deg: f64) {
	pitch_deg = -f64(wrap_rotator(pitch)) * DEGREES_PER_UNREAL_ROTATOR
	yaw_deg = -f64(wrap_rotator(yaw)) * DEGREES_PER_UNREAL_ROTATOR
	roll_deg = f64(wrap_rotator(roll)) * DEGREES_PER_UNREAL_ROTATOR
	return
}
