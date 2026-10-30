# Security policy

## Supported versions

Oriel has no tagged releases yet. Security fixes land on the `main` branch.

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report them privately through GitHub's [private vulnerability reporting](https://github.com/a-khalid/oriel/security/advisories/new) for this repository. Include:

- a description of the issue and its impact
- steps to reproduce, or a proof of concept
- the host macOS version and the guest system involved, if any

You should get a first reply within a week. Once a fix is ready we will publish an advisory and credit you, unless you prefer to stay anonymous.

## Scope

Oriel runs guests through Apple's Virtualization.framework. Issues in the framework itself, or in a guest operating system, should go to Apple or to that system's vendor. Issues in how Oriel configures machines, handles files in a machine bundle, downloads restore images, or builds installation media are in scope.
