package at

import "os"

// FencePresent fails closed for any result other than a definite missing file.
func FencePresent(path string) bool { _, e := os.Lstat(path); return !os.IsNotExist(e) }
