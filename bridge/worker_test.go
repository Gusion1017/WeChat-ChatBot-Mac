package main

// 回包投递契约：Frida 回调派生出的 goroutine 在「发送已超时/R3 跳过等待」后
// 没有消费者，投递必须是非阻塞的，否则每个迟到回包都会永久泄漏一个 goroutine
// 并占住回包数据。这里用局部 channel 覆盖满队列场景。

import (
	"testing"
	"time"
)

func TestPostBuf2RespDropsWhenQueueFull(t *testing.T) {
	ch := make(chan *Buf2RespData, 1)
	ch <- &Buf2RespData{MsgType: "first"}

	done := make(chan struct{})
	go func() {
		postBuf2RespTo(ch, &Buf2RespData{MsgType: "late"})
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("队列已满时 postBuf2RespTo 阻塞（迟到回包会泄漏 goroutine）")
	}
	if got := (<-ch).MsgType; got != "first" {
		t.Fatalf("队列里应保留先到的回包，实际 %q", got)
	}
}

func TestPostBuf2RespDeliversWhenQueueHasRoom(t *testing.T) {
	ch := make(chan *Buf2RespData, 1)
	postBuf2RespTo(ch, &Buf2RespData{MsgType: "text"})
	select {
	case got := <-ch:
		if got.MsgType != "text" {
			t.Fatalf("msg_type = %q, want text", got.MsgType)
		}
	case <-time.After(time.Second):
		t.Fatal("队列有空位时回包应投递成功")
	}
}

func TestPostAppAttachRespDropsWhenQueueFull(t *testing.T) {
	ch := make(chan []byte, 1)
	ch <- []byte("first")
	done := make(chan struct{})
	go func() {
		postAppAttachRespTo(ch, []byte("late"))
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("队列已满时 postAppAttachRespTo 阻塞")
	}
	if got := string(<-ch); got != "first" {
		t.Fatalf("队列里应保留先到的回包，实际 %q", got)
	}
}
