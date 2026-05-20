package backends

// All returns all built-in adapters.
func All() []Adapter {
	return []Adapter{&Claude{}, &Copilot{}, &OpenCode{}, &Pi{}}
}

// Detected returns only adapters whose binary is installed.
func Detected() []Adapter {
	all := All()
	result := make([]Adapter, 0, len(all))
	for _, a := range all {
		if a.Detect() {
			result = append(result, a)
		}
	}
	return result
}
