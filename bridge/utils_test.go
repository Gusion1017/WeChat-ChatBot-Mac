package main

import (
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestFileToBase64(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sample.txt")
	if err := os.WriteFile(path, []byte("hello"), 0o600); err != nil {
		t.Fatalf("写入临时文件失败: %v", err)
	}

	got, err := FileToBase64(path)
	if err != nil {
		t.Fatalf("FileToBase64 失败: %v", err)
	}
	const want = "aGVsbG8="
	if got != want {
		t.Fatalf("base64 结果错误: got %q, want %q", got, want)
	}

	if _, err := FileToBase64(filepath.Join(dir, "missing.txt")); err == nil {
		t.Fatal("读取不存在的文件应当返回错误")
	}
}

// TestOutgoingMediaPath 覆盖出站媒体落盘路径拼接：App 传的 -image_path 来自
// 目录 URL 的 .path（末尾没有 "/"），旧实现 ImagePath+fileName 会把文件写成
// 目录同级的 "temp123_456.png"。
func TestOutgoingMediaPath(t *testing.T) {
	cases := []struct {
		name string
		dir  string
		file string
		want string
	}{
		{name: "空目录保持旧行为", dir: "", file: "1_2.png", want: "1_2.png"},
		{name: "带斜杠", dir: "/w/temp/", file: "1_2.png", want: "/w/temp/1_2.png"},
		{name: "不带斜杠", dir: "/w/temp", file: "1_2.png", want: "/w/temp/1_2.png"},
		{name: "两端空白", dir: "  /w/temp  ", file: "1_2.png", want: "/w/temp/1_2.png"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := outgoingMediaPath(tc.dir, tc.file); got != tc.want {
				t.Fatalf("outgoingMediaPath(%q, %q) = %q, want %q", tc.dir, tc.file, got, tc.want)
			}
		})
	}
}

// TestSaveBase64ImageWritesIntoImageDirWithoutSlash 是上面路径 bug 的端到端回归：
// 目录末尾没有 "/" 时也必须把文件写进该目录。
func TestSaveBase64ImageWritesIntoImageDirWithoutSlash(t *testing.T) {
	oldPath := config.ImagePath
	dir := t.TempDir() // t.TempDir 返回的路径末尾没有 "/"，与 App 的 -image_path 一致
	config.ImagePath = dir
	t.Cleanup(func() { config.ImagePath = oldPath })

	// PNG 魔数（走 DetectFileFormat 的 png 分支），后面补足数据。
	header := []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}
	payload := base64.StdEncoding.EncodeToString(append(header, []byte(strings.Repeat("x", 48))...))
	path, md5Hex, err := SaveBase64Image(payload)
	if err != nil {
		t.Fatalf("SaveBase64Image 失败: %v", err)
	}
	if got := filepath.Dir(path); got != dir {
		t.Fatalf("文件应写进 -image_path 目录: dir=%q, got=%q, path=%q", dir, got, path)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("落盘文件不存在: %v", err)
	}
	if len(md5Hex) != 32 {
		t.Fatalf("md5 = %q, want 32 位 hex", md5Hex)
	}
}

// TestDownloadFileUsesTimeout 覆盖 legacy 入站媒体下载：零值 http.Client（无超时）
// 会让 CDN 卡住时 HandleMsg 派生出的 goroutine 永久挂起（入站表情走这条路径）。
func TestDownloadFileUsesTimeout(t *testing.T) {
	old := mediaDownloadClient
	mediaDownloadClient = &http.Client{Timeout: 50 * time.Millisecond}
	t.Cleanup(func() { mediaDownloadClient = old })

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(300 * time.Millisecond)
		_, _ = w.Write([]byte("late"))
	}))
	defer srv.Close()

	started := time.Now()
	if _, err := DownloadFile(srv.URL); err == nil {
		t.Fatal("超时的下载应返回错误")
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("下载超时未生效，耗时 %v", elapsed)
	}

	// 空 URL / 非法 URL 仍按参数错误处理，不发请求。
	if _, err := DownloadFile(""); err == nil {
		t.Fatal("空 URL 应返回错误")
	}
	if _, err := DownloadFile("://bad"); err == nil {
		t.Fatal("非法 URL 应返回错误")
	}
}
