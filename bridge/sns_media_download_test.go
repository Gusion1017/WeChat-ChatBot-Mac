package main

import (
	"context"
	"encoding/xml"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSNSMediaURLAttributesAndSigning(t *testing.T) {
	raw := `<TimelineObject><ContentObject><mediaList><media><id>1</id><type>2</type>
<url type="1" key="12345678901234567890" token="tok+/=" enc_idx="1">http://szmmsns.qpic.cn/mmsns/abc/150</url>
<thumb type="1" key="12345678901234567890" token="thumbtok" enc_idx="1">http://szmmsns.qpic.cn/mmsns/abc/150</thumb>
</media></mediaList></ContentObject></TimelineObject>`
	var obj SNSTimelineObject
	if err := xml.Unmarshal([]byte(raw), &obj); err != nil {
		t.Fatal(err)
	}
	media := obj.ContentObject.MediaList.Media[0]
	if media.URL.Token != "tok+/=" || media.URL.Key == "" || media.URL.EncIdx != "1" {
		t.Fatalf("url attrs lost: %+v", media.URL)
	}
	full, token, key := snsMediaURLAndToken(media, "full")
	if !strings.HasPrefix(full, "https://szmmsns.qpic.cn/") || !strings.HasSuffix(full, "/0") {
		t.Fatalf("full url = %q", full)
	}
	if token != "tok+/=" || key != "12345678901234567890" {
		t.Fatalf("token/key = %q/%q", token, key)
	}
	signed := snsSignedMediaURL(full, token)
	if !strings.Contains(signed, "token=tok%2B%2F%3D") || !strings.HasSuffix(signed, "&idx=1") {
		t.Fatalf("signed = %q", signed)
	}
	thumb, thumbToken, _ := snsMediaURLAndToken(media, "thumb")
	if !strings.HasSuffix(thumb, "/150") || thumbToken != "thumbtok" {
		t.Fatalf("thumb = %q token=%q", thumb, thumbToken)
	}
}

func TestSNSImageMagic(t *testing.T) {
	if !snsImageMagicOK([]byte{0xff, 0xd8, 0xff, 0xe0}) {
		t.Fatal("jpeg magic")
	}
	if !snsImageMagicOK([]byte("\x89PNG\r\n\x1a\nxxxx")) {
		t.Fatal("png magic")
	}
	if snsImageMagicOK([]byte("not-image")) {
		t.Fatal("false positive")
	}
}

func TestSNSImageISAAC64FixtureVector(t *testing.T) {
	cipher := snsMustHex(t, "bde99d22eccb3e5d37a02ca7b140a01c86659c5c894a0ba128245f1bde524003")
	want := "ffd8ffe000104a46494600010100000100010000ffdb0043000c08090a09070c"
	got, err := snsDecryptSNSImage(cipher, "14308171453855278126")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) < 32 || fmt.Sprintf("%x", got[:32]) != want {
		t.Fatalf("decrypt vector mismatch: %x", got[:32])
	}
}

// raw 媒体索引必须与归一化 media[] 对齐（归一化会跳过 type 为空的条目），
// 并且评论/点赞写回包的空 mediaList 不能清掉时间线已缓存的 raw 媒体。
func TestSNSRememberRawMediaIndexAlignment(t *testing.T) {
	snsClearRawMediaForTest()
	t.Cleanup(snsClearRawMediaForTest)

	obj := &SNSTimelineObject{ContentObject: &SNSContentObject{MediaList: &SNSMediaList{
		Media: []SNSMedia{
			{Type: "", URL: SNSMediaURL{Value: "http://example.invalid/skip/0"}},
			{Type: "2", URL: SNSMediaURL{Value: "http://example.invalid/keep/0"},
				Thumb: SNSMediaURL{Value: "http://example.invalid/keep/150"}},
		},
	}}}
	snsRememberRawMedia("42", obj)
	raw, ok := snsLookupRawMedia("42", 0)
	if !ok || raw.Type != "2" || !strings.Contains(raw.URL.Value, "/keep/") {
		t.Fatalf("media_index 0 应指向归一化后的第一张图: %+v ok=%v", raw, ok)
	}
	if _, ok := snsLookupRawMedia("42", 1); ok {
		t.Fatal("type 为空的媒体不应占用索引")
	}

	// 空 mediaList（写回包摘要 XML）不覆盖已缓存的 raw 媒体。
	snsRememberRawMedia("42", &SNSTimelineObject{
		ContentObject: &SNSContentObject{MediaList: &SNSMediaList{}},
	})
	if raw, ok := snsLookupRawMedia("42", 0); !ok || raw.Type != "2" {
		t.Fatalf("空 mediaList 不应清掉已缓存 raw 媒体: %+v ok=%v", raw, ok)
	}
}

func TestSNSDownloadRetriesOnceOnServerError(t *testing.T) {
	var calls int
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "image/jpeg")
		// 最小 JPEG magic，足以通过 snsImageMagicOK。
		_, _ = w.Write([]byte{0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10})
	}))
	defer server.Close()

	oldClient := http.DefaultClient
	http.DefaultClient = server.Client()
	defer func() { http.DefaultClient = oldClient }()

	raw := SNSMedia{URL: SNSMediaURL{Value: server.URL}}
	dest := filepath.Join(t.TempDir(), "thumb.bin")
	file, err := snsDownloadSNSImage(context.Background(), raw, "thumb", dest)
	if err != nil {
		t.Fatalf("下载重试后应成功: %v", err)
	}
	if calls != 2 {
		t.Fatalf("应重试 1 次，实际请求 %d 次", calls)
	}
	if file != dest {
		t.Fatalf("返回路径 = %q", file)
	}
	if info, err := os.Stat(dest); err != nil || info.Size() == 0 {
		t.Fatalf("落盘文件无效: %v", err)
	}
}
