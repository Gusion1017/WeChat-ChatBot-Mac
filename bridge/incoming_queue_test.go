package main

// 本文件覆盖入站事件串行化（task-7）：runIncomingWorker 必须按入队顺序逐条处理，
// 且单条事件 panic 不能终止 worker（否则整条入站链路永久停摆）。
// 相关实现见 incoming.go；生产调用方是 main.go 的 incoming_message 分支。

import (
	"testing"
	"time"
)

func TestRunIncomingWorkerPreservesOrderAndSeriality(t *testing.T) {
	ch := make(chan map[string]interface{}, 16)
	done := make(chan struct{})

	var got []int
	active := 0
	overlapped := false
	handle := func(payload map[string]interface{}) {
		if active != 0 {
			overlapped = true
		}
		active++
		// 故意拉长单条处理时间：若 worker 不是串行，后一条会在这里并发进入。
		time.Sleep(2 * time.Millisecond)
		got = append(got, payload["seq"].(int))
		active--
	}

	go func() {
		runIncomingWorker(ch, handle)
		close(done)
	}()

	for i := 0; i < 8; i++ {
		ch <- map[string]interface{}{"seq": i}
	}
	close(ch)
	<-done

	if overlapped {
		t.Fatal("事件被并发处理（worker 不是串行）")
	}
	if len(got) != 8 {
		t.Fatalf("处理条数 = %d, want 8", len(got))
	}
	for i, seq := range got {
		if seq != i {
			t.Fatalf("第 %d 条事件 seq = %d, want %d（顺序被打乱）", i, seq, i)
		}
	}
}

func TestRunIncomingWorkerRecoversFromPanic(t *testing.T) {
	ch := make(chan map[string]interface{}, 4)
	done := make(chan struct{})

	var got []int
	handle := func(payload map[string]interface{}) {
		seq := payload["seq"].(int)
		if seq == 0 {
			panic("模拟单条事件解析失败")
		}
		got = append(got, seq)
	}

	go func() {
		runIncomingWorker(ch, handle)
		close(done)
	}()

	ch <- map[string]interface{}{"seq": 0}
	ch <- map[string]interface{}{"seq": 1}
	close(ch)
	<-done

	if len(got) != 1 || got[0] != 1 {
		t.Fatalf("panic 后 worker 未继续消费: got=%v want [1]", got)
	}
}
