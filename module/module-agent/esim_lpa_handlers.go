//go:build esim_lpa

package main

import ("net/http"; "strings"; "time"; sgp22 "github.com/damonto/euicc-go/v2")

func (a *agent) esimSwitch(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		ICCID string `json:"iccid"`
		AID   string `json:"aid"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if !digitsPattern.MatchString(strings.TrimSpace(body.ICCID)) {
		writeError(response, http.StatusBadRequest, "ICCID 格式无效")
		return
	}
	a.esimMu.Lock()
	defer a.esimMu.Unlock()
	targetAID, profile, err := a.resolveProfileTarget(body.ICCID, body.AID)
	if err != nil {
		writeError(response, http.StatusNotFound, err.Error())
		return
	}
	if profile.ProfileState == sgp22.ProfileEnabled {
		writeJSON(response, http.StatusOK, map[string]any{
			"switch_accepted": true, "phase": "done", "target_iccid": body.ICCID,
			"recovery_pending": false, "module_reboot_requested": false,
		})
		return
	}
	iccid, _ := sgp22.NewICCID(strings.TrimSpace(body.ICCID))
	client, err := a.newLPAClient(targetAID)
	if err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	enableErr := client.EnableProfile(iccid, false)
	closeErr := client.Close()
	if enableErr != nil {
		writeError(response, http.StatusBadGateway, "启用 Profile 失败: "+enableErr.Error())
		return
	}
	if closeErr != nil {
		writeError(response, http.StatusBadGateway, "关闭 eUICC 通道失败: "+closeErr.Error())
		return
	}
	// 先返回 HTTP 结果，再重启基带；否则 iPad 会把预期的 USB 断开误报成切换失败。
	go func() {
		time.Sleep(500 * time.Millisecond)
		_, _ = a.at.command("AT+CFUN=1,1", 3*time.Second)
	}()
	writeJSON(response, http.StatusOK, map[string]any{
		"switch_accepted": true, "phase": "card_reset_settling", "target_iccid": body.ICCID,
		"recovery_pending": true, "module_reboot_requested": true, "reconnect_wait_seconds": 15,
	})
}

func (a *agent) esimProfile(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPatch, http.MethodDelete) {
		return
	}
	var body struct {
		ICCID string `json:"iccid"`
		AID   string `json:"aid"`
		Name  string `json:"name"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if !digitsPattern.MatchString(strings.TrimSpace(body.ICCID)) {
		writeError(response, http.StatusBadRequest, "ICCID 格式无效")
		return
	}
	a.esimMu.Lock()
	defer a.esimMu.Unlock()
	targetAID, profile, err := a.resolveProfileTarget(body.ICCID, body.AID)
	if err != nil {
		writeError(response, http.StatusNotFound, err.Error())
		return
	}
	iccid, _ := sgp22.NewICCID(strings.TrimSpace(body.ICCID))
	client, err := a.newLPAClient(targetAID)
	if err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	defer client.Close()
	switch request.Method {
	case http.MethodPatch:
		name := strings.TrimSpace(body.Name)
		if name == "" || len([]byte(name)) > 64 {
			writeError(response, http.StatusBadRequest, "Profile 名称必须为 1 到 64 字节")
			return
		}
		if err := client.SetNickname(iccid, name); err != nil {
			writeError(response, http.StatusBadGateway, "修改 Profile 名称失败: "+err.Error())
			return
		}
		writeJSON(response, http.StatusOK, map[string]string{"message": "Profile 名称已修改"})
	case http.MethodDelete:
		if profile.ProfileState == sgp22.ProfileEnabled {
			writeError(response, http.StatusConflict, "正在使用的 Profile 不能删除，请先切换到其他 Profile")
			return
		}
		if err := client.DeleteProfile(iccid); err != nil {
			writeError(response, http.StatusBadGateway, "删除 Profile 失败: "+err.Error())
			return
		}
		writeJSON(response, http.StatusOK, map[string]string{"message": "Profile 已删除"})
	}
}

