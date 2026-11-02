package eg25

import (
	"context"
	"errors"
	"fmt"
	"log"
	"sort"
)

// reclaimSMS frees a small batch only when the selected receive store is full.
// It deletes whole, previously decoded messages in service-centre timestamp
// order. Partial/undecodable messages and this poll's new arrivals are retained.
// App history is independent and is never removed by this operation.
func (s *Session) reclaimSMS(ctx context.Context, messages []receivedSMS) (int, error) {
	var candidates []receivedSMS
	for _, m := range messages {
		if s.previousSMS[m.key] && len(m.indices) > 0 && !m.receivedAt.IsZero() {
			candidates = append(candidates, m)
		}
	}
	if len(candidates) == 0 {
		return 0, nil
	}
	lines, err := s.at.Query(ctx, "AT+CPMS?")
	if err != nil {
		return 0, err
	}
	storage, err := parseSMSStorage(lines)
	if err != nil {
		return 0, err
	}
	r := storage.Read
	if r.Used < r.Total || r.Total == 0 {
		return 0, nil
	}
	if r.Name != storage.Receive.Name {
		return 0, errors.New("storage_mismatch")
	}
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].receivedAt.Before(candidates[j].receivedAt) })
	target := r.Total / 4
	if target < 1 {
		target = 1
	}
	if target > 8 {
		target = 8
	}
	deleted := map[int]bool{}
	for _, m := range candidates {
		for _, index := range m.indices {
			if deleted[index] {
				continue
			}
			if _, err = s.at.Command(ctx, fmt.Sprintf("AT+CMGD=%d", index), ""); err != nil {
				return len(deleted), err
			}
			deleted[index] = true
		}
		if len(deleted) >= target {
			break
		}
	}
	if len(deleted) > 0 {
		log.Printf("eg25 sms storage reclaimed: records=%d", len(deleted))
	}
	return len(deleted), nil
}
