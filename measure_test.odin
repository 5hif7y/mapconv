package main

import "core:encoding/json"
import "core:strings"
import "core:testing"

// The measurement is what a regression is checked against, so the checks are about the
// comparison itself: a document that survives a round trip, and every kind of fall that
// the diff must refuse to call "no regression".

measure_fixture :: proc(path: string, bytes, interpreted, uninterpreted: i64) -> Measure {
	return Measure {
		path          = path,
		format        = "bsp",
		bytes         = bytes,
		interpreted   = interpreted,
		uninterpreted = uninterpreted,
		lumps         = 42,
		lightmap_blocks = 100,
		luxels        = 1000,
	}
}

@(test)
test_a_document_survives_a_round_trip :: proc(t: ^testing.T) {
	files := []Measure {
		measure_fixture("a/b/de_nuke.bsp", 1000, 998, 2),
		measure_fixture("a/c/de_dust2.bsp", 2000, 2000, 0),
	}
	document := measure_document(files)
	defer measure_destroy(&document)
	testing.expect_value(t, len(document.files), 2)
	testing.expect_value(t, document.totals.bytes, i64(3000))
	testing.expect_value(t, document.totals.uninterpreted, i64(2))

	data, err := json.marshal(document, {pretty = true})
	testing.expectf(t, err == nil, "marshal failed: %v", err)
	defer delete(data)

	back: Measure_Document
	unmarshal_err := json.unmarshal(data, &back)
	testing.expectf(t, unmarshal_err == nil, "unmarshal failed: %v", unmarshal_err)
	defer measure_destroy(&back)
	testing.expectf(t, len(back.files) == 2, "the file list did not survive, got %d", len(back.files))
	testing.expect_value(t, back.schema, MEASURE_SCHEMA)
	testing.expect_value(t, back.files[0].interpreted, i64(998))
	testing.expect_value(t, back.files[1].path, "a/c/de_dust2.bsp")
}

@(test)
test_the_diff_refuses_a_file_that_interprets_less :: proc(t: ^testing.T) {
	before := []Measure{measure_fixture("x/de_tides.bsp", 1000, 1000, 0)}
	after := []Measure{measure_fixture("x/de_tides.bsp", 1000, 996, 0)}
	baseline := measure_document(before)
	defer measure_destroy(&baseline)
	current := measure_document(after)
	defer measure_destroy(&current)

	regressions := diff_documents(&baseline, &current)
	defer {
		for regression in regressions {
			delete(regression.path)
			delete(regression.detail)
		}
		delete(regressions)
	}
	testing.expectf(t, len(regressions) == 1, "expected one regression, got %d", len(regressions))
	testing.expect(t, strings.contains(regressions[0].detail, "interpreted"))
}

@(test)
test_the_diff_refuses_a_file_that_leaves_more_uninterpreted :: proc(t: ^testing.T) {
	before := []Measure{measure_fixture("x/de_nuke.bsp", 1000, 1000, 0)}
	after := []Measure{measure_fixture("x/de_nuke.bsp", 1000, 998, 2)}
	baseline := measure_document(before)
	defer measure_destroy(&baseline)
	current := measure_document(after)
	defer measure_destroy(&current)
	regressions := diff_documents(&baseline, &current)
	defer {
		for regression in regressions {
			delete(regression.path)
			delete(regression.detail)
		}
		delete(regressions)
	}
	// The bytes partition, so losing 2 interpreted bytes is also leaving 2 more
	// uninterpreted: both are reported, and the file is named in each.
	testing.expectf(t, len(regressions) == 2, "expected two regressions, got %d", len(regressions))
	found := false
	for regression in regressions {
		if strings.contains(regression.detail, "uninterpreted") {
			found = true
		}
	}
	testing.expect(t, found, "no regression names the uninterpreted bytes")
}

@(test)
test_the_diff_refuses_a_counter_that_falls :: proc(t: ^testing.T) {
	before := []Measure{measure_fixture("x/de_prodigy.bsp", 1000, 1000, 0)}
	after := []Measure{measure_fixture("x/de_prodigy.bsp", 1000, 1000, 0)}
	after[0].luxels = 999
	baseline := measure_document(before)
	defer measure_destroy(&baseline)
	current := measure_document(after)
	defer measure_destroy(&current)
	regressions := diff_documents(&baseline, &current)
	defer {
		for regression in regressions {
			delete(regression.path)
			delete(regression.detail)
		}
		delete(regressions)
	}
	testing.expectf(t, len(regressions) == 1, "expected one regression, got %d", len(regressions))
	testing.expect(t, strings.contains(regressions[0].detail, "luxels"))
}

@(test)
test_a_file_that_changed_its_bytes_is_not_a_regression :: proc(t: ^testing.T) {
	// The corpus can change. A file whose size changed is a different measurement, and
	// comparing its numbers would report a regression that says nothing.
	before := []Measure{measure_fixture("x/a.bsp", 1000, 1000, 0)}
	after := []Measure{measure_fixture("x/a.bsp", 2000, 1500, 0)}
	baseline := measure_document(before)
	defer measure_destroy(&baseline)
	current := measure_document(after)
	defer measure_destroy(&current)
	regressions := diff_documents(&baseline, &current)
	defer {
		for regression in regressions {
			delete(regression.path)
			delete(regression.detail)
		}
		delete(regressions)
	}
	testing.expect_value(t, len(regressions), 0)
}

@(test)
test_a_file_missing_from_the_new_measurement_is_a_regression :: proc(t: ^testing.T) {
	before := []Measure {
		measure_fixture("x/a.bsp", 1000, 1000, 0),
		measure_fixture("x/b.bsp", 1000, 1000, 0),
	}
	after := []Measure{measure_fixture("x/a.bsp", 1000, 1000, 0)}
	baseline := measure_document(before)
	defer measure_destroy(&baseline)
	current := measure_document(after)
	defer measure_destroy(&current)
	regressions := diff_documents(&baseline, &current)
	defer {
		for regression in regressions {
			delete(regression.path)
			delete(regression.detail)
		}
		delete(regressions)
	}
	testing.expectf(t, len(regressions) == 1, "expected one regression, got %d", len(regressions))
	testing.expect(t, strings.contains(regressions[0].detail, "missing"))
}
