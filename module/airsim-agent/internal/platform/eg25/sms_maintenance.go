package eg25

import (
	"context"
	"errors"
)

// ClearStoredME is called only by the maintenance CLI while it holds both
// Agent instance locks and the AT device lock. Never invoke it from polling.
func ClearStoredME(ctx context.Context, port Controller, expectedUsed, expectedTotal int) (SMSStorageReport, error) {
	if expectedUsed < 1 || expectedTotal < expectedUsed {
		return SMSStorageReport{}, errors.New("confirmation_required")
	}
	read := func() (SMSStorageReport, error) {
		lines, err := port.Query(ctx, "AT+CPMS?")
		if err != nil {
			return SMSStorageReport{}, err
		}
		return parseSMSStorage(lines)
	}
	before, err := read()
	if err != nil {
		return before, err
	}
	for _, store := range []*SMSStorage{before.Read, before.Receive} {
		if store == nil || store.Name != "ME" || store.Used != expectedUsed || store.Total != expectedTotal {
			return before, errors.New("storage_changed")
		}
	}
	if _, err = port.Command(ctx, "AT+CMGD=1,4", ""); err != nil {
		// No automatic retry: even an error can leave the outcome uncertain.
		return before, errors.New("clear_not_confirmed")
	}
	return read()
}
