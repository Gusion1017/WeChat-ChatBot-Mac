package main

import "testing"

// normalizeListenAddr 覆盖 -receive_host 的绑定收敛：
// 空 host（":58080"）原本会监听所有网卡，必须收敛到 127.0.0.1；
// 显式非回环地址仍保留，但 loopback=false 供 main 告警。
func TestNormalizeListenAddr(t *testing.T) {
	cases := []struct {
		in       string
		wantAddr string
		wantLoop bool
	}{
		{"", "127.0.0.1:58080", true},
		{":58080", "127.0.0.1:58080", true},
		{"127.0.0.1:58080", "127.0.0.1:58080", true},
		{"localhost:58080", "localhost:58080", true},
		{"[::1]:58080", "[::1]:58080", true},
		{"0.0.0.0:58080", "0.0.0.0:58080", false},
		{"192.168.1.5:58080", "192.168.1.5:58080", false},
		{"not-an-address", "not-an-address", false},
	}
	for _, tc := range cases {
		gotAddr, gotLoop := normalizeListenAddr(tc.in)
		if gotAddr != tc.wantAddr || gotLoop != tc.wantLoop {
			t.Errorf("normalizeListenAddr(%q) = (%q, %v), want (%q, %v)",
				tc.in, gotAddr, gotLoop, tc.wantAddr, tc.wantLoop)
		}
	}
}
