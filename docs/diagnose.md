# Diagnose

```sh
github-agent-auth status
github-agent-auth doctor
github-agent-auth self-test
github-agent-auth permissions
```

`status` shows the configured App and service state. `doctor` checks the service,
protected executables, wrappers, and Git configuration. Privileged decisions are logged
in `/var/log/github-agent-auth.log`.
