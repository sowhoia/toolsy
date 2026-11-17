# Security policy

## Reporting a vulnerability

Report vulnerabilities privately, never in a public issue or pull request: open the repository's
**Security** tab and choose **Report a vulnerability**. Only you and the maintainers see the report,
and it is discussed there until a fix is released.

Say what an attacker can do and from where (another user account, a process of the same user, a
mod, a file the user opens), the versions of Toolsy and macOS, and the steps or a proof of concept
that show it.

## Scope

In scope:

- **The privileged helper and its XPC interface**: `/Library/PrivilegedHelperTools/app.toolsy.helper`,
  which runs as root, the checks of who may connect to it, what it accepts and what it runs, and the
  script that installs and removes it.
- **Installing and approving mods**: the checks of a package, the confirmation that lists the
  commands a mod will run as root, the approved copies the helper keeps, and the refusal of a mod's
  root commands once its files have changed or it has been removed.
- **toolsy-mod**, the command line tool in `Toolsy.app/Contents/Helpers`.

What a mod does with the access its user confirmed at installation is the mod's own behaviour, not
a vulnerability of Toolsy, unless Toolsy let it do more than the confirmation said.

## Supported versions

Fixes are made for the latest release only; update to it before you report.

## Threat model

What the privileged part of Toolsy defends against, and what it does not, is described under
[Privileged execution](docs/ARCHITECTURE.md#privileged-execution) in the architecture document.
