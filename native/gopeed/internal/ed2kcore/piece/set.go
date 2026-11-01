package piece

// Set marks which parts of a file someone has, indexed by part; its length is
// the file's PartCount.
type Set []bool

func BuildFullSet(partCount int) Set {
	set := make(Set, partCount)
	for i := range set {
		set[i] = true
	}
	return set
}

func (s Set) Count() int {
	count := 0
	for _, has := range s {
		if has {
			count++
		}
	}
	return count
}

func (s Set) IsFull() bool {
	return s.Count() == len(s)
}
