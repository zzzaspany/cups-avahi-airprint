# About this fork

This is a fork of [chuckcharlie/cups-avahi-airprint](https://github.com/chuckcharlie/cups-avahi-airprint),
itself a fork of [quadportnick/docker-cups-airprint](https://github.com/quadportnick/docker-cups-airprint).
It exists for one reason: **upstream's source is maintained, but its published image is not.**

## Why it exists

Upstream builds in AWS CodeBuild (`buildspec.yml`) and publishes to Docker Hub. That pipeline has
stopped producing images:

| | |
|---|---|
| newest tag on Docker Hub | `2.1.3`, pushed 2026-06-17 |
| `version.txt` on upstream `master` | `2.2.0` |
| commits to upstream `master` since that image | many, including CUPS config parsing fixes |

So the only image anyone can pull is a frozen snapshot of Alpine edge as it stood in June. The
Dockerfile pins `FROM alpine:3.20` but appends the three Alpine `edge` repositories on top, so what
lands in the image is whatever edge held *on build day*. An image nobody rebuilds therefore rots
without a single commit landing: by 2026-11-18 the `2.1.3` image carried 152 findings at HIGH or
CRITICAL, **all 152 of them with a fix already published by Alpine**, 21 of them CRITICAL.

Nothing upstream did is wrong here. The packages are fixed; the fix just never got built.

## What this fork changes

Three things, and deliberately nothing else — the value is in building the same Dockerfile
recently, not in rewriting someone's working build.

1. **`.github/workflows/build-push.yml`** — builds on GitHub's runners and publishes to
   `ghcr.io`, weekly as well as on every push, with a smoke test and a Trivy gate that both run
   *before* anything is pushed. The workflow file carries its own reasoning in comments.

2. **`hplip` is no longer installed.** It is HP's driver stack and it brought ten CRITICAL CVEs
   (`CVE-2026-91097` … `CVE-2026-91106`) with it, each firing twice because `hplip` and
   `hplip-libs` both carry it. Nothing in the image depends on it, no script under `root/`
   references it, and dropping it removes the `hp` CUPS backend while leaving fourteen others.
   Re-add it if you front an HP printer; the Dockerfile says so at the point of removal.
   The images this fork was built for drive a Brother laser through `brlaser`, which the
   Dockerfile compiles from source and which the CI smoke test asserts is present.

3. **`run_cups.sh` no longer traces the admin password.** The script runs under `set -x`, which
   traces each command with its arguments already expanded, so the credential block printed
   `CUPSPASSWORD` in clear text on every start — twice, once as `+ '[' -z <password> ]` and once
   as `+ echo <user>:<password>`. On the host this fork was made for that had left 20 copies of
   the password in the journal, the oldest a month old. Tracing is now off for that block and
   restored immediately after.

   CI asserts it stays off, with two positive controls alongside the absence check: a test that
   only greps for a missing secret passes just as happily when the log is empty or the block was
   deleted, so the job also requires evidence that the block ran and that tracing came back.

   The same change quotes the expansions and uses `printf` instead of `echo`. Unquoted, a password
   containing whitespace or a glob character was mangled before it reached `chpasswd`. That is a
   deviation from upstream behaviour and an intentional one.

## Tags

| tag | what it is |
|---|---|
| `2.2.0` | upstream's `version.txt` |
| `2.2.0-<YYYYMMDD>` | **pin this.** Same bytes until you choose to move |
| `latest` | convenience |
| `sha-<short>` | traceable to a commit |

Pin the dated tag rather than `latest`. A pinned image will eventually go red in your own
vulnerability scan as it ages, and that is the signal to bump it — which is better than an
unattended auto-update moving a printing service while someone is printing.

## Keeping up with upstream

```bash
git remote add upstream https://github.com/chuckcharlie/cups-avahi-airprint.git
git fetch upstream
git merge upstream/master
```

Two conflicts are expected and intended: the `apk add` list, where upstream still installs
`hplip`, and the credential block in `root/root/run_cups.sh`. Resolve both by keeping the fork's
version. CI asserts `hplip` is absent and that the password does not reach the log, so a merge
that undoes either one fails rather than quietly shipping it.

## Licence

Upstream is GPL-3.0 and so is this fork; `LICENSE` is unchanged. Publishing a built image from
modified sources is exactly what the licence contemplates, and the modified sources are this
public repository.

## The better fix

The ideal outcome is that this fork becomes unnecessary: upstream has 224 stars, no GitHub Actions
workflow at all, and a build pipeline that has quietly stopped publishing. The workflow here is
offered upstream rather than kept private, and if it lands, pulling upstream's own image becomes
the right answer again.
