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

Profile :: struct {
	name:      string,
	engine:    string,
	entities:  []Mapping,
	materials: []Mapping,
	notes:     []string,
}

// DEFAULT_SOURCE_TO_UNREAL maps Source 1 entity classes to the closest Unreal
// Engine 3 actor class. These are *class hints*: a mapped class is not
// behaviourally equivalent, and the conversion report says so.
DEFAULT_SOURCE_TO_UNREAL :: []Mapping {
	{"WORLDSPAWN", "", "world brushes become Brush actors"},
	{"INFO_PLAYER_START", "PlayerStart", "spawn point"},
	{"INFO_PLAYER_TERRORIST", "PlayerStart", "team spawn collapses to PlayerStart"},
	{"INFO_PLAYER_COUNTER_TERRORIST", "PlayerStart", "team spawn collapses to PlayerStart"},
	{"LIGHT", "PointLight", "light entity; brightness/colour need remapping"},
	{"LIGHT_SPOT", "SpotLight", "spot light"},
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
	{"POINTLIGHT", "light", "brightness/colour need remapping"},
	{"SPOTLIGHT", "light_spot", "spot light"},
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

PROFILE_SOURCE_TO_UNREAL := Profile {
	name     = "source1-to-unreal3",
	engine   = "unreal3",
	entities = DEFAULT_SOURCE_TO_UNREAL,
	notes    = NOTES_SOURCE_TO_UNREAL,
}

PROFILE_UNREAL_TO_SOURCE := Profile {
	name     = "unreal3-to-source1",
	engine   = "source1",
	entities = DEFAULT_UNREAL_TO_SOURCE,
	notes    = NOTES_UNREAL_TO_SOURCE,
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

describe :: proc(p: Profile) -> string {
	if len(p.entities) == 0 {
		return p.name
	}
	return strings.concatenate({p.name, " (", p.engine, " entity classes)"})
}
