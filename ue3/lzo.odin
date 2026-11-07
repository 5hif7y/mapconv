// LZO1X decompression (state machine written from the format description).
//
// The decoder follows the layout UE3 uses for BULKDATA_CompressedLzo: literal
// runs, matches of 2..N bytes, and the special three-byte match after every
// literal run. After a match the length of the following literal run is stored
// in the low two bits of the second offset byte, not in a separate byte.
package ue3

LZO_EOF :: 0

lzo1x_decompress :: proc(src: []u8, dst: []u8) -> (out_len: int, ok: bool) {
	ip := 0
	op := 0
	n := len(src)

	byte_at :: proc(src: []u8, ip: ^int) -> u8 {
		v := src[ip^]
		ip^ += 1
		return v
	}
	literals :: proc(src: []u8, ip: ^int, dst: []u8, op: ^int, count: int) -> bool {
		if ip^ + count > len(src) || op^ + count > len(dst) {
			return false
		}
		copy(dst[op^:op^ + count], src[ip^:ip^ + count])
		ip^ += count
		op^ += count
		return true
	}
	copy_match :: proc(dst: []u8, op: ^int, source: int, count: int) -> bool {
		from := source
		if from < 0 || from >= op^ || op^ + count > len(dst) {
			return false
		}
		for _ in 0..<count {
			dst[op^] = dst[from]
			op^ += 1
			from += 1
		}
		return true
	}

	state := 0 // 0 = read selector, 1 = first literal run, 2 = match, 3 = match done, 4 = pending t
	t: int
	if n == 0 {
		return 0, false
	}
	t = int(byte_at(src, &ip))
	if t > 17 {
		t -= 17
		if t < 4 {
			if !literals(src, &ip, dst, &op, t) {
				return op, false
			}
			t = int(byte_at(src, &ip))
			state = 2
		} else {
			if !literals(src, &ip, dst, &op, t) {
				return op, false
			}
			state = 1
		}
	} else {
		state = 4
	}

	for {
		switch state {
		case 0:
			if ip >= n {
				return op, true
			}
			t = int(byte_at(src, &ip))
			if t >= 16 {
				state = 2
				continue
			}
			if t == 0 {
				for src[ip] == 0 {
					t += 255
					ip += 1
				}
				t += 15 + int(byte_at(src, &ip))
			}
			if !literals(src, &ip, dst, &op, t + 3) {
				return op, false
			}
			state = 1
		case 4:
			if t >= 16 {
				state = 2
				continue
			}
			if t == 0 {
				for src[ip] == 0 {
					t += 255
					ip += 1
				}
				t += 15 + int(byte_at(src, &ip))
			}
			if !literals(src, &ip, dst, &op, t + 3) {
				return op, false
			}
			state = 1
		case 1:
			if ip >= n {
				return op, true
			}
			t = int(byte_at(src, &ip))
			if t >= 16 {
				state = 2
				continue
			}
			from := op - (1 + 0x800) - (t >> 2) - int(byte_at(src, &ip)) << 2
			if !copy_match(dst, &op, from, 3) {
				return op, false
			}
			state = 3
		case 2:
			length: int
			from: int
			switch {
			case t >= 64:
				length = (t >> 5) + 1
				from = op - 1 - ((t >> 2) & 7) - int(byte_at(src, &ip)) << 3
			case t >= 32:
				length = t & 31
				if length == 0 {
					for src[ip] == 0 {
						length += 255
						ip += 1
					}
					length += 31 + int(byte_at(src, &ip))
				}
				lo := int(byte_at(src, &ip))
				hi := int(byte_at(src, &ip))
				from = op - 1 - ((lo | (hi << 8)) >> 2)
				length += 2
			case t >= 16:
				from = op - ((t & 8) << 11)
				length = t & 7
				if length == 0 {
					for src[ip] == 0 {
						length += 255
						ip += 1
					}
					length += 7 + int(byte_at(src, &ip))
				}
				lo := int(byte_at(src, &ip))
				hi := int(byte_at(src, &ip))
				from -= (lo | (hi << 8)) >> 2
				if from == op {
					return op, true // end of stream
				}
				from -= 0x4000
				length += 2
			case:
				from = op - 1 - (t >> 2) - int(byte_at(src, &ip)) << 2
				length = 2
			}
			if !copy_match(dst, &op, from, length) {
				return op, false
			}
			state = 3
		case 3:
			if ip < 2 {
				return op, false
			}
			t = int(src[ip - 2]) & 3
			if t == 0 {
				state = 0
				continue
			}
			if !literals(src, &ip, dst, &op, t) {
				return op, false
			}
			if ip >= n {
				return op, true
			}
			t = int(byte_at(src, &ip))
			state = 2
		}
	}
}
