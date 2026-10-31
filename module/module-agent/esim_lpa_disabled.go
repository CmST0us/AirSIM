//go:build !esim_lpa

package main

import "net/http"

func (a *agent) readESIMOverview() (moduleESIMOverview, error) {
 return moduleESIMOverview{}, errLPADisabled
}

func (a *agent) esimSwitch(w http.ResponseWriter, r *http.Request) {
 if requireMethod(w, r, http.MethodPost) { a.unsupported(w, errLPADisabled.Error()) }
}

func (a *agent) esimProfile(w http.ResponseWriter, r *http.Request) {
 if requireMethod(w, r, http.MethodPatch, http.MethodDelete) { a.unsupported(w, errLPADisabled.Error()) }
}
