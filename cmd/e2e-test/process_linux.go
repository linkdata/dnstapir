//go:build linux

package main

import (
	"os/exec"
	"syscall"
)

func configureSupervisedCommand(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setpgid:   true,
		Pdeathsig: syscall.SIGTERM,
	}
}
