package main

import ("errors"; "fmt"; "regexp"; "strings")

var errLPADisabled = errors.New("eSIM LPA not included in this build")

var cglaResponsePattern = regexp.MustCompile(`\+CGLA:\s*\d+\s*,\s*"?([0-9A-Fa-f]+)"?`)

type moduleEUICCInfo struct {
	AID       string `json:"aid"`
	EID       string `json:"eid"`
	SpecGuess string `json:"spec_guess,omitempty"`
	InfoError string `json:"info_error,omitempty"`
}

type moduleESIMChipInfo struct {
	EIDs []moduleEUICCInfo `json:"eids"`
}

type moduleESIMProfile struct {
	ICCID               string `json:"iccid"`
	Name                string `json:"name"`
	ServiceProviderName string `json:"service_provider_name"`
	State               int    `json:"state"`
	StateText           string `json:"state_text"`
	ClassText           string `json:"class_text,omitempty"`
}

type moduleESIMProfileGroup struct {
	EID      string              `json:"eid"`
	AIDHex   string              `json:"aid_hex"`
	Profiles []moduleESIMProfile `json:"profiles"`
}

type moduleESIMOverview struct {
	CardType string                   `json:"card_type"`
	Message  string                   `json:"message,omitempty"`
	ChipInfo moduleESIMChipInfo       `json:"chip_info"`
	Profiles []moduleESIMProfileGroup `json:"profiles"`
}

func normalizeKnownEUICCAID(value string) (string, error) {
	normalized := strings.ToUpper(strings.TrimSpace(value))
	if normalized == "" {
		return "", nil
	}
	for _, candidate := range euiccAIDs {
		if normalized == candidate {
			return normalized, nil
		}
	}
	return "", fmt.Errorf("AID 不在已验证的 eUICC 列表中: %s", normalized)
}

