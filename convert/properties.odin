// Entity property mapping: the conversion stage that turns authored properties of
// one engine into the properties of the other. Class renaming alone is not a
// conversion; this is where values are re-expressed, and where everything that
// cannot be is reported.
package convert

import "core:fmt"
import "core:math"
import "core:sort"
import "core:strconv"
import "core:strings"
import "../diag"
import "../geom"
import "../ir"
import "../profile"
import "../xform"

// SOURCE_LIGHT_BRIGHTNESS_DEFAULT is the brightness of a default Source light.
// Unreal's LightComponent defaults to Brightness = 1.0, so the Source 0..2000
// scale is normalised by this constant. Documented in docs/entity-mapping.md.
SOURCE_LIGHT_BRIGHTNESS_DEFAULT :: 200.0

// MAX_REPORTED_UNMAPPED caps the property list inside one diagnostic; the total
// count is always reported, so truncation is visible.
MAX_REPORTED_UNMAPPED :: 8

// map_entity_properties applies the profile's property table to every entity.
// Converted properties replace their source; whatever has no rule is reported and
// dropped, because the target text format does not accept foreign property names.
map_entity_properties :: proc(doc: ^ir.Document, prof: profile.Profile, target: ir.Format, dg: ^diag.Diagnostics) {
	for &entity in doc.entities {
		remaining := make([dynamic]ir.Property, 0, len(entity.props) + 2)
		unmapped := make([dynamic]string, 0, 4)
		light_color: geom.Vec3
		has_light_color := false
		light_brightness: f64
		has_light_brightness := false
		light_radius: f64
		has_light_radius := false
		inner_cone: f64
		has_inner_cone := false
		outer_cone: f64
		has_outer_cone := false

		for property in entity.props {
			rule, has_rule := profile.property_rule(prof, property.key)
			if !has_rule {
				if profile.structural_key(property.key) {
					continue
				}
				append(&unmapped, property.key)
				continue
			}
			switch rule.op {
			case .Copy:
				ir.push_property(&remaining, rule.target, property.value, property.raw)
				diag.info(
					dg,
					"convert.property-mapped",
					ir.concat(property.key, " -> ", rule.target, " (", rule.note, ")"),
					entity.id,
				)
			case .Drop:
				diag.info(
					dg,
					"convert.property-dropped",
					ir.concat(property.key, " = '", property_text(property), "': ", rule.note),
					entity.id,
				)
			case .Source_Light:
				color, brightness, ok := parse_source_light(property_text(property))
				if ok {
					light_color = color
					has_light_color = true
					light_brightness = brightness
					has_light_brightness = true
				} else {
					diag.warn(dg, "convert.light-value-invalid", "could not parse _light; the property was dropped", entity.id)
				}
			case .Unreal_Light_Shape:
				value, value_ok := strconv.parse_f64(strings.trim_space(property_text(property)))
				if !value_ok {
					diag.warn(dg, "convert.light-shape-invalid", "could not parse light shape value", entity.id)
					continue
				}
				switch strings.to_lower(property.key) {
				case "attenuationradius":
					light_radius = value
					has_light_radius = true
				case "innerconeangle":
					inner_cone = value
					has_inner_cone = true
				case "outerconeangle":
					outer_cone = value
					has_outer_cone = true
				}
			case .Unreal_Light:
				switch strings.to_lower(property.key) {
				case "lightcolor":
					color, ok := parse_unreal_color(property_text(property))
					if ok {
						light_color = color
						has_light_color = true
					} else {
						diag.warn(dg, "convert.light-color-invalid", "could not parse LightColor", entity.id)
					}
				case "brightness":
					value, ok := strconv.parse_f64(strings.trim_space(property_text(property)))
					if ok {
						light_brightness = value
						has_light_brightness = true
					} else {
						diag.warn(dg, "convert.light-brightness-invalid", "could not parse Brightness", entity.id)
					}
				}
			case .Source_Angles:
				angles, ok := parse_triple(property_text(property))
				if ok {
					pitch, yaw, roll := xform.source_angles_to_unreal_rotator(angles.x, angles.y, angles.z)
					entity.rotation = ir.Rotation {
						pitch = pitch,
						yaw   = yaw,
						roll  = roll,
					}
					entity.has_rotation = true
					entity.angles = geom.VEC3_ZERO
					diag.info(
						dg,
						"convert.rotation-mapped",
						fmt.aprintf(
							"Source angles (%s) -> Rotation=(Pitch=%d,Yaw=%d,Roll=%d)",
							geom.vec3_string(angles),
							pitch,
							yaw,
							roll,
						),
						entity.id,
					)
				} else {
					diag.warn(dg, "convert.angles-invalid", "could not parse angles; rotation is not converted", entity.id)
				}
			case .Unreal_Rotation:
				if entity.has_rotation {
					emit_source_angles(&entity, dg)
				}
			case .Asset_Reference:
				diag.warn(
					dg,
					"convert.asset-reference",
					ir.concat(property.key, " = '", property_text(property), "': ", rule.note),
					entity.id,
				)
			}
		}

		// Typed rotation that never appeared as a property line still has to reach
		// the target instead of being lost silently.
		if target == .Source_VMF && entity.has_rotation {
			emit_source_angles(&entity, dg)
		}
		if target == .Unreal_T3D && !entity.has_rotation && entity.angles != geom.VEC3_ZERO {
			mapped := source_angles_to_rotation(entity.angles)
			entity.rotation = mapped
			entity.has_rotation = true
			entity.angles = geom.VEC3_ZERO
			diag.info(dg, "convert.rotation-mapped", "typed Source angles converted to an Unreal rotator", entity.id)
		}

		if has_light_color || has_light_brightness {
			color := has_light_color ? light_color : geom.vec3(255, 255, 255)
			brightness := has_light_brightness ? light_brightness : 1.0
			if target == .Unreal_T3D {
				// The source brightness is on the Source 0..2000 scale.
				unreal_brightness := brightness / SOURCE_LIGHT_BRIGHTNESS_DEFAULT
				ir.push_property(
					&remaining,
					"LightColor",
					fmt.aprintf("(R=%d,G=%d,B=%d,A=255)", clamp_byte(color.x), clamp_byte(color.y), clamp_byte(color.z)),
				)
				ir.push_property(&remaining, "Brightness", unreal_brightness)
				diag.warn(
					dg,
					"convert.light-brightness-scaled",
					fmt.aprintf(
						"LightColor mapped exactly; Brightness=%s is the Source brightness %.0f divided by %.0f (Unreal's default scale)",
						geom.f64_string(unreal_brightness),
						brightness,
						SOURCE_LIGHT_BRIGHTNESS_DEFAULT,
					),
					entity.id,
				)
			} else {
				// The source brightness is Unreal's 0..20 scale.
				source_brightness := brightness * SOURCE_LIGHT_BRIGHTNESS_DEFAULT
				ir.push_property(
					&remaining,
					"_light",
					fmt.aprintf(
						"%d %d %d %.0f",
						clamp_byte(color.x),
						clamp_byte(color.y),
						clamp_byte(color.z),
						source_brightness,
					),
				)
				diag.warn(
					dg,
					"convert.light-brightness-scaled",
					fmt.aprintf(
						"_light rebuilt with brightness %.0f from Unreal Brightness=%s x %.0f",
						source_brightness,
						geom.f64_string(brightness),
						SOURCE_LIGHT_BRIGHTNESS_DEFAULT,
					),
					entity.id,
				)
			}
		}

		if target == .Source_VMF && (has_light_radius || has_inner_cone || has_outer_cone) {
			// Unreal stores the attenuation radius in centimetres and the cone
			// angles in radians; Source wants units and degrees.
			CM_TO_UNITS :: 0.3937007874
			if has_light_radius && light_radius > 0 {
				ir.push_property(&remaining, "_distance", fmt.aprintf("%.0f", light_radius * CM_TO_UNITS))
			}
			if has_outer_cone && outer_cone > 0 {
				ir.push_property(&remaining, "_cone", fmt.aprintf("%.1f", outer_cone * 180.0 / 3.141592653589793))
			}
			if has_inner_cone && inner_cone > 0 {
				ir.push_property(&remaining, "_inner_cone", fmt.aprintf("%.1f", inner_cone * 180.0 / 3.141592653589793))
			}
		}

		if len(unmapped) > 0 {
			report_unmapped(dg, entity.id, unmapped[:])
		}
		entity.props = remaining
	}
}

emit_source_angles :: proc(entity: ^ir.Entity, dg: ^diag.Diagnostics) {
	pitch, yaw, roll := xform.unreal_rotator_to_source_angles(
		entity.rotation.pitch,
		entity.rotation.yaw,
		entity.rotation.roll,
	)
	entity.angles = geom.vec3(pitch, yaw, roll)
	entity.has_rotation = false
	diag.info(
		dg,
		"convert.rotation-mapped",
		fmt.aprintf(
			"Rotation=(Pitch=%d,Yaw=%d,Roll=%d) -> Source angles (%s)",
			entity.rotation.pitch,
			entity.rotation.yaw,
			entity.rotation.roll,
			geom.vec3_string(entity.angles),
		),
		entity.id,
	)
}

source_angles_to_rotation :: proc(angles: geom.Vec3) -> ir.Rotation {
	pitch, yaw, roll := xform.source_angles_to_unreal_rotator(angles.x, angles.y, angles.z)
	return ir.Rotation{pitch = pitch, yaw = yaw, roll = roll}
}

// report_unmapped emits one deterministic warning per entity.
report_unmapped :: proc(dg: ^diag.Diagnostics, entity_id: string, keys: []string) {
	sorted := make([]string, len(keys))
	copy(sorted, keys)
	sort.sort(sort.slice_interface(&sorted))
	shown := sorted
	if len(shown) > MAX_REPORTED_UNMAPPED {
		shown = shown[:MAX_REPORTED_UNMAPPED]
	}
	message := ir.concat("no target property for: ", strings.join(shown, ", "))
	if len(sorted) > len(shown) {
		message = ir.concat(message, fmt.aprintf(" and %d more", len(sorted) - len(shown)))
	}
	diag.warn(dg, "convert.property-unmapped", message, entity_id)
}

// parse_source_light parses the Source "_light" value: "R G B brightness". The
// optional fifth value is an HDR scale and is not used here.
parse_source_light :: proc(text: string) -> (color: geom.Vec3, brightness: f64, ok: bool) {
	fields := strings.fields(strings.trim_space(text), context.temp_allocator)
	if len(fields) < 4 {
		return {}, 0, false
	}
	values: [4]f64
	for i in 0 ..< 4 {
		value, parsed := strconv.parse_f64(fields[i])
		if !parsed {
			return {}, 0, false
		}
		values[i] = value
	}
	if values[3] <= 0 {
		return {}, 0, false
	}
	return geom.vec3(values[0], values[1], values[2]), values[3], true
}

// parse_unreal_color parses "(R=255,G=255,B=255,A=255)"; property order is
// irrelevant because the fields are named.
parse_unreal_color :: proc(text: string) -> (color: geom.Vec3, ok: bool) {
	inner := strings.trim(strings.trim_space(text), "()")
	parts := strings.split(inner, ",", context.temp_allocator)
	if len(parts) < 3 {
		return {}, false
	}
	values := [3]f64{255, 255, 255}
	for part in parts {
		piece := strings.trim_space(part)
		eq := strings.index_byte(piece, '=')
		if eq <= 0 {
			continue
		}
		name := strings.to_lower(strings.trim_space(piece[:eq]))
		value, parsed := strconv.parse_f64(strings.trim_space(piece[eq + 1:]))
		if !parsed {
			continue
		}
		switch name {
		case "r":
			values[0] = value
		case "g":
			values[1] = value
		case "b":
			values[2] = value
		}
	}
	return geom.vec3(values[0], values[1], values[2]), true
}

// parse_triple parses "p q r" with any whitespace or comma separator.
parse_triple :: proc(text: string) -> (value: geom.Vec3, ok: bool) {
	cleaned := strings.trim(strings.trim_space(text), "()")
	fields := strings.fields(cleaned, context.temp_allocator)
	if len(fields) < 3 {
		fields = strings.split(cleaned, ",", context.temp_allocator)
	}
	if len(fields) < 3 {
		return {}, false
	}
	values: [3]f64
	for i in 0 ..< 3 {
		parsed, parsed_ok := strconv.parse_f64(strings.trim_space(fields[i]))
		if !parsed_ok {
			return {}, false
		}
		values[i] = parsed
	}
	return geom.vec3(values[0], values[1], values[2]), true
}

clamp_byte :: proc(v: f64) -> int {
	rounded := math.round(v)
	if rounded < 0 {
		return 0
	}
	if rounded > 255 {
		return 255
	}
	return int(rounded)
}

// property_text renders a property value the way both text formats spell it,
// preferring the exact source text when the importer kept it.
property_text :: proc(p: ir.Property) -> string {
	if p.raw != "" {
		return p.raw
	}
	switch v in p.value {
	case string:
		return v
	case f64:
		return geom.f64_string(v)
	case i64:
		return fmt.aprintf("%d", v)
	case bool:
		return v ? "1" : "0"
	case geom.Vec3:
		return geom.vec3_string(v)
	case ir.Rotation:
		return fmt.aprintf("(Pitch=%d,Yaw=%d,Roll=%d)", v.pitch, v.yaw, v.roll)
	case ir.Raw:
		return v.text
	case ir.Struct_Value, ir.Array_Value:
		return ""
	}
	return ""
}
