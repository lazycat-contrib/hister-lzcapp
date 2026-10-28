// ptyexec 在伪终端(PTY)里运行命令，并把标准输入喂给它。
//
// Hister CLI 的 `hister user create --offline --admin` 用 bubbletea 弹出交互式
// 密码提示，而 bubbletea 要求进程拥有控制终端 (/dev/tty)。懒猫微服的容器没有
// TTY，setup_script 也没有交互式 stdin，所以直接调用会失败：
//
//	failed to read password: bubbletea: error opening TTY: could not open TTY: open /dev/tty: no such device or address
//
// ptyexec 分配一个 PTY，把子进程设为该 PTY 的会话首进程并挂上控制终端，
// 然后按行把输入写进 master，最后把 PTY 的输出转发到 stdout。
//
// 用法: ptyexec <输入文件> <命令> [参数...]
//
// 输入文件每行一条输入，行尾用 \n 即可，ptyexec 会按行补上回车。
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"
	"time"
	"unsafe"
)

func ioctl(fd uintptr, req uintptr, arg uintptr) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, req, arg)
	if errno != 0 {
		return errno
	}
	return nil
}

// setRaw 把终端切到 raw 模式，关闭 ICRNL/ICANON/ECHO。
// 这样写入的 "\r" 会原样到达应用，被识别为回车键。
// (bubbletea 自己也会设置 raw，但那发生在启动之后；
//  提前设置可避免行规程把 \r 转成 \n 或在换行前缓存住输入。)
func setRaw(fd uintptr) error {
	var t syscall.Termios
	if err := ioctl(fd, syscall.TCGETS, uintptr(unsafe.Pointer(&t))); err != nil {
		return err
	}
	t.Iflag &^= syscall.IGNBRK | syscall.BRKINT | syscall.PARMRK | syscall.ISTRIP |
		syscall.INLCR | syscall.IGNCR | syscall.ICRNL | syscall.IXON
	t.Oflag &^= syscall.OPOST
	t.Lflag &^= syscall.ECHO | syscall.ECHONL | syscall.ICANON | syscall.ISIG | syscall.IEXTEN
	t.Cflag &^= syscall.CSIZE | syscall.PARENB
	t.Cflag |= syscall.CS8
	t.Cc[syscall.VMIN] = 1
	t.Cc[syscall.VTIME] = 0
	return ioctl(fd, syscall.TCSETS, uintptr(unsafe.Pointer(&t)))
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: ptyexec <input-file> <cmd> [args...]")
		os.Exit(2)
	}

	input, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "read input: %v\n", err)
		os.Exit(1)
	}

	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open ptmx: %v\n", err)
		os.Exit(1)
	}

	var n uint32
	if err := ioctl(master.Fd(), syscall.TIOCGPTN, uintptr(unsafe.Pointer(&n))); err != nil {
		fmt.Fprintf(os.Stderr, "TIOCGPTN: %v\n", err)
		os.Exit(1)
	}
	var unlock int32
	if err := ioctl(master.Fd(), syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock))); err != nil {
		fmt.Fprintf(os.Stderr, "TIOCSPTLCK: %v\n", err)
		os.Exit(1)
	}

	slave, err := os.OpenFile(fmt.Sprintf("/dev/pts/%d", n), os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open pts: %v\n", err)
		os.Exit(1)
	}
	if err := setRaw(slave.Fd()); err != nil {
		fmt.Fprintf(os.Stderr, "set raw: %v\n", err)
		os.Exit(1)
	}

	cmd := exec.Command(os.Args[2], os.Args[3:]...)
	cmd.Stdin = slave
	cmd.Stdout = slave
	cmd.Stderr = slave
	// 让子进程拥有控制终端，这样它打开 /dev/tty 时拿到的是这个 PTY。
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid:  true,
		Setctty: true,
		Ctty:    0,
	}

	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "start: %v\n", err)
		os.Exit(1)
	}
	slave.Close()

	// 把输入写进 PTY master。
	// 按行分批写入并留出间隔: bubbletea 逐个字符解析输入,
	// 一次性灌入可能让回车与前一个字符落在同一个读取批次里被丢弃。
	go func() {
		for _, line := range bytes.Split(input, []byte("\n")) {
			if len(line) == 0 {
				continue
			}
			_, _ = master.Write(line)
			time.Sleep(120 * time.Millisecond)
			_, _ = master.Write([]byte("\r"))
			time.Sleep(200 * time.Millisecond)
		}
	}()

	// 把 PTY 输出转发到 stdout, 子进程退出后关闭 master 让 copy 结束。
	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(os.Stdout, master)
		close(done)
	}()

	_ = cmd.Wait()
	_ = master.Close()
	<-done

	if code := cmd.ProcessState.ExitCode(); code != 0 {
		os.Exit(code)
	}
}
