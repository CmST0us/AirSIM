//go:build esim_lpa

package main

import ("testing"; sgp22 "github.com/damonto/euicc-go/v2")

func TestProfilePayloadKeepsEUICCState(t *testing.T) {
	iccid, err := sgp22.NewICCID("8944305293607172968")
	if err != nil {
		t.Fatal(err)
	}
	payload := profilePayload(&sgp22.ProfileInfo{
		ICCID:               iccid,
		ProfileState:        sgp22.ProfileEnabled,
		ProfileNickname:     "CTExcel eSIM",
		ServiceProviderName: "CTExcel",
		ProfileClass:        sgp22.ProfileClassOperational,
	})
	if payload.ICCID != "8944305293607172968" || payload.State != 1 || payload.StateText != "已启用" {
		t.Fatalf("Profile 映射错误: %#v", payload)
	}
}

