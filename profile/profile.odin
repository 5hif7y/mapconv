// Package profile holds entity, material and unit mapping profiles. A profile is
// data, not code: adding a game or editor variant must not require touching the
// conversion pipeline.
package profile

import "core:strings"

Mapping :: struct {
	source_class: string,
	target_class: string,
	note:         string,
}

// Property_Op is what a rule does with one source property.
Property_Op :: enum {
	// Copy the value to `target`.
	Copy,
	// Drop the property; the reason is `note`.
	Drop,
	// Source "_light" ("R G B brightness") -> Unreal LightColor + Brightness.
	Source_Light,
	// Unreal LightColor + Brightness -> Source "_light".
	Unreal_Light,
	// Source "angles" (degrees) -> Unreal Rotation (rotator units).
	Source_Angles,
	// Unreal Rotation -> Source "angles" (degrees).
	Unreal_Rotation,
	// An asset reference that cannot be resolved; reported and dropped.
	Asset_Reference,
	// Unreal light shape (radius, cone angles) -> Source light keys.
	Unreal_Light_Shape,
}

Property_Rule :: struct {
	key:    string, // source key, matched case-insensitively
	op:     Property_Op,
	target: string, // target key for Copy
	note:   string,
}

Profile :: struct {
	name:       string,
	engine:     string,
	entities:   []Mapping,
	properties: []Property_Rule,
	materials:  []Mapping,
	notes:      []string,
}

// DEFAULT_SOURCE_TO_UNREAL maps Source 1 entity classes to the closest Unreal
// Engine 3 actor class. These are *class hints*: a mapped class is not
// behaviourally equivalent, and the conversion report says so.
DEFAULT_SOURCE_TO_UNREAL :: []Mapping {
	{"WORLDSPAWN", "", "world brushes become Brush actors"},
	{"INFO_PLAYER_START", "PlayerStart", "spawn point"},
	{"INFO_PLAYER_TERRORIST", "PlayerStart", "team spawn collapses to PlayerStart"},
	{"INFO_PLAYER_COUNTER_TERRORIST", "PlayerStart", "team spawn collapses to PlayerStart"},
	{"LIGHT", "PointLight", "light entity; colour and brightness mapped, falloff is not"},
	{"LIGHT_SPOT", "SpotLight", "spot light; cone angles are not converted"},
	{"LIGHT_ENVIRONMENT", "SkyLight", "environment light"},
	{"PROP_STATIC", "StaticMeshActor", "static mesh reference is not converted"},
	{"PROP_DYNAMIC", "KActor", "dynamic prop becomes a rigid body actor"},
	{"PROP_PHYSICS", "KActor", "physics prop"},
	{"FUNC_DETAIL", "Brush", "detail brush has no CSG equivalent; geometry only"},
	{"FUNC_BRUSH", "Brush", "brush entity becomes a Brush actor"},
	{"FUNC_WALL", "Brush", "brush entity becomes a Brush actor"},
	{"FUNC_DOOR", "InterpActor", "door behaviour is not converted"},
	{"TRIGGER_MULTIPLE", "Trigger", "trigger volume"},
	{"ENV_FOG_CONTROLLER", "FogVolumeDensityInfo", "fog settings are not converted"},
}

// DEFAULT_UNREAL_TO_SOURCE maps Unreal Engine 3 classes to Source 1 classes.
DEFAULT_UNREAL_TO_SOURCE :: []Mapping {
	{"WORLDSPAWN", "worldspawn", ""},
	{"PLAYERSTART", "info_player_start", "spawn point"},
	{"POINTLIGHT", "light", "colour and brightness mapped back, falloff is not"},
	{"SPOTLIGHT", "light_spot", "spot light"},
	{"POINTLIGHTTOGGLEABLE", "light", "toggleable point light"},
	{"SPOTLIGHTTOGGLEABLE", "light_spot", "toggleable spot light"},
	{"DIRECTIONALLIGHT", "light_environment", "directional light becomes an environment light"},
	{"DIRECTIONALLIGHTTOGGLEABLE", "light_environment", "toggleable directional light"},
	{"SKYLIGHT", "light_environment", "environment light"},
	{"STATICMESHACTOR", "prop_static", "static mesh reference is not converted"},
	{"KActor", "prop_physics", "physics prop"},
	{"INTERPACTOR", "func_door", "movement behaviour is not converted"},
	{"TRIGGER", "trigger_multiple", "trigger volume"},
	{"BRUSH", "", "brush actors become world or entity solids"},
}

NOTES_SOURCE_TO_UNREAL :: []string {
	"Entity classes are hints, not behaviourally equivalent actors.",
	"Materials are preserved by name; no asset conversion is attempted.",
}

NOTES_UNREAL_TO_SOURCE :: []string {
	"Unreal CSG subtractive brushes have no Source VMF equivalent.",
	"Materials are preserved by name; no asset conversion is attempted.",
}

NOTES_DEFAULT :: []string{"no entity mapping applied"}

// SOURCE_TO_UNREAL_PROPERTIES converts Source 1 entity keys that have a known
// Unreal 3 counterpart. Everything not listed here is reported and dropped: an
// Unreal text importer rejects property names it does not know.
SOURCE_TO_UNREAL_PROPERTIES :: []Property_Rule {
	{"_light", .Source_Light, "", "colour mapped exactly; brightness normalised from the Source 0..2000 scale"},
	{"_lightHDR", .Drop, "", "HDR light values have no Unreal counterpart"},
	{"_lightscale", .Drop, "", "Source light scale has no Unreal counterpart"},
	{"_fifty_percent_distance", .Drop, "", "Source falloff distances are baked, not authored"},
	{"_zero_percent_distance", .Drop, "", "Source falloff distances are baked, not authored"},
	{"_quadratic_attn", .Drop, "", "Source attenuation constants are baked, not authored"},
	{"_linear_attn", .Drop, "", "Source attenuation constants are baked, not authored"},
	{"_constant_attn", .Drop, "", "Source attenuation constants are baked, not authored"},
	{"style", .Drop, "", "light styles do not exist in Unreal 3"},
	{"angles", .Source_Angles, "", "Source pitch/yaw/roll converted to an Unreal rotator"},
	{"targetname", .Copy, "Tag", "the name is preserved; no I/O relationship is created"},
	{"model", .Asset_Reference, "", "the model asset is not converted"},
	{"spawnflags", .Drop, "", "spawn flags are class-specific and have no generic Unreal counterpart"},
	{"rendermode", .Drop, "", "render modes are not converted"},
	{"renderamt", .Drop, "", "render amounts are not converted"},
	{"rendercolor", .Drop, "", "render colours are not converted"},
	{"renderfx", .Drop, "", "render effects are not converted"},
	{"disablereceiveshadows", .Drop, "", "shadow receive flags are not converted"},
}

// UNREAL_TO_SOURCE_PROPERTIES is the reverse table.
UNREAL_TO_SOURCE_PROPERTIES :: []Property_Rule {
	{"brightness", .Unreal_Light, "", "Unreal brightness re-expressed on the Source 0..2000 scale"},
	{"lightcolor", .Unreal_Light, "", "colour mapped exactly"},
	{"attenuationradius", .Unreal_Light_Shape, "_distance", "radius in centimetres converted to Source units"},
	{"innerconeangle", .Unreal_Light_Shape, "_inner_cone", "radians converted to degrees"},
	{"outerconeangle", .Unreal_Light_Shape, "_cone", "radians converted to degrees"},
	{"rotation", .Unreal_Rotation, "", "Unreal rotator converted to Source angles"},
	{"tag", .Copy, "targetname", "the name is preserved; no I/O relationship is created"},
	{"staticmesh", .Copy, "model", "the static mesh asset is not converted; the path is kept"},
	{"drawscale", .Drop, "", "Unreal draw scale has no Source VMF equivalent"},
	{"drawscale3d", .Drop, "", "Unreal draw scale has no Source VMF equivalent"},
	{"prepivot", .Drop, "", "pre-pivot is folded into the actor origin"},
	{"bhiddengame", .Drop, "", "game visibility flags are not converted"},
}

PROFILE_SOURCE_TO_UNREAL := Profile {
	name       = "source1-to-unreal3",
	engine     = "unreal3",
	entities   = DEFAULT_SOURCE_TO_UNREAL,
	properties = SOURCE_TO_UNREAL_PROPERTIES,
	notes      = NOTES_SOURCE_TO_UNREAL,
}

PROFILE_UNREAL_TO_SOURCE := Profile {
	name       = "unreal3-to-source1",
	engine     = "source1",
	entities   = DEFAULT_UNREAL_TO_SOURCE,
	properties = UNREAL_TO_SOURCE_PROPERTIES,
	notes      = NOTES_UNREAL_TO_SOURCE,
}

PROFILE_DEFAULT := Profile {
	name  = "default",
	notes = NOTES_DEFAULT,
}

source_to_unreal :: proc() -> Profile {
	return PROFILE_SOURCE_TO_UNREAL
}

unreal_to_source :: proc() -> Profile {
	return PROFILE_UNREAL_TO_SOURCE
}

by_name :: proc(name: string) -> (Profile, bool) {
	switch strings.to_lower(name) {
	case "", "default":
		return PROFILE_DEFAULT, true
	case "source1-to-unreal3", "source-to-unreal":
		return source_to_unreal(), true
	case "unreal3-to-source1", "unreal-to-source":
		return unreal_to_source(), true
	}
	return {}, false
}

// map_class looks a class name up case-insensitively and reports whether a
// mapping exists. A mapping to the empty string means "do not emit an actor".
map_class :: proc(p: Profile, class_name: string) -> (target: string, mapped: bool, note: string) {
	upper := strings.to_upper(class_name)
	for m in p.entities {
		if strings.to_upper(m.source_class) == upper {
			return m.target_class, true, m.note
		}
	}
	return class_name, false, ""
}

// property_rule finds the rule for a source key, case-insensitively.
property_rule :: proc(p: Profile, key: string) -> (rule: Property_Rule, ok: bool) {
	for r in p.properties {
		if strings.equal_fold(r.key, key) {
			return r, true
		}
	}
	return {}, false
}

// structural_key reports keys that the adapters already consume into typed IR
// fields, so the property mapper must not report them as unmapped.
structural_key :: proc(key: string) -> bool {
	lower := strings.to_lower(key)
	// Adapter bookkeeping, never part of a target format.
	if strings.has_prefix(lower, "source_") || strings.has_prefix(lower, "mapconv.") {
		return true
	}
	switch lower {
	case "id", "classname", "origin", "location", "prepivot", "csgoper":
		return true
	}
	return false
}

describe :: proc(p: Profile) -> string {
	if len(p.entities) == 0 {
		return p.name
	}
	return strings.concatenate({p.name, " (", p.engine, " entity classes)"})
}
