package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// SNS 图片下载：mac 4.2 的媒体 URL 需要 token 认证，响应可能带 x-enc:1。
// token/key 只在内存中使用，不写日志。解密算法确认前，加密响应的下载会显式失败，
// 不会把加密数据当作图片交给 App。

var (
	snsRawMediaMu sync.Mutex
	snsRawMedia   = map[string][]SNSMedia{}
)

// snsRememberRawMedia 记录动态 XML 里的原始媒体（url/key/token）。
// 只保留会出现在归一化 media[] 里的条目（type 为空的不暴露给 App），保证
// /sns/media 的 media_index 与 post.Media 对齐；空列表不覆盖已缓存的 raw media
// （评论/点赞写回包可能只带摘要 XML，不带媒体）。
func snsRememberRawMedia(postID string, obj *SNSTimelineObject) {
	if obj == nil || obj.ContentObject == nil || obj.ContentObject.MediaList == nil {
		return
	}
	rawList := obj.ContentObject.MediaList.Media
	media := make([]SNSMedia, 0, len(rawList))
	for _, m := range rawList {
		if m.Type == "" {
			continue
		}
		media = append(media, m)
	}
	if len(media) == 0 {
		return
	}
	snsRawMediaMu.Lock()
	defer snsRawMediaMu.Unlock()
	if len(snsRawMedia) > 256 {
		snsRawMedia = map[string][]SNSMedia{}
	}
	snsRawMedia[postID] = media
}

// snsDownloadImageFunc 便于单测替换真实 CDN 下载。
var snsDownloadImageFunc = snsDownloadSNSImage

// snsClearRawMediaForTest 仅供单测清理 raw 媒体缓存（走 legacy RPC 路径的用例）。
func snsClearRawMediaForTest() {
	snsRawMediaMu.Lock()
	snsRawMedia = map[string][]SNSMedia{}
	snsRawMediaMu.Unlock()
}

func snsLookupRawMedia(postID string, index int) (SNSMedia, bool) {
	snsRawMediaMu.Lock()
	defer snsRawMediaMu.Unlock()
	media, ok := snsRawMedia[postID]
	if !ok || index < 0 || index >= len(media) {
		return SNSMedia{}, false
	}
	return media[index], true
}

func snsMediaURLAndToken(raw SNSMedia, variant string) (string, string, string) {
	var u, token, key string
	if variant == "thumb" {
		u, token, key = raw.Thumb.Value, raw.Thumb.Token, raw.Thumb.Key
	} else {
		u, token, key = raw.URL.Value, raw.URL.Token, raw.URL.Key
	}
	u = strings.TrimSpace(u)
	if token == "" {
		token = strings.TrimSpace(raw.Token)
	}
	if key == "" {
		key = strings.TrimSpace(raw.Key)
	}
	if variant == "thumb" && u == "" {
		u = strings.TrimSpace(raw.URL.Value)
		if strings.HasSuffix(u, "/0") {
			u = strings.TrimSuffix(u, "/0") + "/150"
		}
	}
	if variant == "full" && u == "" {
		u = strings.TrimSpace(raw.Thumb.Value)
	}
	if variant == "full" && strings.HasSuffix(u, "/150") {
		u = strings.TrimSuffix(u, "/150") + "/0"
	}
	u = strings.Replace(u, "http://", "https://", 1)
	return u, token, key
}

func snsSignedMediaURL(base, token string) string {
	base = strings.TrimSpace(base)
	if base == "" || token == "" {
		return base
	}
	sep := "?"
	if strings.Contains(base, "?") {
		sep = "&"
	}
	return base + sep + "token=" + url.QueryEscape(token) + "&idx=1"
}

// snsDownloadSNSImage 下载并（在算法就绪时）解密一张图片，返回落盘路径。
// 网络错误/5xx 自动重试一次（CDN 偶发失败常见）；4xx/解密失败不重试。
func snsDownloadSNSImage(ctx context.Context, raw SNSMedia, variant, dest string) (string, error) {
	base, token, key := snsMediaURLAndToken(raw, variant)
	if base == "" {
		return "", errors.New("sns media: empty url")
	}
	signed := snsSignedMediaURL(base, token)
	body, hdr, err := snsFetchMediaBody(ctx, signed)
	if err != nil {
		return "", err
	}
	encrypted := strings.TrimSpace(hdr.Get("x-enc")) == "1" || strings.TrimSpace(key) != ""
	if encrypted {
		dec, decErr := snsDecryptSNSImage(body, key)
		if decErr != nil {
			return "", decErr
		}
		body = dec
	}
	if len(body) < 4 || !snsImageMagicOK(body) {
		return "", errors.New("sns media: not a supported image (decrypt pending/bad key)")
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return "", err
	}
	tmp := dest + ".tmp"
	if err := os.WriteFile(tmp, body, 0o600); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, dest); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	return dest, nil
}

// snsFetchMediaBody 带一次重试的 CDN 下载（仅网络错误/5xx 重试）。
func snsFetchMediaBody(ctx context.Context, signed string) ([]byte, http.Header, error) {
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, signed, nil)
		if err != nil {
			return nil, nil, err
		}
		req.Header.Set("User-Agent", "MicroMessenger Client")
		req.Header.Set("Accept", "*/*")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			lastErr = err
		} else {
			body, readErr := io.ReadAll(io.LimitReader(resp.Body, 20*1024*1024))
			hdr := resp.Header.Clone()
			status := resp.StatusCode
			resp.Body.Close()
			if readErr != nil {
				lastErr = readErr
			} else if status == http.StatusOK {
				return body, hdr, nil
			} else {
				lastErr = fmt.Errorf("sns media: http %d (x-errno=%s)", status, hdr.Get("X-ErrNo"))
				if status < 500 {
					return nil, nil, lastErr // 4xx 不重试
				}
			}
		}
		if attempt == 0 {
			select {
			case <-ctx.Done():
				return nil, nil, ctx.Err()
			case <-time.After(300 * time.Millisecond):
			}
		}
	}
	return nil, nil, lastErr
}

func snsImageMagicOK(b []byte) bool {
	if len(b) >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF {
		return true
	}
	if len(b) >= 8 && string(b[:8]) == "\x89PNG\r\n\x1a\n" {
		return true
	}
	if len(b) >= 6 && (string(b[:6]) == "GIF87a" || string(b[:6]) == "GIF89a") {
		return true
	}
	if len(b) >= 12 && string(b[:4]) == "RIFF" && string(b[8:12]) == "WEBP" {
		return true
	}
	return false
}

// snsDecryptSNSImage 解密 mac 4.2 的 x-enc:1 朋友圈图片：
// ISAAC-64 流密码 XOR（golden 0x9E3779B97F4A7C13、raw big-endian、逆序消费）。
func snsDecryptSNSImage(data []byte, key string) ([]byte, error) {
	if len(data) == 0 {
		return nil, errors.New("sns media: empty encrypted body")
	}
	seedText := strings.TrimSpace(key)
	if seedText == "" {
		return nil, errors.New("sns media: encrypted body without key")
	}
	seed, err := strconv.ParseUint(seedText, 10, 64)
	if err != nil {
		// 极少数 key 可能带符号/超出 uint64；按 Python 的 int(...) & 2^64-1 语义处理。
		if strings.HasPrefix(seedText, "-") || strings.ContainsAny(seedText, "0123456789") {
			seed = snsParseSeedMod2_64(seedText)
		} else {
			return nil, fmt.Errorf("sns media: invalid key")
		}
	}
	rng := newSNSIsaac64(seed)
	out := make([]byte, len(data))
	var block [8]byte
	for i := 0; i < len(data); i += 8 {
		binary.BigEndian.PutUint64(block[:], rng.next())
		n := len(data) - i
		if n > 8 {
			n = 8
		}
		for j := 0; j < n; j++ {
			out[i+j] = data[i+j] ^ block[j]
		}
	}
	return snsTrimImagePayload(out), nil
}

func snsParseSeedMod2_64(text string) uint64 {
	var v uint64
	neg := strings.HasPrefix(text, "-")
	text = strings.TrimPrefix(text, "-")
	for _, r := range text {
		if r < '0' || r > '9' {
			return 0
		}
		v = v*10 + uint64(r-'0') // 自然溢出 = mod 2^64
	}
	if neg {
		v = -v
	}
	return v
}

// snsTrimImagePayload 去掉 CDN 在图片容器后附加的 trailer（JPEG 以 FF D9 结尾）。
func snsTrimImagePayload(b []byte) []byte {
	if len(b) >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF {
		for i := len(b) - 2; i >= 2; i-- {
			if b[i] == 0xFF && b[i+1] == 0xD9 {
				return b[:i+2]
			}
		}
	}
	return b
}

// snsIsaac64 是 mac 微信使用的 ISAAC-64 变体（golden c13）。
type snsIsaac64 struct {
	mm         [256]uint64
	randrsl    [256]uint64
	aa, bb, cc uint64
	cnt        int
}

const snsISAACGolden uint64 = 0x9E3779B97F4A7C13

func newSNSIsaac64(seed uint64) *snsIsaac64 {
	r := &snsIsaac64{}
	r.randrsl[0] = seed
	r.init()
	return r
}

func (r *snsIsaac64) mix(a, b, c, d, e, f, g, h uint64) (uint64, uint64, uint64, uint64, uint64, uint64, uint64, uint64) {
	a -= e
	f ^= h >> 9
	h += a
	b -= f
	g ^= a << 9
	a += b
	c -= g
	h ^= b >> 23
	b += c
	d -= h
	a ^= c << 15
	c += d
	e -= a
	b ^= d >> 14
	d += e
	f -= b
	c ^= e << 20
	e += f
	g -= c
	d ^= f >> 17
	f += g
	h -= d
	e ^= g << 14
	g += h
	return a, b, c, d, e, f, g, h
}

func (r *snsIsaac64) init() {
	a, b, c, d, e, f, g, h := snsISAACGolden, snsISAACGolden, snsISAACGolden, snsISAACGolden,
		snsISAACGolden, snsISAACGolden, snsISAACGolden, snsISAACGolden
	for i := 0; i < 4; i++ {
		a, b, c, d, e, f, g, h = r.mix(a, b, c, d, e, f, g, h)
	}
	for i := 0; i < 256; i += 8 {
		a += r.randrsl[i]
		b += r.randrsl[i+1]
		c += r.randrsl[i+2]
		d += r.randrsl[i+3]
		e += r.randrsl[i+4]
		f += r.randrsl[i+5]
		g += r.randrsl[i+6]
		h += r.randrsl[i+7]
		a, b, c, d, e, f, g, h = r.mix(a, b, c, d, e, f, g, h)
		r.mm[i], r.mm[i+1], r.mm[i+2], r.mm[i+3] = a, b, c, d
		r.mm[i+4], r.mm[i+5], r.mm[i+6], r.mm[i+7] = e, f, g, h
	}
	for i := 0; i < 256; i += 8 {
		a += r.mm[i]
		b += r.mm[i+1]
		c += r.mm[i+2]
		d += r.mm[i+3]
		e += r.mm[i+4]
		f += r.mm[i+5]
		g += r.mm[i+6]
		h += r.mm[i+7]
		a, b, c, d, e, f, g, h = r.mix(a, b, c, d, e, f, g, h)
		r.mm[i], r.mm[i+1], r.mm[i+2], r.mm[i+3] = a, b, c, d
		r.mm[i+4], r.mm[i+5], r.mm[i+6], r.mm[i+7] = e, f, g, h
	}
	r.generate()
	r.cnt = 256
}

func (r *snsIsaac64) generate() {
	r.cc++
	r.bb += r.cc
	for i := 0; i < 256; i++ {
		x := r.mm[i]
		switch i & 3 {
		case 0:
			r.aa ^= (r.aa << 21) ^ ^uint64(0)
		case 1:
			r.aa ^= r.aa >> 5
		case 2:
			r.aa ^= r.aa << 12
		default:
			r.aa ^= r.aa >> 33
		}
		r.aa += r.mm[(i+128)&255]
		y := r.mm[(x>>3)&255] + r.aa + r.bb
		r.mm[i] = y
		r.bb = r.mm[(y>>11)&255] + x
		r.randrsl[i] = r.bb
	}
}

func (r *snsIsaac64) next() uint64 {
	if r.cnt == 0 {
		r.generate()
		r.cnt = 256
	}
	r.cnt--
	return r.randrsl[r.cnt]
}
